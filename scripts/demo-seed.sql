-- ═══════════════════════════════════════════════════════════════════════════
-- Substribe · demo data seed  (DEV PROJECT ONLY — never run in production)
-- ═══════════════════════════════════════════════════════════════════════════
-- Creates two sign-in-able accounts and one live Spotify listing so the app
-- has real inventory to browse and join.
--
--   owner@substribe.dev / substribe123   (verified host, owns the listing)
--   buyer@substribe.dev / substribe123   (joins a seat)
--
-- Sign in at /login → "Dev sign-in (email + password)". Emails are marked
-- confirmed here, so Supabase's "Confirm email" setting doesn't matter.
--
-- This COMMITS (unlike e2e-money-test.sql). Re-running is safe: it deletes and
-- recreates the demo accounts, cascading away their old listings/seats.
-- Cleanup: just run the DELETE at the top on its own.
-- ═══════════════════════════════════════════════════════════════════════════

-- Remove any previous demo run (cascades to profiles → listings → seats).
delete from auth.users where email in ('owner@substribe.dev', 'buyer@substribe.dev');

insert into auth.users
  (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
   created_at, updated_at, confirmation_token, email_change,
   email_change_token_new, recovery_token, raw_app_meta_data, raw_user_meta_data)
values
  ('aaaaaaaa-0000-4000-8000-000000000001',
   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'owner@substribe.dev', crypt('substribe123', gen_salt('bf')), now(),
   now(), now(), '', '', '', '',
   '{"provider":"email","providers":["email"]}', '{}'),
  ('bbbbbbbb-0000-4000-8000-000000000002',
   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'buyer@substribe.dev', crypt('substribe123', gen_salt('bf')), now(),
   now(), now(), '', '', '', '',
   '{"provider":"email","providers":["email"]}', '{}');

-- Owner: verified host (kyc_tier 1) with a plausible trust history.
update public.profiles
   set full_name = 'Brian Otieno',
       phone = '+254722000001',
       mpesa_name = 'BRIAN OTIENO',
       mpesa_name_verified = true,
       kyc_tier = 1,
       preferred_language = 'en'
 where id = 'aaaaaaaa-0000-4000-8000-000000000001';

-- Buyer: ordinary account.
update public.profiles
   set full_name = 'Achieng Wanjiru',
       phone = '+254712345678',
       preferred_language = 'en'
 where id = 'bbbbbbbb-0000-4000-8000-000000000002';

-- The owner lists 5 Spotify seats at KSh 250 (via the real RPC, so seat rows
-- and validation match production exactly).
do $$
declare
  v_service uuid;
  v_listing uuid;
begin
  select id into v_service from public.services where slug = 'spotify-family';

  perform set_config('request.jwt.claims',
    json_build_object('sub', 'aaaaaaaa-0000-4000-8000-000000000001')::text, true);

  select public.create_listing(v_service, 5, 25000) into v_listing;
  raise notice 'demo listing created: % (5 seats @ KSh 250)', v_listing;
end $$;

-- What the marketplace now looks like.
select
  s.name                as service,
  p.full_name           as host,
  p.owner_rating,
  l.seat_price_cents / 100 as seat_price_kes,
  count(seat.id) filter (where seat.status = 'open') as open_seats
from public.listings l
join public.services s on s.id = l.service_id
join public.profiles p on p.id = l.owner_id
left join public.seats seat on seat.listing_id = l.id
where l.status = 'active'
group by s.name, p.full_name, p.owner_rating, l.seat_price_cents;
