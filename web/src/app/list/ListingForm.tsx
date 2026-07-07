"use client";

import { useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { supabaseBrowser } from "@/lib/supabase/client";
import { fmtKes } from "@/lib/format";

export interface ListableService {
  id: string;
  name: string;
  seats_total: number;
  plan_price_cents: number;
  official_solo_price_cents: number | null;
  suggested_seat_price_cents: number | null;
  platform_fee_bps: number;
  insurance_fee_bps: number;
}

const ERRORS: Record<string, string> = {
  verification_required: "Your account isn't verified to host yet.",
  listing_limit_reached:
    "You already have a live listing. More listings unlock at the next verification tier.",
  price_above_solo:
    "Your seat price is higher than buying the plan solo — nobody would join. Lower it.",
  invalid_price: "Price must be whole shillings, at least KSh 50.",
  invalid_seat_count: "That's more seats than this plan can share.",
  service_not_active: "This service isn't open for listings right now.",
};

export default function ListingForm({ services }: { services: ListableService[] }) {
  const router = useRouter();
  const [serviceId, setServiceId] = useState(services[0]?.id ?? "");
  const service = useMemo(
    () => services.find((s) => s.id === serviceId) ?? services[0],
    [services, serviceId],
  );
  const maxSeats = service ? service.seats_total - 1 : 1;
  const [seats, setSeats] = useState(maxSeats);
  const [priceKes, setPriceKes] = useState(
    service?.suggested_seat_price_cents
      ? String(service.suggested_seat_price_cents / 100)
      : "",
  );
  const [agreed, setAgreed] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  if (!service) {
    return (
      <p className="rounded-2xl border border-dashed border-stone-300 bg-white p-6 text-center text-sm text-stone-600">
        No services are open for listings yet — check back soon.
      </p>
    );
  }

  function pickService(s: ListableService) {
    setServiceId(s.id);
    setSeats(s.seats_total - 1);
    setPriceKes(
      s.suggested_seat_price_cents ? String(s.suggested_seat_price_cents / 100) : "",
    );
    setError(null);
  }

  const priceCents = Math.round(Number(priceKes || "0")) * 100;
  const feeBps = service.platform_fee_bps + service.insurance_fee_bps;
  const takePerSeat = priceCents > 0 ? priceCents - Math.floor((priceCents * feeBps) / 10000) : 0;
  const monthlyWhenFull = takePerSeat * seats;
  const coverage =
    service.plan_price_cents > 0
      ? Math.round((monthlyWhenFull / service.plan_price_cents) * 100)
      : 0;

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);

    const kes = Number(priceKes);
    if (!Number.isInteger(kes) || kes < 50) {
      setError(ERRORS.invalid_price);
      return;
    }
    if (!agreed) {
      setError("Please agree to the host promise first.");
      return;
    }

    setBusy(true);
    const supabase = supabaseBrowser();
    const { error } = await supabase.rpc("create_listing", {
      p_service_id: service.id,
      p_seats_offered: seats,
      p_seat_price_cents: kes * 100,
    });
    setBusy(false);

    if (error) {
      const known = Object.keys(ERRORS).find((k) => error.message.includes(k));
      setError(known ? ERRORS[known] : "Couldn't create the listing — please try again.");
      return;
    }
    router.push("/dashboard?listed=1");
    router.refresh();
  }

  return (
    <form onSubmit={submit} className="space-y-5">
      {/* Service picker */}
      <fieldset>
        <legend className="text-sm font-medium">Which plan do you have?</legend>
        <div className="mt-2 space-y-2">
          {services.map((s) => (
            <label
              key={s.id}
              className={`flex cursor-pointer items-center justify-between rounded-xl border p-4 transition ${
                s.id === service.id
                  ? "border-brand bg-brand-soft/40 ring-2 ring-brand-soft"
                  : "border-stone-200 bg-white hover:border-stone-300"
              }`}
            >
              <span>
                <input
                  type="radio"
                  name="service"
                  checked={s.id === service.id}
                  onChange={() => pickService(s)}
                  className="sr-only"
                />
                <span className="font-semibold">{s.name}</span>
                <span className="mt-0.5 block text-xs text-stone-500">
                  {s.seats_total} accounts · you pay {fmtKes(s.plan_price_cents)}/mo
                </span>
              </span>
              {s.id === service.id && <span className="text-brand">✓</span>}
            </label>
          ))}
        </div>
      </fieldset>

      {/* Seats */}
      <label className="block">
        <span className="text-sm font-medium">Seats to offer</span>
        <div className="mt-2 flex items-center gap-4">
          <button
            type="button"
            onClick={() => setSeats(Math.max(1, seats - 1))}
            className="h-11 w-11 rounded-xl border border-stone-300 text-lg font-bold text-stone-600 hover:bg-stone-50"
            aria-label="Fewer seats"
          >
            −
          </button>
          <span className="w-10 text-center text-xl font-bold">{seats}</span>
          <button
            type="button"
            onClick={() => setSeats(Math.min(maxSeats, seats + 1))}
            className="h-11 w-11 rounded-xl border border-stone-300 text-lg font-bold text-stone-600 hover:bg-stone-50"
            aria-label="More seats"
          >
            +
          </button>
          <span className="text-xs text-stone-500">
            max {maxSeats} — one seat stays yours
          </span>
        </div>
      </label>

      {/* Price */}
      <label className="block">
        <span className="text-sm font-medium">Price per seat (KSh/month)</span>
        <input
          type="number"
          inputMode="numeric"
          min={50}
          step={1}
          required
          value={priceKes}
          onChange={(e) => setPriceKes(e.target.value)}
          className="mt-1 w-full rounded-xl border border-stone-300 bg-white px-4 py-3 text-lg outline-none focus:border-brand focus:ring-2 focus:ring-brand-soft"
        />
        {service.suggested_seat_price_cents && (
          <span className="mt-1 block text-xs text-stone-500">
            Suggested: {fmtKes(service.suggested_seat_price_cents)} — fills fastest
          </span>
        )}
      </label>

      {/* Earnings preview — the reason to list, made concrete. */}
      {priceCents >= 5000 && (
        <div className="rounded-2xl bg-brand-soft/60 p-4 text-sm">
          <p className="font-semibold text-brand-strong">
            You&apos;ll receive {fmtKes(monthlyWhenFull)}/month when full
          </p>
          <p className="mt-1 text-stone-700">
            {fmtKes(takePerSeat)} × {seats} seat{seats === 1 ? "" : "s"} after
            the Substribe fee —{" "}
            {coverage >= 100
              ? "your plan pays for itself, and then some."
              : `covers ${coverage}% of your ${fmtKes(service.plan_price_cents)} plan.`}
          </p>
        </div>
      )}

      {/* The host promise — this is what buyers are trusting. */}
      <label className="flex items-start gap-3 rounded-2xl border border-stone-200 bg-white p-4 text-sm">
        <input
          type="checkbox"
          checked={agreed}
          onChange={(e) => setAgreed(e.target.checked)}
          className="mt-0.5 h-5 w-5 accent-emerald-700"
        />
        <span className="text-stone-700">
          <span className="font-semibold">The host promise:</span> I&apos;ll
          send invites within 12 hours, keep the plan active, and never remove
          a paid member. I understand payouts pause if a member reports a
          problem.
        </span>
      </label>

      {error && (
        <p className="rounded-xl bg-red-50 px-4 py-3 text-sm text-red-700">{error}</p>
      )}

      <button
        type="submit"
        disabled={busy}
        className="w-full rounded-xl bg-brand px-6 py-4 text-lg font-semibold text-white shadow-lg transition hover:bg-brand-strong disabled:opacity-60"
      >
        {busy ? "Publishing…" : "Publish listing"}
      </button>
    </form>
  );
}
