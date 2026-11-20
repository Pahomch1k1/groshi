// Live OpenAI check of the WorkFlow Spend assistant, run on a computer (not in CI).
//
// It sends the app's exact contract (tools + system prompt exported by the Core tests, see
// AIContractTests) to the real OpenAI API, executes the tool calls on synthetic data with a
// small mirror of the Swift engine, checks the expectations and records every model response.
// The recording is then replayed through the real Swift engine in CI (LiveReplayTests).
//
//   node harness.mjs <ai-contract.json> <out-recordings.json> [model]
//
// The key is read from OPENAI_API_KEY or from the file named by OPENAI_KEY_FILE (a line
// OPENAI_API_KEY=...). It is never printed or written anywhere.
import { readFileSync, writeFileSync } from "node:fs";
import { scenarios } from "./scenarios.mjs";

const [contractPath, outPath, modelArg] = process.argv.slice(2);
const model = modelArg || "gpt-4.1-mini";
const contract = JSON.parse(readFileSync(contractPath, "utf8"));
let key = process.env.OPENAI_API_KEY;
if (!key && process.env.OPENAI_KEY_FILE) {
  const m = readFileSync(process.env.OPENAI_KEY_FILE, "utf8").match(/^\s*OPENAI_API_KEY\s*=\s*"?([^"\s]+)/m);
  key = m && m[1];
}
if (!key) { console.error("No OpenAI key (OPENAI_API_KEY or OPENAI_KEY_FILE)"); process.exit(2); }

// ---- Synthetic state mirroring SpendeeFixture ------------------------------------------------
const NOW = "2026-11-20";
const catNames = [...contract.system.matchAll(/^(Expense|Income) categories: (.*)\.$/gm)];
function freshState() {
  const cats = [];
  for (const [, kind, list] of catNames) for (const n of list.split(", ")) cats.push({ name: n, kind: kind === "Expense" ? "expense" : "income" });
  return { cats, txs: [], undo: [], pending: null, seq: 0 };
}
const norm = (s) => String(s).trim().toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/ё/g, "е");
const catNamed = (S, n, kind) => S.cats.find((c) => norm(c.name) === norm(n) && (!kind || c.kind === kind));
const money = (v) => { const x = Number(String(v).replace(",", ".").replace(/\s/g, "")); return isFinite(x) && x !== 0 ? Math.round(Math.abs(x) * 100) : null; };
const describe = (t) => `${t.date} ${t.kind === "expense" ? "-" : "+"}${(t.minor / 100).toFixed(2)} ${t.currency} ${t.category}${t.note ? ` (${t.note})` : ""}`;
const numbered = (txs) => txs.map((t, i) => `${i + 1}. ${describe(t)}`);
const notFound = (S, n) => `Category '${n}' not found. Expense: ${S.cats.filter((c) => c.kind === "expense").map((c) => c.name).join(", ")}. Income: ${S.cats.filter((c) => c.kind === "income").map((c) => c.name).join(", ")}`;
class ToolError extends Error {}
const isDup = (S, t) => S.txs.some((o) => o.kind === t.kind && o.minor === t.minor && o.currency === t.currency && o.category === t.category && o.date === t.date);

function parseItems(S, items, offset) {
  return items.map((it, i) => {
    const n = i + 1 + offset;
    if (!["expense", "income"].includes(it.kind)) throw new ToolError(`item ${n}: kind must be expense or income`);
    if (!it.category) throw new ToolError(`item ${n}: category required`);
    const c = catNamed(S, it.category, it.kind);
    if (!c) throw new ToolError(`item ${n}: ` + notFound(S, it.category));
    if (it.wallet && norm(it.wallet) !== "mono") throw new ToolError(`item ${n}: wallet '${it.wallet}' not found; wallets: Mono`);
    const minor = money(it.amount);
    if (minor == null) throw new ToolError(`item ${n}: amount missing or invalid; ask the user`);
    if (!it.date) throw new ToolError(`item ${n}: the user did not state the date. Ask the user for which date (do not assume today); nothing was recorded.`);
    if (!/^\d{4}-\d{2}-\d{2}$/.test(it.date)) throw new ToolError(`bad date '${it.date}', use YYYY-MM-DD`);
    return { id: (++S.seq).toString(16).padStart(8, "0"), kind: it.kind, minor, currency: (it.currency || "UAH").toUpperCase(), category: c.name, date: it.date, note: it.note || "" };
  });
}
function setDraft(S, txs) {
  if (!txs.length) { S.pending = null; return { status: "draft_empty", message: "All items were removed; nothing will be saved." }; }
  S.pending = { draft: true, txs };
  const exp = txs.filter((t) => t.kind === "expense").reduce((a, t) => a + t.minor, 0), inc = txs.filter((t) => t.kind === "income").reduce((a, t) => a + t.minor, 0);
  const dups = txs.map((t, i) => (isDup(S, t) ? i + 1 : 0)).filter(Boolean);
  const r = { status: txs.length === 1 ? "possible_duplicate" : "draft", count: txs.length, total_expense: (exp / 100).toFixed(2) + " UAH", total_income: (inc / 100).toFixed(2) + " UAH", items: numbered(txs), next: "Ask the user to confirm in one short sentence; the list is shown on screen." };
  if (dups.length) r.possible_duplicates_of_saved = dups;
  return r;
}
function apply(S, label, fn) { S.undo.push({ label, txs: S.txs.map((t) => ({ ...t })), cats: S.cats.map((c) => ({ ...c })) }); fn(); }
function applyPending(S) {
  const p = S.pending; S.pending = null;
  if (p.draft) { apply(S, `Added ${p.txs.length}`, () => S.txs.push(...p.txs)); return `saved ${p.txs.length} operation(s)`; }
  apply(S, p.summary, p.run); return p.summary;
}

