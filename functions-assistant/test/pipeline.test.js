// Δοκιμή ολόκληρης της ροής του webhook με ψεύτικο Firestore/Claude/WhatsApp (χωρίς δίκτυο).
const test = require("node:test");
const assert = require("node:assert");
const path = require("path");
const crypto = require("crypto");

// ── Ψεύτικο Firestore ──────────────────────────────────────────────────────
class Timestamp {
  constructor(ms) { this.ms = ms; }
  static now() { return new Timestamp(Date.now()); }
  static fromMillis(ms) { return new Timestamp(ms); }
  toMillis() { return this.ms; }
  toDate() { return new Date(this.ms); }
}
const INC = (n) => ({ __inc: n });
const FieldValue = { increment: INC, serverTimestamp: () => ({ __ts: true }), arrayUnion: (...a) => ({ __union: a }) };
const isPlain = (v) => v && typeof v === "object" && !(v instanceof Timestamp) && !(v instanceof Date) && !Array.isArray(v);

function merge(target, patch) {
  for (const [k, v] of Object.entries(patch)) {
    if (v && v.__inc !== undefined) target[k] = (Number(target[k]) || 0) + v.__inc;
    else if (v && v.__ts) target[k] = Timestamp.now();
    else if (isPlain(v)) { if (!isPlain(target[k])) target[k] = {}; merge(target[k], v); }
    else target[k] = v;
  }
}
function clone(o) { return JSON.parse(JSON.stringify(o, (k, v) => (v instanceof Timestamp ? { __t: v.ms } : v)), (k, v) => (v && v.__t !== undefined ? new Timestamp(v.__t) : v)); }
function getPath(o, p) { return p.split(".").reduce((a, k) => (a == null ? undefined : a[k]), o); }

const store = new Map(); // "coll/doc/sub/doc" -> data
class Snap { constructor(id, data, ref) { this.id = id; this._d = data; this.exists = data !== undefined; this.ref = ref; } data() { return this._d === undefined ? undefined : clone(this._d); } }
class DocRef {
  constructor(p) { this.path = p; this.id = p.split("/").pop(); }
  collection(n) { return new CollRef(this.path + "/" + n); }
  async get() { return new Snap(this.id, store.get(this.path), this); }
  async set(data, opts) {
    if (opts && opts.merge) { const cur = store.get(this.path) || {}; merge(cur, data); store.set(this.path, cur); }
    else { const cur = {}; merge(cur, data); store.set(this.path, cur); }
  }
  async create(data) {
    if (store.has(this.path)) { const e = new Error("ALREADY_EXISTS"); e.code = 6; throw e; }
    const cur = {}; merge(cur, data); store.set(this.path, cur);
  }
}
class CollRef {
  constructor(p) { this.path = p; this._f = []; this._o = null; this._l = null; }
  doc(id) { return new DocRef(this.path + "/" + id); }
  where(f, op, v) { const c = Object.assign(new CollRef(this.path), this); c._f = [...this._f, [f, v]]; return c; }
  orderBy(f, dir) { const c = Object.assign(new CollRef(this.path), this); c._o = [f, dir]; return c; }
  limit(n) { const c = Object.assign(new CollRef(this.path), this); c._l = n; return c; }
  async get() {
    const depth = this.path.split("/").length + 1;
    let docs = [...store.entries()].filter(([p]) => p.startsWith(this.path + "/") && p.split("/").length === depth)
      .map(([p, d]) => new Snap(p.split("/").pop(), d, new DocRef(p)));
    for (const [f, v] of this._f) docs = docs.filter((s) => getPath(s._d, f) === v);
    if (this._o) {
      const [f, dir] = this._o;
      const val = (s) => { const x = getPath(s._d, f); return x instanceof Timestamp ? x.ms : x; };
      docs.sort((a, b) => (dir === "desc" ? val(b) - val(a) : val(a) - val(b)));
    }
    if (this._l) docs = docs.slice(0, this._l);
    return { docs, empty: docs.length === 0 };
  }
}
const fakeDb = { collection: (n) => new CollRef(n), batch() { const ops = []; return { set: (r, d, o) => ops.push([r, d, o]), commit: async () => { for (const [r, d, o] of ops) await r.set(d, o); } }; } };

