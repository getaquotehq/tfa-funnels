-- Send every new lead to TFA Solar's Pipedrive as a deal.
--
-- On insert, pg_net calls the `pipedrive-sync` edge function with the lead id.
-- The function creates (or reuses) the Person, a Deal in the "Lead In" stage
-- owned by "Admin", a pinned note with all the answers, and attaches the bill.
-- It writes pipedrive_person_id / pipedrive_deal_id / synced_at back here,
-- or sync_error if Pipedrive refused. The call is asynchronous, so the website
-- always saves the lead; `select public.send_leads_to_pipedrive();` re-sends
-- anything unsynced.
--
-- BEFORE running this:
--   1. store the Pipedrive API token in Vault, once:
--        select vault.create_secret('<api token>', 'pipedrive_api_token');
--   2. deploy supabase/functions/pipedrive-sync with "Verify JWT" OFF.

create extension if not exists pg_net;

alter table public.leads
  add column if not exists pipedrive_deal_id    bigint,
  add column if not exists pipedrive_claimed_at timestamptz;
-- (pipedrive_person_id, synced_at and sync_error already exist.)
-- anon keeps its column-level insert grant only, so the website can't set these.

-- Token for the edge function (service role only).
create or replace function public.pipedrive_api_token()
returns text
language sql
security definer
set search_path = public
as $$
  select decrypted_secret from vault.decrypted_secrets
  where name = 'pipedrive_api_token' limit 1;
$$;

-- Hand a lead to exactly one sync run. Returns nothing if it's already synced
-- or another run claimed it in the last 5 minutes.
create or replace function public.claim_lead_for_pipedrive(lead_id uuid)
returns setof public.leads
language sql
security definer
set search_path = public
as $$
  update public.leads
     set pipedrive_claimed_at = now()
   where id = lead_id
     and synced_at is null
     and (pipedrive_claimed_at is null or pipedrive_claimed_at < now() - interval '5 minutes')
  returning *;
$$;

create or replace function public.send_lead_to_pipedrive(lead_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform net.http_post(
    url     := 'https://oguiejpjkdtnqhxhgwht.supabase.co/functions/v1/pipedrive-sync',
    body    := jsonb_build_object('id', lead_id),
    headers := jsonb_build_object('Content-Type', 'application/json'),
    timeout_milliseconds := 60000
  );
end;
$$;

create or replace function public.leads_send_to_pipedrive()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Never let the sync break the website's insert.
  begin
    perform public.send_lead_to_pipedrive(new.id);
  exception when others then
    raise warning 'send to Pipedrive failed for lead %: %', new.id, sqlerrm;
  end;
  return new;
end;
$$;

drop trigger if exists leads_send_to_pipedrive on public.leads;
create trigger leads_send_to_pipedrive
  after insert on public.leads
  for each row execute function public.leads_send_to_pipedrive();

-- Re-send every lead Pipedrive doesn't have yet (safe to run repeatedly).
create or replace function public.send_leads_to_pipedrive()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  n integer := 0;
begin
  for r in select id from public.leads where synced_at is null order by created_at loop
    perform public.send_lead_to_pipedrive(r.id);
    n := n + 1;
  end loop;
  return n;
end;
$$;

-- These run as the table owner; keep them away from the website's roles.
revoke all on function public.pipedrive_api_token()                from public, anon, authenticated;
revoke all on function public.claim_lead_for_pipedrive(uuid)       from public, anon, authenticated;
revoke all on function public.send_lead_to_pipedrive(uuid)         from public, anon, authenticated;
revoke all on function public.leads_send_to_pipedrive()            from public, anon, authenticated;
revoke all on function public.send_leads_to_pipedrive()            from public, anon, authenticated;
grant execute on function public.pipedrive_api_token()          to service_role;
grant execute on function public.claim_lead_for_pipedrive(uuid) to service_role;
