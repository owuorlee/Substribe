# Substribe — Master Handoff

**Written:** 2026-07-29 · **Repo:** https://github.com/owuorlee/Substribe · **Branch:** `main` (only branch, clean)
**Last commit at handoff:** `07c33d9`

Read this file first, then `ARCHITECTURE.md`, then `STATE_OF_PLAY.md`, then `ROADMAP_TO_PRODUCTION.md`.

---

## 1. What this product is

Substribe is a **marketplace for splitting subscription costs in Kenya**. A person who owns a
family/team plan (Spotify Premium Family, YouTube Premium, Microsoft 365, ChatGPT Team…) lists
their empty seats. A buyer joins a seat and pays monthly **via M-Pesa**. Substribe holds the
buyer's money **in escrow** and releases it to the owner only after the buyer confirms their
access works. Substribe takes a margin.

**Who it's for:** university students and young freelancers in Kenya who are priced out of
premium subscriptions. A Spotify solo plan is KSh 599/month; a Substribe seat is KSh 250.

**The problem it solves:** these plans are *designed* to be shared, but finding people to split
with and trusting them with money is the hard part. Kenya's informal subscription-sharing market
runs on WhatsApp groups and is riddled with scams. Substribe is the trust layer: escrow,
reputation, automatic refunds.

**Hard product constraint:** Substribe only brokers plans where each member gets their **own
login via an official invite**. No password sharing, ever. If a service requires sharing
credentials, it does not go on the platform. This is both a trust promise and an architectural
simplification — every service uses one code path.

---

## 2. Core user journeys

**Owner (the "host"):**
1. Signs in → gets verified (KYC tier 1) → lists a plan at `/list`, choosing seat count and price
2. Gets notified when a buyer pays
3. Invites the buyer's email on the provider's own site (Spotify, etc.)
4. Marks "I've sent the invite" in Substribe
5. Money is released to their Substribe balance when the buyer confirms

**Buyer (the "saver"):**
1. Browses open seats at `/browse` → sees price, savings %, owner trust card
2. Opens `/join/[seatId]` → sees full fee breakdown and the escrow promise
3. Enters invite email + M-Pesa number → pays via STK push
4. **Money goes to escrow, not to the owner**
5. Accepts the provider invite → taps "I have access" → escrow releases

**Safety nets (implemented in the DB):** if the owner never invites within 12 hours, the buyer is
auto-refunded to their Substribe wallet with a goodwill credit. If the buyer goes silent for 48
hours after being invited, escrow auto-releases so owners aren't held hostage.

---

## 3. Current status — one honest sentence

**The database and money engine are complete and verified against production Postgres; the web
app covers browse/join/pay/list/dashboard and is wired to live M-Pesa sandbox; but owners cannot
yet be paid (no payout code exists), there are no renewals, no disputes/ratings/admin UI, no
automated tests, and nothing is deployed to a public URL.**

Put bluntly: **money can go in, but money cannot come out.** That is the single biggest gap.

---

## 4. Tech stack (exact, verified)

| Layer | Choice | Version | Why |
|---|---|---|---|
| Frontend | Next.js (App Router) | `16.2.10` | SSR for fast first paint on slow Kenyan mobile networks; one codebase |
| UI runtime | React | `19.2.4` | Bundled with Next 16 |
| Styling | Tailwind CSS | `^4` (v4 syntax, `@import "tailwindcss"`) | Small CSS, no runtime |
| Language | TypeScript | `^5`, `strict: true` | Money code must not have type slips |
| Backend/DB | Supabase (hosted Postgres) | Postgres `17.6.1.141` | Postgres + Auth + RLS + Edge Functions + REST on a free tier |
| DB client | `@supabase/supabase-js` | `^2.110.0` | Official |
| SSR auth | `@supabase/ssr` | `^0.12.0` | Cookie-based session handling for App Router |
| Serverless | Supabase Edge Functions (Deno) | deployed | Public HTTPS URLs Safaricom can call back to |
| Payments | M-Pesa Daraja API | sandbox | The payment rail in Kenya; card payments are irrelevant to this market |
| Lint | ESLint + `eslint-config-next` | `^9` / `16.2.10` | Next defaults |
| Tests | **NONE** | — | No test framework installed. See STATE_OF_PLAY. |

**Local toolchain verified on the handoff machine:** Node `v24.12.0`, npm `11.6.2`,
Supabase CLI `2.109.1` (invoked via `npx supabase@latest`), Docker `29.6.1` installed but
**local Supabase stack was never run** — image pull was too slow on this connection. All work
targets the **hosted** Supabase project.

---

## 5. Get running in 10 minutes

