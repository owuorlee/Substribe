-- Substribe · Migration 0900 — listing creation & lifecycle protection
--
-- Seats have no client write policies (they gate money), so listing creation
-- is a self-authorising SECURITY DEFINER RPC: validates the owner, inserts
-- the listing and its seat rows atomically. Mirrors the rules in the
-- listings_insert_own RLS policy (kyc tier, seat cap, active service) and
-- adds the ones RLS can't express (listing limit, price sanity).
--
-- Concierge note: kyc_tier is bumped 0 → 1 manually (admin) during Phase 0/1
-- onboarding after the M-Pesa name check; self-serve verification comes with
-- the first-payment name-match flow.

create or replace function public.create_listing(
  p_service_id       uuid,
  p_seats_offered    integer,
  p_seat_price_cents bigint
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid          uuid := auth.uid();
  v_profile      public.profiles%rowtype;
  v_service      public.services%rowtype;
  v_listing_id   uuid;
  v_active_count integer;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  select * into v_profile from public.profiles where id = v_uid;
  if not found or v_profile.suspended_at is not null then
    raise exception 'account_suspended';
  end if;
  if v_profile.kyc_tier < 1 then
    raise exception 'verification_required';
  end if;

  select * into v_service from public.services
   where id = p_service_id and is_active;
  if not found then
    raise exception 'service_not_active';
  end if;

  -- The owner keeps one seat; you can't sell the whole plan.
  if p_seats_offered is null
     or p_seats_offered < 1
     or p_seats_offered > v_service.seats_total - 1 then
    raise exception 'invalid_seat_count';
  end if;

  -- Whole shillings, KSh 50 floor (M-Pesa fees make less pointless), and a
  -- seat priced above solo retail would only ever trap a confused buyer.
  if p_seat_price_cents is null
     or p_seat_price_cents < 5000
     or p_seat_price_cents % 100 <> 0 then
    raise exception 'invalid_price';
  end if;
  if v_service.official_solo_price_cents is not null
     and p_seat_price_cents > v_service.official_solo_price_cents then
    raise exception 'price_above_solo';
  end if;

  -- Tier 1 hosts get one live listing; tier 2+ unlocks more (SCOPE.md §5.2).
  select count(*) into v_active_count from public.listings l
   where l.owner_id = v_uid and l.status in ('draft', 'active', 'paused');
  if v_profile.kyc_tier = 1 and v_active_count >= 1 then
    raise exception 'listing_limit_reached';
  end if;

  insert into public.listings
    (owner_id, service_id, status, seats_offered, seat_price_cents, currency)
  values
    (v_uid, p_service_id, 'active', p_seats_offered, p_seat_price_cents,
     v_service.currency)
  returning id into v_listing_id;

  insert into public.seats (listing_id, status)
  select v_listing_id, 'open'::public.seat_status
  from generate_series(1, p_seats_offered);

  insert into public.audit_log (actor_id, actor_type, action, target_table, target_id)
  values (v_uid, 'user', 'listing_created', 'listings', v_listing_id::text);

  return v_listing_id;
end;
$$;

grant execute on function public.create_listing(uuid, integer, bigint) to authenticated;
revoke execute on function public.create_listing(uuid, integer, bigint) from public, anon;

-- create_listing is now the only way in — a direct insert would create a
-- listing with no seat rows (inert junk). Keep one code path.
drop policy listings_insert_own on public.listings;

-- ── lifecycle protection ─────────────────────────────────────────────────────
-- Owners may edit their listing (RLS), but some transitions would strand
-- buyers or corrupt seat accounting. Enforced here, not by UI discipline:
--   · seat rows are the truth — seats_offered can't be edited by clients
--   · the service can't be swapped after creation
--   · delisting requires all seats open/ended; open seats are then retired

create or replace function public.protect_listing_transitions()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_is_client boolean := auth.uid() is not null and not public.is_admin();
begin
  if v_is_client and new.seats_offered is distinct from old.seats_offered then
    raise exception 'seat_count_is_system_managed';
  end if;
  if v_is_client and new.service_id is distinct from old.service_id then
    raise exception 'service_cannot_change';
  end if;

  if new.status = 'delisted' and old.status <> 'delisted' then
    if exists (
      select 1 from public.seats s
      where s.listing_id = new.id and s.status not in ('open', 'ended')
    ) then
      raise exception 'cannot_delist_with_active_members';
    end if;
    update public.seats
       set status = 'ended', ended_at = now()
     where listing_id = new.id and status = 'open';
  end if;

  return new;
end;
$$;

create trigger listings_protect_transitions
  before update on public.listings
  for each row execute function public.protect_listing_transitions();
