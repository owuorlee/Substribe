# Substribe — Roadmap to Production

Every remaining piece of work, in dependency order. Each task is sized for **one short agent
session**. Do them in ID order unless dependencies say otherwise.

**Priority:** `P0` blocks launch · `P1` should have · `P2` post-launch.
If you run low on capacity, cut P2 first, then P1. **Never cut a P0.**

**Milestones:** M0 unblock → M1 close the money loop → M2 comms → M3 auth/security →
M4 renewals → M5 trust features → M6 testing/errors → M7 deploy/observability → M8 launch.

**Conventions for every task:** read `QUALITY_STANDARDS.md` first; append to `PROGRESS_LOG.md`
after; one commit per task referencing the TASK id.

**How to apply a migration** (no CLI DB link exists): open the Supabase SQL Editor, paste the
migration file, Run, expect *"Success. No rows returned."*, then record it in `PROGRESS_LOG.md`.

---

# M0 — Unblock (do these first, in order)

### TASK-001: Apply the pending `claim_notifications` migration [P0]
- Milestone: M0 · Depends on: none
- Why: The live DB has a broken `claim_notifications`; the notification outbox never drains.
- Files to touch: none (apply existing `supabase/migrations/20260728000100_fix_claim_notifications.sql`)
- Approach: Paste that file into the Supabase SQL Editor and Run. Do not edit it.
- Acceptance criteria: `notifications-worker` returns a JSON summary instead of an error.
- How to verify:
  ```bash
  curl -s -X POST "https://<ref>.supabase.co/functions/v1/notifications-worker" \
    -H "x-cron-secret: <CRON_SECRET>"
  ```
  Passing = `{"claimed":0,"sent":0,"failed":0}`. Failing = `{"error":"claim_failed"}`.
- Out of scope: changing templates or delivery providers.

### TASK-002: Schedule the two cron functions [P0]
- Milestone: M0 · Depends on: TASK-001
- Why: Nothing currently runs on a timer, so no sweep, timeout, refund or auto-release ever fires.
- Files to touch: new `supabase/migrations/<ts>_schedule_cron.sql`
- Approach: Enable `pg_cron` + `pg_net`, then schedule both endpoints every minute. Pattern is in
  `supabase/functions/README.md`. Prefer the Supabase Dashboard → Integrations → Cron UI if
  pasting the secret into SQL is unappealing; record which you used.
- Acceptance criteria: both functions execute automatically each minute; a reservation older than
  15 min returns to `open` with no manual curl.
- How to verify: `select * from cron.job;` shows two jobs; wait 2 min and check
  `select * from cron.job_run_details order by start_time desc limit 5;` for succeeded runs.
- Out of scope: changing sweep logic.

### TASK-003: Add a bootstrap-regeneration script [P0]
- Milestone: M0 · Depends on: none
- Why: `_bootstrap.generated.sql` is gitignored and hand-generated; a new environment will silently
  miss migrations.
- Files to touch: new `scripts/build-bootstrap.mjs`, `README.md`
- Approach: Node script that reads `supabase/migrations/*.sql` sorted by filename, appends
  `supabase/seed.sql`, writes `supabase/_bootstrap.generated.sql` as UTF-8 **without BOM** (a BOM
  breaks the SQL Editor). Do not hardcode the file list — glob it.
- Acceptance criteria: running it reproduces a bundle containing all 12 migrations; adding a
  migration and re-running includes it.
- How to verify: `node scripts/build-bootstrap.mjs && head -3 supabase/_bootstrap.generated.sql`
  — first byte must be `-`, not a BOM.
- Out of scope: applying migrations.

### TASK-004: Correct stale docs in `supabase/functions/README.md` [P1]
- Milestone: M0 · Depends on: none
- Why: It tells the next engineer they need ngrok for callbacks; functions are deployed publicly.
- Files to touch: `supabase/functions/README.md`
- Approach: State that deployed functions have public URLs Safaricom reaches directly; ngrok is
  only for `supabase functions serve`. Add `notifications-worker` to the schedule section if absent.
- Acceptance criteria: no instruction in the file is false.
- How to verify: read it against the deployed reality.
- Out of scope: rewriting other docs.

---

# M1 — Close the money loop (owners must be able to get paid)

> **This is the most important milestone in the document.** Today Substribe can take money and
> cannot pay it out.

### TASK-101: Add a B2C client to the Daraja shared module [P0]
- Milestone: M1 · Depends on: TASK-001
- Why: Payouts and cash refunds both need M-Pesa B2C.
- Files to touch: `supabase/functions/_shared/daraja.ts`
- Approach: Add `b2cPayment({phone, amountKes, remarks, occasion, resultUrl, timeoutUrl})`
  following the existing `stkPush` style (same error class, same token cache, same phone helper).
  B2C needs `InitiatorName` + an RSA-encrypted `SecurityCredential` — read them from new env vars
  `DARAJA_INITIATOR_NAME`, `DARAJA_SECURITY_CREDENTIAL`. Do not generate the credential in code;
  it is produced once from Safaricom's public cert.
