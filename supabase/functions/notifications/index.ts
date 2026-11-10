// Supabase Edge Function for database webhooks and scheduled store summaries.
// Secrets stay server-side: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY,
// RESEND_API_KEY, NOTIFY_HOOK_SECRET, MAIL_FROM.
const env = (key: string) => Deno.env.get(key) || "";
const url = env("SUPABASE_URL").replace(/\/$/, "");
const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
const resendKey = env("RESEND_API_KEY");
const hookSecret = env("NOTIFY_HOOK_SECRET");
const from = env("MAIL_FROM");
const siteUrl = env("SITE_URL") || url;

async function db(path: string, init: RequestInit = {}) {
  const res = await fetch(`${url}/rest/v1/${path}`, {
    ...init,
    headers: { apikey: serviceKey, Authorization: `Bearer ${serviceKey}`, "Content-Type": "application/json", ...(init.headers || {}) },
  });
  if (!res.ok) throw new Error(`Supabase request failed (${res.status})`);
  return res.status === 204 ? null : await res.json();
}
async function send(to: string, subject: string, html: string) {
  if (!to || !resendKey) return;
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${resendKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from, to: [to], subject, html }),
  });
  if (!res.ok) throw new Error(`Email provider rejected the message (${res.status})`);
}
function esc(value: unknown) {
  const entities: Record<string, string> = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };
  return String(value ?? "").replace(/[&<>"']/g, ch => entities[ch]);
}
async function accountEmail(userId: string) {
  const res = await fetch(`${url}/auth/v1/admin/users/${encodeURIComponent(userId)}`, {
    headers: { apikey: serviceKey, Authorization: `Bearer ${serviceKey}` },
  });
  if (!res.ok) return "";
  return (await res.json()).email || "";
}
async function mailStoreOwner(storeId: string, subject: string, body: string) {
  const rows = await db(`stores?id=eq.${encodeURIComponent(storeId)}&select=id,name,owner_id,status`);
  const store = rows?.[0];
  if (!store) return;
  await send(await accountEmail(store.owner_id), subject, `<div dir="rtl" style="font:16px Arial;line-height:1.8"><h2>سوق الجملة</h2><p>${esc(body)}</p><p>المتجر: <b>${esc(store.name)}</b></p><a href="${esc(siteUrl)}/#dash">افتح لوحة المورد</a></div>`);
}

Deno.serve(async req => {
  if (!url || !serviceKey || !resendKey || !from || !hookSecret) return new Response("Function is not configured", { status: 500 });
  if (req.headers.get("x-notify-secret") !== hookSecret) return new Response("Unauthorized", { status: 401 });
  try {
    const payload = await req.json();
    if (payload.mode === "summary") {
      const days = payload.period === "weekly" ? 7 : 1;
      const since = new Date(Date.now() - days * 86400000).toISOString();
      const clicks = await db(`whatsapp_clicks?created_at=gte.${encodeURIComponent(since)}&select=store_id`);
      const counts = new Map<string, number>();
      for (const row of clicks || []) counts.set(row.store_id, (counts.get(row.store_id) || 0) + 1);
      for (const [storeId, count] of counts) await mailStoreOwner(storeId, "ملخص طلبات متجرك", `لديك ${count} نقرة واتساب جديدة خلال ${days === 1 ? "اليوم" : "الأسبوع الماضي"}.`);
      return Response.json({ sent: counts.size });
    }
    const table = payload.table, type = payload.type, record = payload.record || {};
    if (table === "whatsapp_clicks" && type === "INSERT" && record.store_id) {
      const claimed = await fetch(`${url}/rest/v1/rpc/claim_first_click_notification`, {
        method: "POST", headers: { apikey: serviceKey, Authorization: `Bearer ${serviceKey}`, "Content-Type": "application/json" },
        body: JSON.stringify({ p_store: record.store_id }),
      });
      if (claimed.ok && await claimed.json()) await mailStoreOwner(record.store_id, "أول طلب تواصل لمتجرك", "تلقى أحد منتجاتك أول نقرة تواصل عبر واتساب.");
    }
    if (table === "stores" && type === "UPDATE" && payload.old_record?.status !== record.status && ["approved", "suspended"].includes(record.status)) {
      await mailStoreOwner(record.id, record.status === "approved" ? "تم اعتماد متجرك" : "تم إيقاف متجرك", record.status === "approved" ? "تمت مراجعة متجرك واعتماده، ويمكنه الظهور للزوار." : "تم إيقاف المتجر. يرجى التواصل مع الإدارة لمزيد من التفاصيل.");
    }
    return Response.json({ ok: true });
  } catch (error) {
    console.error(error);
    return Response.json({ error: "Notification processing failed" }, { status: 500 });
  }
});
