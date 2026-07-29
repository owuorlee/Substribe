# Substribe — State of Play

**As of commit `07c33d9`, 2026-07-29.** Every row was checked by reading the code and, where
marked *verified live*, by running it against the hosted Supabase project.

> **⚠️ Read section 2 before writing any code.** It lists everything that is faked, missing, or
> would break in production. Do not mistake a table for a feature: several subsystems have a
> schema, RLS, and enums but **zero implementing code**.

---

## 1. Feature status

Status key: **Done** = implemented and verified · **Partial** = works but incomplete ·
**Stubbed** = schema/scaffolding only, no logic · **Not started** · **Broken**

| Feature | Status | Where it lives | What's missing | Confidence |
|---|---|---|---|---|
| **Database schema** (16 tables, 19 enums, 21 triggers, 2 views) | **Done** | `supabase/migrations/*.sql` | — | High — applied to live DB, verified |
| **Double-entry ledger** | **Done** | `…000600_ledger.sql`, `docs/LEDGER.md` | — | High — full purchase simulated, all balances correct to the cent |
| **RLS / access control** | **Done** | `…000700_rls_and_access.sql` | Admin-role UI | High — verified live: anon blocked, ledger denied, no self-promotion |
| **Seat reservation (race-safe)** | **Done** | `reserve_seat_and_start_join` | — | High — atomic single-statement claim |
| **STK push initiation** | **Done** | `functions/mpesa-stk-initiate/`, `_shared/daraja.ts` | — | High — **verified live**, Daraja returned `ResponseCode 0` + CheckoutRequestID |
| **Payment callback ingestion** | **Partial** | `functions/mpesa-stk-callback/` | Never exercised by a **real** Daraja callback | Medium — logic verified via simulated event in SQL; real callback `[UNVERIFIED]` |
| **Payment state machine** | **Done** | `process_payment_event` | — | High — success/failure/late-refund paths all coded; success path verified in SQL test |
| **Escrow hold → release** | **Done** | `process_payment_event`, `release_escrow` | — | High — verified end-to-end in SQL test |
| **Invite SLA auto-refund** | **Done** | `sweep_invite_sla`, `refund_to_wallet` | Not exercised with real data | Medium |
| **Reservation expiry sweep** | **Done** | `expire_stale_reservations` | — | High — **verified live** (`reservations_expired: 1`, seat returned to `open`) |
| **48h escrow auto-release** | **Done** | `auto_release_confirmed_silent` | Not exercised with real data | Medium |
| **STK timeout recovery** | **Partial** | `payments_needing_stk_query`, `payments-cron` | Never triggered in practice | Medium |
| **Owner listing creation** | **Done** | `create_listing`, `web/src/app/list/` | — | High — demo listing created through this RPC |
| **Browse marketplace** | **Done** | `web/src/app/browse/page.tsx` | Filters, pagination, sorting | High — **verified live** rendering real data |
| **Join / pay screen** | **Done** | `web/src/app/join/[seatId]/` | — | High — **verified live**; fee split matches ledger exactly |
| **Dashboard (buyer + owner)** | **Partial** | `web/src/app/dashboard/` | Earnings totals, payout status, history, ratings | Medium-High |
| **Confirm access / mark invited** | **Done** | `dashboard/actions.tsx` → RPCs | — | High — RPCs verified in SQL test |
| **Auth — dev email/password** | **Done** | `login/LoginForm.tsx` (gated) | **Must be removed before production** | High — user signed in successfully |
| **Auth — phone OTP** | **Broken** | `login/LoginForm.tsx` | No SMS provider configured; untested | High that it is unconfigured |
| **Notification templates (EN/SW)** | **Done** | `_shared/templates.ts` | Templates for payouts/renewals/disputes | High |
| **Notification delivery** | **Broken** | `functions/notifications-worker/` | **Migration 1200 not applied to live DB** → `claim_failed` on every call. Also no WhatsApp/AT credentials. | High — **verified live failure** |
| **Owner payouts (B2C)** | **Not started** | `payouts` table only | **Everything.** No B2C client, no batch job, no UI. | High |
| **Renewals / recurring billing** | **Not started** | `next_billing_at` written, never read | Entire engine | High |
| **Disputes** | **Stubbed** | table + RLS insert policy | Payout freeze, resolution, UI, admin queue | High |
| **Ratings** | **Stubbed** | table + RLS + aggregate triggers | UI to submit one | High |
| **Waitlist** | **Stubbed** | table + RLS | Join UI, auto-match logic | High |
| **Admin console** | **Not started** | — | KYC queue, dispute queue, reconciliation view | High |
| **KYC verification flow** | **Not started** | `kyc_tier` column | M-Pesa name-match flow; today it's manual SQL | High |
| **Scheduled cron** | **Not started** | — | pg_cron/dashboard schedule; today curl-only | High — verified nothing is scheduled |
| **Automated tests (JS/TS)** | **Not started** | — | No framework, no `test` script | High |
| **SQL regression test** | **Done** | `scripts/e2e-money-test.sql` | Not automated in CI | High — run live, passed |
| **CI/CD** | **Not started** | — | No `.github/workflows` | High |
| **Deployment** | **Not started** | — | Nothing hosted; localhost only | High |
| **Error boundaries / 404 / loading states** | **Not started** | — | No `error.tsx`, `loading.tsx`, `not-found.tsx` | High — verified absent |
| **Monitoring / health checks** | **Not started** | — | Everything | High |
| **Legal pages (ToS, privacy)** | **Not started** | — | Required for ODPC compliance | High |