- Acceptance criteria: function compiles; throws `DarajaError` on non-zero `ResponseCode`; never
  logs the security credential.
- How to verify: `npx tsc --noEmit` in a scratch Deno check, or deploy and call with a sandbox
  test number; expect a `ConversationID`.
- Out of scope: the payout batch job (TASK-103).

### TASK-102: Create the payout-building RPC [P0]
- Milestone: M1 · Depends on: TASK-101
- Why: Something must turn accrued `owner_payable` into `payouts` rows.
- Files to touch: new `supabase/migrations/<ts>_payout_engine.sql`
- Approach: Add `build_payout_batch(p_batch_date date)` — `SECURITY DEFINER`, service-role only.
  For each owner whose `owner_payable` balance ≥ 10000 cents (KSh 100 floor, per `docs/PAYMENTS.md`
  §6), insert one `payouts` row with `idempotency_key = 'payout:'||owner_id||':'||batch_date` and
  status `pending`. **Do not post to the ledger here** — the ledger posts only when M-Pesa confirms
  (TASK-104). Skip owners with an open dispute.
- Acceptance criteria: running twice for the same date creates no duplicates; owners below the
  floor are skipped; total pending payouts never exceed total `owner_payable`.
- How to verify: extend `scripts/e2e-money-test.sql` (or add `scripts/payout-test.sql`) to run a
  purchase, call `build_payout_batch`, and assert one row of exactly `18000` cents; ROLLBACK.
- Out of scope: sending money.

### TASK-103: Build the payouts-cron Edge Function [P0]
- Milestone: M1 · Depends on: TASK-101, TASK-102
- Why: Executes the batch against M-Pesa.
- Files to touch: new `supabase/functions/payouts-cron/index.ts`, `supabase/functions/README.md`
- Approach: Mirror `payments-cron/index.ts` exactly (same `x-cron-secret` auth, same summary-JSON
  return). Steps: call `build_payout_batch`, select `pending` payouts, set `processing`, call
  `b2cPayment`, store `mpesa_conversation_id`. **Never mark `paid` here** — only the result callback
  does that (the schema enforces `paid` requires a receipt).
- Acceptance criteria: wrong secret → 401; idempotent across runs; a Daraja failure marks the
  payout `failed` with a reason and does not lose money.
- How to verify: deploy with `--no-verify-jwt`, curl with the secret, inspect `payouts` rows.
- Out of scope: the result webhook (TASK-104).

### TASK-104: Build the B2C result webhook and post the payout ledger entry [P0]
- Milestone: M1 · Depends on: TASK-103
- Why: Money only leaves the ledger when M-Pesa confirms it left the float.
- Files to touch: new `supabase/functions/mpesa-b2c-result/index.ts`, new migration
  `<ts>_payout_result.sql`
- Approach: Copy the two-phase pattern from `mpesa-stk-callback` (store raw event → ack 200 →
  process). Add `process_payout_result(p_event_id)` posting `payout` (Dr `owner_payable` /
  Cr `mpesa_operating`) per `docs/LEDGER.md` row 3 with key `payout:{payout_id}`; on failure post
  nothing and set `failed`. Capture `B2CUtilityAccountAvailableFunds` for float monitoring.
- Acceptance criteria: success posts exactly one balanced transaction; replayed callbacks are
  no-ops; a failed payout leaves `owner_payable` untouched.
- How to verify: add assertions to the payout SQL test — after a simulated success,
  `owner_payable = 0` and `mpesa_operating` decreased by the payout amount.
- Out of scope: retry scheduling (TASK-108).

### TASK-105: Configure a real notification provider [P0]
- Milestone: M1 · Depends on: TASK-001
- Why: With `DELIVERY_MODE=log`, owners never learn a buyer paid, so every purchase hits the 12h
  SLA and auto-refunds. **The marketplace cannot function.**
- Files to touch: none (configuration) — plus `supabase/functions/README.md`
- Approach: Create an Africa's Talking account (cheapest path to Kenyan SMS; WhatsApp Cloud API
  needs business verification). Set `AT_API_KEY`, `AT_USERNAME`, `AT_SENDER_ID`, `DELIVERY_MODE=sms`
  via `supabase secrets set`. The code in `_shared/messaging.ts` already supports it.
- Acceptance criteria: a queued notification is delivered to a real handset; the row becomes `sent`
  with an `external_id`.
- How to verify: insert a test notification via SQL, curl `notifications-worker`, expect `sent: 1`.
- Out of scope: writing new templates.

### TASK-106: Validate fee percentages against real M-Pesa tariffs [P0]
- Milestone: M1 · Depends on: TASK-104
- Why: 24%/4% are placeholders. Substribe absorbs STK + B2C charges; margin may be negative.
- Files to touch: new migration updating `services.platform_fee_bps` / `insurance_fee_bps`;
  `docs/PAYMENTS.md` §9
