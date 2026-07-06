// POST /mpesa-stk-initiate — buyer starts a seat join.
// Body: { seat_id: uuid, invite_email: string, phone?: "+2547..." }
// Reserves the seat + creates membership/payment atomically (RPC), then sends
// the STK push. Spec: docs/PAYMENTS.md §3.

import { json, serviceClient, userClient } from "../_shared/util.ts";
import { DarajaError, stkPush, toDarajaPhone } from "../_shared/daraja.ts";

// Postgres RAISE codes → HTTP + human copy. Trust rule: the buyer must always
// know whether their money moved.
const KNOWN_ERRORS: Record<string, { status: number; message: string }> = {
  seat_unavailable: { status: 409, message: "Someone just took this seat. Join the waitlist and we'll match you to the next one." },
  payment_pending: { status: 409, message: "There's already an M-Pesa prompt on your phone — enter your PIN there." },
  already_paid: { status: 409, message: "You've already paid for this seat. Check your dashboard." },
  cannot_join_own_listing: { status: 400, message: "You can't join your own listing." },
  listing_not_active: { status: 409, message: "This listing is no longer active." },
  service_not_active: { status: 409, message: "This service isn't available right now." },
  buyer_not_eligible: { status: 403, message: "Your account can't make purchases right now. Contact support." },
  invalid_phone: { status: 400, message: "Enter a valid Kenyan mobile number (07XX or 01XX)." },
  invalid_email: { status: 400, message: "Enter a valid email — it's where your invite will be sent." },
};

Deno.serve(async (req) => {
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });

  const { data: { user } } = await userClient(req.headers.get("Authorization") ?? "")
    .auth.getUser();
  if (!user) return json(401, { error: "not_authenticated" });

  let body: { seat_id?: string; invite_email?: string; phone?: string };
  try {
    body = await req.json();
  } catch {
    return json(400, { error: "invalid_json" });
  }
  if (!body.seat_id || !body.invite_email) {
    return json(400, { error: "missing_fields", message: "seat_id and invite_email are required." });
  }

  const db = serviceClient();

  let phone = body.phone;
  if (!phone) {
    const { data: profile } = await db.from("profiles")
      .select("phone").eq("id", user.id).single();
    phone = profile?.phone ?? undefined;
  }
  if (!phone) {
    return json(400, { error: "no_phone", message: "Add your M-Pesa number to your profile first." });
  }

  let darajaPhone: string;
  try {
    darajaPhone = toDarajaPhone(phone);
  } catch {
    return json(400, { error: "invalid_phone", message: KNOWN_ERRORS.invalid_phone.message });
  }

  const { data, error } = await db.rpc("reserve_seat_and_start_join", {
    p_seat_id: body.seat_id,
    p_buyer_id: user.id,
    p_invite_email: body.invite_email.trim().toLowerCase(),
    p_phone: phone,
  });
  if (error) {
    for (const [code, resp] of Object.entries(KNOWN_ERRORS)) {
      if (error.message.includes(code)) return json(resp.status, { error: code, message: resp.message });
    }
    console.error("reserve_seat_and_start_join failed:", error.message);
    return json(500, { error: "internal", message: "Something went wrong. Your money has NOT moved." });
  }

  const r = Array.isArray(data) ? data[0] : data;
  const callbackBase = Deno.env.get("CALLBACK_BASE_URL") ??
    `${Deno.env.get("SUPABASE_URL")}/functions/v1`;
  const callbackUrl =
    `${callbackBase}/mpesa-stk-callback?pid=${r.payment_id}&t=${r.callback_token}`;

  try {
    const stk = await stkPush({
      phone: darajaPhone,
      amountKes: r.amount_cents / 100,
      accountReference: r.account_reference,
      description: "Substribe",
      callbackUrl,
    });
    await db.rpc("record_stk_initiated", {
      p_payment_id: r.payment_id,
      p_checkout_request_id: stk.checkoutRequestId,
      p_merchant_request_id: stk.merchantRequestId,
      p_raw: stk.raw,
    });
    return json(200, {
      payment_id: r.payment_id,
      status: "pending",
      message: stk.customerMessage || "Check your phone and enter your M-Pesa PIN.",
    });
  } catch (e) {
    const reason = e instanceof DarajaError ? e.message : String(e);
    await db.rpc("record_stk_request_failed", {
      p_payment_id: r.payment_id,
      p_reason: reason,
    });
    console.error("STK push failed:", reason);
    return json(502, {
      error: "mpesa_unavailable",
      message: "M-Pesa isn't responding right now. Your money has NOT moved — please try again in a minute.",
    });
  }
});
