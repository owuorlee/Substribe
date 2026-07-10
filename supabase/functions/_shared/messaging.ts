// Messaging providers: WhatsApp Cloud API (primary) with Africa's Talking SMS
// fallback. DELIVERY_MODE lets local dev run without provider creds ("log").
//
//   whatsapp → WhatsApp only        sms → SMS only
//   auto     → WhatsApp, fall back to SMS on failure (default when configured)
//   log      → no send, console only (default when nothing is configured)

export type Channel = "whatsapp" | "sms";

export interface SendOutcome {
  channel: Channel | "log";
  externalId: string;
}

function mode(): "whatsapp" | "sms" | "auto" | "log" {
  const m = Deno.env.get("DELIVERY_MODE");
  if (m === "whatsapp" || m === "sms" || m === "auto" || m === "log") return m;
  const hasWa = Deno.env.get("WHATSAPP_TOKEN") && Deno.env.get("WHATSAPP_PHONE_NUMBER_ID");
  const hasSms = Deno.env.get("AT_API_KEY") && Deno.env.get("AT_USERNAME");
  if (hasWa && hasSms) return "auto";
  if (hasWa) return "whatsapp";
  if (hasSms) return "sms";
  return "log";
}

// WhatsApp wants MSISDN without '+'; Africa's Talking wants E.164 with '+'.
const bare = (e164: string) => e164.replace(/^\+/, "");

async function sendWhatsApp(phone: string, body: string): Promise<string> {
  const token = Deno.env.get("WHATSAPP_TOKEN")!;
  const phoneNumberId = Deno.env.get("WHATSAPP_PHONE_NUMBER_ID")!;
  const res = await fetch(`https://graph.facebook.com/v20.0/${phoneNumberId}/messages`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      messaging_product: "whatsapp",
      to: bare(phone),
      type: "text",
      text: { body },
    }),
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error(`whatsapp ${res.status}: ${JSON.stringify(json?.error ?? json)}`);
  }
  return json?.messages?.[0]?.id ?? "wa_sent";
}

async function sendSms(phone: string, body: string): Promise<string> {
  const apiKey = Deno.env.get("AT_API_KEY")!;
  const username = Deno.env.get("AT_USERNAME")!;
  const sender = Deno.env.get("AT_SENDER_ID") ?? "";
  const form = new URLSearchParams({ username, to: phone, message: body });
  if (sender) form.set("from", sender);
  const res = await fetch("https://api.africastalking.com/version1/messaging", {
    method: "POST",
    headers: {
      apiKey,
      "Content-Type": "application/x-www-form-urlencoded",
      Accept: "application/json",
    },
    body: form,
  });
  const json = await res.json().catch(() => ({}));
  const recipient = json?.SMSMessageData?.Recipients?.[0];
  if (!res.ok || !recipient || recipient.status !== "Success") {
    throw new Error(`sms: ${JSON.stringify(recipient ?? json)}`);
  }
  return recipient.messageId ?? "at_sent";
}

export async function sendMessage(
  requestedChannel: Channel,
  phone: string,
  body: string,
): Promise<SendOutcome> {
  const m = mode();

  if (m === "log") {
    console.log(`[notify:log] → ${phone}: ${body}`);
    return { channel: "log", externalId: `log_${crypto.randomUUID()}` };
  }

  const wantWhatsApp = requestedChannel === "whatsapp" && (m === "whatsapp" || m === "auto");

  if (wantWhatsApp) {
    try {
      return { channel: "whatsapp", externalId: await sendWhatsApp(phone, body) };
    } catch (e) {
      if (m !== "auto") throw e; // whatsapp-only: surface the failure
      console.warn(`whatsapp failed, falling back to sms: ${String(e)}`);
    }
  }

  return { channel: "sms", externalId: await sendSms(phone, body) };
}
