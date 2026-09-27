// lead-to-pipedrive
// Called by the on_lead_created database trigger for every new lead.
// Creates a Pipedrive Person + Lead, attaches a note with all the answers
// and a 30 day link to the uploaded bill, then writes the IDs back to the row.
//
// Secrets (supabase secrets set ...):
//   PIPEDRIVE_API_TOKEN   Pipedrive > Personal preferences > API
//   WEBHOOK_SECRET        any long random string, also used in the trigger SQL
//   PIPEDRIVE_OWNER_ID    optional, Pipedrive user id to assign leads to
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided automatically.

import { createClient } from "npm:@supabase/supabase-js@2";

const PD = "https://api.pipedrive.com/v1";
const PD_TOKEN = Deno.env.get("PIPEDRIVE_API_TOKEN")!;
const WEBHOOK_SECRET = Deno.env.get("WEBHOOK_SECRET")!;
const OWNER_ID = Deno.env.get("PIPEDRIVE_OWNER_ID");
const BILL_LINK_DAYS = 30;

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

async function pd(path: string, body: Record<string, unknown>) {
  const res = await fetch(`${PD}${path}?api_token=${PD_TOKEN}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const json = await res.json();
  if (!res.ok || !json.success) {
    throw new Error(`Pipedrive ${path} failed (${res.status}): ${JSON.stringify(json)}`);
  }
  return json.data;
}

function esc(s: unknown) {
  return String(s ?? "").replace(/[&<>"]/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!)
  );
}

Deno.serve(async (req) => {
  if (req.headers.get("x-webhook-secret") !== WEBHOOK_SECRET) {
    return new Response("unauthorised", { status: 401 });
  }

  const { record: lead } = await req.json();
  if (!lead?.id) return new Response("no record", { status: 400 });

  try {
    const owner = OWNER_ID ? { owner_id: Number(OWNER_ID) } : {};

    const person = await pd("/persons", {
      name: lead.name,
      email: [{ value: lead.email, primary: true, label: "home" }],
      phone: [{ value: lead.phone, primary: true, label: "mobile" }],
      ...owner,
    });

    const pdLead = await pd("/leads", {
      title: `Energy Health Check: ${lead.name} (${lead.postcode})`,
      person_id: person.id,
      ...owner,
    });

    let billLine = "No bill uploaded";
    if (lead.bill_path) {
      const { data } = await db.storage
        .from("bills")
        .createSignedUrl(lead.bill_path, BILL_LINK_DAYS * 24 * 60 * 60);
      billLine = data?.signedUrl
        ? `<a href="${esc(data.signedUrl)}">View bill (${esc(lead.bill_filename)})</a>, link valid ${BILL_LINK_DAYS} days`
        : `Bill stored at bills/${esc(lead.bill_path)}`;
    }

    const t = lead.tracking ?? {};
    await pd("/notes", {
      lead_id: pdLead.id,
      content: [
        `<b>Energy Health Check request</b>`,
        `Interested in: ${esc(lead.interest)}`,
        `Existing solar: ${esc(lead.existing_solar)}`,
        `Quarterly bill: ${esc(lead.bill_range)}`,
        `Home: ${esc(lead.ownership)}`,
        `Timeframe: ${esc(lead.timeframe)}`,
        `Postcode: ${esc(lead.postcode)}`,
        billLine,
        `Source: ${esc(lead.source)}`,
        t.utm_campaign ? `Campaign: ${esc(t.utm_campaign)} / ${esc(t.utm_content)}` : "",
      ].filter(Boolean).join("<br>"),
    });

    await db.from("leads").update({
      pipedrive_person_id: person.id,
      pipedrive_lead_id: pdLead.id,
      synced_at: new Date().toISOString(),
      sync_error: null,
    }).eq("id", lead.id);

    return Response.json({ ok: true, lead_id: pdLead.id });
  } catch (err) {
    console.error(err);
    await db.from("leads").update({ sync_error: String(err).slice(0, 1000) }).eq("id", lead.id);
    return new Response(String(err), { status: 500 });
  }
});
