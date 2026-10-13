-- What Pipedrive holds in the Person's "Leads source" field after each sync,
-- read back from Pipedrive by the pipedrive-sync function. Lets you confirm
-- the field was filled without opening Pipedrive:
--   select name, synced_at, pipedrive_lead_source, sync_error
--   from public.leads order by created_at desc limit 10;
alter table public.leads
  add column if not exists pipedrive_lead_source text;
-- anon keeps its column-level insert grant only, so the website can't set it.
