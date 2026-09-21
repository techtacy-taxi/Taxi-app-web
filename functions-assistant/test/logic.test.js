const test = require("node:test");
const assert = require("node:assert");
const crypto = require("crypto");

const cfgLib = require("../lib/config");
const booking = require("../lib/booking");
const claude = require("../lib/claude");
const wa = require("../lib/whatsapp");

const cfg = cfgLib.withDefaults({ enabled: true });

test("χώρα από αριθμό", () => {
  assert.strictEqual(wa.countryOf("306936123322"), "GR");
  assert.strictEqual(wa.countryOf("447400123456"), "GB");
  assert.strictEqual(wa.countryOf("4915112345678"), "DE");
  assert.strictEqual(wa.countryOf("000"), "XX");
});

test("κανόνες: ελληνικός → άνθρωπος, ξένος → συλλογή", () => {
  assert.strictEqual(cfgLib.decideAction(cfg, { country: "GR", text: "καλησπέρα" }).action, "human_only");
  assert.strictEqual(cfgLib.decideAction(cfg, { country: "GB", text: "hello" }).action, "collect");
});

test("κανόνες: λέξεις κλειδιά παράπονο/ακύρωση περνούν σε άνθρωπο (και με τόνους/κεφαλαία)", () => {
  assert.match(cfgLib.decideAction(cfg, { country: "GB", text: "I want a REFUND" }).reason, /^escalate/);
  assert.match(cfgLib.decideAction(cfg, { country: "GB", text: "ΑΚΥΡΩΣΗ παρακαλώ" }).reason, /^escalate/);
});

test("κανόνες tenant: δικός του κανόνας για DE → auto, απενεργοποιημένος κανόνας αγνοείται", () => {
  const c = cfgLib.withDefaults({ rules: [
    { id: "de", enabled: true, match: { countries: ["DE"] }, action: "auto" },
    { id: "off", enabled: false, match: { countries: ["*"] }, action: "auto" },
  ], defaultAction: "human_only" });
  assert.strictEqual(cfgLib.decideAction(c, { country: "DE", text: "hallo" }).action, "auto");
  assert.strictEqual(cfgLib.decideAction(c, { country: "FR", text: "salut" }).action, "human_only");
});

test("ωράριο", () => {
  const c = cfgLib.withDefaults({ workingHours: { enabled: true, tz: "Europe/Athens", start: "08:00", end: "23:00" } });
  assert.strictEqual(cfgLib.isOffHours(c, new Date("2026-09-20T09:00:00Z")), false); // 12:00 Αθήνα
  assert.strictEqual(cfgLib.isOffHours(c, new Date("2026-09-20T02:00:00Z")), true);  // 05:00 Αθήνα
});

test("προσχέδιο: πληρότητα και υπό συνθήκη πτήση", () => {
  let d = booking.mergeDraft(cfg, {}, { from: "Airport", to: "Plaka", date: "2026-10-12", time: "14:30", persons: "3", luggage: "2" }, true);
  assert.deepStrictEqual(booking.missingFields(cfg, d), ["flightOrShip"]);
  d = booking.mergeDraft(cfg, d, { flightOrShip: "A3 123" }, true);
  assert.strictEqual(booking.isComplete(cfg, d), true);
  const d2 = booking.mergeDraft(cfg, d, {}, false);
  assert.strictEqual(booking.isComplete(cfg, d2), true);
  assert.match(booking.summary(cfg, d), /Από: Airport/);
});

test("προσχέδιο: κενές τιμές δεν σβήνουν υπάρχουσες", () => {
  const d = booking.mergeDraft(cfg, { from: "A" }, { from: "", to: "B" });
  assert.strictEqual(d.from, "A");
  assert.strictEqual(d.to, "B");
});

test("φράγμα: τιμή και επιβεβαίωση μπλοκάρονται, ουδέτερο περνά", () => {
  assert.strictEqual(claude.violatesGuardrails("The price is 45€"), "price");
  assert.strictEqual(claude.violatesGuardrails("It costs 40 euro"), "price");
  assert.strictEqual(claude.violatesGuardrails("Η τιμή είναι 35 ευρώ"), "price");
  assert.strictEqual(claude.violatesGuardrails("Your booking is confirmed"), "confirmation");
  assert.strictEqual(claude.violatesGuardrails("We are available on that date"), "confirmation");
  assert.strictEqual(claude.violatesGuardrails("Thanks! We will check availability and the price and get back to you shortly."), null);
  assert.strictEqual(claude.violatesGuardrails("Πόσα άτομα θα είστε;"), null);
});

test("μηνύματα προς Claude: εναλλαγή ρόλων, ξεκινά/τελειώνει με user", () => {
  const m = claude.toClaudeMessages([
    { by: "ai", text: "παλιό" },
    { by: "customer", text: "hi" }, { by: "customer", text: "I need a taxi" },
    { by: "ai", text: "Where from?" },
    { by: "customer", text: "Airport" },
  ]);
  assert.deepStrictEqual(m.map((x) => x.role), ["user", "assistant", "user"]);
  assert.strictEqual(m[0].content, "hi\nI need a taxi");
});

test("ανάλυση JSON του μοντέλου (με περιττό κείμενο γύρω)", () => {
  const p = claude.parseModelJson('Εδώ: {"extracted":{"from":"X"},"reply":"ok","needs_human":false} τέλος');
  assert.strictEqual(p.extracted.from, "X");
  assert.strictEqual(claude.parseModelJson("τίποτα"), null);
});

test("prompt περιέχει τα όρια πλατφόρμας και τα πεδία του tenant", () => {
  const p = claude.buildSystemPrompt(cfg, { from: "X" }, ["to"], "collect");
  assert.match(p, /ΔΕΝ αναφέρεις τιμή/);
  assert.match(p, /- to:/);
  assert.match(p, /ΛΕΙΠΟΥΝ ΑΚΟΜΑ: to/);
});

test("υπογραφή webhook", () => {
  const body = Buffer.from('{"a":1}');
  const good = "sha256=" + crypto.createHmac("sha256", "s3cret").update(body).digest("hex");
  assert.strictEqual(wa.verifySignature(body, good, "s3cret"), true);
  assert.strictEqual(wa.verifySignature(body, good, "άλλο"), false);
  assert.strictEqual(wa.verifySignature(body, "sha256=00", "s3cret"), false);
  assert.strictEqual(wa.verifySignature(body, undefined, "s3cret"), false);
});

test("εξαγωγή κειμένου μηνύματος", () => {
  assert.deepStrictEqual(wa.extractText({ type: "text", text: { body: "hi" } }), { text: "hi", supported: true });
  assert.strictEqual(wa.extractText({ type: "audio" }).supported, false);
  assert.strictEqual(wa.extractText({ type: "interactive", interactive: { button_reply: { title: "Yes" } } }).text, "Yes");
});
