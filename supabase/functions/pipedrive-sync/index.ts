import { createClient } from "npm:@supabase/supabase-js@2";

// TFA Solar funnel -> Pipedrive.
//
// Fired by the AFTER INSERT trigger on `leads` (see the
// 20261001000000_pipedrive_sync.sql migration) with { id }. For that lead we:
//   1. find or create the Person (matched on email),
//   2. create a Deal in the "Lead In" stage, owned by the "Admin" user,
//   3. pin a note with every answer from the survey to the deal,
//   4. attach the uploaded bill (if any) to the deal,
// then write pipedrive_person_id / pipedrive_deal_id / synced_at back.
//
// The Pipedrive API token lives in Vault as `pipedrive_api_token` and is read
// through public.pipedrive_api_token() (service role only). The function only
// ever sends a lead from this project to that one Pipedrive account, so it
// needs no caller secret; re-sends of a synced lead are no-ops.

const PIPEDRIVE_API = "https://tfasolar.pipedrive.com/api/v1";
const PIPELINE_NAME = /lead\s*in/i; // falls back to pipeline 1
const FALLBACK_PIPELINE_ID = 1;
const STAGE_NAME = /^\s*lead\s*in\s*$/i; // falls back to the pipeline's first stage
const OWNER_NAME = /^\s*admin\s*$/i;
const BILL_BUCKET = "bills";

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function esc(v: unknown): string {
  return String(v ?? "").replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!)
  );
}

async function pd(token: string, method: string, path: string, body?: unknown) {
  const url = `${PIPEDRIVE_API}${path}${path.includes("?") ? "&" : "?"}api_token=${token}`;
  const init: RequestInit = { method };
  if (body instanceof FormData) init.body = body;
  else if (body !== undefined) {
    init.body = JSON.stringify(body);
    init.headers = { "Content-Type": "application/json" };
  }
  const res = await fetch(url, init);
  const out = await res.json().catch(() => ({}));
  if (!res.ok || out.success === false) {
    throw new Error(`Pipedrive ${method} ${path.split("?")[0]} -> ${res.status}: ${out.error || JSON.stringify(out).slice(0, 300)}`);
  }
  return out.data;
}

async function resolveTargets(token: string) {
  const pipelines = (await pd(token, "GET", "/pipelines")) || [];
  const pipeline = pipelines.find((p: any) => PIPELINE_NAME.test(p.name)) ||
    pipelines.find((p: any) => p.id === FALLBACK_PIPELINE_ID);
  if (!pipeline) throw new Error("No Lead In pipeline found in Pipedrive");

  const stages = ((await pd(token, "GET", `/stages?pipeline_id=${pipeline.id}`)) || [])
    .sort((a: any, b: any) => a.order_nr - b.order_nr);
  const stage = stages.find((s: any) => STAGE_NAME.test(s.name)) || stages[0];
  if (!stage) throw new Error(`Pipeline "${pipeline.name}" has no stages`);

  const users = (await pd(token, "GET", "/users")) || [];
  const owner = users.find((u: any) => u.active_flag && OWNER_NAME.test(u.name));
  if (!owner) console.warn('No active Pipedrive user named "Admin"; deal owner defaults to the API token owner');

  return { pipelineId: pipeline.id, stageId: stage.id, ownerId: owner?.id as number | undefined };
}

