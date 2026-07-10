-- Substribe · Migration 1000 — notification outbox draining
--
-- The app writes notifications rows (status 'queued'); a worker claims and
-- sends them. Claiming uses SELECT ... FOR UPDATE SKIP LOCKED so multiple
-- worker invocations never send the same message twice, and a crashed worker's
-- claim is reclaimed after 5 minutes. All functions are service-role only.

alter table public.notifications
  add column claimed_at timestamptz,
  add column attempts   smallint not null default 0;

-- queued rows not currently claimed (or with a stale claim) drain fastest.
create index notifications_claimable_idx
  on public.notifications (created_at)
  where status = 'queued';

-- Claim up to p_limit due notifications, returning the recipient's phone and
-- language so the worker can render + send without extra round-trips.
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
  )
  update public.notifications n
     set claimed_at = now(), attempts = n.attempts + 1
  from due d
  join public.profiles p on p.id = n.user_id
  where n.id = d.id
  returning n.id, n.channel, n.template, n.payload, p.phone,
            p.preferred_language, n.attempts;
end;
$$;

create or replace function public.notification_mark_sent(
  p_id          uuid,
  p_external_id text,
  p_channel     public.notification_channel
) returns void
language sql
security definer
set search_path = ''
as $$
  update public.notifications
     set status = 'sent', sent_at = now(), external_id = p_external_id,
         channel = p_channel, error = null, claimed_at = null
   where id = p_id;
$$;

-- Give up after 5 attempts; before that, leave it 'queued' so the stale-claim
-- reclaim (5 min) retries it with natural backoff.
create or replace function public.notification_mark_failed(
  p_id    uuid,
  p_error text
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.notifications n
     set status = case when n.attempts >= 5 then 'failed'::public.notification_status
                       else 'queued'::public.notification_status end,
         error  = left(p_error, 500)
   where n.id = p_id;
end;
$$;

revoke execute on function public.claim_notifications(integer)                              from public, anon, authenticated;
revoke execute on function public.notification_mark_sent(uuid, text, public.notification_channel) from public, anon, authenticated;
revoke execute on function public.notification_mark_failed(uuid, text)                      from public, anon, authenticated;
