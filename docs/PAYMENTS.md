# Substribe Payments — M-Pesa Integration Spec

This document specifies the complete payment layer: Daraja API usage, state
machines, webhook handling, timers, and every edge case we handle. It is the
implementation contract for the payment Edge Functions and workers.
Ledger semantics (what gets posted when) live in [LEDGER.md](LEDGER.md); this
doc covers *how we get to "proof"* — the M-Pesa receipt that triggers a post.

Daraja request/response field names below are from the current Safaricom docs
at time of writing — **re-verify against the Daraja portal before go-live**,
especially Ratiba, which is the newest API.

---

## 1. Rails & endpoints

| Purpose | Daraja API | Direction |
|---|---|---|
| Seat join / renewal / wallet top-up | **STK Push** (Lipa na M-Pesa Online) | buyer → us |
| Manual paybill payment (fallback) | **C2B** (RegisterURL: validation + confirmation) | buyer → us |
| Owner payouts, buyer refunds | **B2C** (`BusinessPayment`) | us → user |
| Recurring renewals (opt-in) | **Ratiba** (standing order) | buyer → us |
| Timeout recovery | **STK Query** + **Transaction Status** | query |

- **Environments:** sandbox (`sandbox.safaricom.co.ke`) until the company +
  paybill exist; production (`api.safaricom.co.ke`) after Daraja go-live.
- **Auth:** OAuth client-credentials token, valid ~3599s. Cache for 50 minutes,
  refresh on 401. Never fetch per-request.
- **Amounts:** M-Pesa moves **whole shillings**. Ledger is cents → every
  chargeable amount must satisfy `cents % 100 == 0` (enforce at price entry).
- **Phone format:** Daraja wants `2547XXXXXXXX` / `2541XXXXXXXX` (no `+`).
  Convert from our E.164 at the boundary, never store the bare form.
- **B2C prerequisite:** initiator credentials + RSA-encrypted
  `SecurityCredential` (M-Pesa public cert). Keep initiator password in
  Supabase Vault only.

## 2. Webhook architecture — ingest, then process

Safaricom **does not sign callbacks**. Compensating controls, all mandatory:

