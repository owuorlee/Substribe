-- Substribe · Migration 0700 — Row-Level Security and access shaping
--
-- Access model:
--   · Browsing (services, active listings, open seats, owner trust cards) is
--     public — a first-time visitor must see real inventory before signing up.
--   · Users read their own money data (payments, payouts, memberships).
--   · ALL state transitions that gate money (seats, memberships, payments,
--     payouts, ledger) are server-only: no client write policies exist.
--   · Ledger, payment_events, audit_log: no policies at all — clients denied
--     outright; the service role bypasses RLS.

-- ── enable RLS everywhere ────────────────────────────────────────────────────

alter table public.profiles            enable row level security;
alter table public.services            enable row level security;
alter table public.listings            enable row level security;
alter table public.seats               enable row level security;
alter table public.memberships         enable row level security;
alter table public.waitlist_entries    enable row level security;
alter table public.payments            enable row level security;
alter table public.payment_events     enable row level security;
alter table public.payouts             enable row level security;
alter table public.disputes            enable row level security;
alter table public.ratings             enable row level security;
alter table public.notifications       enable row level security;
alter table public.audit_log           enable row level security;
alter table public.ledger_accounts     enable row level security;
alter table public.ledger_transactions enable row level security;
alter table public.ledger_entries      enable row level security;

-- Defense in depth: even if a policy is added by mistake later, plain grants
-- are gone for the money tables.
revoke all on public.ledger_accounts,
              public.ledger_transactions,
              public.ledger_entries,
              public.payment_events,
              public.audit_log
  from anon, authenticated;

-- ── profiles ─────────────────────────────────────────────────────────────────

create policy profiles_select_own on public.profiles
  for select using (id = auth.uid() or public.is_admin());

create policy profiles_update_own on public.profiles
  for update using (id = auth.uid())
  with check (id = auth.uid());
-- (system columns are guarded by the profiles_protect_columns trigger)

-- Public trust card for browsing: first name only, ratings, tenure. This view
-- intentionally runs with definer rights to bypass profiles RLS — it is the
-- ONLY public window into profiles, and it exposes only these columns.
create view public.owner_public_profiles
with (security_invoker = false) as
select
  p.id,
  coalesce(nullif(split_part(p.full_name, ' ', 1), ''), 'Substribe member') as display_name,
  p.owner_rating,
  p.seats_filled_count,
  p.disputes_against_count,
  p.kyc_tier,
  p.created_at as member_since
from public.profiles p
where p.suspended_at is null;

grant select on public.owner_public_profiles to anon, authenticated;

-- ── services ─────────────────────────────────────────────────────────────────

create policy services_select_active on public.services
  for select using (is_active or public.is_admin());

-- ── listings ─────────────────────────────────────────────────────────────────

create policy listings_select_browse on public.listings
  for select using (
    status = 'active'
    or owner_id = auth.uid()
    or public.is_admin()
  );

-- Listing requires KYC tier 1+ (M-Pesa name verified), an unsuspended account,
-- an active service, and a seat count that physically fits the plan.
create policy listings_insert_own on public.listings
  for insert to authenticated
  with check (
    owner_id = auth.uid()
    and exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.kyc_tier >= 1 and p.suspended_at is null
    )
    and exists (
      select 1 from public.services s
      where s.id = service_id
        and s.is_active
        and seats_offered <= s.seats_total - 1
    )
  );

create policy listings_update_own on public.listings
  for update to authenticated
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid());

create policy listings_admin_all on public.listings
  for all using (public.is_admin());

-- ── seats (read-only for clients) ────────────────────────────────────────────

create policy seats_select on public.seats
  for select using (
    buyer_id = auth.uid()
    or exists (
      select 1 from public.listings l
      where l.id = listing_id and l.owner_id = auth.uid()
    )
    or (
      status = 'open'
      and exists (
        select 1 from public.listings l
        where l.id = listing_id and l.status = 'active'
      )
    )
    or public.is_admin()
  );

-- ── memberships (read-only for clients) ──────────────────────────────────────

create policy memberships_select_participants on public.memberships
  for select using (
    buyer_id = auth.uid()
    or exists (
      select 1
      from public.seats s
      join public.listings l on l.id = s.listing_id
      where s.id = seat_id and l.owner_id = auth.uid()
    )
    or public.is_admin()
  );

-- ── waitlist ─────────────────────────────────────────────────────────────────

create policy waitlist_select_own on public.waitlist_entries
  for select using (buyer_id = auth.uid() or public.is_admin());

create policy waitlist_insert_own on public.waitlist_entries
  for insert to authenticated
  with check (
    buyer_id = auth.uid()
    and exists (select 1 from public.services s where s.id = service_id and s.is_active)
  );

create policy waitlist_update_own on public.waitlist_entries
  for update to authenticated
  using (buyer_id = auth.uid())
  with check (buyer_id = auth.uid() and status in ('waiting', 'cancelled'));

-- ── payments / payouts (read-only for clients) ───────────────────────────────

create policy payments_select_own on public.payments
  for select using (user_id = auth.uid() or public.is_admin());

create policy payouts_select_own on public.payouts
  for select using (owner_id = auth.uid() or public.is_admin());

-- ── disputes ─────────────────────────────────────────────────────────────────

create policy disputes_select_participants on public.disputes
  for select using (
    reporter_id = auth.uid()
    or exists (
      select 1
      from public.memberships m
      join public.seats s on s.id = m.seat_id
      join public.listings l on l.id = s.listing_id
      where m.id = membership_id
        and (m.buyer_id = auth.uid() or l.owner_id = auth.uid())
    )
    or public.is_admin()
  );

create policy disputes_insert_participants on public.disputes
  for insert to authenticated
  with check (
    reporter_id = auth.uid()
    and exists (
      select 1
      from public.memberships m
      join public.seats s on s.id = m.seat_id
      join public.listings l on l.id = s.listing_id
      where m.id = membership_id
        and s.id = seat_id
        and (m.buyer_id = auth.uid() or l.owner_id = auth.uid())
    )
  );

create policy disputes_update_admin on public.disputes
  for update using (public.is_admin());

-- ── ratings ──────────────────────────────────────────────────────────────────

create policy ratings_select_participants on public.ratings
  for select using (
    from_user = auth.uid() or to_user = auth.uid() or public.is_admin()
  );

-- Only the two parties to a membership may rate each other, once each.
create policy ratings_insert_participant on public.ratings
  for insert to authenticated
  with check (
    from_user = auth.uid()
    and exists (
      select 1
      from public.memberships m
      join public.seats s on s.id = m.seat_id
      join public.listings l on l.id = s.listing_id
      where m.id = membership_id
        and (
          (m.buyer_id = auth.uid() and l.owner_id = to_user)
          or (l.owner_id = auth.uid() and m.buyer_id = to_user)
        )
    )
  );

-- ── notifications ────────────────────────────────────────────────────────────

create policy notifications_select_own on public.notifications
  for select using (user_id = auth.uid() or public.is_admin());
