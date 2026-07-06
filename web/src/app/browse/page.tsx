import Link from "next/link";
import { isSupabaseConfigured, supabaseServer } from "@/lib/supabase/server";
import SetupNotice from "@/components/SetupNotice";
import TrustCard, { type OwnerTrust } from "@/components/TrustCard";
import { fmtKes, savingsPercent } from "@/lib/format";

export const dynamic = "force-dynamic";

interface ListingRow {
  id: string;
  owner_id: string;
  seat_price_cents: number;
  invite_sla_hours: number;
  seats: { id: string; status: string }[];
  service: {
    name: string;
    slug: string;
    official_solo_price_cents: number | null;
  } | null;
}

export default async function BrowsePage() {
  if (!isSupabaseConfigured()) return <SetupNotice />;
  const supabase = await supabaseServer();

  const { data, error } = await supabase
    .from("listings")
    .select(
      "id, owner_id, seat_price_cents, invite_sla_hours, seats(id, status), service:services(name, slug, official_solo_price_cents)",
    )
    .eq("status", "active")
    .order("created_at", { ascending: true });

  const listings = ((data ?? []) as unknown as ListingRow[])
    .map((l) => ({ ...l, openSeats: l.seats.filter((s) => s.status === "open") }))
    .filter((l) => l.openSeats.length > 0);

  const ownerIds = [...new Set(listings.map((l) => l.owner_id))];
  const owners = new Map<string, OwnerTrust>();
  if (ownerIds.length > 0) {
    const { data: ownerRows } = await supabase
      .from("owner_public_profiles")
      .select("*")
      .in("id", ownerIds);
    for (const o of (ownerRows ?? []) as OwnerTrust[]) owners.set(o.id, o);
  }

  return (
    <main className="mx-auto w-full max-w-3xl flex-1 px-6 py-10">
      <h1 className="text-2xl font-bold sm:text-3xl">Open seats</h1>
      <p className="mt-2 text-sm text-stone-600">
        Every seat is escrow-protected: the owner is only paid after you
        confirm your access works.
      </p>

      {error && (
        <p className="mt-6 rounded-xl bg-red-50 px-4 py-3 text-sm text-red-700">
          Couldn&apos;t load listings — please refresh.
        </p>
      )}

      {!error && listings.length === 0 && (
        <div className="mt-10 rounded-2xl border border-dashed border-stone-300 bg-white p-10 text-center">
          <p className="font-semibold">No open seats right now</p>
          <p className="mt-1 text-sm text-stone-600">
            Seats go fast — new ones open when owners list their plans.
          </p>
        </div>
      )}

      <ul className="mt-6 space-y-4">
        {listings.map((l) => {
          const owner = owners.get(l.owner_id);
          const solo = l.service?.official_solo_price_cents ?? null;
          return (
            <li
              key={l.id}
              className="rounded-2xl border border-stone-200 bg-white p-5 shadow-sm"
            >
              <div className="flex items-start justify-between gap-4">
                <div>
                  <h2 className="font-semibold">{l.service?.name ?? "Plan"}</h2>
                  <p className="mt-0.5 text-sm text-stone-500">
                    {l.openSeats.length} seat{l.openSeats.length === 1 ? "" : "s"} open
                  </p>
                </div>
                <div className="text-right">
                  <p className="text-lg font-bold text-brand-strong">
                    {fmtKes(l.seat_price_cents)}
                    <span className="text-sm font-normal text-stone-500">/mo</span>
                  </p>
                  {solo && (
                    <p className="text-xs text-stone-500">
                      <span className="line-through">{fmtKes(solo)}</span>{" "}
                      <span className="font-semibold text-accent">
                        save {savingsPercent(l.seat_price_cents, solo)}%
                      </span>
                    </p>
                  )}
                </div>
              </div>

              <div className="mt-4 flex items-end justify-between gap-4 border-t border-stone-100 pt-4">
                {owner ? (
                  <TrustCard owner={owner} />
                ) : (
                  <span className="text-sm text-stone-400">Substribe member</span>
                )}
                <Link
                  href={`/join/${l.openSeats[0].id}`}
                  className="shrink-0 rounded-xl bg-brand px-5 py-2.5 text-sm font-semibold text-white transition hover:bg-brand-strong"
                >
                  Join seat
                </Link>
              </div>
            </li>
          );
        })}
      </ul>
    </main>
  );
}