1. **Unguessable URLs**: every callback URL carries a per-payment secret —
   `/mpesa/stk-callback?pid={payment_id}&t={random 32-byte token}` stored on
   the payment row. Wrong/missing token → 200 OK (don't leak), log, discard.
2. **IP allowlist** of Safaricom's published CIDRs at the edge (belt) — but
   never *instead of* the token (suspenders).
3. **Trust nothing in the payload**: match callback → pending payment row;
   compare amount, phone tail; on any mismatch, park as `manual` review, do
   not post.
4. **Verify-by-query**: for any amount ≥ KSh 5,000, confirm with STK
   Query/Transaction Status before posting to the ledger, even if the callback
   looks fine.

**Two-phase handling** (webhooks must be fast and never lose data):

```
Edge Function (webhook):                Worker (processor):
  validate token                          poll unprocessed payment_events
  INSERT payment_events                   (or Realtime-triggered)
    (raw payload, dedupe_key)             in ONE db transaction:
  respond 200 immediately                   advance payment state machine
                                            post_ledger_transaction(...)
  dedupe_key = sha256(source +              advance membership/seat state
    CheckoutRequestID/ConversationID +      queue notifications
    ResultCode)                             mark event processed
  → duplicate INSERT = no-op, ack 200
```

A replayed/duplicate callback dies at the `dedupe_key` unique constraint. A
crashed worker re-picks the unprocessed event; ledger idempotency keys make
re-processing harmless. **Every state change and its ledger post happen in the
same Postgres transaction** — no half-applied money.

## 3. Inbound payment state machine (STK Push)

```
                     ┌─────────┐
        create row → │ created │  (nothing sent to Daraja yet)
                     └────┬────┘
              STK accepted│(ResponseCode 0, got CheckoutRequestID)
                     ┌────▼────┐
                     │ pending │──── callback ResultCode 0 ───▶ ┌───────────┐
                     └────┬────┘     (+ MpesaReceiptNumber)     │ succeeded │──▶ ledger post
        no callback after │                                     └─────┬─────┘
        3 min → STK Query │──── callback/query non-zero ──▶ ┌────────┐│
                     ┌────▼────┐                            │ failed ││ M-Pesa reversal
                     │ timeout │── query says success ──▶───└────────┘▼ (rare)
                     └────┬────┘   (join `succeeded` path)   ┌──────────┐
                          └── reconciliation resolves ──▶    │ reversed │──▶ ledger post
                                                             └──────────┘     (payment_reversal)
```

**Transitions & side effects:**

| From → To | Trigger | Side effects |
|---|---|---|
| `created → pending` | Daraja accepts STK request | store `CheckoutRequestID`; start 3-min timer |
| `created → failed` | Daraja rejects request (bad phone, downtime) | show retry UI; release seat reservation after 3 failures |
| `pending → succeeded` | callback/query `ResultCode 0` | store receipt; **post `escrow_hold`**; membership → `awaiting_invite`; start invite SLA timer; notify owner (WhatsApp) |
| `pending → failed` | non-zero result (see table below) | user-facing message per code; seat reservation released after retry window |
| `pending → timeout` | 3 min, then STK Query attempts exhausted | keep seat reserved 15 more min; nightly reconciliation owns it |
| `timeout → succeeded/failed` | later query or reconciliation resolves | same side effects as normal resolution |
| `succeeded → reversed` | Safaricom reversal notification | **post `payment_reversal`**; membership suspended; ops alerted |

**STK result codes → user copy** (exact codes verified in sandbox before launch):

| Code | Meaning | What we tell the buyer |
|---|---|---|
| `0` | success | "Payment received — your money is held safely until your seat works." |
| `1` | insufficient funds | "Your M-Pesa balance is too low. Top up and try again." |
| `1032` | user cancelled prompt | "You cancelled the request. Tap to try again." |
| `1037` | no response / phone unreachable | "We couldn't reach your phone. Check your signal and retry." |
| `2001` | wrong PIN | "Wrong M-Pesa PIN entered. Try again." |
| `1019` / `1025` / other | expired / push error | "Something went wrong on M-Pesa's side. Please retry." |

**STK Query discipline:** first query at T+3min (querying too early returns
"transaction is being processed"), then T+5, T+10. Rate-limited API — back off,
never hammer. **Note:** STK Query returns a ResultCode but *no receipt number*,
and success posts require proof (LEDGER.md rule 4) — so a query-confirmed
*success* stays `pending` (parked to audit) until the late callback or the
statement reconciliation supplies the receipt. Query-confirmed *failures*
resolve immediately.

**Seat reservation concurrency:** reserving is one atomic statement —
`UPDATE seats SET status='reserved', buyer_id=$1, reserved_at=now() WHERE id=$2
AND status='open' RETURNING id`. Zero rows = someone got there first; offer the
waitlist. Reservations expire after 15 min without a successful payment
(30 for `timeout` state), freeing the seat.

**Payment idempotency keys:** `seat_join:{membership_id}`,
`renewal:{membership_id}:{period_start}`, `wallet_topup:{client_uuid}`.
Retrying a failed attempt **replaces** the Daraja request but reuses the
payment row (attempt counter + fresh CheckoutRequestID).

## 4. Escrow → release (the trust core)

After `escrow_hold` posts, membership is `awaiting_invite`:

```
awaiting_invite ── owner marks invited (invited_at set) ──▶ invited
invited ── buyer taps "I have access" ─────────────────────▶ active  → post escrow_release
invited ── 48h pass, no confirm, no dispute ───────────────▶ active  → post escrow_release (auto)
awaiting_invite ── invite SLA (12h) breached ──────────────▶ refund → post escrow_refund, seat reopens
any ── buyer opens dispute ────────────────────────────────▶ frozen until resolution
```

- **Owner nudges:** WhatsApp at T+0 ("You have a buyer! Invite {email} within
  12h to get paid KSh X"), T+2h, T+8h. SLA breach = auto-refund + reputation
  hit + seat back to open + buyer offered next seat from waitlist.
- **Auto-release after 48h** protects owners from buyers who get access and
  never confirm. The buyer is told exactly this at invite time: "Confirm within
  48 hours or we'll assume it works."
- **Dispute during the window** freezes everything (see §7).

## 5. Renewals

Anchor: `memberships.next_billing_at` (same day monthly; clamp to month-end).

**Method A — `stk_reminder` (default at launch):**
- T-2d: WhatsApp "Your Spotify seat renews Thursday — KSh 250. Reply PAY or
  tap to pay now."
- T-0: send STK push at the buyer's historically-most-responsive hour
  (default 19:00 EAT).
- Retries on failure/no-action: T+1d, T+3d. Grace period: **3 days** with seat
  intact, status `past_due`.
- Grace exhausted → membership `suspended`, owner told to remove the member,
  seat → `open`, waitlist auto-fill kicks in. Buyer who pays late but before
  re-fill is restored; after re-fill, they go to the waitlist head.

**Method B — `wallet`:** debit wallet at T-0 (`wallet_charge` post). If balance
short → fall back to Method A flow for the difference (or full amount; no
partial charges — keep reconciliation simple). Top-up nudge at T-3d if balance
< renewal amount.

**Method C — `ratiba`:** register standing order on opt-in; renewal arrives as
a Ratiba callback → same processing path as STK success. Cancellation/failed
standing order → fall back to Method A. *(Newest Daraja API — verify contract
and coverage in sandbox before enabling; ship launch on A + B if not ready.)*

Renewal money follows the same escrow pattern: `escrow_hold` on payment, then
auto-release at T+48h unless a dispute is open. Same code path as joins — no
special cases.

## 6. Outbound: payouts & refunds (B2C)

**Payout state machine:**

```
pending ── Friday batch run picks it up ──▶ processing ── ResultCode 0 ──▶ paid → post `payout`
pending ── linked dispute opens ──────────▶ frozen ── resolution ──▶ pending (or cancelled)
processing ── non-zero result / timeout callback ──▶ failed → post nothing; retry queue + ops alert
```

- **Schedule:** weekly batch (Friday 10:00 EAT). Minimum payout **KSh 100**
  (below that, rolls to next week) — B2C per-transaction tariffs make micro
  payouts uneconomical. Owners see pending balance + next payout date always.
- **Payout = sum of released `owner_payable`** at batch time, one B2C per
  owner. `idempotency_key = payout:{owner_id}:{batch_date}`.
- **B2C result handling:** `TransactionReceipt` → `mpesa_receipt`; store
  `B2CUtilityAccountAvailableFunds` from every result — **this is our float
  monitor** (alert when float < 2× next batch estimate; block batch if
  insufficient rather than partially paying).
- **QueueTimeOutURL hits or no result in 5 min** → Transaction Status query →
  resolve. Unresolvable = `failed`, never assume paid.
- **`failed` retries:** 3 attempts across 24h, then ops queue (usually a wrong
  number → owner contacted to fix their payout number, name-match re-checked).

**Refunds** ride the same B2C machinery with `kind='refund'` on the payments
table: full refund on invite-SLA breach or dispute win; **prorated refund**
(unused days ÷ period days, rounded up in the buyer's favor, whole shillings)
on mid-cycle seat death. Buyer chooses M-Pesa refund (B2C) or instant wallet
credit + KSh 20 goodwill — wallet is instant and costs us no B2C fee, so the
UI leads with it. Ledger: `escrow_refund` / `wallet_refund` + `goodwill_credit`.

## 7. Disputes & money

Opening a dispute (buyer or owner):
1. Freeze any `pending` payout of the counterparty owner (`frozen`,
   `frozen_reason = dispute:{id}`).
2. If within escrow window: pause the 48h auto-release timer.
3. SubBot attempts auto-remediation first (§4.5 of SCOPE.md): for
   `lost_access`, immediately offer top waitlist seat + prorated transfer.
4. Human resolution paths → exactly one of: `resolved_refunded` (post refund),
   `resolved_rematched` (prorated transfer + goodwill), `resolved_released`
   (unfreeze payout, release escrow). Every resolution writes `audit_log`.

**SLA we publish:** first response < 2h (bot, instant in practice), resolution
< 24h. The public trust page shows our rolling actuals.

## 8. Timers (scheduled jobs)

| Timer | Cadence | Action |
|---|---|---|
| STK query sweep | every minute | query `pending` payments past T+3min |
| Reservation expiry | every 5 min | reopen seats with expired reservations |
| Invite SLA | every 15 min | nudge owners; auto-refund breaches |
| Escrow auto-release | hourly | release confirmed-silent invites past 48h |
| Renewal engine | hourly | T-2d reminders, T-0 charges, grace retries |
| Payout batch | Fri 10:00 EAT | build + send B2C batch |
| Float monitor | hourly | alert on low B2C float |
| **Reconciliation** | nightly 03:00 EAT | ledger identity check (LEDGER.md) + M-Pesa statement diff + stuck-state sweep (`timeout` payments, `processing` payouts > 24h) → ops report |

All timers are idempotent and safe to double-fire (keys do the work).

## 9. Fees & who pays what

- **Buyer sees one price.** KSh 250 means KSh 250 — Substribe absorbs M-Pesa
  charges inside the platform fee. Hidden fees are how you become the thing
  people warn each other about.
- Paybill customer-charge config: set to **business pays** (customer pays 0 on
  STK) — confirm tariff band at paybill setup.
- Fee split configured per service (env/config, snapshotted into memberships
  at join): launch defaults for Spotify seat KSh 250 → owner 180 / platform 60 /
  insurance 10 (validate against real B2C+STK tariffs before locking).

## 10. Go-live checklist (payments)

- [ ] Company registered; paybill issued; Daraja production app approved
- [ ] B2C initiator + SecurityCredential in Vault; test payout to founder phone
- [ ] Callback URLs live with per-payment tokens; Safaricom IP allowlist on edge
- [ ] Sandbox suite passed: success, cancel (1032), insufficient (1), wrong PIN
      (2001), timeout (1037), duplicate callback replay, query-resolves-timeout
- [ ] Reconciliation job running against sandbox statement for 1 week, zero drift
- [ ] Float alert wired to founder WhatsApp
- [ ] Refund + payout drills executed end-to-end with real KSh 10
