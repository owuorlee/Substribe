import Link from "next/link";
import { redirect } from "next/navigation";
import { isSupabaseConfigured, supabaseServer } from "@/lib/supabase/server";
import SetupNotice from "@/components/SetupNotice";
import ListingForm, { type ListableService } from "./ListingForm";

export const dynamic = "force-dynamic";

export default async function ListPage() {
  if (!isSupabaseConfigured()) return <SetupNotice />;
  const supabase = await supabaseServer();

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login?next=/list");

  const { data: profile } = await supabase
    .from("profiles")
    .select("kyc_tier, suspended_at")
    .eq("id", user.id)
    .maybeSingle();

  if (!profile || profile.suspended_at) {
    return (
      <main className="mx-auto w-full max-w-md flex-1 px-6 py-20 text-center">
        <h1 className="text-xl font-bold">Account unavailable</h1>
        <p className="mt-2 text-sm text-stone-600">
          Your account can&apos;t host listings right now. Contact support.
        </p>
      </main>
    );
  }

  // Hosts are verified before they can take buyers' money — that's the
  // product. Tier bumps are manual during the concierge phase.
  if (profile.kyc_tier < 1) {
    return (
      <main className="mx-auto w-full max-w-md flex-1 px-6 py-14">
        <h1 className="text-2xl font-bold">Become a host</h1>
        <div className="mt-6 rounded-2xl border border-stone-200 bg-white p-6 shadow-sm">
          <p className="text-3xl">🛡️</p>
          <h2 className="mt-3 font-bold">Hosts are verified first</h2>
          <p className="mt-2 text-sm text-stone-600">
            Buyers trust Substribe because every host is verified before they
            can list — we match your name against your M-Pesa registration.
            It&apos;s quick and it&apos;s why seats here are safe to join.
          </p>
          <p className="mt-3 text-sm text-stone-600">
            Verification is invite-only during early access. Want in early?
            Reach out and we&apos;ll fast-track you.
          </p>
          <Link
            href="/browse"
            className="mt-5 inline-block rounded-xl border border-stone-300 px-5 py-2.5 text-sm font-semibold text-stone-700 hover:bg-stone-50"
          >
            Browse seats meanwhile
          </Link>
        </div>
      </main>
    );
  }

  const { data: services } = await supabase
    .from("services")
    .select(
      "id, name, seats_total, plan_price_cents, official_solo_price_cents, suggested_seat_price_cents, platform_fee_bps, insurance_fee_bps",
    )
    .eq("is_active", true)
    .order("name");

  return (
    <main className="mx-auto w-full max-w-md flex-1 px-6 py-10">
      <h1 className="text-2xl font-bold">List your plan</h1>
      <p className="mt-2 text-sm text-stone-600">
        Fill your empty seats and let the plan pay for itself. You get paid
        after each member confirms their seat works.
      </p>
      <div className="mt-6">
        <ListingForm services={(services ?? []) as unknown as ListableService[]} />
      </div>
    </main>
  );
}