const sent = { graph: [], claude: [], push: [] };
function inject(id, exports_) { require.cache[id] = { id, filename: id, loaded: true, exports: exports_ }; }
const r = (m) => require.resolve(m);
inject(r("firebase-admin/app"), { initializeApp() {} });
inject(r("firebase-admin/firestore"), { getFirestore: () => fakeDb, FieldValue, Timestamp });
inject(r("firebase-admin/messaging"), { getMessaging: () => ({ sendEachForMulticast: async (m) => { sent.push.push(m); return { responses: [] }; } }) });
inject(path.resolve(__dirname, "../lib/secrets.js"), { tenantSecretId: (t, f) => `tenant-${t}-${f}`, readSecret: async (id) => (id === "tenant-default-wa-token" ? "WATOKEN" : null) });

process.env.WA_VERIFY_TOKEN = "vt"; process.env.WA_APP_SECRET = "appsec"; process.env.ANTHROPIC_API_KEY = "sk-test";

let claudeReply = null;
global.fetch = async (url, opts) => {
  const body = JSON.parse(opts.body);
  if (String(url).includes("api.anthropic.com")) {
    sent.claude.push(body);
    return { ok: true, json: async () => ({ content: [{ type: "text", text: JSON.stringify(claudeReply) }], usage: { input_tokens: 1000, output_tokens: 100 } }) };
  }
  sent.graph.push({ url: String(url), body });
  return { ok: true, json: async () => ({ messages: [{ id: "wamid.OUT" + sent.graph.length }] }) };
};

const fns = require("../index.js");

function webhook(payload) {
  const raw = Buffer.from(JSON.stringify(payload));
  const req = { method: "POST", rawBody: raw, body: payload, query: {}, get: (h) => (h.toLowerCase() === "x-hub-signature-256" ? "sha256=" + crypto.createHmac("sha256", "appsec").update(raw).digest("hex") : undefined) };
  let status = 0; const res = { status(s) { status = s; return this; }, send() { return this; } };
  return fns.waWebhook(req, res).then(() => status);
}
const inbound = (from, text, id, ts = Math.floor(Date.now() / 1000)) => ({ entry: [{ changes: [{ field: "messages", value: { metadata: { phone_number_id: "PN1" }, contacts: [{ profile: { name: "Tom" } }], messages: [{ from, id, timestamp: String(ts), type: "text", text: { body: text } }] } }] }] });
const echo = (to, id) => ({ entry: [{ changes: [{ field: "smb_message_echoes", value: { metadata: { phone_number_id: "PN1" }, message_echoes: [{ from: "306900000000", to, id, timestamp: String(Math.floor(Date.now() / 1000)), type: "text", text: { body: "Hello from Kostas" } }] } }] }] });

function reset() {
  store.clear(); sent.graph.length = 0; sent.claude.length = 0; sent.push.length = 0;
  store.set("assistant_config/default", { enabled: true, whatsapp: { phoneNumberId: "PN1" } });
  store.set("presence/u1", { master: true, fcmToken: "TOK1" });
}
const day = () => new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Athens" }).format(new Date());

test("ξένος πελάτης: συλλογή στοιχείων, απάντηση, στατιστικά, κόστος Claude", async () => {
  reset();
  claudeReply = { extracted: { from: "Airport", to: "Plaka" }, involves_airport_or_port: true, language: "en", reply: "Sure! How many people will travel?", needs_human: false, reason: "" };
  assert.strictEqual(await webhook(inbound("447400123456", "Hi, taxi from the airport to Plaka please", "wamid.A1")), 200);
  const conv = store.get("wa_conversations/default__447400123456");
  assert.strictEqual(conv.status, "collecting");
  assert.strictEqual(conv.country, "GB");
  assert.deepStrictEqual({ from: conv.draft.from, to: conv.draft.to }, { from: "Airport", to: "Plaka" });
  assert.strictEqual(sent.graph.length, 1);
  assert.strictEqual(sent.graph[0].body.text.body, "Sure! How many people will travel?");
  assert.match(sent.graph[0].url, /PN1\/messages$/);
  const st = store.get(`wa_stats/default/daily/${day()}`);
  assert.strictEqual(st.byCountry.GB.messages, 1);
  assert.strictEqual(st.byCountry.GB.conversations, 1);
  assert.strictEqual(st.byCountry.GB.aiReplies, 1);
  assert.strictEqual(st.byCountry.GB.responded, 1);
  const mon = [...store.entries()].find(([p]) => p.startsWith("usage/default/monthly/"))[1];
  assert.ok(mon.services.claude.units === 1 && mon.services.claude.tokensIn === 1000);
  assert.ok(mon.totalCostEur > 0);
});

