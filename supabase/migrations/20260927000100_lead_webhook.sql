-- Fires the lead-to-pipedrive edge function for every new lead.
-- Run AFTER deploying the function and AFTER replacing the two placeholders:
--   YOUR-PROJECT-REF      your Supabase project ref
--   YOUR-WEBHOOK-SECRET   same value you set as the WEBHOOK_SECRET function secret
-- (Equivalent to Dashboard > Database > Webhooks > Create, if you prefer the UI.)

create extension if not exists pg_net with schema extensions;

create or replace function public.notify_new_lead()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform net.http_post(
    url     := 'https://YOUR-PROJECT-REF.supabase.co/functions/v1/lead-to-pipedrive',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-webhook-secret', 'YOUR-WEBHOOK-SECRET'
    ),
    body    := jsonb_build_object('type', 'INSERT', 'table', 'leads', 'record', to_jsonb(new)),
    timeout_milliseconds := 5000
  );
  return new;
end;
$$;

revoke all on function public.notify_new_lead() from public, anon, authenticated;

drop trigger if exists on_lead_created on public.leads;
create trigger on_lead_created
  after insert on public.leads
  for each row execute function public.notify_new_lead();
