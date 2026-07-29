# Substribe — Architecture

Companion to `HANDOFF.md`. Everything here was read from the code at commit `07c33d9`.

---

## 1. The governing idea

> **Anything that moves money is a Postgres function. The Edge Functions are thin HTTP adapters.**

Every state change that gates money (reserving a seat, posting to the ledger, releasing escrow,
refunding) happens inside a `SECURITY DEFINER` Postgres function, so the state change and its
ledger posting **commit in the same transaction**. There is no window where a payment is recorded
but the ledger is not — a crash rolls back both.

The web app and Edge Functions never write to `seats`, `memberships`, `payments`, `payouts`, or
`ledger_*` directly. RLS is the safety net; the RPCs are the gate.

---

## 2. Component diagram

```
┌──────────────────────────────────────────────────────────────────────┐
│ Browser (Next.js 16, React 19, PWA-ish, mobile-first)                 │
│   SSR pages: /, /browse, /join/[seatId], /list, /dashboard, /login    │
│   Client components: PayForm, ListingForm, LoginForm, actions.tsx     │
└───────────┬──────────────────────────────────┬───────────────────────┘
            │ supabase-js (anon key + user JWT) │ functions.invoke()
            ▼                                   ▼
┌───────────────────────────┐   ┌──────────────────────────────────────┐
│ Supabase REST (PostgREST) │   │ Edge Functions (Deno, public HTTPS)   │
│  reads guarded by RLS     │   │  mpesa-stk-initiate   (user JWT)      │
│  RPC: confirm_seat_access │   │  mpesa-stk-callback   (URL token)     │
│       mark_seat_invited   │   │  payments-cron        (x-cron-secret) │
│       create_listing      │   │  notifications-worker (x-cron-secret) │
└───────────┬───────────────┘   └──────────┬───────────────────────────┘
            │                              │ service-role key
            ▼                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ Postgres 17 — the system of record                                    │
│   marketplace: profiles services listings seats memberships waitlist  │
│   payments:    payments payment_events payouts                        │
│   trust:       disputes ratings notifications audit_log               │
│   money:       ledger_accounts ledger_transactions ledger_entries     │
│   ~29 functions · 21 triggers · 2 views · RLS on every table          │
└───────────┬──────────────────────────────────────────────────────────┘
            │ https (Edge Function → Safaricom)
            ▼
┌──────────────────────────────────────────────────────────────────────┐
│ M-Pesa Daraja: STK Push · STK Query · (B2C — NOT YET BUILT)           │
│   calls back to → /functions/v1/mpesa-stk-callback?pid=…&t=…          │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 3. Request flow: the join-and-pay journey

```
1. GET /join/[seatId]              (server component)
   → supabaseServer() reads seat + listing + service + owner_public_profiles
   → renders price, fee split, escrow promise, trust card

2. User submits PayForm            (client component)
   → supabase.functions.invoke("mpesa-stk-initiate", {seat_id, invite_email, phone})

3. Edge: mpesa-stk-initiate
   → userClient(JWT).auth.getUser()             ← identifies the buyer
   → serviceClient().rpc("reserve_seat_and_start_join")
        ATOMIC: claim open seat (UPDATE … WHERE status='open') → if 0 rows: seat_unavailable
                create membership (price + fee snapshot)
                create payment row (status 'created', deterministic idempotency_key,
                                    per-payment callback_token)
   → daraja.stkPush(...) with callback URL carrying ?pid=&t=
   → rpc("record_stk_initiated")  → payment status 'pending'
   → returns {payment_id, status:"pending"}

4. PayForm polls  payments.status  every 3s (max ~2 min)
   'succeeded' → success screen | 'failed' → per-code message | else keep waiting

5. Safaricom → POST /mpesa-stk-callback?pid=…&t=…
   → verify token matches payments.callback_token (silently; always 200)
   → INSERT payment_events (raw payload, dedupe_key = sha256(source+checkoutId+resultCode))
        duplicate replay dies on the unique constraint
   → rpc("process_payment_event", event_id)
   → always respond 200

