-- Forward every new lead to ql-hq (TFA Solar's account), bill included.
--
-- On insert, pg_net POSTs the row to ql-hq's `tfa-intake` function. That
-- function creates the lead in ql-hq, copies the bill out of the private
-- `bills` bucket, and writes qlhq_lead_id / qlhq_synced_at back here.
-- The call is asynchronous: if ql-hq is down the website still saves the lead,
-- and `select public.forward_leads_to_qlhq();` re-sends anything unsynced.
--
-- BEFORE running this, store the shared secret (the same value as
-- TFA_INTAKE_SECRET in ql-hq's edge function secrets) in Vault, once:
--   select vault.create_secret('<the secret>', 'qlhq_intake_secret');

create extension if not exists pg_net;

alter table public.leads
  add column if not exists qlhq_lead_id   uuid,
  add column if not exists qlhq_synced_at timestamptz;
-- anon keeps its column-level insert grant only, so the website can't set these.

create or replace function public.send_lead_to_qlhq(lead public.leads)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  secret text;
begin
  select decrypted_secret into secret
  from vault.decrypted_secrets
  where name = 'qlhq_intake_secret'
  limit 1;

  if secret is null then
    raise warning 'qlhq_intake_secret is not in Vault; lead % not sent to ql-hq', lead.id;
    return;
  end if;

  perform net.http_post(
    url     := 'https://wjadekgptkstfdootuol.supabase.co/functions/v1/tfa-intake',
    body    := to_jsonb(lead),
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-intake-secret', secret
    ),
    timeout_milliseconds := 30000
  );
end;
$$;

create or replace function public.leads_forward_to_qlhq()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Never let the forward break the website's insert.
  begin
    perform public.send_lead_to_qlhq(new);
  exception when others then
    raise warning 'forward to ql-hq failed for lead %: %', new.id, sqlerrm;
  end;
  return new;
end;
$$;

drop trigger if exists leads_forward_to_qlhq on public.leads;
create trigger leads_forward_to_qlhq
  after insert on public.leads
  for each row execute function public.leads_forward_to_qlhq();

-- Re-send every lead ql-hq hasn't confirmed (safe to run repeatedly: ql-hq
-- skips leads it already has and only retries a missing bill).
create or replace function public.forward_leads_to_qlhq()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.leads;
  n integer := 0;
begin
  for r in select * from public.leads where qlhq_synced_at is null order by created_at loop
    perform public.send_lead_to_qlhq(r);
    n := n + 1;
  end loop;
  return n;
end;
$$;

-- These run as the table owner; keep them away from the website's roles.
revoke all on function public.send_lead_to_qlhq(public.leads) from public, anon, authenticated;
revoke all on function public.leads_forward_to_qlhq()         from public, anon, authenticated;
revoke all on function public.forward_leads_to_qlhq()          from public, anon, authenticated;
