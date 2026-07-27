-- ═══════════════════════════════════════════════════════════════════════════
-- Substribe · end-to-end money-engine test
-- ═══════════════════════════════════════════════════════════════════════════
-- Simulates a full KSh 250 Spotify seat purchase against the real schema:
--   owner lists → buyer reserves → M-Pesa STK success callback → escrow hold →
--   buyer confirms access → escrow release (fee split) → verify ledger.
--
-- Runs entirely inside ONE transaction and ROLLS BACK at the end, so it leaves
-- NOTHING behind — safe to run repeatedly. Paste into the Supabase SQL editor
-- and Run. Watch the "Messages" panel for step-by-step NOTICEs; the final grid
-- shows every ledger balance vs. its expected value. Any mismatch raises a
-- loud EXCEPTION instead of finishing.
-- ═══════════════════════════════════════════════════════════════════════════

begin;

-- Defensive cleanup (no-op on a clean DB; matters only if a prior run somehow
-- committed). Cascades to profiles via FK.
delete from auth.users
where email in ('owner_test@substribe.dev', 'buyer_test@substribe.dev');

-- Two test auth users. The handle_new_user trigger auto-creates their profiles.
insert into auth.users
  (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
   created_at, updated_at, confirmation_token, email_change,
   email_change_token_new, recovery_token, raw_app_meta_data, raw_user_meta_data)
values
  ('11111111-1111-1111-1111-111111111111',
   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'owner_test@substribe.dev', '', now(), now(), now(), '', '', '', '',
   '{"provider":"email","providers":["email"]}', '{}'),
  ('22222222-2222-2222-2222-222222222222',
   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'buyer_test@substribe.dev', '', now(), now(), now(), '', '', '', '',
   '{"provider":"email","providers":["email"]}', '{}');

-- Make the owner a verified host; give both a phone.
update public.profiles
   set kyc_tier = 1, full_name = 'Test Owner',
       mpesa_name = 'TEST OWNER', mpesa_name_verified = true,
       phone = '+254700000001'
 where id = '11111111-1111-1111-1111-111111111111';
update public.profiles
   set full_name = 'Test Buyer', phone = '+254712345678'
 where id = '22222222-2222-2222-2222-222222222222';

do $$
declare
  v_owner   uuid := '11111111-1111-1111-1111-111111111111';
  v_buyer   uuid := '22222222-2222-2222-2222-222222222222';
  v_service uuid;
  v_listing uuid;
  v_seat    uuid;
  v_res     record;
  v_payment uuid;
  v_member  uuid;
  v_event   bigint;
  v_status  text;
  -- expected fee split for KSh 250 at 24% platform + 4% insurance bps
  c_price     bigint := 25000;
  c_platform  bigint := 6000;
  c_insurance bigint := 1000;
  c_owner     bigint := 18000;
  v_bal       bigint;
