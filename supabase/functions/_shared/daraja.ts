// Daraja (M-Pesa) API client — the only place that talks to Safaricom.
// Spec: docs/PAYMENTS.md. Sandbox until the production paybill exists.

const ENV = Deno.env.get("DARAJA_ENV") === "production" ? "production" : "sandbox";
const BASE = ENV === "production"
  ? "https://api.safaricom.co.ke"
  : "https://sandbox.safaricom.co.ke";

export class DarajaError extends Error {
  constructor(message: string, public readonly raw: unknown) {
    super(message);
    this.name = "DarajaError";
  }
}

let cachedToken: { token: string; expiresAt: number } | null = null;

export async function darajaToken(): Promise<string> {
  if (cachedToken && Date.now() < cachedToken.expiresAt) return cachedToken.token;

  const key = Deno.env.get("DARAJA_CONSUMER_KEY");
  const secret = Deno.env.get("DARAJA_CONSUMER_SECRET");
  if (!key || !secret) throw new DarajaError("Daraja credentials not configured", null);

  const res = await fetch(`${BASE}/oauth/v1/generate?grant_type=client_credentials`, {
    headers: { Authorization: `Basic ${btoa(`${key}:${secret}`)}` },
  });
  if (!res.ok) throw new DarajaError(`auth failed: HTTP ${res.status}`, await res.text());

  const body = await res.json();
  // Token lives ~3599s; cache for 50 min (PAYMENTS.md §1).
  cachedToken = { token: body.access_token, expiresAt: Date.now() + 50 * 60 * 1000 };
  return cachedToken.token;
}

// Daraja expects EAT (UTC+3) timestamps, yyyyMMddHHmmss.
function eatTimestamp(): string {
  return new Date(Date.now() + 3 * 60 * 60 * 1000)
    .toISOString()
    .replace(/\D/g, "")
    .slice(0, 14);
}

// E.164 (+2547XXXXXXXX / +2541XXXXXXXX) → Daraja's bare 254 form.
export function toDarajaPhone(e164: string): string {
  const digits = e164.replace(/^\+/, "");
  if (!/^254(7|1)\d{8}$/.test(digits)) {
    throw new DarajaError("phone must be a Kenyan mobile number", e164);
  }
  return digits;
}

export interface StkPushResult {
  checkoutRequestId: string;
  merchantRequestId: string;
  customerMessage: string;
  raw: Record<string, unknown>;
}

export async function stkPush(args: {
  phone: string; // Daraja 254... form
  amountKes: number; // whole shillings
  accountReference: string;
  description: string;
  callbackUrl: string;
}): Promise<StkPushResult> {
  if (!Number.isInteger(args.amountKes) || args.amountKes < 1) {
    throw new DarajaError("amount must be whole shillings >= 1", args.amountKes);
  }
  const shortcode = Deno.env.get("DARAJA_SHORTCODE");
  const passkey = Deno.env.get("DARAJA_PASSKEY");
  if (!shortcode || !passkey) throw new DarajaError("shortcode/passkey not configured", null);

  const timestamp = eatTimestamp();
  const token = await darajaToken();

  const res = await fetch(`${BASE}/mpesa/stkpush/v1/processrequest`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      BusinessShortCode: shortcode,
      Password: btoa(`${shortcode}${passkey}${timestamp}`),
      Timestamp: timestamp,
      TransactionType: "CustomerPayBillOnline",
      Amount: args.amountKes,
      PartyA: args.phone,
      PartyB: shortcode,
      PhoneNumber: args.phone,
      CallBackURL: args.callbackUrl,
      AccountReference: args.accountReference.slice(0, 12),
      TransactionDesc: args.description.slice(0, 13),
    }),
  });

  const body = await res.json().catch(() => ({} as Record<string, unknown>));
  if (!res.ok || body.ResponseCode !== "0") {
    throw new DarajaError(
      String(body.errorMessage ?? body.ResponseDescription ?? `HTTP ${res.status}`),
      body,
    );
  }
  return {
    checkoutRequestId: body.CheckoutRequestID as string,
    merchantRequestId: body.MerchantRequestID as string,
    customerMessage: (body.CustomerMessage as string) ?? "",
    raw: body,
  };
}

export interface StkQueryResult {
  stillProcessing: boolean;
  resultCode: number | null;
  resultDesc: string;
  raw: Record<string, unknown>;
}

export async function stkQuery(checkoutRequestId: string): Promise<StkQueryResult> {
  const shortcode = Deno.env.get("DARAJA_SHORTCODE")!;
  const passkey = Deno.env.get("DARAJA_PASSKEY")!;
  const timestamp = eatTimestamp();
  const token = await darajaToken();

  const res = await fetch(`${BASE}/mpesa/stkpushquery/v1/query`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      BusinessShortCode: shortcode,
      Password: btoa(`${shortcode}${passkey}${timestamp}`),
      Timestamp: timestamp,
      CheckoutRequestID: checkoutRequestId,
    }),
  });

  const body = await res.json().catch(() => ({} as Record<string, unknown>));
  if (!res.ok) {
    // "The transaction is being processed" — not an error, just not done yet.
    if (body.errorCode === "500.001.1001") {
      return {
        stillProcessing: true,
        resultCode: null,
        resultDesc: String(body.errorMessage ?? "processing"),
        raw: body,
      };
    }
    throw new DarajaError(String(body.errorMessage ?? `HTTP ${res.status}`), body);
  }
  return {
    stillProcessing: false,
    resultCode: Number(body.ResultCode),
    resultDesc: String(body.ResultDesc ?? ""),
    raw: body,
  };
}
