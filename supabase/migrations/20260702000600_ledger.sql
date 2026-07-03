-- Substribe · Migration 0600 — double-entry ledger (the money truth)
--
-- Rules (enforced here, not by convention):
--   1. Every transaction balances: sum(debits) = sum(credits). Deferred
--      constraint trigger — checked at commit, so multi-row posts are atomic.
--   2. Entries and transactions are immutable. Mistakes are corrected by
--      posting a reversing transaction, never by editing history.
--   3. Every post is idempotent via ledger_transactions.idempotency_key.
--   4. Clients never touch these tables (no RLS policies + explicit revoke).
-- Posting matrix and worked examples: docs/LEDGER.md.

-- ── accounts ─────────────────────────────────────────────────────────────────
-- Platform accounts (mpesa_operating, platform_revenue, insurance_reserve) are
-- singletons with user_id null. User accounts (buyer_escrow, wallet,
-- owner_payable) are one per user per kind, created lazily.

create table public.ledger_accounts (
  id         uuid primary key default gen_random_uuid(),
  kind       public.ledger_account_kind not null,
  user_id    uuid references public.profiles (id),
  currency   char(3) not null default 'KES',
  created_at timestamptz not null default now(),
  constraint ledger_accounts_scope check (
    (kind in ('mpesa_operating', 'platform_revenue', 'insurance_reserve')
       and user_id is null)
    or
    (kind in ('buyer_escrow', 'wallet', 'owner_payable')
       and user_id is not null)
  )
);

create unique index ledger_accounts_platform_singleton
  on public.ledger_accounts (kind) where user_id is null;
create unique index ledger_accounts_user_unique
  on public.ledger_accounts (kind, user_id) where user_id is not null;

-- ── transactions & entries ───────────────────────────────────────────────────

create table public.ledger_transactions (
  id              uuid primary key default gen_random_uuid(),
  kind            text not null check (kind in
                    ('escrow_hold', 'escrow_release', 'escrow_refund',
                     'wallet_topup', 'wallet_charge', 'wallet_refund',
                     'goodwill_credit', 'payout', 'payout_reversal',
                     'payment_reversal', 'insurance_claim', 'adjustment')),
  idempotency_key text not null unique,
  membership_id   uuid references public.memberships (id),
  payment_id      uuid references public.payments (id),
  payout_id       uuid references public.payouts (id),
  dispute_id      uuid references public.disputes (id),
  memo            text,
  created_at      timestamptz not null default now()
);

create index ledger_tx_membership_idx on public.ledger_transactions (membership_id)
  where membership_id is not null;
create index ledger_tx_payment_idx on public.ledger_transactions (payment_id)
  where payment_id is not null;

create table public.ledger_entries (
  id             bigint generated always as identity primary key,
  transaction_id uuid not null references public.ledger_transactions (id),
  account_id     uuid not null references public.ledger_accounts (id),
  direction      public.entry_direction not null,
  amount_cents   bigint not null check (amount_cents > 0),
  created_at     timestamptz not null default now()
);

create index ledger_entries_account_idx on public.ledger_entries (account_id);
create index ledger_entries_tx_idx on public.ledger_entries (transaction_id);

-- Rule 2: immutability.
create trigger ledger_transactions_immutable
  before update or delete on public.ledger_transactions
  for each row execute function public.forbid_change();

create trigger ledger_entries_immutable
  before update or delete on public.ledger_entries
  for each row execute function public.forbid_change();

-- Rule 1: balance, enforced at commit.
create or replace function public.assert_transaction_balanced()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_imbalance bigint;
begin
  select coalesce(sum(
           case e.direction when 'debit' then e.amount_cents else -e.amount_cents end
         ), 0)
    into v_imbalance
  from public.ledger_entries e
  where e.transaction_id = new.transaction_id;

  if v_imbalance <> 0 then
    raise exception 'ledger transaction % is unbalanced by % cents',
      new.transaction_id, v_imbalance;
  end if;
  return null;
end;
$$;

create constraint trigger ledger_entries_balanced
  after insert on public.ledger_entries
  deferrable initially deferred
  for each row execute function public.assert_transaction_balanced();

-- ── posting API (server-side only) ───────────────────────────────────────────

