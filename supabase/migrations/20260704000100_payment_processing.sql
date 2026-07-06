-- Substribe · Migration 0800 — payment processing engine
--
-- Implements docs/PAYMENTS.md §3–§5 and §8 as SQL functions. The state
-- machines live in Postgres so that every state change and its ledger post
-- commit in ONE transaction — the Edge Functions are thin HTTP adapters
-- around Daraja and call these via RPC with the service role.
--
-- Client-callable (authenticated, self-authorising via auth.uid()):
--   confirm_seat_access(seat_id), mark_seat_invited(seat_id)
-- Everything else is service-role only.

-- ── schema additions ─────────────────────────────────────────────────────────

alter table public.services
  add column platform_fee_bps  integer not null default 2400
    check (platform_fee_bps between 0 and 5000),
  add column insurance_fee_bps integer not null default 400
    check (insurance_fee_bps between 0 and 2000);

alter table public.payments
  -- per-payment secret embedded in the callback URL (PAYMENTS.md §2.1)
  add column callback_token text not null default encode(gen_random_bytes(24), 'hex'),
  add column stk_attempts   smallint not null default 0;

alter table public.memberships
  add column paid_at timestamptz;  -- anchor for the invite SLA timer

-- ══ JOIN FLOW ════════════════════════════════════════════════════════════════

