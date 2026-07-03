-- Substribe · Migration 0100 — extensions, enums, shared helpers
-- All money amounts platform-wide are stored as bigint cents (KES cents).

create extension if not exists pgcrypto;
create extension if not exists citext;

-- ── Enums ────────────────────────────────────────────────────────────────────

create type public.service_category as enum
  ('music', 'streaming', 'productivity', 'storage', 'ai', 'other');

-- How a buyer gets their own seat. If a service needs a shared password, it
-- does not belong in this enum — or on Substribe (SCOPE.md §1, hard constraint).
create type public.invite_mechanism as enum
  ('email_invite', 'link_invite', 'profile_add');

create type public.risk_rating as enum ('low', 'medium', 'high');

create type public.listing_status as enum ('draft', 'active', 'paused', 'delisted');

create type public.seat_status as enum
  ('open', 'reserved', 'invited', 'active', 'suspended', 'ended');

create type public.membership_status as enum
  ('pending_payment', 'awaiting_invite', 'active', 'past_due',
   'suspended', 'cancelled', 'ended');

create type public.billing_method as enum ('stk_reminder', 'ratiba', 'wallet');

create type public.payment_kind as enum
  ('seat_join', 'renewal', 'wallet_topup', 'refund');

create type public.payment_direction as enum ('inbound', 'outbound');

-- 'created'  = row exists, nothing sent to Daraja yet
-- 'pending'  = sent to Daraja, awaiting callback / status query
-- 'timeout'  = no callback and status query inconclusive — needs reconciliation
create type public.payment_status as enum
  ('created', 'pending', 'succeeded', 'failed', 'timeout', 'reversed');

create type public.mpesa_channel as enum
  ('stk_push', 'c2b', 'b2c', 'ratiba', 'manual');

create type public.payout_status as enum
  ('pending', 'processing', 'paid', 'failed', 'frozen');

create type public.dispute_reason as enum
  ('no_invite', 'lost_access', 'wrong_service', 'billing', 'other');

create type public.dispute_status as enum
  ('open', 'under_review', 'resolved_refunded', 'resolved_rematched',
   'resolved_released', 'rejected');

-- Ledger chart of accounts. Asset: mpesa_operating. Liabilities: buyer_escrow,
-- wallet, owner_payable, insurance_reserve. Revenue: platform_revenue.
create type public.ledger_account_kind as enum
  ('mpesa_operating', 'buyer_escrow', 'wallet', 'owner_payable',
   'platform_revenue', 'insurance_reserve');

create type public.entry_direction as enum ('debit', 'credit');

create type public.waitlist_status as enum ('waiting', 'matched', 'cancelled', 'expired');

create type public.notification_channel as enum ('whatsapp', 'sms', 'email', 'inapp');

create type public.notification_status as enum ('queued', 'sent', 'delivered', 'failed');

-- ── Shared trigger helpers ───────────────────────────────────────────────────

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace function public.forbid_change()
returns trigger
language plpgsql
as $$
begin
  raise exception '%.% is append-only: % not allowed. Post a reversing transaction instead.',
    tg_table_schema, tg_table_name, tg_op;
end;
$$;