---

## 2. ⚠️ Faked, hardcoded, or placeholder — would break in production

**Treat every item here as a production blocker or a trap.**

1. **`NEXT_PUBLIC_DEV_LOGIN` email/password sign-in** (`web/src/app/login/LoginForm.tsx`)
   Creates accounts with no verification. It is env-gated, but shipping with the flag on would let
   anyone create unlimited accounts. **Must be removed or hard-disabled before launch** (TASK-201).

2. **Demo accounts with a known password exist in the live database.**
   `owner@substribe.dev` / `buyer@substribe.dev`, both `substribe123`, created by
   `scripts/demo-seed.sql`. The owner is KYC-verified. **Delete before production** (TASK-202).

3. **Owner payouts do not exist.** Owners accumulate `owner_payable` in the ledger and there is
   **no code path that pays them**. The UI in `dashboard/page.tsx` and the host promise in
   `ListingForm.tsx` imply payouts happen. **The product currently takes money and cannot pay it
   out.** Highest-priority gap (TASK-101…104).

4. **Notification delivery is dead.** Live DB has the broken `claim_notifications`; verified
   returning `{"error":"claim_failed"}`. Even after the fix, `DELIVERY_MODE` defaults to `log`, so
   messages are **written to function logs, not sent**. Owners will never learn a buyer paid, so
   the 12h invite SLA will expire and auto-refund every purchase (TASK-001, TASK-105).

5. **Nothing runs on a schedule.** All sweeps require a manual curl. Without cron: reservations
   never expire, SLA refunds never fire, escrow never auto-releases, STK timeouts never resolve
   (TASK-002).

6. **Renewals never happen.** `next_billing_at` is set and never read. Every membership is
   effectively a one-month purchase that silently continues without billing (TASK-301…303).

7. **The `frozen` payout status is unreachable.** `payouts.status = 'frozen'` and `frozen_reason`
   exist with a CHECK constraint, but no code sets them. Documented dispute behaviour ("payouts
   pause if a member reports a problem" — shown to owners in `ListingForm.tsx`) **is not
   implemented** (TASK-304).

8. **`supabase/functions/README.md` contains stale instructions** telling you to use ngrok for
   callbacks. Functions are deployed at public URLs; ngrok is only needed for `functions serve`.

9. **`supabase/_bootstrap.generated.sql` is gitignored and generated.** A fresh clone does **not**
   contain it. Regenerate before setting up a new environment (TASK-003).

10. **Migration tracking is manual.** Migrations were applied by pasting SQL, so Supabase's
    migration table does not reflect reality. **Migration `20260728000100_fix_claim_notifications.sql`
    is in the repo but NOT applied to the live database.** Verified at handoff.

11. **Fee percentages are placeholders.** `platform_fee_bps = 2400` (24%) and
    `insurance_fee_bps = 400` (4%) were chosen for illustration and are **not validated against
    real M-Pesa STK/B2C tariffs**. Substribe currently absorbs all transaction costs — margin may
    be negative (TASK-106).

12. **Only `spotify-family` is active** in the catalogue. Other rows carry warnings in
    `supabase/seed.sql`; `chatgpt-team`/`claude-team` are per-seat priced (splitting saves nothing)
    and `netflix-standard` is excluded by policy. Prices are **mid-2026 estimates, unverified**.

13. **The `insurance_reserve` has no payout mechanism.** It accrues 4% of every transaction and
    funds goodwill credits, but there is no claims process.

14. **Wallet balances cannot be spent or withdrawn.** `refund_to_wallet` credits a buyer's
    `wallet` account, but nothing lets a buyer *use* that balance. Refunded users have money
    trapped (TASK-107).

---

## 3. Verification log (what was actually run at handoff)

| Check | Command | Result |
|---|---|---|
| Build | `cd web && npm run build` | **exit 0**, 8 routes |
| Lint | `cd web && npm run lint` | **exit 0**, no findings |
| Types | `cd web && npx tsc --noEmit` | **exit 0** |
| Dev server | `cd web && npm run dev` | Ready, `/browse` rendered live data |
| Money engine | `scripts/e2e-money-test.sql` in SQL Editor | Passed — all ledger balances exact |
| Auth + RLS | script via `supabase-js` | 6/6 passed |
| STK initiate | live Edge Function invoke | **Passed** — CheckoutRequestID `ws_CO_290720261137079708374149` |
| Reservation sweep | `payments-cron` curl | **Passed** — `reservations_expired: 1` |
| Cron auth | curl with wrong secret | **401** |
| Notifications worker | curl | **FAILED** — `claim_failed` (migration not applied) |
| TODO/stub sweep | grep | No TODO/FIXME/HACK/STUB in code |

**`[UNVERIFIED]`** — never tested end-to-end:
- A **real Daraja callback** reaching `mpesa-stk-callback` (only simulated in SQL)
- STK Query timeout recovery against real Daraja
- WhatsApp / SMS sending (no credentials)
- Phone OTP login (no SMS provider)
- Anything on a production paybill (sandbox only)
- The local Supabase stack (`supabase start` was never completed)
- Behaviour under concurrency beyond the single-statement seat claim
