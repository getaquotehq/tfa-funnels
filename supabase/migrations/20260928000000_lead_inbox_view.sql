-- Lead inbox: newest leads first, Adelaide time, and a clear Yes/No for the bill.
-- Open it in Table Editor (it appears under Views as lead_inbox).
-- security_invoker means it follows the leads table's rules, so the website still can't read it.

create or replace view public.lead_inbox
with (security_invoker = true) as
select
  to_char(created_at at time zone 'Australia/Adelaide', 'DD Mon YYYY HH12:MI am') as received,
  name,
  phone,
  email,
  postcode,
  case when bill_path is not null then 'Yes' else 'No' end as bill_uploaded,
  bill_path  as bill_in_storage,   -- Storage > bills > this path
  interest,
  existing_solar,
  bill_range,
  ownership,
  timeframe,
  tracking->>'utm_campaign' as campaign,
  id
from public.leads
order by created_at desc;

revoke all on public.lead_inbox from anon, authenticated;
