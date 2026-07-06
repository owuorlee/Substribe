# Substribe Ledger — How Money Moves

The ledger is a **double-entry** system in Postgres. It is the single source of
truth for every shilling. M-Pesa tells us money moved; the ledger tells us
*whose* it is and *why we're holding it*.

## Accounts

| Account kind        | Type      | Scope        | Meaning |
|---------------------|-----------|--------------|---------|
| `mpesa_operating`   | Asset     | platform     | Cash sitting in our M-Pesa paybill/B2C float |
| `buyer_escrow`      | Liability | per buyer    | Buyer's money we hold until their seat is confirmed working |
| `wallet`            | Liability | per buyer    | Prepaid balance a buyer topped up for future renewals |
| `owner_payable`     | Liability | per owner    | Earnings an owner is owed but hasn't been paid out |
| `insurance_reserve` | Liability | platform     | Reserve funded from fees, backing the money-back guarantee |
| `platform_revenue`  | Revenue   | platform     | Our take |

**Normal balances:** `mpesa_operating` is debit-normal; everything else is
credit-normal. The `ledger_account_balances` view already applies this, so
**every balance should read ≥ 0**. A negative balance is a bug or fraud — page
someone.

## The core invariant

> `mpesa_operating` balance = `buyer_escrow` + `wallet` + `owner_payable` + `insurance_reserve` + retained `platform_revenue`
> (all per currency)

Cash on hand always equals what we owe people plus what we've earned. The
nightly reconciliation job checks this identity **and** checks
`mpesa_operating` against the actual M-Pesa statement. Any drift is an
incident, not a cleanup task.

## Posting matrix

Every business event posts exactly one balanced transaction:

| # | Event | Debit | Credit | `kind` |
|---|-------|-------|--------|--------|
| 1 | Buyer pays for a seat (STK success) | `mpesa_operating` | `buyer_escrow(buyer)` | `escrow_hold` |
| 2 | Buyer confirms access → release | `buyer_escrow(buyer)` | `owner_payable(owner)` + `platform_revenue` + `insurance_reserve` | `escrow_release` |
| 3 | Owner payout (B2C success) | `owner_payable(owner)` | `mpesa_operating` | `payout` |
| 4 | Refund before release (B2C out) | `buyer_escrow(buyer)` | `mpesa_operating` | `escrow_refund` |
| 5 | Refund issued as wallet credit | `buyer_escrow(buyer)` | `wallet(buyer)` | `wallet_refund` |
| 6 | Wallet top-up (STK success) | `mpesa_operating` | `wallet(buyer)` | `wallet_topup` |
| 7 | Renewal charged from wallet | `wallet(buyer)` | `buyer_escrow(buyer)` | `wallet_charge` |
| 8 | Goodwill credit (make-whole loop) † | `insurance_reserve` | `wallet(buyer)` | `goodwill_credit` |
| 9 | M-Pesa reversal of a received payment | `buyer_escrow(buyer)` | `mpesa_operating` | `payment_reversal` |
| 10 | Failed B2C payout (money returns) | `mpesa_operating` | `owner_payable(owner)` | `payout_reversal` |
| 11 | Manual correction (admin, memo required) | *case by case* | *case by case* | `adjustment` |

† Until the insurance reserve has funds (early days), goodwill credits debit
`platform_revenue` instead (contra-revenue) so no liability balance goes
negative. `refund_to_wallet()` picks the source automatically.

### Worked example — the happy path, KSh 250 Spotify seat

Fee split (illustrative): owner take 180, platform 60, insurance 10.

```
1. STK succeeds (receipt QGH7SK61SU):
   escrow_hold      Dr mpesa_operating 25000 | Cr buyer_escrow(alice) 25000

2. Alice taps "I have access":
   escrow_release   Dr buyer_escrow(alice) 25000 | Cr owner_payable(bob)   18000
                                                 | Cr platform_revenue      6000
                                                 | Cr insurance_reserve     1000

3. Friday payout run (B2C receipt RF31...):
   payout           Dr owner_payable(bob) 18000 | Cr mpesa_operating 18000
```

After step 3: escrow(alice) 0, payable(bob) 0, revenue +6000, reserve +1000,
mpesa_operating +7000. Identity holds.

## Rules (enforced by the schema, not by discipline)

1. **Balance** — a deferred constraint trigger rejects any commit where a
   transaction's debits ≠ credits.
2. **Immutability** — `ledger_transactions` and `ledger_entries` reject UPDATE
   and DELETE. Mistakes are fixed with a reversing transaction (`adjustment`),
   which preserves the audit trail.
3. **Idempotency** — every post carries a **deterministic**
   `idempotency_key`; re-posting returns the existing transaction untouched.
   Convention: `{kind}:{primary_ref_id}[:{qualifier}]`, e.g.
   `escrow_hold:pay_7f3a...`, `escrow_release:mem_91c2...:2026-07`,
   `payout:pyt_44b8...`. Never include timestamps or random values.
4. **Post on proof, never on intent** — a ledger transaction is posted only
   when Daraja confirms an outcome (callback or status query with an M-Pesa
   receipt). Initiating an STK push writes a `payments` row, not a ledger row.
5. **Server-only** — no RLS policies exist on ledger tables and grants are
   revoked; only the service role (Edge Functions / workers) can read or
   write, via `post_ledger_transaction()`.

## How the tables relate

```
payments (M-Pesa in/out, buyer side)──┐
payouts  (M-Pesa out, owner side) ────┼──referenced by──▶ ledger_transactions ──▶ ledger_entries
disputes (freezes + resolutions) ─────┤                        (immutable)          (immutable)
memberships (what the money is for) ──┘
```

`payments`/`payouts` = what M-Pesa did (receipts, callbacks, retries).
`ledger_*` = what it means for who owns what. Reconciliation joins the two.

## Dispute holds

Opening a dispute does **not** move money (the escrow/payable entry already
exists). It freezes the owner's payout row (`payouts.status = 'frozen'`) so
nothing leaves while under review. Resolution posts one of: `escrow_refund` /
`wallet_refund` (buyer wins pre-release), `goodwill_credit` (make-whole), or
simply unfreezes the payout (owner wins).
