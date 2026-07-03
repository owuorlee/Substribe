-- Substribe · Migration 0200 — profiles (identity + trust) and service catalogue

-- ── profiles ─────────────────────────────────────────────────────────────────
-- Extends auth.users. Phone is the identity anchor (M-Pesa number).
-- Trust/aggregate columns are system-maintained; a trigger blocks client edits.

create table public.profiles (
  id                      uuid primary key references auth.users (id) on delete cascade,
  phone                   text unique
                          check (phone is null or phone ~ '^\+[1-9]\d{6,14}$'),
  full_name               text,
  -- Registered M-Pesa name, captured from Daraja on first payment; matching it
  -- against full_name is our cheapest, highest-signal KYC step (SCOPE.md §5.2).
  mpesa_name              text,
  mpesa_name_verified     boolean not null default false,
  kyc_tier                smallint not null default 0 check (kyc_tier between 0 and 3),
  is_admin                boolean not null default false,
  owner_rating            numeric(3, 2) check (owner_rating between 1 and 5),
  buyer_rating            numeric(3, 2) check (buyer_rating between 1 and 5),
  seats_filled_count      integer not null default 0,
  disputes_against_count  integer not null default 0,
  preferred_language      text not null default 'en' check (preferred_language in ('en', 'sw')),
  whatsapp_opt_in         boolean not null default true,
  suspended_at            timestamptz,
  suspension_reason       text,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now()
);

create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- Auto-provision a profile on signup. Supabase stores phone without '+'.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, phone)
  values (
    new.id,
    case
      when new.phone is null or new.phone = '' then null
      when new.phone ~ '^\d+$' then '+' || new.phone
      else new.phone
    end
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select p.is_admin from public.profiles p where p.id = auth.uid()),
    false
  );
$$;

-- Clients may edit their own profile, but never the trust/KYC columns.
-- Server-side code (service role / direct SQL) and admins pass through.
create or replace function public.protect_profile_columns()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null
     or coalesce(auth.role(), '') = 'service_role'
     or public.is_admin() then
    return new;
  end if;

  if new.kyc_tier                is distinct from old.kyc_tier
     or new.is_admin             is distinct from old.is_admin
     or new.mpesa_name           is distinct from old.mpesa_name
     or new.mpesa_name_verified  is distinct from old.mpesa_name_verified
     or new.owner_rating         is distinct from old.owner_rating
     or new.buyer_rating         is distinct from old.buyer_rating
     or new.seats_filled_count   is distinct from old.seats_filled_count
     or new.disputes_against_count is distinct from old.disputes_against_count
     or new.suspended_at         is distinct from old.suspended_at
     or new.suspension_reason    is distinct from old.suspension_reason then
    raise exception 'column is system-managed and cannot be modified by the user';
  end if;

  return new;
end;
$$;

create trigger profiles_protect_columns
  before update on public.profiles
  for each row execute function public.protect_profile_columns();

-- ── services (catalogue) ─────────────────────────────────────────────────────
-- One row per shareable plan type. seats_total includes the owner, so a
-- listing may offer at most seats_total - 1 (enforced in the listing policy).

create table public.services (
  id                        uuid primary key default gen_random_uuid(),
  slug                      text unique not null check (slug ~ '^[a-z0-9-]+$'),
  name                      text not null,
  category                  public.service_category not null,
  seats_total               smallint not null check (seats_total between 2 and 10),
  -- What the owner pays for the whole plan, monthly-normalised.
  plan_price_cents          bigint not null check (plan_price_cents > 0),
  -- What one person would pay alone (for the savings banner). Null when there
  -- is no meaningful solo equivalent.
  official_solo_price_cents bigint check (official_solo_price_cents > 0),
  suggested_seat_price_cents bigint check (suggested_seat_price_cents > 0),
  currency                  char(3) not null default 'KES',
  invite_mechanism          public.invite_mechanism not null,
  household_required        boolean not null default false,
  risk                      public.risk_rating not null default 'low',
  support_burden            public.risk_rating not null default 'low',
  is_active                 boolean not null default false,
  notes                     text,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now()
);

create trigger services_set_updated_at
  before update on public.services
  for each row execute function public.set_updated_at();