function execute(S, name, a) {
  try {
    switch (name) {
      case "add_transactions": {
        if (!a.items?.length) return { status: "error", message: "items required" };
        const existing = S.pending?.draft ? S.pending.txs : [];
        const all = existing.concat(parseItems(S, a.items, existing.length));
        if (all.length === 1 && !isDup(S, all[0])) { apply(S, "Added", () => S.txs.push(all[0])); return { status: "saved", item: describe(all[0]) }; }
        return setDraft(S, all);
      }
      case "revise_draft": {
        if (!S.pending?.draft) return { status: "error", message: "no draft is pending; to change saved operations use find_transactions and update_transactions" };
        let txs = S.pending.txs.map((t) => ({ ...t }));
        const removed = new Set();
        for (const ch of a.changes || []) {
          const n = ch.number; if (!(n >= 1 && n <= txs.length)) throw new ToolError(`bad item number; the draft has ${txs.length} items`);
          if (ch.remove) { removed.add(n - 1); continue; }
          const t = txs[n - 1];
          if (ch.kind) t.kind = ch.kind;
          if (ch.currency) t.currency = ch.currency.toUpperCase();
          if (ch.amount) { const m = money(ch.amount); if (m == null) throw new ToolError(`item ${n}: bad amount`); t.minor = m; }
          if (ch.category) { const c = catNamed(S, ch.category, t.kind); if (!c) throw new ToolError(`item ${n}: ` + notFound(S, ch.category)); t.category = c.name; }
          else if (!catNamed(S, t.category, t.kind)) throw new ToolError(`item ${n}: the type changed, also give a ${t.kind} category`);
          if (ch.date) t.date = ch.date;
          if (ch.note != null) t.note = ch.note;
        }
        txs = txs.filter((_, i) => !removed.has(i));
        if (a.add?.length) txs = txs.concat(parseItems(S, a.add, txs.length));
        return setDraft(S, txs);
      }
      case "confirm_pending": if (!S.pending) return { status: "error", message: "nothing is pending" }; return { status: "done", summary: applyPending(S) };
      case "cancel_pending": if (!S.pending) return { status: "error", message: "nothing is pending" }; S.pending = null; return { status: "cancelled" };
      case "find_transactions": {
        let l = S.txs.slice();
        if (a.kind) l = l.filter((t) => t.kind === a.kind);
        if (a.category) l = l.filter((t) => norm(t.category).includes(norm(a.category)));
        if (a.date_from) l = l.filter((t) => t.date >= a.date_from);
        if (a.date_to) l = l.filter((t) => t.date <= a.date_to);
        if (a.text) l = l.filter((t) => norm(t.note).includes(norm(a.text)));
        l.sort((x, y) => (a.sort === "oldest" ? x.date.localeCompare(y.date) : y.date.localeCompare(x.date) || Number.parseInt(y.id, 16) - Number.parseInt(x.id, 16)));
        return { status: "ok", total_matches: l.length, items: l.slice(0, Math.max(1, Math.min(50, a.limit || 10))).map((t) => ({ id: t.id, date: t.date + " 12:00", kind: t.kind, amount: (t.minor / 100).toFixed(2), currency: t.currency, wallet: "Mono", note: t.note, category: t.category })) };
      }
      case "update_transactions": case "delete_transactions": {
        const ts = (a.ids || []).map((id) => S.txs.find((t) => t.id.startsWith(String(id).toLowerCase())));
        if (!ts.length || ts.some((t) => !t)) throw new ToolError("unknown id; call find_transactions first");
        const run = name === "delete_transactions"
          ? () => { S.txs = S.txs.filter((t) => !ts.includes(t)); }
          : () => { for (const t of ts) { if (a.amount) t.minor = money(a.amount); if (a.category) t.category = catNamed(S, a.category, a.kind || t.kind).name; if (a.date) t.date = a.date; if (a.note != null) t.note = a.note; if (a.kind) t.kind = a.kind; } };
        if (a.category && !catNamed(S, a.category, a.kind || ts[0].kind)) return { status: "error", message: notFound(S, a.category) };
        const summary = `${name === "delete_transactions" ? "Delete" : "Update"} ${ts.length}: ` + ts.slice(0, 5).map(describe).join("; ");
        if (ts.length >= 2) { S.pending = { draft: false, summary, run }; return { status: "awaiting_user_confirmation", summary }; }
        apply(S, summary, run); return { status: "done", summary };
      }
      case "undo_last_action": { const u = S.undo.pop(); if (!u) return { status: "error", message: "nothing to undo" }; S.txs = u.txs; S.cats = u.cats; return { status: "done", undone: u.label }; }
      case "summarize": {
        let l = S.txs.filter((t) => t.date >= a.date_from && t.date <= a.date_to);
        if (a.kind) l = l.filter((t) => t.kind === a.kind);
        if (a.category) l = l.filter((t) => norm(t.category) === norm(a.category));
        const e = l.filter((t) => t.kind === "expense").reduce((s, t) => s + t.minor, 0), i = l.filter((t) => t.kind === "income").reduce((s, t) => s + t.minor, 0);
        return { status: "ok", currency: "UAH", count: l.length, total_expense: (e / 100).toFixed(2), total_income: (i / 100).toFixed(2), net: ((i - e) / 100).toFixed(2) };
      }
      case "wallet_balances": return { status: "ok", wallets: [{ wallet: "Mono", currency: "UAH", balance: (S.txs.reduce((s, t) => s + (t.kind === "income" ? t.minor : -t.minor), 0) / 100).toFixed(2) }] };
      case "create_category": apply(S, `Created category ${a.name}`, () => S.cats.push({ name: a.name, kind: a.kind || "expense" })); return { status: "done", summary: `Created category ${a.name}` };
      case "update_category": { const c = catNamed(S, a.name, a.kind); if (!c) return { status: "error", message: notFound(S, a.name) }; apply(S, `Updated category ${c.name}`, () => { if (a.new_name) c.name = a.new_name; }); return { status: "done", summary: `Updated category ${c.name}` }; }
      case "delete_category": { const c = catNamed(S, a.name, a.kind); if (!c) return { status: "error", message: notFound(S, a.name) }; S.pending = { draft: false, summary: `Delete category ${c.name}`, run: () => { S.cats = S.cats.filter((x) => x !== c); } }; return { status: "awaiting_user_confirmation", summary: `Delete category ${c.name}` }; }
      case "add_transfer": return { status: "error", message: "destination wallet not found; wallets: Mono. Offer to create it with create_wallet." };
      case "create_wallet": case "update_wallet": case "delete_wallet": return { status: "error", message: "not available in this test" };
      default: return { status: "error", message: `unknown tool ${name}` };
    }
  } catch (e) {
    if (e instanceof ToolError) return { status: "error", message: e.message };
    throw e;
  }
}

