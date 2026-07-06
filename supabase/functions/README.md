# Substribe Edge Functions

Thin HTTP adapters around Daraja. All money state transitions happen in
Postgres functions (migration `20260704000100_payment_processing.sql`) so each
change commits atomically with its ledger post. Spec: [docs/PAYMENTS.md](../../docs/PAYMENTS.md).

| Function | Auth | Purpose |
|---|---|---|
| `mpesa-stk-initiate` | user JWT | Reserve seat → create payment → send STK push |
| `mpesa-stk-callback` | per-payment URL token | Ingest Daraja STK result, ack 200, process |
| `payments-cron` | `x-cron-secret` header | Heartbeat: retries, STK queries, sweeps |

## Secrets

```bash
supabase secrets set \
  DARAJA_ENV=sandbox \
  DARAJA_CONSUMER_KEY=... \
  DARAJA_CONSUMER_SECRET=... \
  DARAJA_SHORTCODE=174379 \
  DARAJA_PASSKEY=... \
  CRON_SECRET=$(openssl rand -hex 32)
# optional: CALLBACK_BASE_URL to override the default
# {SUPABASE_URL}/functions/v1 (e.g. an ngrok tunnel during sandbox testing)
```

`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` are injected
automatically. Shortcode `174379` is the shared Daraja sandbox paybill.

## Deploy

```bash
supabase functions deploy mpesa-stk-initiate
supabase functions deploy mpesa-stk-callback --no-verify-jwt   # Daraja sends no JWT
supabase functions deploy payments-cron      --no-verify-jwt   # authed by CRON_SECRET
```

## Schedule the heartbeat (every minute)

Supabase Dashboard → Integrations → Cron, or via pg_cron + pg_net:

```sql
select cron.schedule('payments-heartbeat', '* * * * *', $$
  select net.http_post(
    url     := 'https://<project-ref>.supabase.co/functions/v1/payments-cron',
    headers := jsonb_build_object('x-cron-secret', '<CRON_SECRET>')
  );
$$);
```

## Local testing

```bash
supabase start
supabase functions serve --env-file supabase/functions/.env.local
```

Daraja sandbox cannot reach localhost — tunnel with ngrok and set
`CALLBACK_BASE_URL=https://<tunnel>.ngrok.app` to receive callbacks locally.
Full sandbox test matrix (success, 1032 cancel, 1 insufficient, 2001 wrong
PIN, 1037 timeout, duplicate replay): PAYMENTS.md §10 go-live checklist.