- Approach: Look up current Safaricom paybill and B2C tariff bands for a KSh 250 collection and a
  KSh 180–900 payout. Compute true contribution per seat per month, then set fees so margin is
  positive at the KSh 250 price point. Record the arithmetic in the migration comment.
- Acceptance criteria: documented per-seat margin is positive; a worked example lives in
  `docs/PAYMENTS.md`.
- How to verify: `scripts/e2e-money-test.sql` still passes with updated expectations.
- Out of scope: changing the retail price without the founder's decision.

### TASK-107: Let buyers spend their wallet balance [P1]
- Milestone: M1 · Depends on: TASK-102
- Why: `refund_to_wallet` traps money — refunded users cannot use or withdraw it.
- Files to touch: new migration adding `charge_wallet(p_membership_id)`; `web/src/app/join/[seatId]/PayForm.tsx`
- Approach: Post `wallet_charge` (Dr `wallet` / Cr `buyer_escrow`) per `docs/LEDGER.md` row 7.
  In `PayForm`, if the buyer's wallet covers the seat price, offer "Pay from wallet" as the primary
  action and skip STK. **No partial charges** — full amount or fall back to STK.
- Acceptance criteria: paying from a sufficient wallet creates no `payments` row and moves the
  membership to `awaiting_invite`; insufficient balance falls back to STK.
- How to verify: SQL test — refund a membership, then join a new seat from wallet; assert
  `wallet = 0` and escrow holds the price.
- Out of scope: wallet withdrawal to M-Pesa (TASK-109).

### TASK-108: Payout retry + float monitoring [P1]
- Milestone: M1 · Depends on: TASK-104
- Why: Failed B2C (wrong number, insufficient float) must not strand owners silently.
- Files to touch: `supabase/functions/payouts-cron/index.ts`, new migration for a retry helper
- Approach: Retry `failed` payouts up to 3 times across 24h, then flag for ops via `audit_log` and
  a notification. Before sending a batch, compare the last known float against the batch total and
  abort the whole batch rather than partially paying.
- Acceptance criteria: a payout to a bad number retries 3× then stops; a batch exceeding float is
  not started.
- How to verify: force a failure with an invalid test number; observe attempts and the final state.
- Out of scope: automated float top-up.

### TASK-109: Wallet withdrawal to M-Pesa [P2]
- Milestone: M1 · Depends on: TASK-104, TASK-107
- Why: Users should be able to take their money out.
- Files to touch: new migration `withdraw_wallet`, `web/src/app/dashboard/`
- Approach: Reuse the B2C client and the payout result webhook; post Dr `wallet` / Cr `mpesa_operating`
  on confirmation only. Enforce a minimum equal to the B2C fee floor.
- Acceptance criteria: withdrawal moves money only on M-Pesa confirmation; balance can never go negative.
- How to verify: SQL test asserting wallet ≥ 0 in all paths.
- Out of scope: withdrawing to anything but the registered M-Pesa number.

---

# M2 — Communications

### TASK-201: Remove the dev login path [P0]
- Milestone: M2 · Depends on: none (but do not do it before phone OTP works — TASK-203)
- Why: Email/password sign-in with no verification must never reach production.
- Files to touch: `web/src/app/login/LoginForm.tsx`, `web/.env.example`
- Approach: Delete the `dev` step, `devAuth`, and the `DEV_LOGIN` gate entirely. Do not merely set
  the env var to false — remove the code path.
- Acceptance criteria: no email/password affordance exists in any build; `grep -r DEV_LOGIN web/src`
  returns nothing.
- How to verify: `npm run build` passes; `/login` shows only phone entry.
- Out of scope: changing OTP logic.

### TASK-202: Purge demo accounts and data from production [P0]
- Milestone: M2 · Depends on: TASK-201
- Why: `owner@substribe.dev` / `buyer@substribe.dev` share a published password and the owner is KYC-verified.
- Files to touch: none (SQL) — plus a note in `scripts/demo-seed.sql`
- Approach: `delete from auth.users where email in ('owner@substribe.dev','buyer@substribe.dev');`
  (cascades). Add a banner at the top of `demo-seed.sql`: **DEV PROJECT ONLY**.
- Acceptance criteria: neither account exists in the production project; no listings remain from them.
- How to verify: query `auth.users` for those emails → 0 rows.
- Out of scope: deleting real users.

### TASK-203: Wire a production SMS provider for phone OTP [P0]
- Milestone: M2 · Depends on: TASK-105
- Why: Phone + OTP is the real auth method and is currently unconfigured/untested.
- Files to touch: Supabase Auth settings; possibly a Send-SMS auth hook
- Approach: Simplest path is Twilio Verify in Supabase Auth → Providers → Phone. To reuse Africa's
  Talking, implement Supabase's custom Send-SMS hook. Then verify `signInWithOtp` +
  `verifyOtp({type:"sms"})` in `LoginForm.tsx` work unchanged.
