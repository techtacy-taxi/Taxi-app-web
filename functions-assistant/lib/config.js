// lib/config.js — προεπιλογές ρυθμίσεων βοηθού + κανόνες «ποιος απαντά».
// Τα δεδομένα ζουν στο Firestore: assistant_config/{tenantId}. Κάθε tenant τα
// αλλάζει από την εφαρμογή· εδώ είναι μόνο οι προεπιλογές και η λογική.

const DEFAULT_FIELDS = [
  { key: "from",         label: "Από (σημείο παραλαβής)",  required: true },
  { key: "to",           label: "Προς (προορισμός)",        required: true },
  { key: "date",         label: "Ημερομηνία",               required: true },
  { key: "time",         label: "Ώρα παραλαβής",            required: true },
  { key: "persons",      label: "Αριθμός ατόμων",           required: true },
  { key: "luggage",      label: "Αριθμός βαλιτσών",         required: true },
  { key: "flightOrShip", label: "Πτήση ή όνομα πλοίου (ΜΟΝΟ αν η παραλαβή ή ο προορισμός είναι αεροδρόμιο/λιμάνι)", required: false, conditional: true },
  { key: "name",         label: "Όνομα επιβάτη",            required: false },
  { key: "notes",        label: "Σχόλια (π.χ. παιδικό κάθισμα)", required: false },
];

const DEFAULT_RULES = [
  { id: "gr",      name: "Ελληνικοί αριθμοί (+30)", enabled: true, match: { countries: ["GR"] }, action: "human_only" },
  { id: "foreign", name: "Ξένοι αριθμοί",           enabled: true, match: { countries: ["*"] },  action: "collect" },
];

const DEFAULT_ESCALATE = [
  "παράπονο", "παραπονο", "ακύρωση", "ακυρωση", "επιστροφή χρημάτων", "επιστροφη χρηματων",
  "complaint", "cancel", "refund", "money back", "lawyer", "police",
];

function defaultConfig() {
  return {
    enabled: false,
    defaultAction: "human_only",
    fields: DEFAULT_FIELDS,
    rules: DEFAULT_RULES,
    escalateKeywords: DEFAULT_ESCALATE,
    tone: "Ευγενικός, σύντομος και επαγγελματίας. Απαντάς στη γλώσσα του πελάτη.",
    signature: "",
    examples: [],
    faq: "",
    humanPauseHours: 6,
    workingHours: { enabled: false, tz: "Europe/Athens", start: "08:00", end: "23:00" },
    offHoursReply: "",
  };
}

// Συγχώνευση προεπιλογών με ό,τι έχει αποθηκεύσει ο tenant.
function withDefaults(data) {
  const d = defaultConfig();
  const c = { ...d, ...(data || {}) };
  if (!Array.isArray(c.fields) || !c.fields.length) c.fields = d.fields;
  if (!Array.isArray(c.rules)) c.rules = d.rules;
  if (!Array.isArray(c.escalateKeywords)) c.escalateKeywords = d.escalateKeywords;
  c.workingHours = { ...d.workingHours, ...(c.workingHours || {}) };
  return c;
}

// Χωρίς κεφαλαία / τόνους, για σύγκριση λέξεων.
function norm(s) {
  return String(s || "").toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "");
}

function isOffHours(config, date = new Date()) {
  const w = config.workingHours || {};
  if (!w.enabled) return false;
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: w.tz || "Europe/Athens", hour: "2-digit", minute: "2-digit", hourCycle: "h23",
  }).formatToParts(date);
  const hh = Number(parts.find((p) => p.type === "hour").value);
  const mm = Number(parts.find((p) => p.type === "minute").value);
  const cur = hh * 60 + mm;
  const toMin = (t) => { const [h, m] = String(t || "0:0").split(":").map(Number); return (h || 0) * 60 + (m || 0); };
  const s = toMin(w.start), e = toMin(w.end);
  const inside = s <= e ? (cur >= s && cur < e) : (cur >= s || cur < e);
  return !inside;
}

function matchRule(rule, ctx) {
  if (!rule || rule.enabled === false) return false;
  const m = rule.match || {};
  if (Array.isArray(m.countries) && m.countries.length) {
    const cc = String(ctx.country || "").toUpperCase();
    if (!m.countries.some((c) => c === "*" || String(c).toUpperCase() === cc)) return false;
  }
  if (Array.isArray(m.keywords) && m.keywords.length) {
    const t = norm(ctx.text);
    if (!m.keywords.some((k) => t.includes(norm(k)))) return false;
  }
  if (m.offHours === true && !ctx.offHours) return false;
  if (m.offHours === false && ctx.offHours) return false;
  return true;
}

// Επιστρέφει { action, reason, rule }.
// action: human_only | collect | auto | draft
function decideAction(config, ctx) {
  const t = norm(ctx.text);
  const hit = (config.escalateKeywords || []).find((k) => k && t.includes(norm(k)));
  if (hit) return { action: "human_only", reason: "escalate:" + hit };
  for (const r of config.rules || []) {
    if (matchRule(r, ctx)) return { action: r.action || "human_only", reason: "rule:" + (r.id || r.name), rule: r };
  }
  return { action: config.defaultAction || "human_only", reason: "default" };
}

module.exports = { DEFAULT_FIELDS, DEFAULT_RULES, DEFAULT_ESCALATE, defaultConfig, withDefaults, norm, isOffHours, matchRule, decideAction };
