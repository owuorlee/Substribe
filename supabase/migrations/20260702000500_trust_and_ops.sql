-- Substribe · Migration 0500 — disputes, ratings, notifications, audit log

-- ── disputes ─────────────────────────────────────────────────────────────────
-- Opening a dispute must freeze the linked owner payout (done server-side in
-- the same transaction; the ledger hold is documented in docs/LEDGER.md).

create table public.disputes (
  id               uuid primary key default gen_random_uuid(),
  membership_id    uuid not null references public.memberships (id),
  seat_id          uuid not null references public.seats (id),
  reporter_id      uuid not null references public.profiles (id),
  reason           public.dispute_reason not null,
  details          text,
  status           public.dispute_status not null default 'open',
  resolution_notes text,
  resolved_by      uuid references public.profiles (id),
  resolved_at      timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint disputes_resolution_complete check (
    status in ('open', 'under_review')
    or (resolved_by is not null and resolved_at is not null)
  )
);

create index disputes_queue_idx on public.disputes (status, created_at);
create index disputes_membership_idx on public.disputes (membership_id);

create trigger disputes_set_updated_at
  before update on public.disputes
  for each row execute function public.set_updated_at();

-- Trust aggregate: disputes count against the counterparty's profile.
create or replace function public.on_dispute_opened()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
  v_buyer uuid;
begin
  select l.owner_id, m.buyer_id
    into v_owner, v_buyer
  from public.memberships m
  join public.seats s on s.id = m.seat_id
  join public.listings l on l.id = s.listing_id
  where m.id = new.membership_id;

  update public.profiles
  set disputes_against_count = disputes_against_count + 1
  where id = case when new.reporter_id = v_buyer then v_owner else v_buyer end;

  return new;
end;
$$;

create trigger disputes_count_against
  after insert on public.disputes
  for each row execute function public.on_dispute_opened();

-- ── ratings ──────────────────────────────────────────────────────────────────

create table public.ratings (
  id            uuid primary key default gen_random_uuid(),
  membership_id uuid not null references public.memberships (id),
  from_user     uuid not null references public.profiles (id),
  to_user       uuid not null references public.profiles (id),
  score         smallint not null check (score between 1 and 5),
  comment       text check (comment is null or length(comment) <= 1000),
  created_at    timestamptz not null default now(),
  constraint ratings_no_self check (from_user <> to_user),
  constraint ratings_once_per_membership unique (membership_id, from_user)
);

create index ratings_to_user_idx on public.ratings (to_user);

-- Keep profile aggregates in sync. A rating counts toward owner_rating when
-- the rated user is the listing owner for that membership, else buyer_rating.
create or replace function public.refresh_rating_aggregates()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.profiles p
  set
    owner_rating = (
      select round(avg(r.score)::numeric, 2)
      from public.ratings r
      join public.memberships m on m.id = r.membership_id
      join public.seats s on s.id = m.seat_id
      join public.listings l on l.id = s.listing_id
      where r.to_user = new.to_user and l.owner_id = new.to_user
    ),
    buyer_rating = (
      select round(avg(r.score)::numeric, 2)
      from public.ratings r
      join public.memberships m on m.id = r.membership_id
      where r.to_user = new.to_user and m.buyer_id = new.to_user
    )
  where p.id = new.to_user;
  return new;
end;
$$;

create trigger ratings_refresh_aggregates
  after insert on public.ratings
  for each row execute function public.refresh_rating_aggregates();

-- ── notifications ────────────────────────────────────────────────────────────
-- Outbox pattern: rows are queued here, a worker delivers via WhatsApp Cloud
-- API with SMS fallback, and writes back delivery state.

create table public.notifications (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles (id),
  channel     public.notification_channel not null,
  template    text not null,
  payload     jsonb not null default '{}'::jsonb,
  status      public.notification_status not null default 'queued',
  external_id text,
  error       text,
  created_at  timestamptz not null default now(),
  sent_at     timestamptz
);

create index notifications_user_idx on public.notifications (user_id, created_at desc);
create index notifications_outbox_idx on public.notifications (created_at)
  where status = 'queued';

-- ── audit log ────────────────────────────────────────────────────────────────

create table public.audit_log (
  id           bigint generated always as identity primary key,
  actor_id     uuid,
  actor_type   text not null check (actor_type in ('user', 'admin', 'system')),
  action       text not null,
  target_table text,
  target_id    text,
  before       jsonb,
  after        jsonb,
  created_at   timestamptz not null default now()
);

create index audit_log_target_idx on public.audit_log (target_table, target_id);
create index audit_log_actor_idx on public.audit_log (actor_id, created_at desc);

create trigger audit_log_immutable
  before update or delete on public.audit_log
  for each row execute function public.forbid_change();
