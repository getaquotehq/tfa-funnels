# tfa-funnels

TFA Solar Energy Health Check landing page (`index.html`). Single self-contained file: the logo is embedded, so it can be hosted anywhere.

## Backend setup (Supabase)

1. **SQL Editor**: run `supabase/migrations/20260927000000_leads_and_bills.sql`
   (creates `leads` table, private `bills` bucket, insert-only RLS).
2. **Page config**: in `index.html` set `SUPABASE_URL` and `SUPABASE_KEY`
   (Project Settings > API: project URL + publishable/anon key. Never the service_role key).
3. **Pipedrive sync (edge function)**:
   ```sh
   supabase secrets set PIPEDRIVE_API_TOKEN=... WEBHOOK_SECRET=$(openssl rand -hex 32) [PIPEDRIVE_OWNER_ID=...]
   supabase functions deploy lead-to-pipedrive --no-verify-jwt
   ```
4. **Trigger**: edit the two placeholders in `supabase/migrations/20260927000100_lead_webhook.sql`
   and run it (or create the same thing under Database > Webhooks).

Uploaded bills are private. View them in Storage > bills, or via the 30 day link in the Pipedrive lead note.
Sync failures are recorded in `leads.sync_error`.