function noteHtml(row: Record<string, any>): string {
  const received = new Date(row.created_at).toLocaleString("en-AU", {
    timeZone: "Australia/Adelaide",
    dateStyle: "medium",
    timeStyle: "short",
  });
  const t = row.tracking || {};
  const rows: [string, unknown][] = [
    ["Name", row.name],
    ["Phone", row.phone],
    ["Email", row.email],
    ["Suburb", row.suburb],
    ["Postcode", row.postcode],
    ["Interested in", row.interest],
    ["Existing solar", row.existing_solar],
    ["Solar age", row.solar_age],
    ["Feed-in tariff", row.feed_in_tariff],
    ["Has battery", row.has_battery],
    ["Quarterly bill", row.bill_range],
    ["Ownership", row.ownership],
    ["Timeframe", row.timeframe],
    ["Bill uploaded", row.bill_path ? "Yes (attached to this deal)" : "No"],
    ["Received", received],
    ["Source", row.source],
    ["UTM source", t.utm_source],
    ["UTM campaign", t.utm_campaign],
    ["UTM content", t.utm_content],
    ["UTM term", t.utm_term],
  ];
  const lines = rows
    .filter(([, v]) => v !== null && v !== undefined && String(v).trim() !== "")
    .map(([k, v]) => `<b>${esc(k)}:</b> ${esc(v)}`);
  return `<b>Energy Health Check request</b><br><br>${lines.join("<br>")}`;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ success: false, error: "Method not allowed" }, 405);

  const body = await req.json().catch(() => null) as Record<string, any> | null;
  const leadId = typeof (body?.record?.id ?? body?.id) === "string" ? (body!.record?.id ?? body!.id) : null;
  if (!leadId) return json({ success: false, error: "id is required" }, 400);

  // Claim the lead so the trigger and a manual re-send can't both create a deal.
  const { data: claimed, error: claimErr } = await db.rpc("claim_lead_for_pipedrive", { lead_id: leadId });
  if (claimErr) return json({ success: false, error: claimErr.message }, 500);
  const row = (claimed as Record<string, any>[] | null)?.[0];
  if (!row) return json({ success: true, skipped: "already synced, in progress, or not found" });

  const fail = async (err: unknown) => {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`pipedrive-sync lead ${leadId}:`, msg);
    await db.from("leads").update({ sync_error: msg.slice(0, 1000), pipedrive_claimed_at: null }).eq("id", leadId);
    return json({ success: false, error: msg }, 502);
  };

  const { data: tokenData, error: tokErr } = await db.rpc("pipedrive_api_token");
  if (tokErr || !tokenData) return fail(tokErr || new Error("pipedrive_api_token is not in Vault"));
  const token = tokenData as string;

  try {
    const { pipelineId, stageId, ownerId } = await resolveTargets(token);

    // 1. person: reuse an existing one with the same email
    let personId: number | null = row.pipedrive_person_id;
    if (!personId) {
      const found = await pd(token, "GET",
        `/persons/search?term=${encodeURIComponent(row.email)}&fields=email&exact_match=true&limit=1`);
      personId = found?.items?.[0]?.item?.id ?? null;
    }
    if (!personId) {
      const person = await pd(token, "POST", "/persons", {
        name: row.name,
        email: [{ value: row.email, primary: true, label: "home" }],
        phone: [{ value: row.phone, primary: true, label: "mobile" }],
        ...(ownerId ? { owner_id: ownerId } : {}),
      });
      personId = person.id;
    }
    await db.from("leads").update({ pipedrive_person_id: personId }).eq("id", leadId);

    // 2. deal (kept if a later step fails, so a retry won't duplicate it)
    let dealId: number | null = row.pipedrive_deal_id;
    if (!dealId) {
      const deal = await pd(token, "POST", "/deals", {
        title: `${row.name}${row.suburb ? ` (${row.suburb})` : ""} - Energy Health Check`,
        person_id: personId,
        pipeline_id: pipelineId,
        stage_id: stageId,
        ...(ownerId ? { user_id: ownerId } : {}),
      });
      dealId = deal.id;
      await db.from("leads").update({ pipedrive_deal_id: dealId }).eq("id", leadId);
    }

    // 3. note with every answer, pinned so it's the first thing on the deal
    await pd(token, "POST", "/notes", {
      deal_id: dealId,
      content: noteHtml(row),
      pinned_to_deal_flag: 1,
    });

    // 4. bill: a failure here only costs the attachment, never the deal
    if (row.bill_path) {
      try {
        const { data: file, error } = await db.storage.from(BILL_BUCKET).download(row.bill_path);
        if (error || !file) throw error || new Error("empty download");
        const form = new FormData();
        form.append("deal_id", String(dealId));
        form.append("file", file, row.bill_filename || row.bill_path.split("/").pop());
        await pd(token, "POST", "/files", form);
      } catch (err) {
        console.error(`pipedrive-sync bill upload failed for lead ${leadId}:`, err);
        await pd(token, "POST", "/notes", {
          deal_id: dealId,
          content: `The customer uploaded a bill but it couldn't be attached automatically. It's in Supabase Storage &gt; bills &gt; ${esc(row.bill_path)}`,
        }).catch(() => {});
      }
    }

    await db.from("leads")
      .update({ synced_at: new Date().toISOString(), sync_error: null, pipedrive_claimed_at: null })
      .eq("id", leadId);
    return json({ success: true, person_id: personId, deal_id: dealId });
  } catch (err) {
    return fail(err);
  }
});
