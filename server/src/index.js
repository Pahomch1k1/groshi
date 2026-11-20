// WorkFlow Spend AI gateway (Cloudflare Worker).
//
// The OpenAI key lives only in the Worker secret OPENAI_API_KEY. The app never sees it.
// Access: each phone gets its own random device token on first use (POST /v1/register),
// stored in the iOS Keychain; the server keeps only its SHA-256. Registration is possible
// only while the enrollment window is open (KV "enroll", opened by the owner with an expiry)
// and closes by itself once MAX_DEVICES phones are registered. A token can be revoked.
//
// Abuse limits even for a valid token: only whitelisted models, bounded request size and
// output tokens, per-device per-minute and per-day request caps, and a global daily cap.

const JSON_HEADERS = { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" };
const json = (obj, status = 200) => new Response(JSON.stringify(obj), { status, headers: JSON_HEADERS });
const fail = (status, code, message) => json({ error: { code, message } }, status);

async function sha256(text) {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function randomToken() {
  const b = new Uint8Array(32);
  crypto.getRandomValues(b);
  return "wfs_" + btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

const num = (v, d) => (Number.isFinite(Number(v)) && Number(v) > 0 ? Number(v) : d);
const kyivDay = () => new Date(Date.now() + 2 * 3600e3).toISOString().slice(0, 10);

// Approximate counters in KV (good enough as a spending brake for one or two phones).
async function bump(env, key, ttl) {
  const n = Number((await env.KV.get(key)) || 0) + 1;
  await env.KV.put(key, String(n), { expirationTtl: ttl });
  return n;
}

async function register(req, env) {
  let body = {};
  try { body = await req.json(); } catch {}
  const installId = String(body.installId || "").slice(0, 64);
  if (!/^[A-Za-z0-9-]{8,64}$/.test(installId)) return fail(400, "bad_request", "installId required");
  const enroll = await env.KV.get("enroll");
  if (!enroll) return fail(403, "enrollment_closed", "Registration of new devices is closed.");
  const list = await env.KV.list({ prefix: "dev:" });
  const phones = list.keys.filter((k) => k.metadata?.kind !== "test");
  // The same install asking again (e.g. lost token) gets a fresh token, replacing the old one.
  const same = phones.filter((k) => k.metadata?.installId === installId);
  if (phones.length - same.length >= num(env.MAX_DEVICES, 1)) return fail(403, "enrollment_closed", "Device limit reached.");
  for (const k of same) await env.KV.delete(k.name);
  const token = randomToken();
  const meta = { installId, kind: "phone", created: new Date().toISOString(), app: String(body.appVersion || "").slice(0, 20) };
  await env.KV.put("dev:" + (await sha256(token)), JSON.stringify(meta), { metadata: meta });
  if (phones.length - same.length + 1 >= num(env.MAX_DEVICES, 1)) await env.KV.delete("enroll");
  return json({ token });
}

async function device(req, env) {
  const m = (req.headers.get("authorization") || "").match(/^Bearer\s+(wfs_[A-Za-z0-9_-]{20,})$/);
  if (!m) return null;
  const id = await sha256(m[1]);
  const rec = await env.KV.get("dev:" + id, { cacheTtl: 60 });
  return rec ? { id, ...JSON.parse(rec) } : null;
}

async function chat(req, env) {
  const dev = await device(req, env);
  if (!dev) return fail(401, "unauthorized", "Unknown or revoked device token.");
  const raw = await req.text();
  if (raw.length > num(env.MAX_BODY_BYTES, 200_000)) return fail(413, "too_large", "Request too large.");
  let body;
  try { body = JSON.parse(raw); } catch { return fail(400, "bad_request", "Invalid JSON."); }
  const models = String(env.ALLOWED_MODELS || "gpt-4.1,gpt-4.1-mini").split(",").map((s) => s.trim());
  if (!models.includes(body.model)) return fail(400, "model_not_allowed", "Allowed models: " + models.join(", "));
  if (!Array.isArray(body.messages) || body.messages.length === 0 || body.messages.length > 80) return fail(400, "bad_request", "messages: 1..80");
  if (body.tools && (!Array.isArray(body.tools) || body.tools.length > 40)) return fail(400, "bad_request", "tools: up to 40");

  const day = kyivDay();
  const minute = Math.floor(Date.now() / 60000);
  if ((await bump(env, `rl:m:${dev.id}:${minute}`, 120)) > num(env.PER_MINUTE, 30)) return fail(429, "rate_limited", "Too many requests per minute.");
  if ((await bump(env, `rl:d:${dev.id}:${day}`, 172800)) > num(env.PER_DAY, 600)) return fail(429, "daily_limit", "Daily limit reached for this device.");
  if ((await bump(env, `rl:g:${day}`, 172800)) > num(env.GLOBAL_PER_DAY, 1500)) return fail(429, "daily_limit", "Daily limit reached.");

  // Forward only the fields the app uses, with a cap on output tokens.
  const upstream = {
    model: body.model,
    messages: body.messages,
    max_tokens: Math.min(num(body.max_tokens, 4000), num(env.MAX_OUTPUT_TOKENS, 4000)),
  };
  if (body.tools?.length) { upstream.tools = body.tools; upstream.tool_choice = body.tool_choice || "auto"; }
  const r = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${env.OPENAI_API_KEY}` },
    body: JSON.stringify(upstream),
  });
  const text = await r.text();
  if (!r.ok) {
    // Pass OpenAI's message through, but never anything about the key itself.
    let msg = "OpenAI error";
    try { msg = JSON.parse(text).error?.message || msg; } catch {}
    return fail(r.status === 429 ? 429 : 502, "upstream_" + r.status, msg.replace(/sk-[A-Za-z0-9_-]+/g, "sk-…"));
  }
  return new Response(text, { status: 200, headers: JSON_HEADERS });
}

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    try {
      if (req.method === "GET" && url.pathname === "/v1/health") {
        return json({ ok: true, key: Boolean(env.OPENAI_API_KEY), enrollment: Boolean(await env.KV.get("enroll")) });
      }
      if (req.method === "POST" && url.pathname === "/v1/register") return await register(req, env);
      if (req.method === "POST" && url.pathname === "/v1/chat/completions") return await chat(req, env);
      return fail(404, "not_found", "Not found");
    } catch (e) {
      return fail(500, "server_error", "Server error");
    }
  },
};
