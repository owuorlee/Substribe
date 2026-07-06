import Link from "next/link";
import { isSupabaseConfigured, supabaseServer } from "@/lib/supabase/server";
import SetupNotice from "@/components/SetupNotice";
import TrustCard, { type OwnerTrust } from "@/components/TrustCard";
import { fmtKes, savingsPercent } from "@/lib/format";
import PayForm from "./PayForm";

export const dynamic = "force-dynamic";

interface SeatRow {
  id: string;
  status: string;
  listing: {
    id: string;
    owner_id: string;
    status: string;
    seat_price_cents: number;
    invite_sla_hours: number;
    service: {
      name: string;
      official_solo_price_cents: number | null;
      platform_fee_bps: number;
      insurance_fee_bps: number;
    } | null;
  } | null;
}

export default async function JoinPage({
  params,
}: {
  params: Promise<{ seatId: string }>;
}) {
  if (!isSupabaseConfigured()) return <SetupNotice />;
  const { seatId } = await params;
  const supabase = await supabaseServer();

  const { data: { user } } = await supabase.auth.getUser();

  const { data } = await supabase
    .from("seats")
    .select(
      "id, status, listing:listings(id, owner_id, status, seat_price_cents, invite_sla_hours, service:services(name, official_solo_price_cents, platform_fee_bps, insurance_fee_bps))",
    )
    .eq("id", seatId)
    .maybeSingle();

  const seat = data as unknown as SeatRow | null;

  if (!seat || !seat.listing || seat.listing.status !== "active") {
    return (
      <main className="mx-auto w-full max-w-md flex-1 px-6 py-20 text-center">
        <h1 className="text-xl font-bold">Seat not found</h1>
        <p className="mt-2 text-sm text-stone-600">
          This seat may have been taken or the listing removed.
        </p>
        <Link
          href="/browse"
          className="mt-6 inline-block rounded-xl bg-brand px-6 py-3 font-semibold text-white"
        >
          Browse open seats
        </Link>
      </main>
    );
  }

  // 'reserved' stays joinable: a buyer retrying a failed payment lands here,
  // and the RPC rejects anyone who isn't the reservation holder.
  if (seat.status !== "open" && seat.status !== "reserved") {
    return (
      <main className="mx-auto w-full max-w-md flex-1 px-6 py-20 text-center">
        <h1 className="text-xl font-bold">This seat is taken</h1>
        <p className="mt-2 text-sm text-stone-600">
          Someone got here first — but seats open up all the time.
        </p>
        <Link
          href="/browse"
          className="mt-6 inline-block rounded-xl bg-brand px-6 py-3 font-semibold text-white"
        >
          Find another seat
        </Link>
      </main>
    );
  }

  const listing = seat.listing;
  const service = listing.service;
  const price = listing.seat_price_cents;
  const platformFee = service
    ? Math.floor((price * (service.platform_fee_bps + service.insurance_fee_bps)) / 10000)
    : 0;
  const ownerTake = price - platformFee;
  const solo = service?.official_solo_price_cents ?? null;

  const { data: ownerRow } = await supabase
    .from("owner_public_profiles")
    .select("*")
    .eq("id", listing.owner_id)
    .maybeSingle();
  const owner = ownerRow as OwnerTrust | null;

  let profilePhone: string | null = null;
  if (user) {
    const { data: profile } = await supabase
      .from("profiles")
      .select("phone")
      .eq("id", user.id)
      .maybeSingle();
    profilePhone = profile?.phone ?? null;
  }

  return (
    <main className="mx-auto w-full max-w-md flex-1 px-6 py-10">
      <p className="text-sm font-semibold uppercase tracking-wider text-brand">
        Join a seat
      </p>
      <h1 className="mt-1 text-2xl font-bold">{service?.name ?? "Plan"}</h1>

      {/* Price + full fee transparency — no hidden cuts, ever. */}
      <div className="mt-6 rounded-2xl border border-stone-200 bg-white p-5 shadow-sm">
        <div className="flex items-baseline justify-between">
          <span className="text-3xl font-bold text-brand-strong">
            {fmtKes(price)}
            <span className="text-base font-normal text-stone-500">/month</span>
          </span>
          {solo && (
            <span className="rounded-full bg-amber-50 px-3 py-1 text-sm font-semibold text-amber-700">
              save {savingsPercent(price, solo)}%
            </span>
          )}
        </div>
        <dl className="mt-4 space-y-1.5 border-t border-stone-100 pt-4 text-sm">
          <div className="flex justify-between">
            <dt className="text-stone-500">Plan owner receives</dt>
            <dd className="font-medium">{fmtKes(ownerTake)}</dd>
          </div>
          <div className="flex justify-between">
            <dt className="text-stone-500">Substribe fee (incl. insurance)</dt>
            <dd className="font-medium">{fmtKes(platformFee)}</dd>
          </div>
        </dl>
      </div>

      {/* The escrow promise, exactly where hesitation happens. */}
      <div className="mt-4 flex gap-3 rounded-2xl bg-brand-soft/60 p-4 text-sm">
        <span aria-hidden className="text-lg">🔒</span>
        <p className="text-stone-700">
          <span className="font-semibold">Your money is held by Substribe</span>{" "}
          — the owner is only paid after you confirm your seat works. If the
          invite doesn&apos;t arrive within {listing.invite_sla_hours} hours,
          you get an automatic refund.
        </p>
      </div>

      {owner && (
        <div className="mt-4 rounded-2xl border border-stone-200 bg-white p-4">
          <p className="mb-3 text-xs font-semibold uppercase tracking-wider text-stone-400">
            Your plan owner
          </p>
          <TrustCard owner={owner} />
        </div>
      )}

      <div className="mt-6">
        {user ? (
          <PayForm
            seatId={seat.id}
            amountCents={price}
            defaultPhone={profilePhone ?? ""}
            slaHours={listing.invite_sla_hours}
          />
        ) : (
          <Link
            href={`/login?next=/join/${seat.id}`}
            className="block w-full rounded-xl bg-brand px-6 py-3.5 text-center font-semibold text-white transition hover:bg-brand-strong"
          >
            Sign in to join this seat
          </Link>
        )}
      </div>
    </main>
  );
}