6. process_payment_event  (ONE transaction)
   ResultCode ≠ 0 → payment 'failed' + reason
   ResultCode = 0 → require MpesaReceiptNumber (else park to audit_log)
                  → verify amount matches (else park)
                  → payment 'succeeded' + receipt
                  → post_ledger_transaction('escrow_hold')
                       Dr mpesa_operating / Cr buyer_escrow(buyer)
                  → membership → 'awaiting_invite', set period + next_billing_at
                  → queue notifications (buyer receipt, owner invite nudge)
   (membership already dead → refund straight to buyer wallet)

7. Owner taps "I've sent the invite" → rpc mark_seat_invited → seat 'invited'
8. Buyer taps "I have access"        → rpc confirm_seat_access
   → seat 'active' (fires on_seat_activated → owner.seats_filled_count++)
   → release_escrow: Dr buyer_escrow / Cr owner_payable + platform_revenue + insurance_reserve
   → membership 'active'
9. ⛔ PAYOUT TO OWNER — NOT IMPLEMENTED. owner_payable accrues with no way out.
```

### Timers (all in `payments-cron`, currently invoked manually)
| Sweep | Function | Behaviour |
|---|---|---|
| Reprocess events | `process_payment_event` | Picks up unprocessed `payment_events` (crash recovery) |
| STK query | `payments_needing_stk_query` → `stkQuery` | First query at T+3min, re-query ≥2min apart, give up at 24h; >10min unresolved → `timeout` |
| Reservation expiry | `expire_stale_reservations` | Reserved >15min with no live payment → seat back to `open` |
| Invite SLA | `sweep_invite_sla` | Paid but owner never invited past `invite_sla_hours` → wallet refund + goodwill |
| Escrow auto-release | `auto_release_confirmed_silent` | Invited >48h, no dispute → release to owner |

---

## 4. Data model

All money is `bigint` **cents** (KES). All timestamps `timestamptz`.

### Marketplace
**`profiles`** (PK = `auth.users.id`)
`phone` (E.164, unique) · `full_name` · `mpesa_name` · `mpesa_name_verified` · `kyc_tier` (0–3) ·
`is_admin` · `owner_rating` · `buyer_rating` · `seats_filled_count` · `disputes_against_count` ·
`preferred_language` (`en`|`sw`) · `whatsapp_opt_in` · `suspended_at` · `suspension_reason`
→ trust columns are **system-managed** (trigger-guarded); auto-created on signup by `handle_new_user`.

**`services`** — catalogue. `slug` · `name` · `category` · `seats_total` · `plan_price_cents` ·
`official_solo_price_cents` · `suggested_seat_price_cents` · `invite_mechanism` ·
`household_required` · `risk` · `support_burden` · `is_active` · `platform_fee_bps` (2400) ·
`insurance_fee_bps` (400) · `notes`

**`listings`** — `owner_id` → profiles · `service_id` → services · `status` · `seats_offered` ·
`seat_price_cents` · `invite_sla_hours` (12)

**`seats`** — `listing_id` → listings · `status` (`open|reserved|invited|active|suspended|ended`) ·
`buyer_id` · `invite_email` · `reserved_at` · `invited_at` · `activated_at` · `ended_at`
→ CHECK: `open` implies no buyer; occupied states require one.

**`memberships`** — `seat_id` · `buyer_id` · `status` · `billing_method` · `seat_price_cents` ·
`platform_fee_cents` · `insurance_fee_cents` · `owner_take_cents` (**generated column**) ·
`current_period_start/end` · `next_billing_at` · `paid_at` · `cancelled_at`
→ partial unique index: **one live membership per seat**.

**`waitlist_entries`** — `buyer_id` · `service_id` · `max_price_cents` · `status` *(no logic uses this)*

### Payments
**`payments`** — `user_id` · `membership_id` · `kind` (`seat_join|renewal|wallet_topup|refund`) ·
`direction` · `channel` · `status` (`created|pending|succeeded|failed|timeout|reversed`) ·
`amount_cents` · `phone` · `idempotency_key` (unique) · `mpesa_checkout_request_id` (unique) ·
`mpesa_conversation_id` · `mpesa_receipt` (unique) · `callback_token` · `stk_attempts` ·
`status_checked_at` · `raw_request` · `raw_callback` · `failure_reason`
→ CHECK: **cannot be `succeeded` without an `mpesa_receipt`**.

**`payment_events`** — append-only raw Daraja log. `dedupe_key` (unique) · `payload` · `processed`
→ no deletes; no edits once processed.

**`payouts`** — `owner_id` · `amount_cents` · `status` (`pending|processing|paid|failed|frozen`) ·
`frozen_reason` · `idempotency_key` · `mpesa_conversation_id` · `mpesa_receipt` · `scheduled_for`
→ **table exists, nothing writes to it.**

### Trust & ops
**`disputes`** — `membership_id` · `seat_id` · `reporter_id` · `reason` · `status` · resolution fields
**`ratings`** — `membership_id` · `from_user` · `to_user` · `score` 1–5 · unique per (membership, from_user)
**`notifications`** — outbox: `user_id` · `channel` · `template` · `payload` · `status` ·
`claimed_at` · `attempts` · `external_id`
**`audit_log`** — append-only: `actor_id` · `actor_type` · `action` · `target_table` · `target_id` · before/after

### Ledger (double-entry)
**`ledger_accounts`** — `kind` × optional `user_id`.
Platform singletons: `mpesa_operating` (asset), `platform_revenue`, `insurance_reserve`.
Per-user: `buyer_escrow`, `wallet`, `owner_payable`.

**`ledger_transactions`** — `kind` · `idempotency_key` (unique) · refs to membership/payment/payout/dispute
**`ledger_entries`** — `transaction_id` · `account_id` · `direction` · `amount_cents`

Enforced invariants:
1. **Balanced** — deferred constraint trigger rejects any commit where debits ≠ credits
2. **Immutable** — UPDATE/DELETE rejected on both ledger tables
3. **Idempotent** — re-posting the same key returns the existing transaction, writes nothing
4. **Server-only** — no RLS policies + grants revoked

**Core invariant:** `mpesa_operating = buyer_escrow + wallet + owner_payable + insurance_reserve + platform_revenue`

Full posting matrix: `docs/LEDGER.md`.

### Relationships
```
auth.users 1─1 profiles 1─┬─* listings 1─* seats 1─* memberships 1─* payments
                          ├─* waitlist_entries          │            └─* ledger_transactions ─* ledger_entries
                          ├─* payouts (unused)          ├─* disputes
                          ├─* notifications             └─* ratings
                          └─* ledger_accounts
