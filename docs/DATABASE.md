# Substribe Database — Schema Guide

Postgres on Supabase. Migrations live in `supabase/migrations/` and are the
only way the schema changes. Money semantics are documented in
[LEDGER.md](LEDGER.md).

## Entity map

```
auth.users ──▶ profiles (identity, KYC tier, trust scores)
                  │
   ┌──────────────┼──────────────────┐
   │ owns         │ buys             │
   ▼              ▼                  ▼
listings ──▶ seats ──▶ memberships   waitlist_entries
(service_id)  (slot)   (tenure,       (auto-fill queue)
   │                    price snapshot)
   ▼                        │
services                    ├──▶ payments ──▶ payment_events (raw Daraja log)
(catalogue +                ├──▶ disputes ──▶ (payout freeze + resolution)
 risk flags)                ├──▶ ratings  ──▶ (profile aggregates via trigger)
                            └──▶ ledger_transactions ──▶ ledger_entries
payouts (owner B2C) ────────────────┘
notifications (outbox) · audit_log (append-only)
```

## Key design decisions

- **Cents everywhere.** All money is `bigint` KES cents. No floats, ever.
- **Seat ≠ membership.** A `seat` is a physical slot on a plan; a `membership`
  is one buyer's tenure on it. Buyer leaves → seat reopens, history stays.
  A partial unique index guarantees one live membership per seat.
- **Price snapshots.** `memberships` copies seat price + fee split at join
  time; `owner_take_cents` is a generated column. Owners repricing a listing
  never affects existing members.
- **State lives in enums.** Every lifecycle (listing, seat, membership,
  payment, payout, dispute) is a Postgres enum — invalid states are
  unrepresentable, and transitions are enforced in server code.
- **Append-only where it matters.** `ledger_*`, `payment_events`, `audit_log`
  reject UPDATE/DELETE via triggers.
- **Trust aggregates are computed, not client-writable.** Ratings and dispute
  triggers maintain `owner_rating`, `buyer_rating`, `seats_filled_count`,
  `disputes_against_count` on profiles; a trigger blocks users from editing
  those columns even though they can edit their own profile row.

## Access control (RLS) summary

| Table | anon | authenticated user | server (service role) |
|---|---|---|---|
| `services` | read active | read active | all |
| `listings` | read active | read active + CRUD own (KYC ≥ 1 to insert) | all |
| `seats` | read open (on active listings) | + read own (as buyer or listing owner) | all — **only writer** |
| `memberships` | — | read own (buyer or owner side) | all — **only writer** |
| `payments` / `payouts` | — | read own | all — **only writer** |
| `waitlist_entries` | — | CRUD own | all |
| `disputes` | — | read/insert as participant | all; admin resolves |
| `ratings` | — | read own; insert as counterparty | all |
| `notifications` | — | read own | all |
| `profiles` | via `owner_public_profiles` view only | own row (system columns trigger-guarded) | all |
| `ledger_*`, `payment_events`, `audit_log` | — | — | all — server-only |

Two deliberate patterns:

1. **Anything that gates money is server-only.** Clients never write seats,
   memberships, payments, payouts, or ledger rows. Reserving a seat, confirming
   access, releasing escrow — all go through Edge Functions with the service
   role. RLS is the safety net, not the gate.
2. **Public browsing without leaking identity.** `owner_public_profiles` is a
   definer-rights view exposing exactly: first name, ratings, seats filled,
   disputes, KYC tier, member-since. It is the only public window into
   `profiles`.

## Conventions

- Idempotency keys are deterministic strings (see LEDGER.md rule 3); they exist
  on `payments`, `payouts`, and `ledger_transactions`.
- `updated_at` is trigger-maintained on all mutable tables.
- Phone numbers are E.164 (`+2547XXXXXXXX`); the signup trigger normalises
  Supabase's `254...` form.
- New migration = new file, timestamp-prefixed, never edit an applied one.

## Running locally

```bash
supabase start        # local stack (Docker)
supabase db reset     # applies all migrations + seed.sql
```
