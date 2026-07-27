-- Substribe · Migration 1100 — fix: profile guard blocked system trust updates
--
-- Bug (caught by scripts/e2e-money-test.sql before launch):
--   protect_profile_columns() rejected ANY non-admin authenticated write to the
--   system-managed trust columns — including writes made by our own triggers on
--   behalf of that user. Three core flows were broken:
--     · confirm_seat_access  → on_seat_activated       → seats_filled_count
--     · opening a dispute    → on_dispute_opened       → disputes_against_count
--     · leaving a rating     → refresh_rating_aggregates → owner/buyer_rating
--   Every buyer confirmation would have failed in production.
--
-- Fix: distinguish a direct client UPDATE from a system trigger cascade.
--   pg_trigger_depth() = 1 → the client is updating profiles itself (guard it)
--   pg_trigger_depth() > 1 → we are inside another trigger's cascade (trust it)
-- The trust columns remain unwritable by clients directly; only our own
-- trigger logic can move them.

create or replace function public.protect_profile_columns()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Server-side callers (service role / direct SQL / admin) pass through.
  if auth.uid() is null
     or coalesce(auth.role(), '') = 'service_role'
     or public.is_admin() then
    return new;
  end if;

  -- Inside a trigger cascade (e.g. seat activation, rating insert, dispute
  -- opened): this is our own logic maintaining aggregates, not a user edit.
  if pg_trigger_depth() > 1 then
    return new;
  end if;

  if new.kyc_tier                is distinct from old.kyc_tier
     or new.is_admin             is distinct from old.is_admin
     or new.mpesa_name           is distinct from old.mpesa_name
     or new.mpesa_name_verified  is distinct from old.mpesa_name_verified
     or new.owner_rating         is distinct from old.owner_rating
     or new.buyer_rating         is distinct from old.buyer_rating
     or new.seats_filled_count   is distinct from old.seats_filled_count
     or new.disputes_against_count is distinct from old.disputes_against_count
     or new.suspended_at         is distinct from old.suspended_at
     or new.suspension_reason    is distinct from old.suspension_reason then
    raise exception 'column is system-managed and cannot be modified by the user';
  end if;

  return new;
end;
$$;
