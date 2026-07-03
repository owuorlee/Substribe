-- Substribe · Migration 0300 — listings, seats, memberships, waitlist
-- A seat is a physical slot on a plan; a membership is one buyer's tenure on a
-- seat. When a buyer leaves, the seat returns to 'open' and history stays in
-- memberships. All seat/membership state transitions happen server-side only
-- (no client write policies) because they gate money movements.

-- ── listings ─────────────────────────────────────────────────────────────────

create table public.listings (
  id               uuid primary key default gen_random_uuid(),
  owner_id         uuid not null references public.profiles (id),
  service_id       uuid not null references public.services (id),
  status           public.listing_status not null default 'draft',
  seats_offered    smallint not null check (seats_offered between 1 and 9),
  seat_price_cents bigint not null check (seat_price_cents > 0),
  currency         char(3) not null default 'KES',
  -- Hours the owner has to send the provider invite before auto-refund.
  invite_sla_hours smallint not null default 12 check (invite_sla_hours between 1 and 72),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create index listings_owner_idx on public.listings (owner_id);
create index listings_browse_idx on public.listings (service_id, status);

create trigger listings_set_updated_at
  before update on public.listings
  for each row execute function public.set_updated_at();

-- ── seats ────────────────────────────────────────────────────────────────────

create table public.seats (
  id           uuid primary key default gen_random_uuid(),
  listing_id   uuid not null references public.listings (id) on delete cascade,
  status       public.seat_status not null default 'open',
  buyer_id     uuid references public.profiles (id),
  invite_email citext,
  reserved_at  timestamptz,
  invited_at   timestamptz,
  activated_at timestamptz,
  ended_at     timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  -- open seats have no buyer; every occupied state must have one.
  constraint seats_buyer_consistency check (
    (status = 'open' and buyer_id is null)
    or (status = 'ended')
    or (status not in ('open', 'ended') and buyer_id is not null)
  )
);

create index seats_listing_idx on public.seats (listing_id);
create index seats_buyer_idx on public.seats (buyer_id) where buyer_id is not null;
create index seats_open_idx on public.seats (status) where status = 'open';

create trigger seats_set_updated_at
  before update on public.seats
  for each row execute function public.set_updated_at();

-- Trust aggregate: count a fill the moment a seat goes active.
create or replace function public.on_seat_activated()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.profiles p
  set seats_filled_count = p.seats_filled_count + 1
  where p.id = (select l.owner_id from public.listings l where l.id = new.listing_id);
  return new;
end;
$$;

create trigger seats_count_activation
  after update on public.seats
  for each row
  when (old.status is distinct from new.status and new.status = 'active')
  execute function public.on_seat_activated();

-- ── memberships ──────────────────────────────────────────────────────────────
-- Price and fee are snapshotted at join time so later listing-price changes
-- never affect an existing member.

create table public.memberships (
  id                   uuid primary key default gen_random_uuid(),
  seat_id              uuid not null references public.seats (id),
  buyer_id             uuid not null references public.profiles (id),
  status               public.membership_status not null default 'pending_payment',
  billing_method       public.billing_method not null default 'stk_reminder',
  seat_price_cents     bigint not null check (seat_price_cents > 0),
  platform_fee_cents   bigint not null default 0 check (platform_fee_cents >= 0),
  insurance_fee_cents  bigint not null default 0 check (insurance_fee_cents >= 0),
  owner_take_cents     bigint generated always as
                         (seat_price_cents - platform_fee_cents - insurance_fee_cents) stored,
  currency             char(3) not null default 'KES',
  current_period_start date,
  current_period_end   date,
  next_billing_at      timestamptz,
  cancelled_at         timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  constraint memberships_fees_fit check
    (platform_fee_cents + insurance_fee_cents <= seat_price_cents),
  constraint memberships_period_order check
    (current_period_start is null or current_period_end is null
     or current_period_start < current_period_end)
);

-- One live membership per seat, ever.
create unique index memberships_one_live_per_seat on public.memberships (seat_id)
  where status in ('pending_payment', 'awaiting_invite', 'active', 'past_due', 'suspended');

create index memberships_buyer_idx on public.memberships (buyer_id);
create index memberships_billing_due_idx on public.memberships (next_billing_at)
  where status in ('active', 'past_due');

create trigger memberships_set_updated_at
  before update on public.memberships
  for each row execute function public.set_updated_at();

-- ── waitlist ─────────────────────────────────────────────────────────────────

create table public.waitlist_entries (
  id              uuid primary key default gen_random_uuid(),
  buyer_id        uuid not null references public.profiles (id),
  service_id      uuid not null references public.services (id),
  max_price_cents bigint check (max_price_cents is null or max_price_cents > 0),
  status          public.waitlist_status not null default 'waiting',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create unique index waitlist_one_waiting_per_service
  on public.waitlist_entries (buyer_id, service_id) where status = 'waiting';
create index waitlist_match_idx
  on public.waitlist_entries (service_id, created_at) where status = 'waiting';

create trigger waitlist_set_updated_at
  before update on public.waitlist_entries
  for each row execute function public.set_updated_at();
