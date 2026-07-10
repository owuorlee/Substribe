// Notification copy. Keyed by the `template` column written in the payment
// engine (migration 0800). Bilingual: rendered per the recipient's
// preferred_language. Keep messages short — some land as SMS.

type Payload = Record<string, unknown>;
type Lang = "en" | "sw";

const kes = (cents: unknown) =>
  `KSh ${Math.round(Number(cents ?? 0) / 100).toLocaleString("en-KE")}`;
const n = (v: unknown) => Number(v ?? 0);

type Renderer = (p: Payload) => string;

const TEMPLATES: Record<string, Record<Lang, Renderer>> = {
  payment_received: {
    en: (p) =>
      `Payment received ✅ ${kes(p.amount_cents)} is held safely by Substribe until your seat works. Receipt ${p.receipt}. We've told the owner to send your invite.`,
    sw: (p) =>
      `Malipo yamepokelewa ✅ ${kes(p.amount_cents)} yamehifadhiwa salama na Substribe hadi kiti chako kianze kufanya kazi. Risiti ${p.receipt}. Tumemwambia mwenye kifurushi akualike.`,
  },
  invite_needed: {
    en: (p) =>
      `You've got a buyer! 🎉 Add ${p.invite_email} to your plan within ${n(p.sla_hours)}h and you'll earn ${kes(p.owner_take_cents)}. Open Substribe once done.`,
    sw: (p) =>
      `Umepata mnunuzi! 🎉 Mwongeze ${p.invite_email} kwenye kifurushi chako ndani ya saa ${n(p.sla_hours)} na utapata ${kes(p.owner_take_cents)}. Fungua Substribe ukimaliza.`,
  },
  confirm_access: {
    en: () =>
      `Your invite has been sent. Once you can log in, tap "I have access" in Substribe to finish. If it doesn't work, you'll be refunded — no questions.`,
    sw: () =>
      `Mwaliko wako umetumwa. Ukishaweza kuingia, gusa "Nina ufikiaji" kwenye Substribe kumaliza. Kama hakifanyi kazi, utarudishiwa pesa — bila maswali.`,
  },
  earnings_released: {
    en: (p) =>
      `Cha-ching 💰 ${kes(p.owner_take_cents)} released to your Substribe balance. Payouts to M-Pesa run every Friday.`,
    sw: (p) =>
      `Hongera 💰 ${kes(p.owner_take_cents)} yameongezwa kwenye salio lako la Substribe. Malipo kwa M-Pesa hufanyika kila Ijumaa.`,
  },
  refund_wallet_credited: {
    en: (p) => {
      const goodwill = n(p.goodwill_cents) > 0 ? ` (+${kes(p.goodwill_cents)} for the trouble)` : "";
      return `Refunded ✅ ${kes(p.amount_cents)} is back in your Substribe wallet${goodwill}. Sorry that seat didn't work out.`;
    },
    sw: (p) => {
      const goodwill = n(p.goodwill_cents) > 0 ? ` (+${kes(p.goodwill_cents)} kwa usumbufu)` : "";
      return `Umerudishiwa ✅ ${kes(p.amount_cents)} yamerudi kwenye pochi yako ya Substribe${goodwill}. Samahani kiti hicho hakikufaa.`;
    },
  },
  seat_reopened: {
    en: () =>
      `A seat on your listing reopened. We'll match a new member from the waitlist — no action needed.`,
    sw: () =>
      `Kiti kwenye tangazo lako kimefunguka tena. Tutapata mwanachama mpya kutoka orodha ya kusubiri — huhitaji kufanya chochote.`,
  },
  late_payment_refunded: {
    en: (p) =>
      `Your payment arrived after the seat had expired, so we've credited ${kes(p.amount_cents)} to your Substribe wallet. Use it on any seat.`,
    sw: (p) =>
      `Malipo yako yalifika baada ya kiti kuisha muda, kwa hivyo tumeweka ${kes(p.amount_cents)} kwenye pochi yako ya Substribe. Itumie kwenye kiti chochote.`,
  },
};

export function renderNotification(
  template: string,
  payload: Payload,
  language: string | null,
): string | null {
  const entry = TEMPLATES[template];
  if (!entry) return null;
  const lang: Lang = language === "sw" ? "sw" : "en";
  return (entry[lang] ?? entry.en)(payload);
}
