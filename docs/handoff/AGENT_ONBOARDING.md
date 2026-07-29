# Start Here — Onboarding for the Incoming Agent

**You are taking over Substribe. Read this page fully before you write any code.**

## What this project is

Substribe is a marketplace for **splitting subscription costs in Kenya**: someone with a family or
team plan (Spotify, YouTube, Microsoft 365, ChatGPT Team) lists their empty seats, and a buyer joins
one and pays monthly **via M-Pesa**. Substribe holds the buyer's money **in escrow** and releases it
to the owner only after the buyer confirms their access works. It exists because these plans are
built to be shared, but the sharing market runs on WhatsApp groups full of scams — Substribe is the
trust layer.

**One sentence of status:** the database and money engine are complete and verified against
production Postgres, and the web app covers browse/join/pay/list/dashboard wired to live M-Pesa
sandbox — **but owners cannot yet be paid, nothing runs on a schedule, notifications are dead, and
nothing is deployed.**

## Reading order (do not skip)

1. **`docs/handoff/HANDOFF.md`** — product, stack, how to run it, env vars, codebase map, and
   §10 **Landmines**. The landmines will save you from breaking things that look wrong but are not.
2. **`docs/handoff/STATE_OF_PLAY.md`** — especially **§2**, everything faked or missing. Several
   subsystems have tables, enums, and RLS but **zero implementing code**. Never assume a table means
   a feature works.
3. **`docs/handoff/ARCHITECTURE.md`** — data flow, data model, auth model, and why things are the
   way they are.
4. **`docs/handoff/QUALITY_STANDARDS.md`** — the rules you must follow. Non-negotiable.
5. **`docs/handoff/ROADMAP_TO_PRODUCTION.md`** — your work queue, in dependency order.
6. **`docs/handoff/PROGRESS_LOG.md`** — what happened most recently. **Read the bottom entry first.**

Before touching money: also read **`docs/LEDGER.md`** (posting matrix) and **`docs/PAYMENTS.md`**
(M-Pesa state machines).

## Your operating loop

Repeat this for every task:

1. **Read `PROGRESS_LOG.md`** (bottom entry) to see where things stand.
2. **Pick the next unblocked task** from `ROADMAP_TO_PRODUCTION.md`, in ID order, respecting
   `Depends on`. Start with **TASK-001**.
3. **Re-read the actual files** the task names — do not rely on these docs for current file
   contents.
4. **Find the existing pattern** to imitate (the task's *Approach* names one).
5. **Implement only that task.** Respect its *Out of scope*.
6. **Verify** with the task's *How to verify*, plus `npm run lint`, `npx tsc --noEmit`,
   `npm test`, `npm run build`.
7. **Append to `PROGRESS_LOG.md`** using the template, pasting real output.
8. **Commit** with the task id in the subject: `TASK-001: Apply claim_notifications migration`.

## Hard rules you must never break

1. **Never claim something works that you did not run.** Paste real output.
2. **Never fabricate** an API, method, column, env var, or file path. `grep` first.
3. **Money is `bigint` cents. Never floats.**
4. **Never post to the ledger without an M-Pesa receipt.** Proof, not intent.
5. **Never UPDATE or DELETE ledger rows.** Post a reversing transaction instead.
6. **Never commit secrets.** Not in code, comments, tests, or fixtures.
7. **Never leave an empty catch or a swallowed error.** Payment errors must tell the user whether
   their money moved.
8. **Never delete or rewrite code you do not understand** — check the Landmines section, then ask.
9. **Never add a dependency** without recording the reason in `PROGRESS_LOG.md`.
10. **Never do more than the task.** Log extra ideas; don't implement them.
11. **When the docs and the code disagree, trust the code**, fix the doc, and flag it.

## First three things to do

- **TASK-001** — apply `supabase/migrations/20260728000100_fix_claim_notifications.sql` via the
  Supabase SQL Editor. It is committed but not applied, and the notification outbox is dead
  until it is.
- **TASK-002** — schedule `payments-cron` and `notifications-worker` to run every minute. Nothing
  is on a timer today, so no refund, timeout, or auto-release ever fires.
- **TASK-105 / M1** — get notifications actually delivering, then build payouts. **Until payouts
  exist, Substribe can take money and cannot pay it out.** That is the most important work in the
  roadmap.

## When you are stuck

Stop and ask the human. Do not guess. This system moves real money belonging to students and
freelancers who cannot afford to lose it — a clear question costs minutes, a wrong assumption costs
someone's rent.