create or replace function public.get_or_create_ledger_account(
  p_kind public.ledger_account_kind,
  p_user uuid default null
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  select a.id into v_id
  from public.ledger_accounts a
  where a.kind = p_kind and a.user_id is not distinct from p_user;
  if found then
    return v_id;
  end if;

  begin
    insert into public.ledger_accounts (kind, user_id)
    values (p_kind, p_user)
    returning id into v_id;
  exception when unique_violation then
    select a.id into v_id
    from public.ledger_accounts a
    where a.kind = p_kind and a.user_id is not distinct from p_user;
  end;

  return v_id;
end;
$$;

-- Atomically post a balanced transaction. Entries arrive as a jsonb array:
--   [{"account_id": "...", "direction": "debit",  "amount_cents": 25000},
--    {"account_id": "...", "direction": "credit", "amount_cents": 25000}]
-- Re-posting the same idempotency_key returns the existing transaction id and
-- writes nothing.
create or replace function public.post_ledger_transaction(
  p_kind            text,
  p_idempotency_key text,
  p_entries         jsonb,
  p_memo            text default null,
  p_membership_id   uuid default null,
  p_payment_id      uuid default null,
  p_payout_id       uuid default null,
  p_dispute_id      uuid default null
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tx        uuid;
  v_entry     jsonb;
  v_imbalance bigint := 0;
begin
  if p_entries is null or jsonb_array_length(p_entries) < 2 then
    raise exception 'a ledger transaction needs at least two entries';
  end if;

  -- Validate balance before writing anything, for a fast, clean failure.
  for v_entry in select * from jsonb_array_elements(p_entries) loop
    v_imbalance := v_imbalance + (
      case (v_entry ->> 'direction')
        when 'debit' then (v_entry ->> 'amount_cents')::bigint
        else -((v_entry ->> 'amount_cents')::bigint)
      end
    );
  end loop;
  if v_imbalance <> 0 then
    raise exception 'refusing unbalanced post (off by % cents)', v_imbalance;
  end if;

  begin
    insert into public.ledger_transactions
      (kind, idempotency_key, memo, membership_id, payment_id, payout_id, dispute_id)
    values
      (p_kind, p_idempotency_key, p_memo, p_membership_id, p_payment_id,
       p_payout_id, p_dispute_id)
    returning id into v_tx;
  exception when unique_violation then
    select t.id into v_tx
    from public.ledger_transactions t
    where t.idempotency_key = p_idempotency_key;
    return v_tx; -- already posted; idempotent no-op
  end;

  for v_entry in select * from jsonb_array_elements(p_entries) loop
    insert into public.ledger_entries (transaction_id, account_id, direction, amount_cents)
    values (
      v_tx,
      (v_entry ->> 'account_id')::uuid,
      (v_entry ->> 'direction')::public.entry_direction,
      (v_entry ->> 'amount_cents')::bigint
    );
  end loop;

  return v_tx;
end;
$$;

-- Money functions are server-only.
revoke execute on function public.post_ledger_transaction(text, text, jsonb, text, uuid, uuid, uuid, uuid)
  from public, anon, authenticated;
revoke execute on function public.get_or_create_ledger_account(public.ledger_account_kind, uuid)
  from public, anon, authenticated;

-- ── balances ─────────────────────────────────────────────────────────────────
-- balance_cents follows each account's normal balance: assets (mpesa_operating)
-- are debit-normal; liabilities and revenue are credit-normal. Every balance
-- should therefore read >= 0; a negative number means a bug or fraud.

create view public.ledger_account_balances
with (security_invoker = false) as
select
  a.id as account_id,
  a.kind,
  a.user_id,
  a.currency,
  coalesce(sum(e.amount_cents) filter (where e.direction = 'debit'), 0)  as debits_cents,
  coalesce(sum(e.amount_cents) filter (where e.direction = 'credit'), 0) as credits_cents,
  case when a.kind = 'mpesa_operating'
    then coalesce(sum(case e.direction when 'debit' then e.amount_cents else -e.amount_cents end), 0)
    else coalesce(sum(case e.direction when 'credit' then e.amount_cents else -e.amount_cents end), 0)
  end as balance_cents
from public.ledger_accounts a
left join public.ledger_entries e on e.account_id = a.id
group by a.id;

revoke all on public.ledger_account_balances from anon, authenticated;
