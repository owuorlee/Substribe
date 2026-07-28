-- Substribe · Migration 1200 — fix: claim_notifications failed at runtime
--
-- Bug (caught by smoke-testing the deployed notifications-worker):
--   the claim query did
--     update public.notifications n ... from due d join public.profiles p
--       on p.id = n.user_id
--   which Postgres rejects — the UPDATE target (n) cannot be referenced inside
--   a JOIN condition in the FROM clause. plpgsql only parses the query at
--   execution time, so CREATE succeeded and every call failed with
--   "invalid reference to FROM-clause entry for table n". The outbox would
--   never have drained: no payment receipts, no invite nudges, no refund
--   alerts.
--
-- Fix: claim rows in a data-modifying CTE (which may reference the target in
-- its own WHERE), then join profiles in the outer select.

create or replace function public.claim_notifications(p_limit integer default 20)
returns table (
  id       uuid,
  channel  public.notification_channel,
  template text,
  payload  jsonb,
  phone    text,
  language text,
  attempts smallint
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  return query
  with due as (
    select n.id
    from public.notifications n
    where n.status = 'queued'
      and (n.claimed_at is null or n.claimed_at < now() - interval '5 minutes')
    order by n.created_at
    limit p_limit
    for update skip locked
  ),
  claimed as (
    update public.notifications n
       set claimed_at = now(), attempts = n.attempts + 1
      from due d
     where n.id = d.id
    returning n.id, n.channel, n.template, n.payload, n.user_id, n.attempts
  )
  select c.id, c.channel, c.template, c.payload,
         p.phone, p.preferred_language, c.attempts
  from claimed c
  join public.profiles p on p.id = c.user_id;
end;
$$;
