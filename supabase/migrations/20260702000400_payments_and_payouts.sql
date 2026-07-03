-- Substribe · Migration 0400 — M-Pesa payments (buyer side) and payouts (owner side)
-- payments = money in from / back to buyers (STK, C2B, Ratiba, refund via B2C).
-- payouts  = money out to owners (B2C).
-- payment_events = raw, append-only Daraja callback log for dedupe + audit.
-- Rows here are written by the server only; ledger postings happen only on
-- confirmed M-Pesa outcomes, never on initiation (docs/LEDGER.md).

create table public.payments (
  id                        uuid primary key default gen_random_uuid(),
  user_id                   uuid not null references public.profiles (id),
  membership_id             uuid references public.memberships (id),
  kind                      public.payment_kind not null,
  direction                 public.payment_direction not null,
  channel                   public.mpesa_channel not null,
  status                    public.payment_status not null default 'created',
  amount_cents              bigint not null check (amount_cents > 0),
  currency                  char(3) not null default 'KES',
  phone                     text not null,
  -- Deterministic key set by the caller (e.g. 'seat_join:{membership_id}:{period}')
  -- so retries can never double-charge.
  idempotency_key           text not null unique,
  mpesa_checkout_request_id text unique,   -- STK push
  mpesa_merchant_request_id text,
  mpesa_conversation_id     text unique,   -- B2C (refunds)
  mpesa_receipt             text unique,   -- e.g. 'QGH7SK61SU' — proof of movement
  account_reference         text,
  failure_reason            text,
  status_checked_at         timestamptz,   -- last transaction-status query (timeout recovery)
  raw_request               jsonb,
  raw_callback              jsonb,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now(),
  constraint payments_kind_direction check (
    (kind in ('seat_join', 'renewal', 'wallet_topup') and direction = 'inbound')
    or (kind = 'refund' and direction = 'outbound')
  ),
  -- A payment may not be marked succeeded without M-Pesa proof.
  constraint payments_success_needs_receipt check (
    status <> 'succeeded' or mpesa_receipt is not null
  )
);

create index payments_user_idx on public.payments (user_id);
create index payments_membership_idx on public.payments (membership_id)
  where membership_id is not null;
create index payments_open_idx on public.payments (status, created_at)
  where status in ('created', 'pending', 'timeout');

create trigger payments_set_updated_at
  before update on public.payments
  for each row execute function public.set_updated_at();

-- ── payment_events ───────────────────────────────────────────────────────────
-- Every callback/status-query result lands here first, verbatim. dedupe_key is
-- a server-computed hash of the Daraja identifiers, so a replayed callback
-- inserts nothing and processing stays idempotent.

create table public.payment_events (
  id              bigint generated always as identity primary key,
  payment_id      uuid references public.payments (id),
  source          text not null check (source in
                    ('stk_callback', 'c2b_validation', 'c2b_confirmation',
                     'b2c_result', 'b2c_timeout', 'status_query', 'ratiba_callback',
                     'manual')),
  dedupe_key      text unique,
  payload         jsonb not null,
  signature_valid boolean,
  processed       boolean not null default false,
  received_at     timestamptz not null default now()
);

create index payment_events_payment_idx on public.payment_events (payment_id);
create index payment_events_unprocessed_idx on public.payment_events (received_at)
  where not processed;

-- Rows may be updated exactly once — to flip processed → true. Nothing is ever
-- deleted: this table is the audit trail for every shilling that moved.
create trigger payment_events_no_delete
  before delete on public.payment_events
  for each row execute function public.forbid_change();

create trigger payment_events_no_edit_after_processing
  before update on public.payment_events
  for each row
  when (old.processed)
  execute function public.forbid_change();

-- ── payouts ──────────────────────────────────────────────────────────────────

create table public.payouts (
  id                          uuid primary key default gen_random_uuid(),
  owner_id                    uuid not null references public.profiles (id),
  amount_cents                bigint not null check (amount_cents > 0),
  currency                    char(3) not null default 'KES',
  status                      public.payout_status not null default 'pending',
  frozen_reason               text,
  idempotency_key             text not null unique,
  mpesa_conversation_id       text unique,
  originator_conversation_id  text,
  mpesa_receipt               text unique,
  scheduled_for               date,
  paid_at                     timestamptz,
  raw_result                  jsonb,
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now(),
  constraint payouts_paid_needs_receipt check (
    status <> 'paid' or mpesa_receipt is not null
  ),
  constraint payouts_frozen_needs_reason check (
    status <> 'frozen' or frozen_reason is not null
  )
);

create index payouts_owner_idx on public.payouts (owner_id);
create index payouts_queue_idx on public.payouts (status, scheduled_for)
  where status in ('pending', 'processing', 'frozen');

create trigger payouts_set_updated_at
  before update on public.payouts
  for each row execute function public.set_updated_at();
