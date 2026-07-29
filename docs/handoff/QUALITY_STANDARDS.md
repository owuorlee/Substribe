# Substribe — Quality Standards

**These are instructions to you, the agent working on this codebase.** They are derived from how
this code is *actually* written, not from generic best practice. Follow them.

---

## 1. Read before you write

Before adding anything, find the closest existing example and imitate it.

| If you're adding… | Read first |
|---|---|
| An Edge Function | `supabase/functions/payments-cron/index.ts` (cron shape) or `mpesa-stk-initiate/index.ts` (user-facing shape) |
| A money-moving DB function | `supabase/migrations/20260704000100_payment_processing.sql` |
| A ledger posting | `docs/LEDGER.md` posting matrix, then `release_escrow` |
| A page | `web/src/app/browse/page.tsx` (server) |
| A form | `web/src/app/list/ListingForm.tsx` (client) |
| A button that calls an RPC | `web/src/app/dashboard/actions.tsx` |
| A notification | `supabase/functions/_shared/templates.ts` |

If you cannot find a precedent, that is a signal to ask — not to invent.

---

## 2. Consistency beats preference

- **Do not restyle, reformat, or "modernise" working code.** No prettier runs across untouched
  files, no import reordering, no converting patterns you merely dislike.
- Match the surrounding style: 2-space indent, double quotes in TS, lowercase SQL keywords,
  `snake_case` in SQL, `camelCase` in TS, `PascalCase` for components.
- Comments in this codebase explain **why**, not what. Match that. Several comments deliberately
  document non-obvious decisions — do not delete them.
- SQL migrations open with a comment block: what this migration does and why. Keep that.

---

## 3. No silent scope creep

Implement the task, nothing more. If you spot something else worth doing, **write it in
`PROGRESS_LOG.md` under "Discovered"** and propose it. Do not fix it in the same commit.

Each task lists **Out of scope** — honour it. Touching extra files makes review impossible and
makes rollback dangerous in a money system.

---

## 4. Never fabricate

Never invent an API method, library function, env var, column, table, or file path. This codebase
has precise names (`reserve_seat_and_start_join`, `owner_take_cents`, `mpesa_checkout_request_id`).
If you are unsure whether something exists:

```bash
grep -rn "the_name" supabase/ web/src/
```

Check before you write. **A fabricated column name in a money function is a production outage.**

Similarly: do not claim a command succeeded unless you ran it and saw the output.

---

## 5. Money rules (non-negotiable)

1. **All money is `bigint` cents.** Never floats. `fmtKes()` is for display only.
2. **Chargeable amounts must be whole shillings** (`cents % 100 == 0`) — M-Pesa cannot move less.
3. **Post to the ledger only on proof.** A ledger transaction requires a real M-Pesa receipt.
   Never post on intent, request acceptance, or an optimistic assumption.
4. **Every ledger post is idempotent** with a deterministic key: `{kind}:{primary_id}[:{qualifier}]`.
   Never include a timestamp or random value.
5. **Never UPDATE or DELETE ledger rows.** Correct with a reversing transaction.
6. **State change + ledger post must share one transaction.** That is why money logic lives in
   Postgres functions. Do not move it into TypeScript.
7. **Read `docs/LEDGER.md` before touching anything financial.** Every posting has a defined
   debit/credit pair; use it rather than reasoning from scratch.
8. **The invariant must hold:** `mpesa_operating = buyer_escrow + wallet + owner_payable +
   insurance_reserve + platform_revenue`.

---

## 6. Security rules

- **Validate every external input at the boundary.** Never trust the client — not the seat id, not
  the amount, not the phone number.
- **Never trust a webhook payload.** Match it to a pending record, verify the amount, and check the
  per-payment token. Daraja does not sign callbacks.
- **Never commit secrets.** No keys, passwords, tokens, or credentials in source — ever, including
  in comments, tests, or fixtures. `.env*` is gitignored; keep it that way.
- **Never hardcode URLs or credentials.** Use env vars.
- **Anything money-critical is service-role only.** Revoke `execute` from `public, anon,
  authenticated` on new money functions, exactly like the existing ones.
- **Client-callable RPCs must self-authorise** via `auth.uid()` internally — see
  `confirm_seat_access`.
- **Never log PII or secrets** (phone numbers, tokens, full callback payloads).

---

## 7. Error handling

