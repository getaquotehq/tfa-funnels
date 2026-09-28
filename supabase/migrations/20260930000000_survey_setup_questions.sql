-- Survey: suburb, solar age, feed-in tariff and battery questions.
--
-- All new columns are optional, so existing leads are untouched, and the
-- live page keeps working before and after this runs. existing_solar is kept
-- and still filled in (from the solar + battery answers) so the Make.com /
-- Pipedrive scenario and ql-hq keep reading it as before.

alter table public.leads
  add column if not exists suburb         text check (char_length(suburb) between 1 and 80),
  add column if not exists solar_age      text check (solar_age in ('Under 5 years','5 to 10 years','10 to 15 years','Over 15 years','Not sure')),
  add column if not exists feed_in_tariff text check (char_length(feed_in_tariff) <= 80),
  add column if not exists has_battery    text check (has_battery in ('Yes','No'));

-- The website (anon) may write the new answers too; still insert-only.
grant insert (suburb, solar_age, feed_in_tariff, has_battery) on public.leads to anon;

-- Lead inbox: same columns as before, new answers added on the end.
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
  id,
  suburb,
  solar_age,
  feed_in_tariff,
  has_battery
from public.leads
order by created_at desc;

revoke all on public.lead_inbox from anon, authenticated;
