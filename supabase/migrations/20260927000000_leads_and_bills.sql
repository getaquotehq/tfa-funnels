-- TFA Solar: Energy Health Check funnel
-- Leads table + private bill storage. The browser (anon / publishable key)
-- can only INSERT. Nobody can read leads or bills without the service role.

-- ---------- LEADS TABLE ----------
create table if not exists public.leads (
  id              uuid primary key default gen_random_uuid(),
  created_at      timestamptz not null default now(),
  interest        text not null check (interest in ('Solar','Battery','Solar + Battery','Not sure')),
  existing_solar  text not null check (existing_solar in ('No, nothing yet','Yes, panels only','Yes, panels + battery')),
  bill_range      text not null check (bill_range in ('Under $300','$300 to $600','$600 to $1,000','Over $1,000')),
  ownership       text not null check (ownership in ('Own outright','Mortgaged')),
  timeframe       text not null check (timeframe in ('ASAP','1 to 3 months','3 to 6 months','Researching')),
  name            text not null check (char_length(name) between 1 and 120),
  email           text not null check (char_length(email) <= 200 and email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  phone           text not null check (char_length(phone) between 8 and 30),
  postcode        text not null check (postcode ~ '^\d{4}$'),
  bill_path       text check (char_length(bill_path) <= 300),
  bill_filename   text check (char_length(bill_filename) <= 200),
  source          text check (char_length(source) <= 100),
  tracking        jsonb not null default '{}'::jsonb check (pg_column_size(tracking) < 4000),
  -- filled in by the lead-to-pipedrive edge function
  pipedrive_person_id bigint,
  pipedrive_lead_id   text,
  synced_at           timestamptz,
  sync_error          text
);

create index if not exists leads_created_at_idx on public.leads (created_at desc);

alter table public.leads enable row level security;

-- Browser may insert new leads only. No select/update/delete policies exist,
-- so anon cannot read anything back. The column grant below also stops it
-- writing the pipedrive_* / sync columns.
drop policy if exists "anon can insert leads" on public.leads;
create policy "anon can insert leads"
  on public.leads for insert
  to anon
  with check (true);

revoke all on public.leads from anon, authenticated;
grant insert (interest, existing_solar, bill_range, ownership, timeframe,
              name, email, phone, postcode, bill_path, bill_filename, source, tracking)
  on public.leads to anon;

-- ---------- PRIVATE BILL STORAGE ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('bills', 'bills', false, 10485760, array['application/pdf','image/jpeg','image/png'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Browser may upload into the bills bucket only. No read, list, overwrite or delete.
drop policy if exists "anon can upload bills" on storage.objects;
create policy "anon can upload bills"
  on storage.objects for insert
  to anon
  with check (bucket_id = 'bills');