```bash
git clone https://github.com/owuorlee/Substribe.git
cd Substribe/web
npm install
```
Expected: `added ~371 packages`. There are 2 moderate advisories from `npm audit` — see roadmap TASK-501.

Create `web/.env.local` (copy from `web/.env.example`):
```
NEXT_PUBLIC_SUPABASE_URL=https://hrhichipovynekorjovb.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=<anon key from Supabase dashboard → Settings → API>
NEXT_PUBLIC_DEV_LOGIN=true
```

```bash
npm run dev
```
Expected output:
```
▲ Next.js 16.2.10 (Turbopack)
- Local:  http://localhost:3000
✓ Ready in ~5s
```

**Verify it works:** open `http://localhost:3000/browse`. You should see a listing card:
*Spotify Premium Family · 5 seats open · KSh 250/mo · save 58% · Brian · New host*.
If you see "Almost there" instead, your env vars are missing.

**Sign in:** `/login` → "Dev sign-in (email + password)" → `buyer@substribe.dev` / `substribe123`
(seeded by `scripts/demo-seed.sql`; owner account is `owner@substribe.dev` / same password).

### Database setup (only if starting a fresh Supabase project)
Migrations were applied by **pasting SQL into the Supabase SQL Editor**, not via `supabase db push`
(the CLI was never linked with a DB password). `supabase/_bootstrap.generated.sql` is a generated
concatenation of all migrations + seed for exactly this purpose.

1. Supabase Dashboard → SQL Editor → New query
2. Paste all of `supabase/_bootstrap.generated.sql` → Run → expect *"Success. No rows returned."*
3. Paste `scripts/demo-seed.sql` → Run → expect a grid showing 5 open seats
4. Dashboard → Authentication → Providers → enable **Email**

### Verify the whole stack
```bash
cd web && npm run build      # exit 0, 8 routes listed
cd web && npm run lint       # exit 0, no output
cd web && npx tsc --noEmit   # exit 0
```
All three were run at handoff and passed.

---

## 6. Environment variables

### Web app (`web/.env.local`)
| Name | Purpose | Example | Where to get it | Required locally |
|---|---|---|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | Supabase project endpoint | `https://hrhichipovynekorjovb.supabase.co` | Dashboard → Settings → API | **Yes** |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | Public anon key (safe in browser; RLS enforces access) | `eyJhbGci…` | Dashboard → Settings → API | **Yes** |
| `NEXT_PUBLIC_DEV_LOGIN` | Shows email/password sign-in on `/login` | `true` | You choose | No (`false`/unset in prod) |

### Edge Functions (`supabase secrets set`)
| Name | Purpose | Example | Where to get it | Required |
|---|---|---|---|---|
| `DARAJA_ENV` | `sandbox` or `production` | `sandbox` | You choose | Yes |
| `DARAJA_CONSUMER_KEY` | Daraja app key | — | developer.safaricom.co.ke → My Apps | Yes |
| `DARAJA_CONSUMER_SECRET` | Daraja app secret | — | same | Yes |
| `DARAJA_SHORTCODE` | Paybill / till | `174379` (shared sandbox paybill) | Safaricom | Yes |
| `DARAJA_PASSKEY` | STK password seed | (public sandbox passkey is in `supabase/functions/.env.local`) | Safaricom | Yes |
| `CRON_SECRET` | Auth header for cron endpoints | long random string | You generate | Yes |
| `CALLBACK_BASE_URL` | Override callback host (ngrok during local testing) | `https://x.ngrok.app` | ngrok | No |
| `DELIVERY_MODE` | `whatsapp` / `sms` / `auto` / `log` | `log` | You choose | No — defaults to `log` when no provider creds |
| `WHATSAPP_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID` | WhatsApp Cloud API | — | Meta developer console | No (not yet configured) |
| `AT_API_KEY`, `AT_USERNAME`, `AT_SENDER_ID` | Africa's Talking SMS | — | africastalking.com | No (not yet configured) |
| `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` | — | — | **Injected automatically by Supabase** — never set these | n/a |

**Six secrets are currently set on the project** (the Daraja five + `CRON_SECRET`).
Local dev copies live in `supabase/functions/.env.local` — **gitignored, never commit**.

---

## 7. External services

| Service | Role | Status |
|---|---|---|
| **Supabase** (`hrhichipovynekorjovb`, region `eu-west-3`/Paris) | Postgres, Auth, RLS, Edge Functions, REST | Live, free tier. **Free projects auto-pause after inactivity** — first request after a pause may fail; open the dashboard to wake it. |
| **M-Pesa Daraja** (Safaricom) | STK Push (collect), B2C (payout, *not yet built*), transaction status | Sandbox app created and **verified working** |
| **WhatsApp Cloud API** | Primary notification channel | Code written, **not configured** |
| **Africa's Talking** | SMS fallback + future SMS OTP | Code written, **not configured** |
| **GitHub** | Source | `owuorlee/Substribe`, pushes via Windows Credential Manager |
| **Vercel** | Intended web host | **Not set up.** Nothing is deployed. |