function pendingDescription(S) {
  if (!S.pending) return "";
  const d = S.pending.draft ? `Draft of ${S.pending.txs.length} operation(s), numbered:\n` + numbered(S.pending.txs).join("\n") : `Action needing confirmation: ${S.pending.summary}`;
  return "\nPENDING (not saved yet, awaiting the user's answer):\n" + d;
}

// ---- OpenAI ------------------------------------------------------------------------------------
const usage = { calls: 0, prompt: 0, completion: 0, ms: [] };
async function complete(messages) {
  for (let attempt = 0; ; attempt++) {
    const t0 = Date.now();
    const r = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${key}` },
      body: JSON.stringify({ model, messages, tools: contract.tools, tool_choice: "auto" }),
    });
    if (r.status === 429 && attempt < 3) { await new Promise((s) => setTimeout(s, 4000)); continue; }
    if (r.status !== 200) throw new Error(`OpenAI ${r.status}: ${(await r.text()).slice(0, 300)}`);
    const j = await r.json();
    usage.calls++; usage.prompt += j.usage?.prompt_tokens || 0; usage.completion += j.usage?.completion_tokens || 0; usage.ms.push(Date.now() - t0);
    const m = j.choices[0].message;
    const out = { role: "assistant", content: m.content ?? null };
    if (m.tool_calls?.length) out.tool_calls = m.tool_calls.map((c) => ({ id: c.id, type: "function", function: { name: c.function.name, arguments: c.function.arguments } }));
    return out;
  }
}

async function send(S, history, text) {
  history.push({ role: "user", content: text });
  const responses = [];
  const seen = new Set();
  for (let round = 0; round < 6; round++) {
    const msg = await complete([{ role: "system", content: contract.system + pendingDescription(S) }, ...history]);
    history.push(msg); responses.push(msg);
    if (!msg.tool_calls) return { reply: msg.content || "", responses };
    for (const c of msg.tool_calls) {
      const sig = c.function.name + "|" + c.function.arguments;
      let res;
      if (seen.has(sig) && !["find_transactions", "summarize"].includes(c.function.name)) res = { status: "already_done", message: "This exact call was already executed in this turn." };
      else { seen.add(sig); let a = {}; try { a = JSON.parse(c.function.arguments || "{}"); } catch {} res = execute(S, c.function.name, a); }
      history.push({ role: "tool", tool_call_id: c.id, content: JSON.stringify(res) });
    }
  }
  return { reply: "…", responses };
}

// ---- Expectations (same format is checked again by the Swift replay) ------------------------------
const key4 = (t) => `${t.date}|${t.kind}|${(t.minor / 100).toFixed(2)}|${t.category}`;
function matches(actual, expected) {
  // expected: "date|kind|amount|Cat1/Cat2" multiset
  const left = actual.map(key4);
  const miss = [];
  for (const e of expected) {
    const [d, k, a, cats] = e.split("|");
    const i = left.findIndex((x) => { const [xd, xk, xa, xc] = x.split("|"); return xd === d && xk === k && Number(xa) === Number(a) && cats.split("/").includes(xc); });
    if (i < 0) miss.push(e); else left.splice(i, 1);
  }
  return { miss, extra: left };
}

const results = [];
const recordings = [];
let failures = 0;
const only = process.env.ONLY;
for (const sc of scenarios) {
  if (only && !sc.name.includes(only)) continue;
  const S = freshState();
  const history = [];
  const rec = { name: sc.name, turns: [], expectTxs: sc.expectTxs };
  const problems = [];
  console.log(`\n=== ${sc.name}`);
  for (const turn of sc.turns) {
    if (turn.button) {
      if (turn.button === "confirm" && S.pending) { const s = applyPending(S); history.push({ role: "assistant", content: `[The user confirmed with the button: ${s}.]` }); }
      rec.turns.push({ button: turn.button, expect: turn.expect });
      console.log(`  [button ${turn.button}]`);
    } else {
      const r = await send(S, history, turn.user);
      rec.turns.push({ user: turn.user, responses: r.responses, expect: turn.expect });
      const calls = r.responses.flatMap((m) => (m.tool_calls || []).map((c) => c.function.name));
      console.log(`  👤 ${turn.user}\n  🤖 ${r.reply}   [${calls.join(", ")}]`);
      const ex = turn.expect || {};
      if (ex.saved != null && S.txs.length !== ex.saved) problems.push(`after "${turn.user.slice(0, 40)}": saved ${S.txs.length}, expected ${ex.saved}`);
      const pend = S.pending?.draft ? S.pending.txs.length : S.pending ? -1 : 0;
      if (ex.pending != null && pend !== ex.pending) problems.push(`after "${turn.user.slice(0, 40)}": pending ${pend}, expected ${ex.pending}`);
      if (ex.asks && (calls.some((c) => c.startsWith("add_")) || !r.reply.trim())) problems.push(`after "${turn.user.slice(0, 40)}": expected a clarifying question, got "${r.reply}" [${calls}]`);
      if (ex.noCreateCategory && calls.includes("create_category")) problems.push("created a category on its own");
    }
  }
  if (sc.expectTxs) {
    const { miss, extra } = matches(S.txs, sc.expectTxs);
    if (miss.length) problems.push("missing: " + miss.join(", "));
    if (extra.length) problems.push("unexpected: " + extra.join(", "));
  }
  if (sc.expectCategory && !catNamed(S, sc.expectCategory)) problems.push(`category ${sc.expectCategory} not created`);
  console.log(problems.length ? "  ❌ " + problems.join("\n     ") : "  ✅ ok");
  if (problems.length) failures++;
  results.push({ name: sc.name, ok: !problems.length, problems });
  recordings.push(rec);
}
writeFileSync(outPath, JSON.stringify({ model, recordings }, null, 1));
const ms = usage.ms.sort((a, b) => a - b);
console.log(`\nModel ${model}: ${results.length - failures}/${results.length} scenarios passed; ${usage.calls} calls, ${usage.prompt} prompt + ${usage.completion} completion tokens; latency median ${ms[Math.floor(ms.length / 2)]} ms, max ${ms[ms.length - 1]} ms`);
process.exit(failures ? 1 : 0);