- Acceptance criteria: a real Kenyan number receives a code and completes sign-in; the resulting
  `profiles.phone` is stored E.164.
- How to verify: sign in on a real handset; confirm the row in `profiles`.
- Out of scope: KYC name matching (TASK-205).

### TASK-204: Add notification templates for payouts, renewals, disputes [P1]
- Milestone: M2 · Depends on: TASK-104
- Why: New flows have no user-facing copy.
- Files to touch: `supabase/functions/_shared/templates.ts`
- Approach: Add EN + SW entries following the existing shape (`payout_sent`, `renewal_due`,
  `renewal_failed`, `dispute_opened`, `dispute_resolved`). Keep them SMS-short; use the `kes()` helper.
- Acceptance criteria: every `insert into public.notifications` template name in the codebase has a
  matching entry; unknown templates still fail loudly.
- How to verify: `grep -rho "'[a-z_]*'," | sort -u` across notification inserts, cross-checked
  against `TEMPLATES` keys.
- Out of scope: changing delivery logic.

### TASK-205: Self-serve KYC via M-Pesa name match [P1]
- Milestone: M2 · Depends on: TASK-203
- Why: Host verification is manual SQL, so no real user can ever list a plan.
- Files to touch: new migration `verify_host_identity`, `web/src/app/list/page.tsx`
- Approach: On a first successful STK payment, Daraja returns the payer's registered name. Store it
  in `profiles.mpesa_name`, compare against `full_name`, set `mpesa_name_verified` and promote
  `kyc_tier` to 1 on a match. Promotion must happen **server-side only** — the trust columns are
  trigger-guarded (see landmine #5 in HANDOFF).
- Acceptance criteria: a user who pays with a matching name becomes tier 1 automatically; a mismatch
  does not.
- How to verify: SQL test simulating a callback carrying a name; assert the tier change.
- Out of scope: ID-document upload (tier 2+).

---

# M3 — Security hardening

### TASK-301: Add input validation at every boundary [P0]
- Milestone: M3 · Depends on: none
- Why: Edge Functions accept raw JSON; only ad-hoc checks exist.
- Files to touch: `supabase/functions/mpesa-stk-initiate/index.ts`, new `_shared/validate.ts`
- Approach: Write small hand-rolled validators (do not add a dependency — see QUALITY_STANDARDS):
  `isUuid`, `isEmail`, `isKenyanPhone`, plus a max-length guard. Reject with the existing
  `json(400, {error, message})` shape and Kenyan-English copy matching `KNOWN_ERRORS`.
- Acceptance criteria: malformed UUID, oversized email, and non-Kenyan phone are all rejected before
  any DB call.
- How to verify: curl the function with bad payloads; expect 400 and no new `payments` rows.
- Out of scope: changing the DB-level checks (they stay as defence in depth).

### TASK-302: Add rate limiting to payment and auth endpoints [P0]
- Milestone: M3 · Depends on: TASK-301
- Why: `mpesa-stk-initiate` can be called in a loop, spamming STK prompts at real people.
- Files to touch: new migration for a `rate_limits` table + `check_rate_limit()`;
  `supabase/functions/mpesa-stk-initiate/index.ts`
- Approach: Postgres-backed counter keyed by `(user_id, action, window)`; allow ~5 STK initiations
  per 10 minutes per user. Deny with HTTP 429 and a clear message. Prefer this over an external
  dependency.
- Acceptance criteria: the 6th attempt inside the window returns 429 and creates no payment row.
- How to verify: loop the curl 6× and observe.
- Out of scope: global WAF/IP-level limiting.

### TASK-303: Add security headers and CSP [P1]
- Milestone: M3 · Depends on: none
- Why: No security headers are set anywhere.
- Files to touch: `web/next.config.ts`
- Approach: Add a `headers()` block: `Strict-Transport-Security`, `X-Content-Type-Options: nosniff`,
  `Referrer-Policy: strict-origin-when-cross-origin`, `X-Frame-Options: DENY`, and a
  `Content-Security-Policy` allowing `self` plus your Supabase origin for `connect-src`.
- Acceptance criteria: response headers present on every route; no CSP violations in console on
  `/`, `/browse`, `/join/[id]`, `/dashboard`, `/list`, `/login`.
- How to verify: `curl -I http://localhost:3000/browse`; walk each page with DevTools open.
- Out of scope: subresource integrity.

### TASK-304: Implement dispute payout freezing and resolution [P0]
- Milestone: M3 · Depends on: TASK-102
- Why: Owners are promised in the UI that payouts pause on a dispute; that is currently false.
- Files to touch: new migration `dispute_resolution.sql`
- Approach: Trigger on `disputes` insert → set any `pending` payout for that owner to `frozen` with
  `frozen_reason = 'dispute:'||id`, and pause the 48h auto-release by excluding disputed
  memberships (`auto_release_confirmed_silent` already does this — verify). Add
  `resolve_dispute(p_dispute_id, p_outcome, p_notes)` for admins implementing the three outcomes in
  `docs/PAYMENTS.md` §7: refunded / rematched / released. Write to `audit_log`.
- Acceptance criteria: opening a dispute freezes the payout; each resolution path posts the correct
  ledger transaction or none; ledger stays balanced.
- How to verify: SQL test — purchase, open dispute, assert frozen; resolve each way in separate
  rolled-back runs.
- Out of scope: dispute UI (TASK-502).

### TASK-305: Dependency audit [P1]
- Milestone: M3 · Depends on: none
- Why: `npm install` reports 2 moderate advisories.
- Files to touch: `web/package.json`, `web/package-lock.json`
- Approach: Run `npm audit`, read each advisory, and patch **only** what is genuinely exploitable
  here. Do not run `npm audit fix --force` (it can jump majors). Record decisions in PROGRESS_LOG.
- Acceptance criteria: no high/critical advisories; each remaining moderate has a written reason.
- How to verify: `npm audit --production`; `npm run build` still exits 0.
- Out of scope: upgrading Next/React majors.

---

# M4 — Renewals & lifecycle

### TASK-401: Build the renewal charge RPC [P1]
- Milestone: M4 · Depends on: TASK-105
- Why: Memberships never bill a second month.
- Files to touch: new migration `renewal_engine.sql`
- Approach: `start_renewal(p_membership_id)` — create a `payments` row with
  `kind='renewal'` and key `renewal:{membership_id}:{period_start}`, advance the period. Reuse
  `process_payment_event` unchanged so renewals follow the identical escrow path (`docs/PAYMENTS.md`
  §5). Add `memberships_due_for_renewal()` returning rows where `next_billing_at <= now()`.
- Acceptance criteria: calling twice for the same period is idempotent; a renewal follows the same
  escrow-hold → auto-release path.
- How to verify: SQL test — activate a membership, backdate `next_billing_at`, run the RPC, assert
  exactly one payment row.
- Out of scope: sending the STK (TASK-402).

### TASK-402: Extend payments-cron to drive renewals [P1]
- Milestone: M4 · Depends on: TASK-401
- Why: Something must call the renewal engine and push the STK.
- Files to touch: `supabase/functions/payments-cron/index.ts`
- Approach: Add a step mirroring the existing sweeps: T-2d reminder notification, T-0 STK via the
  existing `stkPush`, retries at T+1d and T+3d, then `past_due` → `suspended` after a 3-day grace
  (`docs/PAYMENTS.md` §5). Keep the summary-JSON return shape.
- Acceptance criteria: a due membership gets exactly one STK per attempt window; grace exhaustion
  suspends the membership and reopens the seat.
- How to verify: backdate a membership and run the cron; inspect payments and notifications.
- Out of scope: M-Pesa Ratiba standing orders (TASK-403).

### TASK-403: Evaluate M-Pesa Ratiba for true auto-renewal [P2]
- Milestone: M4 · Depends on: TASK-402
- Why: Reminder-STK needs the buyer to act monthly; Ratiba is a standing order.
- Files to touch: `supabase/functions/_shared/daraja.ts`, `docs/PAYMENTS.md`
- Approach: Verify the current Daraja Ratiba contract in sandbox **before** writing code (it is the
  newest API and the spec notes it is unverified). If viable, add registration + a callback path
  reusing `process_payment_event`; if not, document why and stop.
- Acceptance criteria: either a working sandbox standing order, or a written decision not to.
- How to verify: sandbox registration returns success and a scheduled debit arrives.
- Out of scope: migrating existing members.

### TASK-404: Waitlist join + auto-match [P2]
- Milestone: M4 · Depends on: none
- Why: UI copy promises a waitlist that does not exist.
- Files to touch: new migration `waitlist_match.sql`, `web/src/app/browse/page.tsx`
- Approach: Add a "Notify me" control when a service has no open seats (insert into
  `waitlist_entries` — the RLS insert policy already allows it). Add `match_waitlist()` called from
  `payments-cron` when a seat reopens: notify the head of the queue.
- Acceptance criteria: joining twice for one service is prevented by the existing partial unique
  index; a reopened seat notifies exactly one person.
- How to verify: SQL test — reopen a seat with two waiters; assert one notification.
- Out of scope: holding a seat exclusively for a waiter.

---

# M5 — Trust features & admin

### TASK-501: Ratings UI [P1]
- Milestone: M5 · Depends on: none
- Why: Trust cards show "New host" forever; the aggregate triggers have nothing to aggregate.
- Files to touch: `web/src/app/dashboard/page.tsx`, new `web/src/app/dashboard/RatingForm.tsx`
- Approach: On an `active` membership older than ~7 days with no rating from this user, show a
  1–5 star form; insert into `ratings` (client insert is already permitted by RLS to the
  counterparty). Imitate the client-component style of `dashboard/actions.tsx`.
- Acceptance criteria: each party can rate once per membership; `profiles.owner_rating` updates via
  the existing trigger; the trust card shows the score.
- How to verify: submit a rating, refresh `/browse`, see `★ 5.0`.
- Out of scope: review moderation.

### TASK-502: Dispute reporting UI [P1]
- Milestone: M5 · Depends on: TASK-304
- Why: Buyers have no way to report a dead seat — the core safety promise.
- Files to touch: `web/src/app/dashboard/`, new `ReportProblemForm.tsx`
- Approach: "Something's wrong" on each active seat → reason picker mapping to the
  `dispute_reason` enum → insert into `disputes`. Show the frozen/again-safe state clearly and
  restate the money-back promise.
- Acceptance criteria: a dispute appears in the DB, freezes the owner payout, and the buyer sees an
  explicit "we're on it" state.
- How to verify: open a dispute in the UI; confirm `payouts.status = 'frozen'`.
- Out of scope: chat between parties.

### TASK-503: Minimal admin console [P1]
- Milestone: M5 · Depends on: TASK-304
- Why: KYC and disputes are resolved by hand-written SQL today.
- Files to touch: new `web/src/app/admin/page.tsx` + child components
- Approach: Guard with the existing `is_admin()` (add an RLS-safe read). Three lists: pending KYC,
  open disputes (with the three resolution buttons calling `resolve_dispute`), and failed payouts.
  Server components + small client action buttons, exactly like the dashboard.
- Acceptance criteria: a non-admin gets 404/redirect; an admin can resolve a dispute end-to-end.
- How to verify: sign in as a non-admin (blocked) and as an admin (works).
- Out of scope: analytics.

### TASK-504: Ledger reconciliation view + nightly check [P1]
- Milestone: M5 · Depends on: TASK-104
- Why: `docs/LEDGER.md` mandates a nightly invariant check; none exists.
- Files to touch: new migration `reconciliation.sql`, `supabase/functions/payments-cron/index.ts`
- Approach: `check_ledger_invariant()` returning the identity from LEDGER.md §"core invariant" plus
  any negative balances. Call it once daily from the cron; on drift write `audit_log` and queue an
  admin notification.
- Acceptance criteria: a deliberately unbalanced state is detected (test by asserting the function
  returns drift for a crafted case); a healthy ledger reports zero.
- How to verify: run against production data — expect zero drift.
- Out of scope: M-Pesa statement import.

---

# M6 — Testing & error handling

### TASK-601: Install a test framework and write the first tests [P0]
- Milestone: M6 · Depends on: none
- Why: **Zero automated tests exist.** No safety net for any change.
- Files to touch: `web/package.json`, new `web/vitest.config.ts`, `web/src/lib/format.test.ts`
- Approach: Add Vitest (fast, minimal config, works with the existing TS setup). Add
  `"test": "vitest run"`. First target the pure functions in `web/src/lib/format.ts`:
  `fmtKes`, `savingsPercent`, `normalizeKenyanPhone` — including edge cases (07/01/+254/254 forms,
  invalid numbers, zero cents, rounding).
- Acceptance criteria: `npm test` runs and passes; at least 12 assertions covering all three helpers.
- How to verify: `cd web && npm test` → exit 0 with the suite listed.
- Out of scope: component or E2E tests.

### TASK-602: Test the Daraja helpers [P0]
- Milestone: M6 · Depends on: TASK-601
- Why: Phone/timestamp/password formatting bugs would break every payment silently.
- Files to touch: new `web/src/lib/daraja-format.test.ts` (or a Deno test beside the function)
- Approach: `toDarajaPhone` is currently only in the Deno module. Either extract the pure helpers
  into a shared file importable by both, or write Deno tests run via `deno test`. Prefer extraction —
  do not duplicate the logic.
- Acceptance criteria: tests cover `+2547…`/`+2541…` accepted, non-Kenyan rejected, EAT timestamp
  is 14 digits and UTC+3.
- How to verify: `npm test` (or `deno test supabase/functions/_shared/`) exits 0.
- Out of scope: mocking the whole Daraja API.

### TASK-603: Add error boundaries and not-found pages [P0]
- Milestone: M6 · Depends on: none
- Why: No `error.tsx`, `loading.tsx`, or `not-found.tsx` exists anywhere — an exception shows a raw
  Next error page.
- Files to touch: new `web/src/app/error.tsx`, `web/src/app/not-found.tsx`,
  `web/src/app/browse/loading.tsx`, `web/src/app/dashboard/loading.tsx`
- Approach: Match the existing visual language (stone/emerald tokens, rounded-2xl cards, warm copy).
  The error page must **never** blame the user or show a stack trace; give a retry action. Use
  skeletons, not spinners (per `SCOPE.md` §8).
- Acceptance criteria: a thrown error renders the branded boundary; an unknown URL renders the
  branded 404; slow loads show a skeleton.
- How to verify: temporarily throw in a server component; visit `/nonexistent`.
- Out of scope: error reporting to a service (TASK-702).

### TASK-604: Empty and failure states for every data view [P1]
- Milestone: M6 · Depends on: TASK-603
- Why: `/browse` handles empty; `/dashboard` partially; failures mostly render nothing.
- Files to touch: `web/src/app/browse/page.tsx`, `web/src/app/dashboard/page.tsx`,
  `web/src/app/list/ListingForm.tsx`
- Approach: For each fetch, handle three states — data, empty, error — with real copy and a next
  action. Imitate the existing dashed-border empty card in `dashboard/page.tsx`.
- Acceptance criteria: with the network blocked, every page shows an explanatory message rather than
  a blank region.
- How to verify: DevTools offline mode on each route.
- Out of scope: retry-with-backoff.

### TASK-605: Accessibility and responsive pass [P1]
- Milestone: M6 · Depends on: TASK-603
- Why: The audience is Android-on-3G; a11y is an acceptance criterion, not polish.
- Files to touch: all of `web/src/app/**`, `web/src/components/**`
- Approach: Verify at 375 / 768 / 1440 px. Check: labels tied to inputs, focus-visible rings,
  ≥44px tap targets, WCAG AA contrast (especially emerald-on-emerald in the hero and the amber
  savings badge), heading order, and that the polling spinner in `PayForm` announces via
  `aria-live`.
- Acceptance criteria: no contrast failure below AA; keyboard-only completion of the join flow;
  no horizontal scroll at 375px.
- How to verify: Lighthouse a11y ≥ 95 on `/browse` and `/join/[id]`; manual keyboard walkthrough.
- Out of scope: full screen-reader certification.

### TASK-606: Database indexes review under load [P2]
- Milestone: M6 · Depends on: none
- Why: Indexes were written by intuition, never measured.
- Files to touch: new migration adding any missing indexes
- Approach: `EXPLAIN ANALYZE` the browse query, the dashboard queries, and each cron sweep against
  seeded volume (~10k seats). Add indexes only where a scan is proven.
- Acceptance criteria: no sequential scan on a table >1k rows in those queries; each new index
  justified in the migration comment.
- How to verify: paste EXPLAIN output into PROGRESS_LOG.
- Out of scope: partitioning.

---

# M7 — Deployment & observability

### TASK-701: Deploy the web app to Vercel [P0]
- Milestone: M7 · Depends on: TASK-201, TASK-303
- Why: Nothing is hosted; the product only runs on localhost.
- Files to touch: possibly `web/next.config.ts`; new `README.md` deploy section
- Approach: Connect the GitHub repo with root directory `web`. Set `NEXT_PUBLIC_SUPABASE_URL` and
  `NEXT_PUBLIC_SUPABASE_ANON_KEY` in Vercel. **Do not set `NEXT_PUBLIC_DEV_LOGIN`.** Add the Vercel
  domain to Supabase Auth → URL Configuration (redirect allow-list).
- Acceptance criteria: the public URL serves `/browse` with live data; sign-in works; no secrets in
  the client bundle beyond the anon key.
- How to verify: load the deployment on a phone; complete browse → join → pay screen.
- Out of scope: custom domain.

### TASK-702: Add error tracking and health checks [P0]
- Milestone: M7 · Depends on: TASK-701
- Why: There is no way to learn that production broke.
- Files to touch: new `web/src/app/api/health/route.ts`; Sentry config if adopted
- Approach: Health route returns 200 with a DB connectivity check. Add Sentry (free tier) to the web
  app and `console.error` structured JSON in Edge Functions (they already log errors — keep the
  style). Never log phone numbers, tokens, or payloads containing PII.
- Acceptance criteria: `/api/health` returns 200/503 correctly; a deliberate error appears in the
  dashboard within a minute.
- How to verify: curl the health route with the DB paused and running.
- Out of scope: full APM.

### TASK-703: CI pipeline [P0]
- Milestone: M7 · Depends on: TASK-601
- Why: Nothing prevents a broken commit from reaching main.
- Files to touch: new `.github/workflows/ci.yml`
- Approach: On push/PR: Node 24, `npm ci` in `web`, then `npm run lint`, `npx tsc --noEmit`,
  `npm test`, `npm run build`. Fail on any non-zero exit.
- Acceptance criteria: a deliberately broken type fails CI; a clean commit passes.
- How to verify: push a branch with an error, observe red, fix, observe green.
- Out of scope: deploy-from-CI.

### TASK-704: Staging environment [P1]
- Milestone: M7 · Depends on: TASK-701
- Why: Payment changes must never be tested first in production.
- Files to touch: `README.md`
- Approach: Create a second Supabase project, apply `_bootstrap.generated.sql`, keep it on
  `DARAJA_ENV=sandbox`, and point a Vercel preview deployment at it. Production alone uses the
  production paybill.
- Acceptance criteria: two isolated environments; staging cannot touch real money.
- How to verify: confirm distinct project refs and Daraja envs.
- Out of scope: automated data seeding.

### TASK-705: Backups and rollback plan [P0]
- Milestone: M7 · Depends on: TASK-701
- Why: Free-tier Supabase backup retention is limited, and money data is irreplaceable.
- Files to touch: new `docs/RUNBOOK.md`
- Approach: Document/enable daily backups; script a `pg_dump` of the ledger tables to off-platform
  storage. Write the rollback procedure for a bad migration (**forward-only fixes for the ledger** —
  never restore over posted entries without reconciliation) and for a bad Vercel deploy (instant
  rollback).
- Acceptance criteria: a restore has been rehearsed at least once on staging.
- How to verify: perform and record a staging restore.
- Out of scope: multi-region DR.

---

# M8 — Launch

### TASK-801: Legal pages and data-protection registration [P0]
- Milestone: M8 · Depends on: TASK-701
- Why: Kenya's Data Protection Act 2019 requires ODPC registration; the product handles PII and money.
- Files to touch: new `web/src/app/terms/page.tsx`, `web/src/app/privacy/page.tsx`; footer links
- Approach: Terms must cover the account-sharing grey area and place provider-ToS responsibility on
  plan owners (per `SCOPE.md` §9.3). Privacy must state what is collected (phone, name, M-Pesa name,
  email), retention, and the ODPC contact. **Have a Kenyan lawyer review before launch.**
- Acceptance criteria: both pages exist, are linked from the footer, and are referenced at signup.
- How to verify: visit both; confirm footer links.
- Out of scope: writing final legal language without review.

### TASK-802: SEO and social metadata [P2]
- Milestone: M8 · Depends on: TASK-701
- Why: Only a title/description exist; no OG image or sitemap.
- Files to touch: `web/src/app/layout.tsx`, new `web/src/app/sitemap.ts`, `web/public/og.png`
- Approach: Add OpenGraph/Twitter metadata and a share image showing the savings claim. Keep copy
  consistent with the landing page.
- Acceptance criteria: a shared link renders a card; sitemap lists public routes.
- How to verify: paste the URL into a link-preview debugger.
- Out of scope: paid acquisition.

### TASK-803: Production Daraja go-live [P0]
- Milestone: M8 · Depends on: TASK-104, TASK-106, TASK-704
- Why: The sandbox cannot take real money.
- Files to touch: none (configuration) — plus `docs/PAYMENTS.md` §10 checklist
- Approach: Register the company, obtain a paybill, create a production Daraja app, generate the B2C
  `SecurityCredential`, and set production secrets. Work the existing go-live checklist in
  `docs/PAYMENTS.md` §10 item by item, including the sandbox test matrix (success, 1032 cancel,
  1 insufficient, 2001 wrong PIN, 1037 timeout, duplicate replay).
- Acceptance criteria: every checklist box ticked; a real KSh 10 payment and payout completed
  end-to-end.
- How to verify: real transaction receipts reconciled against the ledger.
- Out of scope: scaling limits.

### TASK-804: Pre-launch checklist [P0]
- Milestone: M8 · Depends on: all P0 tasks
- Why: Final gate.
- Files to touch: `docs/RUNBOOK.md`
- Approach: Verify in order — dev login removed · demo accounts purged · cron scheduled and
  observed running · notifications delivering to real handsets · payouts proven end-to-end ·
  ledger invariant clean · backups rehearsed · error tracking live · legal pages published ·
  security headers present · rate limiting active · CI green · staging isolated from production.
- Acceptance criteria: every item verified with pasted evidence in `PROGRESS_LOG.md`.
- How to verify: the log contains real command output for each line.
- Out of scope: marketing launch.

---

## Dependency overview

```
M0: 001 → 002        003, 004 independent
M1: 101 → 102 → 103 → 104 → {106, 108, 109}
    105 (needs 001)        107 (needs 102)
M2: 201 → 202          203 (needs 105) → 205        204 (needs 104)
M3: 301 → 302          303, 305 independent          304 (needs 102)
M4: 401 (needs 105) → 402 → 403                      404 independent
M5: 501 independent    502 (needs 304)    503 (needs 304)    504 (needs 104)
M6: 601 → 602          603 → 604, 605                606 independent
M7: 701 (needs 201,303) → 702, 704, 705              703 (needs 601)
M8: 801 (needs 701)    803 (needs 104,106,704)    804 (needs all P0)
```

**Critical path to a working marketplace:** 001 → 002 → 105 → 101 → 102 → 103 → 104.
Until TASK-104 lands, Substribe can take money but cannot pay it out.
