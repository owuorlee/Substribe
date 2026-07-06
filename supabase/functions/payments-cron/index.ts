// POST /payments-cron — the payments heartbeat (PAYMENTS.md §8).
// Schedule every minute; auth via x-cron-secret header. Every step is
// idempotent and independently safe to double-fire, so overlap is harmless.
//
//   1. re-process any unprocessed payment_events (crashed worker recovery)
//   2. STK status queries for stale pending payments; >10 min → timeout
//   3. expire stale seat reservations
//   4. invite-SLA breaches → refund to wallet + reopen seat
//   5. 48h silent-buyer escrow auto-release

import { json, serviceClient, sha256Hex } from "../_shared/util.ts";
import { stkQuery } from "../_shared/daraja.ts";

Deno.serve(async (req) => {
  if (req.headers.get("x-cron-secret") !== Deno.env.get("CRON_SECRET")) {
    return json(401, { error: "unauthorized" });
  }

  const db = serviceClient();
  const summary: Record<string, unknown> = {};

  // 1 — unprocessed events
  const { data: events } = await db.from("payment_events")
    .select("id").eq("processed", false).order("id").limit(100);
  let reprocessed = 0;
  for (const e of events ?? []) {
    const { error } = await db.rpc("process_payment_event", { p_event_id: e.id });
    if (error) console.error(`cron: event ${e.id} failed:`, error.message);
    else reprocessed++;
  }
  summary.events_processed = reprocessed;

  // 2 — STK status queries
  const { data: stale, error: staleErr } = await db.rpc("payments_needing_stk_query");
  if (staleErr) {
    summary.stk_queries = `error: ${staleErr.message}`;
  } else {
    let queried = 0, resolved = 0, timedOut = 0;
    for (const p of stale ?? []) {
      try {
        const q = await stkQuery(p.checkout_request_id);
        await db.from("payments")
          .update({ status_checked_at: new Date().toISOString() })
          .eq("id", p.payment_id);
        queried++;

        if (q.stillProcessing) {
          const ageMs = Date.now() - new Date(p.created_at).getTime();
          if (ageMs > 10 * 60 * 1000) {
            await db.rpc("mark_payment_timeout", { p_payment_id: p.payment_id });
            timedOut++;
          }
          continue;
        }

        // Definitive result → synthesize an event through the same processor
        // as callbacks. NB: query success carries no receipt, so the processor
        // parks it for the late callback / reconciliation (LEDGER.md rule 4);
        // failures resolve immediately.
        const synthetic = {
          Body: {
            stkCallback: {
              CheckoutRequestID: p.checkout_request_id,
              ResultCode: q.resultCode,
              ResultDesc: q.resultDesc,
            },
          },
        };
        const dedupeKey = await sha256Hex(
          `status_query:${p.checkout_request_id}:${q.resultCode}`,
        );
        const { data: ev, error: insErr } = await db.from("payment_events")
          .insert({
            payment_id: p.payment_id,
            source: "status_query",
            dedupe_key: dedupeKey,
            payload: synthetic,
          })
          .select("id")
          .maybeSingle();
        if (ev) {
          await db.rpc("process_payment_event", { p_event_id: ev.id });
          resolved++;
        } else if (insErr && insErr.code !== "23505") {
          console.error(`cron: synthetic event insert failed:`, insErr.message);
        }
      } catch (e) {
        console.error(`cron: stk query failed for ${p.payment_id}:`, String(e));
      }
    }
    summary.stk_queries = { queried, resolved, timed_out: timedOut };
  }

  // 3–5 — SQL sweeps
  const sweeps: Array<[string, string]> = [
    ["reservations_expired", "expire_stale_reservations"],
    ["invite_sla_refunds", "sweep_invite_sla"],
    ["escrow_auto_released", "auto_release_confirmed_silent"],
  ];
  for (const [key, fn] of sweeps) {
    const { data, error } = await db.rpc(fn);
    summary[key] = error ? `error: ${error.message}` : data;
    if (error) console.error(`cron: ${fn} failed:`, error.message);
  }

  return json(200, summary);
});
