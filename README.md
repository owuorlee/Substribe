# Substribe

**The trusted way to split subscriptions in Kenya.** Spotify, YouTube,
Microsoft 365, AI team plans — paid via M-Pesa, protected by escrow.

Buyer money is held in escrow until their seat is confirmed working. Owners
get paid reliably. Nobody shares a password, ever.

## Documents

| Doc | What it is |
|---|---|
| [SCOPE.md](SCOPE.md) | Full product scope — positioning, flows, trust system, roadmap. **Source of truth.** |
| [docs/DATABASE.md](docs/DATABASE.md) | Schema guide: entities, RLS model, conventions |
| [docs/LEDGER.md](docs/LEDGER.md) | Double-entry ledger: accounts, posting matrix, invariants |

## Stack

Next.js (PWA, mobile-first) · Supabase (Postgres, Auth, RLS, Edge Functions) ·
M-Pesa Daraja (STK Push, B2C, Ratiba) · WhatsApp Business Cloud API +
Africa's Talking SMS.

## Repo layout

```
supabase/
  migrations/   # schema, ledger, RLS — numbered, never edit applied ones
  seed.sql      # service catalogue (Spotify Family live, rest staged)
docs/           # database + ledger documentation
```

## Local development

Prereqs: Docker + [Supabase CLI](https://supabase.com/docs/guides/cli).

```bash
supabase start      # spin up local Postgres/Auth/API
supabase db reset   # apply all migrations + seed
```

## Status

Phase 1 (see SCOPE.md §12): database + ledger foundation ✅ · payments spec →
next · web app → after that. Launch vertical: **Spotify Premium Family**.
