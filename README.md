# tfa-funnels

TFA Solar Energy Health Check landing page (`index.html`). Single self-contained file: the logo is embedded, so it can be hosted anywhere.

## Backend (Supabase project `oguiejpjkdtnqhxhgwht`)

Run `supabase/migrations/20260927000000_leads_and_bills.sql` once in the SQL Editor.
It creates the `leads` table, the private `bills` storage bucket, and insert-only access for the website.
Then run `supabase/migrations/20260928000000_lead_inbox_view.sql` for the `lead_inbox` view (leads with a Yes/No bill column).
No edge functions are needed. The page already has the project URL and anon key.

### Sending leads to ql-hq

`supabase/migrations/20260929000000_forward_leads_to_qlhq.sql` sends every new lead, bill included, to TFA Solar's account in ql-hq.
First store the shared secret in Vault (`select vault.create_secret('<secret>', 'qlhq_intake_secret');`), then run the migration.
`qlhq_synced_at` is filled in once ql-hq has the lead (and bill). To send anything missed, including leads from before this existed: `select public.forward_leads_to_qlhq();`

### Sending leads to Pipedrive

Every new lead becomes a deal in TFA's Pipedrive (tfasolar.pipedrive.com): Lead In stage, owned by the Admin user, with the Person (reused if the email already exists), a pinned note holding every answer, and the bill attached.

1. Store the API token in Vault: `select vault.create_secret('<api token>', 'pipedrive_api_token');`
2. Deploy `supabase/functions/pipedrive-sync` with **Verify JWT off** (`supabase functions deploy pipedrive-sync --no-verify-jwt`, or Dashboard > Edge Functions > Deploy a new function > Via editor, paste `index.ts`, untick Verify JWT).
3. Run `supabase/migrations/20261001000000_pipedrive_sync.sql`.

`pipedrive_deal_id` and `synced_at` are filled in once the deal exists; `sync_error` says why if Pipedrive refused. To send anything missed (this includes every lead from before the sync existed, test leads too): `select public.send_leads_to_pipedrive();`
Uploaded bills are private: view them in Storage > bills, or on the Pipedrive deal.
