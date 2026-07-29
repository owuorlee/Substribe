# Substribe — Progress Log

**This file replaces chat memory.** The agent working on this project has no recollection of
previous sessions. This log is the only continuity between them.

## Rules

1. **Read this file first, every session, before touching anything.** Start from the bottom (most
   recent entry).
2. **Append an entry after every task.** Never edit or delete an old entry — append a correction
   instead.
3. **Paste real command output.** Not "tests passed" — the actual output you observed.
4. Record **applied migrations** here. There is no reliable migration-tracking table (migrations
   are applied by pasting SQL into the Supabase SQL Editor), so this log *is* the record.
5. Record every **dependency change** and its justification.
6. Record everything **discovered** — surprises, wrong assumptions, doc errors. That is often more
   valuable to the next session than the code you wrote.

## Entry template

```markdown
---
## YYYY-MM-DD — TASK-0XX: <title>

**Status:** Complete | Partial | Blocked
**What changed:** <2–4 sentences>
**Files touched:**
- path/to/file.ts — what changed

**Migrations applied to hosted DB:** <filename, or "none">

**Verification:**
```
<paste real output: lint / tsc / test / build, curl results, SQL results>
```

**Discovered:** <surprises, wrong docs, follow-ups worth doing — or "nothing">
**Next:** TASK-0YY
---
```

---

# Log

---
## 2026-07-29 — HANDOFF: project transferred from Claude Code to a new agent

**Status:** Complete
**What changed:** No feature code. Produced the handoff package in `docs/handoff/` after auditing
the codebase and verifying behaviour against the live Supabase project. Also fixed one real bug
found during verification (see below).

**Files touched:**
- `docs/handoff/HANDOFF.md` — master doc: product, stack, setup, env vars, codebase map, landmines
- `docs/handoff/ARCHITECTURE.md` — data flow, data model, auth model, decisions
- `docs/handoff/STATE_OF_PLAY.md` — feature-by-feature status; §2 lists everything faked/missing
- `docs/handoff/ROADMAP_TO_PRODUCTION.md` — 40 tasks, M0–M8, dependency-ordered
- `docs/handoff/QUALITY_STANDARDS.md` — rules for the next agent
- `docs/handoff/PROGRESS_LOG.md` — this file
- `docs/handoff/AGENT_ONBOARDING.md` — start-here brief

**Migrations applied to hosted DB this session:** none.
⚠️ **`20260728000100_fix_claim_notifications.sql` is committed but NOT applied.** It is the very
first task (TASK-001).

**Applied-migration state of the hosted DB** (`hrhichipovynekorjovb`), best reconstruction:
| Migration | Applied? |
|---|---|
| `20260702000100_extensions_and_types.sql` … `20260709000100_notifications_worker.sql` (10 files) | ✅ yes — applied as one bootstrap paste |
| `20260712000100_fix_profile_guard.sql` | ✅ yes |
| `20260728000100_fix_claim_notifications.sql` | ❌ **NO** |

**Verification (all run this session, real output):**
```
cd web && npm run lint        → exit 0, no findings
cd web && npx tsc --noEmit    → exit 0
cd web && npm run build       → exit 0; routes: / /_not-found /auth/signout /browse
                                /dashboard /join/[seatId] /list /login
cd web && npm run dev         → Ready; /browse rendered live data from hosted DB
```
Live checks against `hrhichipovynekorjovb`:
```
services (anon)        → [{"slug":"spotify-family","is_active":true}]
profiles (anon)        → []                       (RLS working)
ledger_entries (anon)  → 42501 permission denied  (money tables locked)
auth+RLS script        → 6/6 PASS (sign-in, own profile only, ledger denied,
                          cannot self-promote kyc_tier)
mpesa-stk-initiate     → {"payment_id":"45dd2022-…","status":"pending"}
                          Daraja CheckoutRequestID ws_CO_290720261137079708374149
payments-cron          → {"events_processed":0,"stk_queries":{…},
                          "reservations_expired":1,…}   ← sweep verified live
payments-cron (bad secret) → HTTP 401
notifications-worker   → {"error":"claim_failed"}       ← BROKEN, see TASK-001
```
SQL money engine (`scripts/e2e-money-test.sql`, run in SQL Editor): passed — a full KSh 250
purchase produced owner_payable 18000, platform_revenue 6000, insurance_reserve 1000,
buyer_escrow 0, mpesa_operating 25000, then rolled back cleanly.

**Discovered:**
1. **Two real bugs were found and fixed by testing, not by reading.**
   - `protect_profile_columns` blocked our own trigger cascades — **every buyer confirmation would
     have failed in production**, plus disputes and ratings. Fixed in `20260712000100`.
   - `claim_notifications` referenced the UPDATE target inside a `FROM` join, which Postgres
     rejects at execution time — the outbox would never have drained. Fixed in `20260728000100`
     (**not yet applied**).
   Lesson for the next agent: plpgsql only parses query bodies at *execution* time, so
   `CREATE FUNCTION` succeeding proves nothing. Call every new function once.
2. **Owners cannot be paid.** The `payouts` table, enum, RLS and constraints exist, but no code
   ever inserts a payout. This is the single largest gap → M1.
3. **Nothing is scheduled.** All sweeps require a manual curl → TASK-002.
4. **Notification delivery defaults to `log`.** Even after TASK-001, no message reaches a human
   until a provider is configured → TASK-105. Without it, every purchase auto-refunds at the 12h
   invite SLA.
5. **No automated tests exist** in JS/TS; the only real test is the SQL money script.
6. `web/src/middleware.ts` had to be renamed to `web/src/proxy.ts` with the export renamed
   `middleware` → `proxy` for Next 16.
7. The local Supabase stack was never run (Docker image pull too slow on this connection);
   everything targets the hosted project, and migrations are applied by pasting SQL.
8. Free-tier Supabase auto-pauses after inactivity; the first request after a pause can fail.
9. The in-app browser pane used for testing does not hydrate React (it is not compositing frames),
   so clicks appear dead there. The app is fine in a real browser — verified by the human.
10. `supabase/_bootstrap.generated.sql` is generated **and gitignored**; it does not exist in a
    fresh clone and does not auto-update → TASK-003.

**Next:** TASK-001 (apply the pending migration), then TASK-002 (schedule cron), then M1.
---
