// Owner trust proof — shown wherever a buyer decides whether to trust a
// stranger. Data comes from the public owner_public_profiles view.
export interface OwnerTrust {
  id: string;
  display_name: string;
  owner_rating: number | null;
  seats_filled_count: number;
  disputes_against_count: number;
  member_since: string;
}

export default function TrustCard({ owner }: { owner: OwnerTrust }) {
  const since = new Date(owner.member_since).toLocaleDateString("en-KE", {
    month: "short",
    year: "numeric",
  });
  return (
    <div className="flex items-center gap-3">
      <div className="flex h-10 w-10 items-center justify-center rounded-full bg-brand-soft font-bold text-brand-strong">
        {owner.display_name.charAt(0).toUpperCase()}
      </div>
      <div className="min-w-0 text-sm">
        <p className="font-semibold">{owner.display_name}</p>
        <p className="text-stone-500">
          {owner.owner_rating !== null ? (
            <>★ {owner.owner_rating.toFixed(1)} · </>
          ) : (
            <>New host · </>
          )}
          {owner.seats_filled_count} seat{owner.seats_filled_count === 1 ? "" : "s"} filled
          {owner.disputes_against_count === 0 ? " · 0 disputes" : ""} · since {since}
        </p>
      </div>
    </div>
  );
}