---

## 8. Map of the codebase

```
SCOPE.md                     Product scope & strategy. Read for "why", not "how".
README.md                    Short orientation.
docs/DATABASE.md             Schema guide: entities, RLS model, conventions.
docs/LEDGER.md               Double-entry ledger: accounts, posting matrix, invariants. READ BEFORE TOUCHING MONEY.
docs/PAYMENTS.md             M-Pesa spec: state machines, webhook handling, timers, edge cases.
docs/handoff/                These documents.

scripts/
  e2e-money-test.sql         Simulates a full purchase in one transaction, asserts every ledger
                             balance, then ROLLS BACK. Your regression test for the money engine.
  demo-seed.sql              Creates 2 sign-in-able accounts + 1 live Spotify listing. COMMITS.
  smoke-test.sql             Verifies tables/functions/RLS exist.

supabase/
  _bootstrap.generated.sql   GENERATED. All migrations + seed concatenated for SQL-Editor paste.
                             Regenerate after adding a migration (see landmine #3).
  config.toml                Local-stack config. Only relevant if you run Supabase locally.
  seed.sql                   Service catalogue (only spotify-family is active).
  migrations/                12 files, timestamp-ordered. NEVER edit an applied one; add a new one.
  functions/
    _shared/daraja.ts        Daraja client: OAuth token cache, STK push, STK query, phone/timestamp formatting.
    _shared/util.ts          Supabase client factories (service-role & user-scoped), json(), sha256Hex().
    _shared/messaging.ts     WhatsApp + SMS senders, DELIVERY_MODE switch, `log` fallback.
    _shared/templates.ts     Bilingual (EN/SW) notification copy keyed by template name.
    mpesa-stk-initiate/      Buyer-facing: reserve seat → create payment → send STK push.
    mpesa-stk-callback/      Daraja webhook: store raw event, ack 200, process.
    payments-cron/           Heartbeat: reprocess events, STK queries, 3 sweeps.
    notifications-worker/    Drains the notification outbox.

web/
  src/proxy.ts               Next 16 "proxy" (was middleware.ts): refreshes Supabase session cookies.
  src/lib/supabase/client.ts Browser client. Throws a clear error if env vars missing.
  src/lib/supabase/server.ts Server client + isSupabaseConfigured().
  src/lib/format.ts          fmtKes(cents), savingsPercent(), normalizeKenyanPhone().
  src/components/SiteHeader.tsx   Nav + auth state.
  src/components/TrustCard.tsx    Owner trust proof (rating, seats filled, disputes, tenure).
  src/components/SetupNotice.tsx  Shown when env vars are missing.
  src/app/page.tsx           Landing page.
  src/app/browse/page.tsx    Open seats list. SSR.
  src/app/join/[seatId]/     page.tsx = fee breakdown + escrow promise; PayForm.tsx = STK + polling.
  src/app/list/              page.tsx = KYC gate; ListingForm.tsx = create listing + earnings preview.
  src/app/dashboard/         page.tsx = buyer seats + owner listings; actions.tsx = confirm/invite buttons.
  src/app/login/             page.tsx + LoginForm.tsx (phone OTP + gated dev email login).
  src/app/auth/signout/route.ts   POST → sign out → redirect.
```

---

## 9. Known bugs, broken things, technical debt

1. **`claim_notifications` fix is committed but NOT applied to the hosted database.** Migration
   `20260728000100_fix_claim_notifications.sql` exists in the repo; the live DB still has the
   broken version. `notifications-worker` returns `{"error":"claim_failed"}` on every call —
   verified at handoff. **Fix this first: TASK-001.**
2. **No payout code exists at all.** The `payouts` table, its enum, RLS and constraints exist, but
   nothing inserts a payout row. Owners accrue `owner_payable` in the ledger with no way to be paid.
3. **No renewal engine.** `memberships.next_billing_at` is written on join and never read.
   Subscriptions will never bill a second month.
4. **No disputes logic.** `disputes` table + RLS insert policy exist; nothing freezes payouts,
   nothing resolves them, and there is no UI to open one.
5. **No waitlist logic.** Table + RLS exist. UI copy references a waitlist that you cannot join.
6. **No ratings UI.** Table, RLS, and aggregate triggers exist; nothing calls them.
7. **No admin console.** KYC verification requires a manual SQL `UPDATE`.
8. **Zero automated tests in JS/TS.** No framework installed, no `test` script.
9. **Cron is not scheduled.** `payments-cron` and `notifications-worker` must be invoked manually
   with curl today. Nothing runs on a timer, so sweeps/timeouts only fire when someone calls them.
