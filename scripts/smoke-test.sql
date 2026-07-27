-- Substribe local smoke test — run after `supabase db reset`.
-- Verifies the schema loaded, the catalogue seeded, and the ledger balance
-- invariant holds on an empty system. Read-only except for temp checks.

\echo '== tables =='
select count(*) as table_count
from information_schema.tables
where table_schema = 'public' and table_type = 'BASE TABLE';

\echo '== money functions present =='
select proname
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and proname in ('reserve_seat_and_start_join','process_payment_event',
                  'release_escrow','refund_to_wallet','post_ledger_transaction',
                  'create_listing','claim_notifications')
order by proname;

\echo '== service catalogue (Spotify should be active) =='
select slug, is_active, seats_total, plan_price_cents, suggested_seat_price_cents
from public.services order by is_active desc, slug;

\echo '== ledger starts empty and balanced =='
select count(*) as ledger_entries from public.ledger_entries;

\echo '== RLS enabled on money tables =='
select relname, relrowsecurity
from pg_class
where relnamespace = 'public'::regnamespace
  and relname in ('ledger_entries','payments','payouts','memberships','seats')
order by relname;
