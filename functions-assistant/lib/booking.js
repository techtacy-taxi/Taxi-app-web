// lib/booking.js — προσχέδιο κράτησης: συγχώνευση στοιχείων, πληρότητα, σύνοψη.

const MAX_LEN = 200;

function clean(v) {
  if (v === null || v === undefined) return "";
  return String(v).trim().slice(0, MAX_LEN);
}

// Συγχωνεύει ό,τι εξήγαγε το AI στο προσχέδιο. Μόνο μη κενές τιμές αλλάζουν κάτι.
function mergeDraft(config, draft, extracted, involvesAirportOrPort) {
  const out = { ...(draft || {}) };
  const keys = (config.fields || []).map((f) => f.key);
  for (const k of keys) {
    const v = clean(extracted && extracted[k]);
    if (v) out[k] = v;
  }
  if (typeof involvesAirportOrPort === "boolean") out._needsFlight = involvesAirportOrPort;
  return out;
}

// Ποια υποχρεωτικά πεδία λείπουν. Το πεδίο με conditional:true γίνεται
// υποχρεωτικό μόνο αν το AI δήλωσε ότι εμπλέκεται αεροδρόμιο/λιμάνι.
function missingFields(config, draft) {
  const d = draft || {};
  const miss = [];
  for (const f of config.fields || []) {
    const need = f.conditional ? d._needsFlight === true : f.required === true;
    if (need && !clean(d[f.key])) miss.push(f.key);
  }
  return miss;
}

function isComplete(config, draft) {
  return missingFields(config, draft).length === 0;
}

function summary(config, draft) {
  const d = draft || {};
  const parts = [];
  for (const f of config.fields || []) {
    const v = clean(d[f.key]);
    if (v) parts.push(shortLabel(f) + ": " + v);
  }
  return parts.join(" · ");
}

function shortLabel(f) {
  return String(f.label || f.key).replace(/\s*\(.*$/, "");
}

module.exports = { clean, mergeDraft, missingFields, isComplete, summary };