test("διπλή παράδοση του ίδιου μηνύματος δεν ξαναεπεξεργάζεται", async () => {
  await webhook(inbound("447400123456", "Hi, taxi from the airport to Plaka please", "wamid.A1"));
  assert.strictEqual(sent.claude.length, 1);
  assert.strictEqual(sent.graph.length, 1);
});

test("πλήρη στοιχεία → status ready + ειδοποίηση στον admin", async () => {
  claudeReply = { extracted: { from: "Airport", to: "Plaka", date: "2026-10-12", time: "14:30", persons: "3", luggage: "2", flightOrShip: "A3 123" }, involves_airport_or_port: true, language: "en", reply: "Thank you! We will check availability and the price and get back to you shortly.", needs_human: false };
  await webhook(inbound("447400123456", "3 people, 2 bags, 12 Oct 14:30, flight A3 123", "wamid.A2"));
  const conv = store.get("wa_conversations/default__447400123456");
  assert.strictEqual(conv.status, "ready");
  assert.ok(conv.notifiedReadyAt);
  assert.strictEqual(sent.push.length, 1);
  assert.deepStrictEqual(sent.push[0].tokens, ["TOK1"]);
  assert.match(sent.push[0].notification.body, /Από: Airport/);
  assert.strictEqual(store.get(`wa_stats/default/daily/${day()}`).byCountry.GB.complete, 1);
});

test("ελληνικός αριθμός: χωρίς Claude, χωρίς αποστολή", async () => {
  reset();
  await webhook(inbound("306944000111", "Καλησπέρα, θέλω ταξί", "wamid.G1"));
  assert.strictEqual(sent.claude.length, 0);
  assert.strictEqual(sent.graph.length, 0);
  assert.ok(store.get("wa_conversations/default__306944000111"));
});

test("απάντηση με τιμή από το AI μπλοκάρεται και περνά σε άνθρωπο", async () => {
  reset();
  claudeReply = { extracted: { from: "Airport" }, involves_airport_or_port: true, language: "en", reply: "The price will be 45€", needs_human: false };
  await webhook(inbound("491511234567", "How much to Athens center?", "wamid.D1"));
  assert.strictEqual(sent.graph.length, 0);
  assert.strictEqual(store.get("wa_conversations/default__491511234567").status, "human");
  assert.strictEqual(sent.push.length, 1);
});

test("ο ιδιοκτήτης απαντά από το κινητό → το AI σταματά", async () => {
  reset();
  claudeReply = { extracted: {}, involves_airport_or_port: false, language: "en", reply: "Where from?", needs_human: false };
  await webhook(inbound("447400123456", "Hi", "wamid.E1"));
  const before = sent.claude.length;
  await webhook(echo("447400123456", "wamid.ECHO1"));
  const conv = store.get("wa_conversations/default__447400123456");
  assert.ok(conv.humanUntil.toMillis() > Date.now());
  await webhook(inbound("447400123456", "Are you there?", "wamid.E2"));
  assert.strictEqual(sent.claude.length, before);
});

test("λέξη παραπόνου → άνθρωπος + ειδοποίηση, χωρίς Claude", async () => {
  reset();
  await webhook(inbound("447400123456", "I want a refund!", "wamid.R1"));
  assert.strictEqual(sent.claude.length, 0);
  assert.strictEqual(store.get("wa_conversations/default__447400123456").status, "human");
  assert.strictEqual(sent.push.length, 1);
});

test("άκυρη υπογραφή → 401", async () => {
  const payload = inbound("447400123456", "x", "wamid.X");
  const req = { method: "POST", rawBody: Buffer.from("{}"), body: payload, query: {}, get: () => "sha256=bad" };
  let st = 0; await fns.waWebhook(req, { status(s) { st = s; return this; }, send() { return this; } });
  assert.strictEqual(st, 401);
});

test("επαλήθευση URL από Meta", async () => {
  let out = ""; let st = 0;
  await fns.waWebhook({ method: "GET", query: { "hub.mode": "subscribe", "hub.verify_token": "vt", "hub.challenge": "1234" } }, { status(s) { st = s; return this; }, send(x) { out = x; return this; } });
  assert.strictEqual(st, 200); assert.strictEqual(out, "1234");
});
