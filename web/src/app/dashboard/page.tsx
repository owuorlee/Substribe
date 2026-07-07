import { redirect } from "next/navigation";
import { isSupabaseConfigured, supabaseServer } from "@/lib/supabase/server";
import SetupNotice from "@/components/SetupNotice";
import { fmtKes } from "@/lib/format";
import { ConfirmAccessButton, MarkInvitedButton } from "./actions";

export const dynamic = "force-dynamic";

interface MembershipRow {
  id: string;
  status: string;
  seat_price_cents: number;
  current_period_end: string | null;
  seat: {
    id: string;
    status: string;
    invite_email: string | null;
    listing: { service: { name: string } | null } | null;
  } | null;
}

interface OwnerListingRow {
  id: string;
  status: string;
  seat_price_cents: number;
  service: { name: string } | null;
  seats: {
    id: string;
    status: string;
    invite_email: string | null;
    memberships: { id: string; status: string }[];
  }[];
}

const seatStatusCopy: Record<string, { label: string; tone: string }> = {
  reserved: { label: "Awaiting invite", tone: "bg-amber-50 text-amber-700" },
  invited: { label: "Invite sent — confirm it", tone: "bg-blue-50 text-blue-700" },
  active: { label: "Active", tone: "bg-emerald-50 text-emerald-700" },
  suspended: { label: "Suspended", tone: "bg-red-50 text-red-700" },
};

export default async function DashboardPage({
  searchParams,
}: {
  searchParams: Promise<{ listed?: string }>;
}) {
  if (!isSupabaseConfigured()) return <SetupNotice />;
  const { listed } = await searchParams;
  const supabase = await supabaseServer();

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login?next=/dashboard");

  const [{ data: membershipData }, { data: listingData }] = await Promise.all([
    supabase
      .from("memberships")
      .select(
        "id, status, seat_price_cents, current_period_end, seat:seats(id, status, invite_email, listing:listings(service:services(name)))",
      )
      .eq("buyer_id", user.id)
      .in("status", ["awaiting_invite", "active", "past_due"])
      .order("created_at", { ascending: false }),
    supabase
      .from("listings")
      .select(
        "id, status, seat_price_cents, service:services(name), seats(id, status, invite_email, memberships(id, status))",
      )
      .eq("owner_id", user.id)
      .neq("status", "delisted")
      .order("created_at", { ascending: false }),
  ]);

  const memberships = (membershipData ?? []) as unknown as MembershipRow[];
  const listings = (listingData ?? []) as unknown as OwnerListingRow[];

  return (
    <main className="mx-auto w-full max-w-3xl flex-1 px-6 py-10">
      <h1 className="text-2xl font-bold sm:text-3xl">Your dashboard</h1>

      {listed === "1" && (
        <p className="mt-4 rounded-2xl bg-emerald-50 px-4 py-3 text-sm font-medium text-emerald-800">
          🎉 Your listing is live. We&apos;ll notify you the moment someone
          joins a seat — then you send the invite and get paid.
        </p>
      )}

      {/* ── My seats (buyer side) ── */}
      <section className="mt-8">
        <h2 className="text-lg font-semibold">My seats</h2>
        {memberships.length === 0 ? (
          <p className="mt-3 rounded-2xl border border-dashed border-stone-300 bg-white p-6 text-center text-sm text-stone-600">
            No seats yet —{" "}
            <a href="/browse" className="font-semibold text-brand">
              browse open seats
            </a>{" "}
            to get started.
          </p>
        ) : (
          <ul className="mt-3 space-y-3">
            {memberships.map((m) => {
              const seat = m.seat;
              const badge = seat ? seatStatusCopy[seat.status] : undefined;
              return (
                <li
                  key={m.id}
                  className="rounded-2xl border border-stone-200 bg-white p-5 shadow-sm"
                >
                  <div className="flex items-center justify-between gap-3">
                    <div>
                      <p className="font-semibold">
                        {seat?.listing?.service?.name ?? "Plan"}
                      </p>
                      <p className="text-sm text-stone-500">
                        {fmtKes(m.seat_price_cents)}/mo
                        {m.current_period_end &&
                          ` · renews ${new Date(m.current_period_end).toLocaleDateString("en-KE", { day: "numeric", month: "short" })}`}
                      </p>
                    </div>
                    {badge && (
                      <span
                        className={`rounded-full px-3 py-1 text-xs font-semibold ${badge.tone}`}
                      >
                        {badge.label}
                      </span>
                    )}
                  </div>

                  {seat && m.status === "awaiting_invite" && (
                    <div className="mt-4 border-t border-stone-100 pt-4">
                      <p className="text-sm text-stone-600">
                        Invite going to{" "}
                        <span className="font-medium">{seat.invite_email}</span>.
                        Got it and it works?
                      </p>
                      <ConfirmAccessButton seatId={seat.id} />
                      <p className="mt-2 text-xs text-stone-500">
                        Confirming releases your escrowed payment to the owner.
                        No invite? You&apos;ll be refunded automatically.
                      </p>
                    </div>
                  )}
                </li>
              );
            })}
          </ul>
        )}
      </section>

      {/* ── My listings (owner side) ── */}
      <section className="mt-10">
        <div className="flex items-center justify-between">
          <h2 className="text-lg font-semibold">My listings</h2>
          <a
            href="/list"
            className="text-sm font-semibold text-brand hover:text-brand-strong"
          >
            + List a plan
          </a>
        </div>
        {listings.length === 0 ? (
          <p className="mt-3 rounded-2xl border border-dashed border-stone-300 bg-white p-6 text-center text-sm text-stone-600">
            You haven&apos;t listed a plan yet.{" "}
            <a href="/list" className="font-semibold text-brand">
              List your empty seats
            </a>{" "}
            and let the plan pay for itself.
          </p>
        ) : (
          <ul className="mt-3 space-y-3">
            {listings.map((l) => (
              <li
                key={l.id}
                className="rounded-2xl border border-stone-200 bg-white p-5 shadow-sm"
              >
                <div className="flex items-center justify-between">
                  <p className="font-semibold">{l.service?.name ?? "Plan"}</p>
                  <p className="text-sm text-stone-500">
                    {fmtKes(l.seat_price_cents)}/seat
                  </p>
                </div>
                <ul className="mt-3 space-y-2">
                  {l.seats.map((s) => {
                    const needsInvite =
                      s.status === "reserved" &&
                      s.memberships.some((m) => m.status === "awaiting_invite");
                    const badge = seatStatusCopy[s.status];
                    return (
                      <li
                        key={s.id}
                        className="flex items-center justify-between gap-3 rounded-xl bg-stone-50 px-4 py-3 text-sm"
                      >
                        <span className="truncate">
                          {s.status === "open"
                            ? "Open seat"
                            : (s.invite_email ?? "Member")}
                        </span>
                        {needsInvite ? (
                          <MarkInvitedButton
                            seatId={s.id}
                            inviteEmail={s.invite_email ?? ""}
                          />
                        ) : (
                          <span
                            className={`shrink-0 rounded-full px-3 py-1 text-xs font-semibold ${badge?.tone ?? "bg-stone-100 text-stone-600"}`}
                          >
                            {badge?.label ?? s.status}
                          </span>
                        )}
                      </li>
                    );
                  })}
                </ul>
              </li>
            ))}
          </ul>
        )}
      </section>
    </main>
  );
}