begin
  select id into v_service from public.services where slug = 'spotify-family';

  -- 1) Owner lists a plan (auth.uid() mocked to the owner).
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner::text)::text, true);
  select public.create_listing(v_service, 5, c_price) into v_listing;
  raise notice '1. listing created: %', v_listing;

  select id into v_seat from public.seats
   where listing_id = v_listing and status = 'open' limit 1;

  -- 2) Buyer reserves the seat + starts the join (creates membership + payment).
  select * into v_res
    from public.reserve_seat_and_start_join(
      v_seat, v_buyer, 'buyer_test@substribe.dev', '+254712345678');
  v_member  := v_res.membership_id;
  v_payment := v_res.payment_id;
  raise notice '2. reserved seat; membership=%, payment=%, amount=% cents',
    v_member, v_payment, v_res.amount_cents;
  if v_res.amount_cents <> c_price then
    raise exception 'FAIL: reserved amount % <> expected %', v_res.amount_cents, c_price;
  end if;

  -- 3) STK push accepted by Daraja.
  perform public.record_stk_initiated(
    v_payment, 'ws_CO_TEST_123', 'MERCH_TEST', '{}'::jsonb);

  -- 4) Daraja fires a success callback → ingest event → process it.
  insert into public.payment_events (payment_id, source, dedupe_key, payload)
  values (v_payment, 'stk_callback', 'test_dedupe_' || v_payment,
    jsonb_build_object('Body', jsonb_build_object('stkCallback',
      jsonb_build_object(
        'CheckoutRequestID', 'ws_CO_TEST_123',
        'ResultCode', 0,
        'ResultDesc', 'The service request is processed successfully.',
        'CallbackMetadata', jsonb_build_object('Item', jsonb_build_array(
          jsonb_build_object('Name', 'Amount', 'Value', 250),
          jsonb_build_object('Name', 'MpesaReceiptNumber', 'Value', 'TEST_RCT_1')
        ))))))
  returning id into v_event;
  perform public.process_payment_event(v_event);

  select status into v_status from public.memberships where id = v_member;
  raise notice '4. payment processed; membership status = %', v_status;
  if v_status <> 'awaiting_invite' then
    raise exception 'FAIL: membership should be awaiting_invite, got %', v_status;
  end if;

  -- 4a) Escrow must now hold the full amount for the buyer.
  select balance_cents into v_bal from public.ledger_account_balances
   where kind = 'buyer_escrow' and user_id = v_buyer;
  if coalesce(v_bal, 0) <> c_price then
    raise exception 'FAIL: buyer escrow = %, expected %', coalesce(v_bal, 0), c_price;
  end if;
  raise notice '4a. escrow holds % cents for the buyer', v_bal;

  -- 5) Buyer confirms access → release escrow with the fee split.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_buyer::text)::text, true);
  perform public.confirm_seat_access(v_seat);
  select status into v_status from public.memberships where id = v_member;
  raise notice '5. access confirmed; membership status = %, seat status = %',
    v_status, (select status from public.seats where id = v_seat);
  if v_status <> 'active' then
    raise exception 'FAIL: membership should be active, got %', v_status;
  end if;

  -- 6) Assert the final ledger — every account to the cent.
  select balance_cents into v_bal from public.ledger_account_balances
   where kind = 'buyer_escrow' and user_id = v_buyer;
  if coalesce(v_bal, 0) <> 0 then
    raise exception 'FAIL: escrow not fully released, still %', v_bal;
  end if;

  select balance_cents into v_bal from public.ledger_account_balances
   where kind = 'owner_payable' and user_id = v_owner;
  if v_bal <> c_owner then raise exception 'FAIL: owner payable % <> %', v_bal, c_owner; end if;

  select balance_cents into v_bal from public.ledger_account_balances
   where kind = 'platform_revenue';
  if v_bal <> c_platform then raise exception 'FAIL: platform revenue % <> %', v_bal, c_platform; end if;

  select balance_cents into v_bal from public.ledger_account_balances
   where kind = 'insurance_reserve';
  if v_bal <> c_insurance then raise exception 'FAIL: insurance reserve % <> %', v_bal, c_insurance; end if;

  -- 7) The core invariant: cash on hand = everything we owe + earned.
  select balance_cents into v_bal from public.ledger_account_balances
   where kind = 'mpesa_operating';
  if v_bal <> (c_owner + c_platform + c_insurance) then
    raise exception 'FAIL: mpesa_operating % <> liabilities+revenue %',
      v_bal, (c_owner + c_platform + c_insurance);
  end if;

  raise notice '════════════════════════════════════════════';
  raise notice '  ALL ASSERTIONS PASSED ✓';
  raise notice '  cash % = owner % + platform % + insurance %',
    v_bal, c_owner, c_platform, c_insurance;
  raise notice '════════════════════════════════════════════';
end $$;

-- Final grid: balances vs. expected (eyeball confirmation).
select
  b.kind,
  coalesce(b.user_id::text, '(platform)') as account,
  b.balance_cents,
  case b.kind
    when 'mpesa_operating'   then 25000
    when 'owner_payable'     then 18000
    when 'platform_revenue'  then 6000
    when 'insurance_reserve' then 1000
    when 'buyer_escrow'      then 0
  end as expected_cents
from public.ledger_account_balances b
order by b.kind;

rollback;