- **No empty catch blocks. No swallowed exceptions.** Ever.
- Every user-facing failure needs a **real message and a real state**. Look at
  `KNOWN_ERRORS` in `mpesa-stk-initiate/index.ts` and `friendlyFailure()` in `PayForm.tsx`.
- **Payment errors must tell the user whether their money moved.** This is a trust product in a
  market full of scams. "Your money has NOT moved" is a required phrase when true. Never leave
  someone guessing.
- Copy is plain Kenyan English, warm, never blaming the user. No stack traces, no error codes as
  the primary message.
- In Postgres functions, `raise exception` with a short machine-readable tag
  (`seat_unavailable`, `invalid_price`) and map it to human copy at the edge.

---

## 8. Tests

- Framework: **Vitest** (added in TASK-601). Run with `cd web && npm test`.
- **Every P0 task ships with a test that fails before your change and passes after.** If you cannot
  write such a test, say so explicitly in the progress log and explain why.
- SQL money changes: extend `scripts/e2e-money-test.sql` or add a sibling script. Wrap in
  `begin; … rollback;` so it leaves nothing behind, and assert with `raise exception` on mismatch —
  follow the existing style.
- Test the edges: invalid phone formats, duplicate callbacks, zero/negative amounts, concurrent
  seat claims, expired reservations.
- Do not mock what you can test for real against the sandbox.

---

## 9. Before you declare a task done

Run all four and **paste the real output** into `PROGRESS_LOG.md`:

```bash
cd web && npm run lint        # expect exit 0
cd web && npx tsc --noEmit    # expect exit 0
cd web && npm test            # expect exit 0 (after TASK-601)
cd web && npm run build       # expect exit 0
```

**Never claim a green build you did not observe.** If something fails and you cannot fix it within
scope, say so plainly and leave the task open. A half-finished task honestly reported is far more
useful than a false "done".

For DB work, also paste the SQL Editor result and record the migration as applied.

---

## 10. Commits

- One focused commit per task. Subject line references the task:
  `TASK-103: Build payouts-cron Edge Function`
- Body: what changed and why, wrapped at ~72 chars. Match the existing log style
  (`git log --oneline`) — imperative subject, explanatory body.
- Do not bundle unrelated fixes. Do not commit generated files that are gitignored.
- Never commit `.env.local`, `_bootstrap.generated.sql`, or `node_modules`.

---

## 11. Dependencies

- **Do not add, upgrade, or remove a dependency without recording the reason in `PROGRESS_LOG.md`.**
- Prefer the standard library or what is already installed. This project deliberately has a tiny
  dependency tree (5 runtime packages) — validation, formatting, and state are all hand-rolled
  because the audience is on slow mobile connections and every KB matters.
- Never run `npm audit fix --force` — it can jump major versions silently.
- Never upgrade Next.js or React majors as part of an unrelated task.

---

## 12. Do not delete what you do not understand

Several things look wrong and are deliberate:

- `protect_profile_columns` allows writes at `pg_trigger_depth() > 1` — **required**, or buyer
  confirmation breaks.
- `mpesa-stk-callback` always returns 200, even on a bad token — **required**, or Daraja retries
  and attackers can probe.
- `process_payment_event` refuses to post a "successful" payment with no receipt — **required**.
- The direct-insert RLS policy on `listings` was dropped on purpose — `create_listing` is the only door.
- Only one service is `is_active` — deliberate, not an oversight.

If you do not understand a piece of code, **leave it and ask**. Do not rewrite it to make it
comprehensible to you.

---

## 13. Accessibility and responsiveness are acceptance criteria

Not polish. The users are on Android phones, often on 3G, sometimes in sunlight.

- Test at **375px** first; then 768 and 1440.
- Tap targets ≥ 44px. Labels bound to inputs. Visible focus rings. WCAG AA contrast.
- Skeletons over spinners. Never a blank screen while loading.
- Use the design tokens (`bg-brand`, `text-brand-strong`, `bg-brand-soft`, `text-accent`) from
  `globals.css` — not raw hex, not arbitrary Tailwind colours.

---

## 14. When reality contradicts these docs

These documents were accurate at commit `07c33d9`. If you find something different:

1. **Trust the code over the docs.**
2. **Update the doc in the same commit** that reveals the discrepancy.
3. **Flag it in `PROGRESS_LOG.md`** so the human knows.

Do not guess and proceed silently. If you are blocked or a task's assumptions are wrong, stop and
say so — a clear question costs minutes; a wrong assumption in a payment system costs real money
belonging to real people who cannot afford to lose it.