10. **Nothing is deployed.** The web app runs only on localhost.
11. **`supabase/functions/README.md` says ngrok is needed for callbacks.** That is now stale —
    Edge Functions are deployed at public HTTPS URLs Safaricom can reach directly.
12. **Free-tier Supabase auto-pauses.** Expect failures after idle periods until you wake it.

---

## 10. Landmines (non-obvious things that will bite you)

1. **All money is `bigint` cents. Never use floats.** M-Pesa moves whole shillings, so any
   chargeable amount must satisfy `cents % 100 == 0` — `reserve_seat_and_start_join` raises
   `price_not_whole_shillings` otherwise.
2. **The ledger is append-only and enforced by triggers.** `ledger_entries` / `ledger_transactions`
   reject UPDATE and DELETE. To correct a mistake you post a *reversing* transaction. Do not try
   to "fix" a row.
3. **`supabase/_bootstrap.generated.sql` is generated and gitignored.** It does NOT auto-update.
   After adding a migration you must regenerate it (the PowerShell snippet is in PROGRESS_LOG)
   or a fresh setup will silently miss your migration.
4. **Migrations were applied by pasting, not by CLI.** There is no `supabase_migrations` tracking
   table in sync. **You cannot trust `supabase db push` to know what's applied.** Track applied
   migrations manually in `PROGRESS_LOG.md`.
5. **`protect_profile_columns` deliberately allows writes at `pg_trigger_depth() > 1`.** This looks
   like a security hole; it is not. Client updates run at depth 1 (blocked); our own triggers
   (seat activation, ratings, disputes) cascade at depth 2 (allowed). Removing this breaks buyer
   confirmation. See migration `20260712000100`.
6. **`mpesa-stk-callback` always returns HTTP 200, even for a bad token.** Deliberate: a non-200
   makes Daraja retry, and differentiated responses would let an attacker probe which payment IDs
   exist. Auth is the per-payment `callback_token` in the URL, checked silently.
7. **Ledger postings happen only on M-Pesa *proof* (a receipt number), never on intent.**
   `process_payment_event` parks a "successful" STK Query result that lacks a receipt rather than
   posting it. Do not shortcut this.
8. **Seat vs membership are different things.** A `seat` is a slot on a plan; a `membership` is one
   buyer's tenure on it. A buyer leaving reopens the seat and keeps membership history.
9. **`create_listing` is the only way to make a listing.** The direct-insert RLS policy was
   deliberately dropped — a raw insert would create a listing with no seat rows.
10. **Fee split is snapshotted into `memberships` at join time.** Changing `services.platform_fee_bps`
    does not affect existing members. That is intentional.
11. **`web/src/proxy.ts` must be named that** (Next 16 renamed `middleware`). The exported function
    is `proxy`, not `middleware`.
12. **Idempotency keys are deterministic strings**, e.g. `escrow_hold:{payment_id}`. Never include
    a timestamp or random value — re-posting must be a no-op.
13. **Daraja sandbox never prompts a real phone.** Use test MSISDN `254708374149`.
14. **The `services` catalogue ships mostly inactive on purpose.** Only `spotify-family` is active.
    `chatgpt-team` / `claude-team` carry a note that they are per-seat priced (splitting yields no
    discount) — read `supabase/seed.sql` notes before activating anything.

---

## 11. Glossary

| Term | Meaning |
|---|---|
| **Owner / host** | Person who owns the family/team plan and lists seats |
| **Buyer / saver** | Person who rents a seat |
| **Seat** | One slot on a plan (`seats` table) |
| **Membership** | One buyer's tenure on a seat, with price snapshot (`memberships`) |
| **Escrow** | Buyer's money held by Substribe until access is confirmed |
| **Escrow hold / release** | Ledger transactions moving money into / out of escrow |
| **Invite SLA** | Hours an owner has to send the provider invite (default 12) before auto-refund |
| **STK Push** | M-Pesa "enter your PIN" prompt sent to a phone |
| **Daraja** | Safaricom's M-Pesa developer API |
| **B2C** | M-Pesa business-to-customer payment (used for payouts/refunds) |
| **Ratiba** | M-Pesa standing order API (for recurring billing) |
| **KYC tier** | 0 = browse/buy, 1 = verified host (M-Pesa name matched), 2+ = higher limits |
| **bps** | Basis points; `platform_fee_bps = 2400` means 24% |
| **SubBot** | Product name for the automation layer (matching, nudges, sweeps) |
| **Make-whole loop** | Auto-refund + goodwill credit when a seat fails |
