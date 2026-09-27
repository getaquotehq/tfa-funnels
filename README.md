# tfa-funnels

TFA Solar Energy Health Check landing page (`index.html`). Single self-contained file: the logo is embedded, so it can be hosted anywhere.

## Backend (Supabase project `oguiejpjkdtnqhxhgwht`)

Run `supabase/migrations/20260927000000_leads_and_bills.sql` once in the SQL Editor.
It creates the `leads` table, the private `bills` storage bucket, and insert-only access for the website.
No edge functions are needed. The page already has the project URL and anon key.

Pipedrive sync is handled separately in Make.com (watching new rows in `leads`).
Uploaded bills are private: view them in Storage > bills, or have Make create a signed URL from `leads.bill_path`.