-- Atomically: reserve the seat, snapshot prices into a membership, create the
-- payment row. Idempotent for retries: if the buyer already holds this seat
-- with a join in flight, the existing rows are returned (with the payment
-- reset to 'created' so a fresh STK push can be recorded).
create or replace function public.reserve_seat_and_start_join(
  p_seat_id      uuid,
  p_buyer_id     uuid,
  p_invite_email text,
  p_phone        text
) returns table (
  membership_id     uuid,
  payment_id        uuid,
  amount_cents      bigint,
  account_reference text,
  callback_token    text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_seat          public.seats%rowtype;
  v_listing       public.listings%rowtype;
  v_service       public.services%rowtype;
  v_membership_id uuid;
  v_payment       public.payments%rowtype;
  v_platform_fee  bigint;
  v_insurance_fee bigint;
begin
  if p_phone !~ '^\+[1-9]\d{6,14}$' then
    raise exception 'invalid_phone';
  end if;
  if p_invite_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'invalid_email';
  end if;

  perform 1 from public.profiles pr
   where pr.id = p_buyer_id and pr.suspended_at is null;
  if not found then
    raise exception 'buyer_not_eligible';
  end if;

  -- Retry path: this buyer already holds the seat with a join in flight.
  select m.id into v_membership_id
  from public.memberships m
  join public.seats s on s.id = m.seat_id
  where m.seat_id = p_seat_id
    and m.buyer_id = p_buyer_id
    and m.status = 'pending_payment'
    and s.status = 'reserved'
    and s.buyer_id = p_buyer_id;

  if found then
    select * into v_payment from public.payments p
    where p.idempotency_key = 'seat_join:' || v_membership_id;

    if v_payment.status = 'succeeded' then
      raise exception 'already_paid';
    end if;
    if v_payment.status = 'pending' then
      raise exception 'payment_pending';  -- STK already on the buyer's phone
    end if;

    update public.payments p
       set status = 'created', failure_reason = null, phone = p_phone
     where p.id = v_payment.id;
    -- refresh the reservation clock so the expiry sweep spares an active retry
    update public.seats s
       set reserved_at = now(), invite_email = p_invite_email
     where s.id = p_seat_id;

    return query select v_membership_id, v_payment.id, v_payment.amount_cents,
                        v_payment.account_reference, v_payment.callback_token;
    return;
  end if;

  -- Fresh join: one atomic claim — zero rows means someone else got the seat.
  update public.seats s
     set status = 'reserved', buyer_id = p_buyer_id,
         invite_email = p_invite_email, reserved_at = now()
   where s.id = p_seat_id and s.status = 'open'
  returning * into v_seat;
  if not found then
    raise exception 'seat_unavailable';
  end if;

  select * into v_listing from public.listings l
   where l.id = v_seat.listing_id and l.status = 'active';
  if not found then
    raise exception 'listing_not_active';
  end if;
  if v_listing.owner_id = p_buyer_id then
    raise exception 'cannot_join_own_listing';
  end if;

  select * into v_service from public.services sv
   where sv.id = v_listing.service_id and sv.is_active;
  if not found then
    raise exception 'service_not_active';
  end if;

  if v_listing.seat_price_cents % 100 <> 0 then
    raise exception 'price_not_whole_shillings';  -- M-Pesa moves whole KSh
  end if;

  v_platform_fee  := (v_listing.seat_price_cents * v_service.platform_fee_bps)  / 10000;
  v_insurance_fee := (v_listing.seat_price_cents * v_service.insurance_fee_bps) / 10000;

  insert into public.memberships
    (seat_id, buyer_id, status, billing_method, seat_price_cents,
     platform_fee_cents, insurance_fee_cents, currency)
  values
    (p_seat_id, p_buyer_id, 'pending_payment', 'stk_reminder',
     v_listing.seat_price_cents, v_platform_fee, v_insurance_fee, v_listing.currency)
  returning id into v_membership_id;

  insert into public.payments
    (user_id, membership_id, kind, direction, channel, status, amount_cents,
     currency, phone, idempotency_key, account_reference)
  values
    (p_buyer_id, v_membership_id, 'seat_join', 'inbound', 'stk_push', 'created',
     v_listing.seat_price_cents, v_listing.currency, p_phone,
     'seat_join:' || v_membership_id,
     'SUB' || upper(left(replace(v_membership_id::text, '-', ''), 8)))
  returning * into v_payment;

  return query select v_membership_id, v_payment.id, v_payment.amount_cents,
                      v_payment.account_reference, v_payment.callback_token;
end;
$$;

create or replace function public.record_stk_initiated(
  p_payment_id          uuid,
  p_checkout_request_id text,
  p_merchant_request_id text,
  p_raw                 jsonb
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.payments p
     set status = 'pending',
         mpesa_checkout_request_id = p_checkout_request_id,
         mpesa_merchant_request_id = p_merchant_request_id,
         raw_request = p_raw,
         stk_attempts = p.stk_attempts + 1
   where p.id = p_payment_id and p.status = 'created';
  if not found then
    raise exception 'payment_not_in_created_state';
  end if;
end;
$$;

create or replace function public.record_stk_request_failed(
  p_payment_id uuid,
  p_reason     text
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.payments p
     set status = 'failed', failure_reason = left(p_reason, 500)
   where p.id = p_payment_id and p.status = 'created';
end;
$$;

-- ══ EVENT PROCESSOR (the inbound state machine) ══════════════════════════════

-- Processes one raw Daraja event: advances the payment, posts to the ledger,
-- moves the membership, queues notifications — all in this one transaction.
-- Fully idempotent: re-running on a processed event or terminal payment is a
-- no-op. Returns an outcome tag for logging.
create or replace function public.process_payment_event(p_event_id bigint)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event        public.payment_events%rowtype;
  v_cb           jsonb;
  v_checkout     text;
  v_code         integer;
  v_desc         text;
  v_receipt      text;
  v_amount_kes   numeric;
  v_item         jsonb;
  v_payment      public.payments%rowtype;
  v_m            public.memberships%rowtype;
  v_owner        uuid;
  v_sla_hours    smallint;
  v_invite_email text;
  v_acc_float    uuid;
  v_acc_escrow   uuid;
  v_acc_wallet   uuid;
begin
  select * into v_event from public.payment_events e
   where e.id = p_event_id and not e.processed
   for update;
  if not found then
    return 'already_processed';
  end if;

  if v_event.source not in ('stk_callback', 'status_query') then
    update public.payment_events set processed = true where id = p_event_id;
    return 'ignored_source';
  end if;

  v_cb       := coalesce(v_event.payload -> 'Body' -> 'stkCallback', v_event.payload);
  v_checkout := v_cb ->> 'CheckoutRequestID';
  v_code     := coalesce(nullif(v_cb ->> 'ResultCode', '')::integer, -1);
  v_desc     := v_cb ->> 'ResultDesc';

  select * into v_payment from public.payments p
   where p.mpesa_checkout_request_id = v_checkout
   for update;
  if not found then
    insert into public.audit_log (actor_type, action, target_table, target_id, after)
    values ('system', 'orphan_payment_event', 'payment_events', p_event_id::text, v_cb);
    update public.payment_events set processed = true where id = p_event_id;
    return 'orphan';
  end if;

  if v_payment.status in ('succeeded', 'failed', 'reversed') then
    update public.payment_events
       set processed = true, payment_id = v_payment.id where id = p_event_id;
    return 'noop_terminal';
  end if;

  if v_code <> 0 then
    -- ── failure path ──
    update public.payments
       set status = 'failed',
           failure_reason = coalesce(v_desc, 'unknown') || ' (code ' || v_code || ')',
           raw_callback = v_event.payload
     where id = v_payment.id;
    update public.payment_events
       set processed = true, payment_id = v_payment.id where id = p_event_id;
    return 'failed';
  end if;

  -- ── success path ──
  for v_item in
    select * from jsonb_array_elements(
      coalesce(v_cb -> 'CallbackMetadata' -> 'Item', '[]'::jsonb))
  loop
    case v_item ->> 'Name'
      when 'MpesaReceiptNumber' then v_receipt    := v_item ->> 'Value';
      when 'Amount'             then v_amount_kes := (v_item ->> 'Value')::numeric;
      else null;
    end case;
  end loop;

  if v_receipt is null then
    -- STK Query confirms success but carries no receipt; success posts require
    -- proof (LEDGER.md rule 4). Park for the late callback / reconciliation.
    insert into public.audit_log (actor_type, action, target_table, target_id, after)
    values ('system', 'stk_success_without_receipt', 'payments', v_payment.id::text, v_cb);
    update public.payment_events
       set processed = true, payment_id = v_payment.id where id = p_event_id;
    return 'success_no_receipt_parked';
  end if;

  if v_amount_kes is not null
     and (v_amount_kes * 100)::bigint <> v_payment.amount_cents then
    insert into public.audit_log (actor_type, action, target_table, target_id, after)
    values ('system', 'payment_amount_mismatch', 'payments', v_payment.id::text, v_cb);
    update public.payment_events
       set processed = true, payment_id = v_payment.id where id = p_event_id;
    return 'amount_mismatch_parked';
  end if;

  update public.payments
     set status = 'succeeded', mpesa_receipt = v_receipt,
         raw_callback = v_event.payload
   where id = v_payment.id;

  select * into v_m from public.memberships
   where id = v_payment.membership_id for update;

  v_acc_float  := public.get_or_create_ledger_account('mpesa_operating', null);
  v_acc_escrow := public.get_or_create_ledger_account('buyer_escrow', v_payment.user_id);

  perform public.post_ledger_transaction(
    'escrow_hold',
    'escrow_hold:' || v_payment.id,
    jsonb_build_array(
      jsonb_build_object('account_id', v_acc_float,  'direction', 'debit',
                         'amount_cents', v_payment.amount_cents),
      jsonb_build_object('account_id', v_acc_escrow, 'direction', 'credit',
                         'amount_cents', v_payment.amount_cents)
    ),
    'M-Pesa ' || v_receipt, v_m.id, v_payment.id, null, null
  );

  if v_m.status = 'pending_payment' then
    update public.memberships
       set status = 'awaiting_invite',
           paid_at = now(),
           current_period_start = current_date,
           current_period_end   = (current_date + interval '1 month')::date,
           next_billing_at      = (current_date + interval '1 month')::date::timestamptz
                                    + interval '16 hours'
     where id = v_m.id;

    select l.owner_id, l.invite_sla_hours, s.invite_email
      into v_owner, v_sla_hours, v_invite_email
    from public.seats s
    join public.listings l on l.id = s.listing_id
    where s.id = v_m.seat_id;

    insert into public.notifications (user_id, channel, template, payload) values
      (v_payment.user_id, 'whatsapp', 'payment_received',
       jsonb_build_object('membership_id', v_m.id,
                          'amount_cents', v_payment.amount_cents,
                          'receipt', v_receipt)),
      (v_owner, 'whatsapp', 'invite_needed',
       jsonb_build_object('membership_id', v_m.id,
                          'invite_email', v_invite_email,
                          'sla_hours', v_sla_hours,
                          'owner_take_cents', v_m.owner_take_cents));

    update public.payment_events
       set processed = true, payment_id = v_payment.id where id = p_event_id;
    return 'succeeded';
  end if;

  -- Money arrived for a dead membership (reservation expired before a late
  -- callback landed). Hold it, then bounce it straight to the buyer's wallet.
  v_acc_wallet := public.get_or_create_ledger_account('wallet', v_payment.user_id);
  perform public.post_ledger_transaction(
    'wallet_refund',
    'wallet_refund:' || v_m.id,
    jsonb_build_array(
      jsonb_build_object('account_id', v_acc_escrow, 'direction', 'debit',
                         'amount_cents', v_payment.amount_cents),
      jsonb_build_object('account_id', v_acc_wallet, 'direction', 'credit',
                         'amount_cents', v_payment.amount_cents)
    ),
    'late payment auto-refunded to wallet', v_m.id, v_payment.id, null, null
  );
  insert into public.notifications (user_id, channel, template, payload)
  values (v_payment.user_id, 'whatsapp', 'late_payment_refunded',
          jsonb_build_object('membership_id', v_m.id,
                             'amount_cents', v_payment.amount_cents));

  update public.payment_events
     set processed = true, payment_id = v_payment.id where id = p_event_id;
  return 'succeeded_late_refunded';
end;
$$;

-- ══ TIMEOUT RECOVERY ═════════════════════════════════════════════════════════

create or replace function public.mark_payment_timeout(p_payment_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.payments
     set status = 'timeout'
   where id = p_payment_id and status = 'pending';
end;
$$;

-- Pending STK payments old enough to query (PAYMENTS.md §3: first query at
-- T+3min, re-query no sooner than every 2min, give up after 24h → nightly
-- reconciliation owns it).
create or replace function public.payments_needing_stk_query()
returns table (payment_id uuid, checkout_request_id text, created_at timestamptz)
language sql
security definer
set search_path = ''
as $$
  select p.id, p.mpesa_checkout_request_id, p.created_at
  from public.payments p
  where p.status = 'pending'
    and p.channel = 'stk_push'
    and p.mpesa_checkout_request_id is not null
    and p.created_at < now() - interval '3 minutes'
    and coalesce(p.status_checked_at, timestamptz 'epoch') < now() - interval '2 minutes'
    and p.created_at > now() - interval '24 hours'
  order by p.created_at
  limit 50;
$$;

-- ══ SWEEPS (idempotent, cron-driven) ═════════════════════════════════════════

-- Seats reserved >15min with no live payment go back on the market.
create or replace function public.expire_stale_reservations()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_count integer := 0;
begin
  for r in
    select s.id as seat_id, m.id as mem_id
    from public.seats s
    join public.memberships m on m.seat_id = s.id and m.status = 'pending_payment'
    where s.status = 'reserved'
      and s.reserved_at < now() - interval '15 minutes'
      and not exists (
        select 1 from public.payments p
        where p.membership_id = m.id
          and (p.status = 'succeeded'
               or (p.status in ('pending', 'timeout')
                   and p.created_at > now() - interval '30 minutes'))
      )
    for update of s, m skip locked
  loop
    update public.payments
       set status = 'failed', failure_reason = 'reservation_expired'
     where membership_id = r.mem_id and status = 'created';
    update public.memberships
       set status = 'cancelled', cancelled_at = now()
     where id = r.mem_id;
    update public.seats
       set status = 'open', buyer_id = null, invite_email = null, reserved_at = null
     where id = r.seat_id;
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- ══ ESCROW LIFECYCLE ═════════════════════════════════════════════════════════

-- Release held funds to the owner (split per membership snapshot) and
-- activate the membership. Called by confirm_seat_access and the 48h
-- auto-release sweep.
create or replace function public.release_escrow(p_membership_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_m           public.memberships%rowtype;
  v_owner       uuid;
  v_acc_escrow  uuid;
  v_acc_payable uuid;
  v_acc_revenue uuid;
  v_acc_reserve uuid;
  v_entries     jsonb;
begin
  select * into v_m from public.memberships
   where id = p_membership_id for update;
  if not found then
    raise exception 'membership_not_found';
  end if;
  if v_m.status <> 'awaiting_invite' then
    raise exception 'membership_not_awaiting_invite';
  end if;
  if v_m.paid_at is null then
    raise exception 'membership_not_paid';
  end if;

  select l.owner_id into v_owner
  from public.seats s
  join public.listings l on l.id = s.listing_id
  where s.id = v_m.seat_id;

  v_acc_escrow  := public.get_or_create_ledger_account('buyer_escrow', v_m.buyer_id);
  v_acc_payable := public.get_or_create_ledger_account('owner_payable', v_owner);

  v_entries := jsonb_build_array(
    jsonb_build_object('account_id', v_acc_escrow,  'direction', 'debit',
                       'amount_cents', v_m.seat_price_cents),
    jsonb_build_object('account_id', v_acc_payable, 'direction', 'credit',
                       'amount_cents', v_m.owner_take_cents)
  );
  if v_m.platform_fee_cents > 0 then
    v_acc_revenue := public.get_or_create_ledger_account('platform_revenue', null);
    v_entries := v_entries || jsonb_build_object(
      'account_id', v_acc_revenue, 'direction', 'credit',
      'amount_cents', v_m.platform_fee_cents);
  end if;
  if v_m.insurance_fee_cents > 0 then
    v_acc_reserve := public.get_or_create_ledger_account('insurance_reserve', null);
    v_entries := v_entries || jsonb_build_object(
      'account_id', v_acc_reserve, 'direction', 'credit',
      'amount_cents', v_m.insurance_fee_cents);
  end if;

  perform public.post_ledger_transaction(
    'escrow_release',
    'escrow_release:' || v_m.id || ':' || coalesce(v_m.current_period_start::text, 'joined'),
    v_entries,
    null, v_m.id, null, null, null
  );

  update public.memberships set status = 'active' where id = v_m.id;

  insert into public.notifications (user_id, channel, template, payload)
  values (v_owner, 'whatsapp', 'earnings_released',
          jsonb_build_object('membership_id', v_m.id,
                             'owner_take_cents', v_m.owner_take_cents));
end;
$$;

-- Full refund to the buyer's wallet (pre-release only), seat back on the
-- market. Goodwill (KSh 20) comes from the insurance reserve once it has
-- funds; before that it books as contra-revenue so no balance goes negative.
create or replace function public.refund_to_wallet(
  p_membership_id uuid,
  p_reason        text,
  p_goodwill      boolean default false
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_m               public.memberships%rowtype;
  v_owner           uuid;
  v_acc_escrow      uuid;
  v_acc_wallet      uuid;
  v_acc_src         uuid;
  v_goodwill_cents  bigint := 2000;
  v_reserve_balance bigint;
begin
  select * into v_m from public.memberships
   where id = p_membership_id for update;
  if not found then
    raise exception 'membership_not_found';
  end if;
  if v_m.status <> 'awaiting_invite' then
    raise exception 'refund_only_before_release';
  end if;

  select l.owner_id into v_owner
  from public.seats s
  join public.listings l on l.id = s.listing_id
  where s.id = v_m.seat_id;

  v_acc_escrow := public.get_or_create_ledger_account('buyer_escrow', v_m.buyer_id);
  v_acc_wallet := public.get_or_create_ledger_account('wallet', v_m.buyer_id);

  perform public.post_ledger_transaction(
    'wallet_refund',
    'wallet_refund:' || v_m.id,
    jsonb_build_array(
      jsonb_build_object('account_id', v_acc_escrow, 'direction', 'debit',
                         'amount_cents', v_m.seat_price_cents),
      jsonb_build_object('account_id', v_acc_wallet, 'direction', 'credit',
                         'amount_cents', v_m.seat_price_cents)
    ),
    'refund: ' || p_reason, v_m.id, null, null, null
  );

  if p_goodwill then
    select b.balance_cents into v_reserve_balance
    from public.ledger_account_balances b
    where b.kind = 'insurance_reserve' and b.user_id is null;

    v_acc_src := case
      when coalesce(v_reserve_balance, 0) >= v_goodwill_cents
        then public.get_or_create_ledger_account('insurance_reserve', null)
      else public.get_or_create_ledger_account('platform_revenue', null)
    end;

    perform public.post_ledger_transaction(
      'goodwill_credit',
      'goodwill_credit:' || v_m.id,
      jsonb_build_array(
        jsonb_build_object('account_id', v_acc_src,    'direction', 'debit',
                           'amount_cents', v_goodwill_cents),
        jsonb_build_object('account_id', v_acc_wallet, 'direction', 'credit',
                           'amount_cents', v_goodwill_cents)
      ),
      'goodwill: ' || p_reason, v_m.id, null, null, null
    );
  end if;

  update public.memberships
     set status = 'cancelled', cancelled_at = now()
   where id = v_m.id;
  update public.seats
     set status = 'open', buyer_id = null, invite_email = null,
         reserved_at = null, invited_at = null
   where id = v_m.seat_id;

  insert into public.notifications (user_id, channel, template, payload) values
    (v_m.buyer_id, 'whatsapp', 'refund_wallet_credited',
     jsonb_build_object('membership_id', v_m.id,
                        'amount_cents', v_m.seat_price_cents,
                        'goodwill_cents', case when p_goodwill then v_goodwill_cents else 0 end,
                        'reason', p_reason)),
    (v_owner, 'whatsapp', 'seat_reopened',
     jsonb_build_object('membership_id', v_m.id, 'reason', p_reason));
end;
$$;

-- ── client-callable actions ──────────────────────────────────────────────────

-- Owner: "I've sent the invite." reserved → invited, starts the 48h
-- auto-release clock.
create or replace function public.mark_seat_invited(p_seat_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_seat  public.seats%rowtype;
  v_buyer uuid;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  select * into v_seat from public.seats where id = p_seat_id for update;
  if not found then
    raise exception 'seat_not_found';
  end if;
  perform 1 from public.listings l
   where l.id = v_seat.listing_id and l.owner_id = v_uid;
  if not found then
    raise exception 'not_your_listing';
  end if;
  if v_seat.status <> 'reserved' then
    raise exception 'seat_not_in_reserved_state';
  end if;
  perform 1 from public.memberships m
   where m.seat_id = p_seat_id and m.status = 'awaiting_invite';
  if not found then
    raise exception 'buyer_has_not_paid';  -- invite only after money is in escrow
  end if;

  update public.seats
     set status = 'invited', invited_at = now()
   where id = p_seat_id;

  select buyer_id into v_buyer from public.seats where id = p_seat_id;
  insert into public.notifications (user_id, channel, template, payload)
  values (v_buyer, 'whatsapp', 'confirm_access',
          jsonb_build_object('seat_id', p_seat_id));
end;
$$;

-- Buyer: "I have access." Activates the seat and releases escrow. Allowed
-- from 'reserved' too — owners often send the provider invite without
-- updating Substribe first; the buyer's confirmation is the stronger signal.
create or replace function public.confirm_seat_access(p_seat_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_seat public.seats%rowtype;
  v_mid  uuid;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  select * into v_seat from public.seats where id = p_seat_id for update;
  if not found or v_seat.buyer_id is distinct from v_uid then
    raise exception 'not_your_seat';
  end if;
  if v_seat.status not in ('reserved', 'invited') then
    raise exception 'seat_not_confirmable';
  end if;

  select m.id into v_mid from public.memberships m
   where m.seat_id = p_seat_id and m.status = 'awaiting_invite';
  if not found then
    raise exception 'nothing_to_confirm';
  end if;

  update public.seats
     set status = 'active', activated_at = now(),
         invited_at = coalesce(invited_at, now())
   where id = p_seat_id;

  perform public.release_escrow(v_mid);
end;
$$;

-- ── escrow timers ────────────────────────────────────────────────────────────

-- 48h after invite with no confirmation and no dispute → auto-release
-- (protects owners from silent buyers; buyer is told at invite time).
create or replace function public.auto_release_confirmed_silent()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_count integer := 0;
begin
  for r in
    select s.id as seat_id, m.id as mem_id
    from public.seats s
    join public.memberships m on m.seat_id = s.id and m.status = 'awaiting_invite'
    where s.status = 'invited'
      and s.invited_at < now() - interval '48 hours'
      and not exists (
        select 1 from public.disputes d
        where d.membership_id = m.id and d.status in ('open', 'under_review')
      )
    for update of s, m skip locked
  loop
    update public.seats
       set status = 'active', activated_at = now()
     where id = r.seat_id;
    perform public.release_escrow(r.mem_id);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- Invite SLA breached (owner never invited) → full refund to wallet with
-- goodwill, seat reopened, incident logged.
create or replace function public.sweep_invite_sla()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_count integer := 0;
begin
  for r in
    select m.id as mem_id
    from public.memberships m
    join public.seats s on s.id = m.seat_id
    join public.listings l on l.id = s.listing_id
    where m.status = 'awaiting_invite'
      and s.status = 'reserved'   -- owner never marked invited
      and m.paid_at is not null
      and m.paid_at < now() - make_interval(hours => l.invite_sla_hours)
    for update of m skip locked
  loop
    perform public.refund_to_wallet(r.mem_id, 'invite_sla_breach', true);
    insert into public.audit_log (actor_type, action, target_table, target_id)
    values ('system', 'invite_sla_breach', 'memberships', r.mem_id::text);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- ── grants ───────────────────────────────────────────────────────────────────

-- Service-role only (Edge Functions / workers):
revoke execute on function public.reserve_seat_and_start_join(uuid, uuid, text, text) from public, anon, authenticated;
revoke execute on function public.record_stk_initiated(uuid, text, text, jsonb)       from public, anon, authenticated;
revoke execute on function public.record_stk_request_failed(uuid, text)               from public, anon, authenticated;
revoke execute on function public.process_payment_event(bigint)                       from public, anon, authenticated;
revoke execute on function public.mark_payment_timeout(uuid)                          from public, anon, authenticated;
revoke execute on function public.payments_needing_stk_query()                        from public, anon, authenticated;
revoke execute on function public.expire_stale_reservations()                         from public, anon, authenticated;
revoke execute on function public.release_escrow(uuid)                                from public, anon, authenticated;
revoke execute on function public.refund_to_wallet(uuid, text, boolean)               from public, anon, authenticated;
revoke execute on function public.auto_release_confirmed_silent()                     from public, anon, authenticated;
revoke execute on function public.sweep_invite_sla()                                  from public, anon, authenticated;

-- Client-callable (self-authorising via auth.uid()):
grant execute on function public.mark_seat_invited(uuid)    to authenticated;
grant execute on function public.confirm_seat_access(uuid)  to authenticated;
revoke execute on function public.mark_seat_invited(uuid)   from public, anon;
revoke execute on function public.confirm_seat_access(uuid) from public, anon;
