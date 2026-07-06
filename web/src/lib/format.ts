// Money is bigint cents in the DB; the UI always shows whole KSh.
export function fmtKes(cents: number): string {
  return `KSh ${Math.round(cents / 100).toLocaleString("en-KE")}`;
}

export function savingsPercent(seatCents: number, soloCents: number): number {
  return Math.round((1 - seatCents / soloCents) * 100);
}

// Accepts 07XX/01XX, 2547XX, +2547XX → E.164, or null if not a Kenyan mobile.
export function normalizeKenyanPhone(input: string): string | null {
  const d = input.replace(/[\s-]/g, "");
  if (/^\+254(7|1)\d{8}$/.test(d)) return d;
  if (/^254(7|1)\d{8}$/.test(d)) return `+${d}`;
  if (/^0(7|1)\d{8}$/.test(d)) return `+254${d.slice(1)}`;
  return null;
}
