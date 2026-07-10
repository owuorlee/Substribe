// POST /notifications-worker — drains the notifications outbox.
// Schedule every minute; auth via x-cron-secret. Claiming is atomic
// (SELECT FOR UPDATE SKIP LOCKED in claim_notifications), so overlapping runs
// never double-send. Spec: SCOPE.md §7 (SubBot messaging surface).

import { json, serviceClient } from "../_shared/util.ts";
import { renderNotification } from "../_shared/templates.ts";
import { sendMessage, type Channel } from "../_shared/messaging.ts";

interface Claimed {
  id: string;
  channel: string;
  template: string;
  payload: Record<string, unknown>;
  phone: string | null;
  language: string | null;
  attempts: number;
}

Deno.serve(async (req) => {
  if (req.headers.get("x-cron-secret") !== Deno.env.get("CRON_SECRET")) {
    return json(401, { error: "unauthorized" });
  }

  const db = serviceClient();
  const { data, error } = await db.rpc("claim_notifications", { p_limit: 30 });
  if (error) {
    console.error("claim_notifications failed:", error.message);
    return json(500, { error: "claim_failed" });
  }

  const claimed = (data ?? []) as Claimed[];
  let sent = 0;
  let failed = 0;

  for (const c of claimed) {
    const body = renderNotification(c.template, c.payload, c.language);

    // A row we can never deliver (unknown template, no phone) shouldn't churn
    // the retry loop — fail it hard so it lands in 'failed' after backoff.
    if (!body) {
      await db.rpc("notification_mark_failed", {
        p_id: c.id,
        p_error: `no template for "${c.template}"`,
      });
      failed++;
      continue;
    }
    if (!c.phone) {
      await db.rpc("notification_mark_failed", { p_id: c.id, p_error: "recipient has no phone" });
      failed++;
      continue;
    }

    const requested: Channel = c.channel === "sms" ? "sms" : "whatsapp";
    try {
      const outcome = await sendMessage(requested, c.phone, body);
      // 'log' deliveries record as the requested channel for a clean audit.
      const recorded = outcome.channel === "log" ? requested : outcome.channel;
      await db.rpc("notification_mark_sent", {
        p_id: c.id,
        p_external_id: outcome.externalId,
        p_channel: recorded,
      });
      sent++;
    } catch (e) {
      await db.rpc("notification_mark_failed", { p_id: c.id, p_error: String(e) });
      failed++;
    }
  }

  return json(200, { claimed: claimed.length, sent, failed });
});