services 1─* listings
```

---

## 5. Auth & permissions

**Identity:** Supabase Auth. Intended production method is **phone + SMS OTP** (the phone number
is the M-Pesa number and therefore the account anchor). No SMS provider is configured, so a
**dev-only email/password path** exists, gated by `NEXT_PUBLIC_DEV_LOGIN`.

**Session:** cookie-based via `@supabase/ssr`. `web/src/proxy.ts` refreshes tokens on every
matched request (that is the only place cookie writes are legal).

**Authorisation is three-layered:**
1. **RLS** on every table — the safety net
2. **Self-authorising RPCs** — `confirm_seat_access` / `mark_seat_invited` / `create_listing` are
   `SECURITY DEFINER` but check `auth.uid()` internally
3. **Service-role-only functions** — everything money-critical; grants revoked from `anon`/`authenticated`

| Table | anon | authenticated | service role |
|---|---|---|---|
| `services` | read active | read active | all |
| `listings` | read active | read active + update own | all |
| `seats` | read open (active listings) | + own (buyer or owner) | **only writer** |
| `memberships` | — | read own (either side) | **only writer** |
| `payments` / `payouts` | — | read own | **only writer** |
| `waitlist_entries` | — | CRUD own | all |
| `disputes` | — | read/insert as participant | all (admin resolves) |
| `ratings` | — | read own; insert as counterparty | all |
| `notifications` | — | read own | all |
| `profiles` | via `owner_public_profiles` view only | own row (trust cols trigger-guarded) | all |
| `ledger_*`, `payment_events`, `audit_log` | **denied** | **denied** | all |

`owner_public_profiles` is a definer-rights view exposing only: first name, ratings, seats filled,
disputes, KYC tier, member-since. It is the **only** public window into `profiles`.

**KYC tiers:** 0 = browse/buy · 1 = verified host, 1 listing · 2 = multiple listings · 3 = high volume.
Promotion is **manual SQL today** — no verification flow exists.

**Verified at handoff** (via `@supabase/supabase-js` against the live project):
anon cannot read `profiles`; authenticated users see only their own row; `ledger_entries` denied
even when authenticated; a user cannot self-promote `kyc_tier` (raises
`column is system-managed and cannot be modified by the user`).

---

## 6. Frontend state management

**There is no state library, and none is needed.** The approach:

- **Server components fetch data.** `/browse`, `/join`, `/dashboard`, `/list` are async server
  components using `supabaseServer()`; all are `dynamic = "force-dynamic"`.
- **Client components own only local form state** (`useState`) — `PayForm`, `ListingForm`,
  `LoginForm`, `actions.tsx`.
- **Mutations go through RPC or Edge Function, then `router.refresh()`** to re-run the server
  component. There is no client cache to invalidate.
- **One polling loop:** `PayForm` polls `payments.status` every 3s up to ~2 min. It is the only
  place with a timer. (Supabase Realtime would be the natural upgrade — see roadmap TASK-403.)

**Styling:** Tailwind v4 with semantic tokens in `globals.css` (`--brand`, `--brand-strong`,
`--brand-soft`, `--accent`). Use `bg-brand`, `text-brand-strong` etc., not raw hex.

---

## 7. Key architectural decisions

| Decision | Reason | Consequence for you |
|---|---|---|
| Money logic in Postgres, not app code | Atomicity: state + ledger commit together | Add money features as migrations + RPCs, not TypeScript |
| Double-entry ledger instead of balance columns | Auditability; balances are derived, never mutated | Never write a "balance" field |
| Append-only ledger & event log | Regulatory/forensic integrity | Correct with reversing transactions |
| Deterministic idempotency keys everywhere | M-Pesa retries and duplicate callbacks are normal | Never include randomness/time in a key |
| Post to ledger only on M-Pesa receipt | A callback can lie or be replayed; a receipt is proof | Query-confirmed success without a receipt gets parked |
| Two-phase webhook (store raw → ack 200 → process) | Webhooks must never lose data or block | Add new webhooks the same way |
| One invite-based sharing mechanism for all services | Legality + a single code path | Reject any service needing password sharing |
| Cents as `bigint` | Float money is a bug generator | `fmtKes()` for display only |
| Fee split snapshotted per membership | Repricing must not affect existing members | Read fees from `memberships`, not `services` |
| SSR-first, no client state library | Slow mobile networks; less JS | Prefer server components |
| Supabase free tier | Zero budget | Beware auto-pause and free-tier limits |

---

## 8. What is deliberately NOT here

- No API layer of our own (PostgREST + RPC is the API)
- No ORM (SQL is the source of truth)
- No Redis/queue (the `notifications` table *is* the outbox; `payment_events` *is* the event log)
- No Docker for app runtime (Supabase hosts the functions)
- No client-side credential handling of any kind
