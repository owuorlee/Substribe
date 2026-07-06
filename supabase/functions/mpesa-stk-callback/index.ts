// POST /mpesa-stk-callback?pid={payment_id}&t={token} — Daraja STK webhook.
// Deploy with --no-verify-jwt (Safaricom sends no JWT); auth is the
// per-payment token (PAYMENTS.md §2.1). Two-phase: store the raw event, ack
// 200 immediately, process; the cron re-processes anything left unprocessed.
// We ALWAYS ack 200 — a non-200 makes Daraja retry against an endpoint that
// already has the event, and reveals which URLs are live.

import { json, serviceClient, sha256Hex } from "../_shared/util.ts";

const ack = () => json(200, { ResultCode: 0, ResultDesc: "Accepted" });

Deno.serve(async (req) => {
  if (req.method !== "POST") return ack();

  const url = new URL(req.url);
  const pid = url.searchParams.get("pid");
  const token = url.searchParams.get("t");

  let payload: unknown;
  try {
    payload = await req.json();
  } catch {
    return ack();
  }
  if (!pid || !token) {
    console.error("stk-callback: missing pid/token");
    return ack();
  }

  const db = serviceClient();

  // Token check — constant response either way, log for ops.
  const { data: payment } = await db.from("payments")
    .select("id, callback_token").eq("id", pid).maybeSingle();
  if (!payment || payment.callback_token !== token) {
    console.error(`stk-callback: token mismatch for payment ${pid}`);
    return ack();
  }

  const cb = (payload as Record<string, any>)?.Body?.stkCallback ?? {};
  const dedupeKey = await sha256Hex(
    `stk_callback:${cb.CheckoutRequestID ?? pid}:${cb.ResultCode ?? "?"}`,
  );

  const { data: inserted, error } = await db.from("payment_events")
    .insert({
      payment_id: pid,
      source: "stk_callback",
      dedupe_key: dedupeKey,
      payload,
    })
    .select("id")
    .maybeSingle();

  if (error) {
    // 23505 = duplicate replay: already ingested, nothing to do.
    if (error.code !== "23505") console.error("stk-callback: ingest failed", error.message);
    return ack();
  }

  if (inserted) {
    const { error: procErr } = await db.rpc("process_payment_event", {
      p_event_id: inserted.id,
    });
    // Processing failure is not a webhook failure — event is stored, the cron
    // sweep will retry it.
    if (procErr) console.error("stk-callback: processing deferred to cron:", procErr.message);
  }
  return ack();
});
