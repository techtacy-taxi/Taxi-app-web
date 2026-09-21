// lib/claude.js — prompt, κλήση στο Claude Haiku 4.5, ανάλυση απάντησης, φράγμα ασφαλείας.

const MODEL = "claude-haiku-4-5-20251001";

// ── Όρια της ΠΛΑΤΦΟΡΜΑΣ — ο tenant ΔΕΝ τα αλλάζει από τις ρυθμίσεις του ──────
const PLATFORM_RULES = `
ΟΡΙΑ ΠΟΥ ΔΕΝ ΠΑΡΑΒΙΑΖΟΝΤΑΙ ΠΟΤΕ:
- ΔΕΝ αναφέρεις τιμή, κόστος ή έκπτωση, ούτε εκτίμηση κόστους.
- ΔΕΝ επιβεβαιώνεις διαθεσιμότητα οχήματος ή οδηγού και ΔΕΝ λες ότι η κράτηση «έκλεισε».
- ΔΕΝ ζητάς στοιχεία κάρτας, κωδικούς ή προσωπικά έγγραφα.
- ΔΕΝ επινοείς πληροφορίες. Αν δεν ξέρεις κάτι, λες ότι θα απαντήσει η ομάδα.
- Απαντάς ΠΑΝΤΑ στη γλώσσα του πελάτη, σε το πολύ 60 λέξεις, με ένα μόνο ερώτημα κάθε φορά.
- Όταν έχουν συλλεχθεί ΟΛΑ τα απαραίτητα στοιχεία, ευχαριστείς και λες ότι θα ελέγξετε και θα επικοινωνήσετε σύντομα με διαθεσιμότητα και τιμή.
- Αν ο πελάτης είναι εκνευρισμένος, ζητά κάτι εκτός των δυνατοτήτων σου ή θέλει άνθρωπο, θέτεις needs_human=true.`;

function buildSystemPrompt(config, draft, missing, mode) {
  const fields = (config.fields || []).map((f) => {
    const req = f.conditional ? "υποχρεωτικό μόνο αν εμπλέκεται αεροδρόμιο/λιμάνι" : (f.required ? "υποχρεωτικό" : "προαιρετικό");
    return `- ${f.key}: ${f.label} (${req})`;
  }).join("\n");
  const examples = (config.examples || []).slice(0, 6).map((e, i) =>
    `Παράδειγμα ${i + 1}:\nΠελάτης: ${e.q}\nΑπάντηση: ${e.a}`).join("\n\n");
  const modeTxt = mode === "collect"
    ? "ΛΕΙΤΟΥΡΓΙΑ: μόνο συλλογή στοιχείων κράτησης. Για οτιδήποτε άλλο λες ότι θα απαντήσει η ομάδα."
    : "ΛΕΙΤΟΥΡΓΙΑ: συλλογή στοιχείων κράτησης και απαντήσεις σε γενικές ερωτήσεις, ΜΟΝΟ από τις «Πληροφορίες» παρακάτω.";
  return [
    "Είσαι ο βοηθός μιας υπηρεσίας μεταφορών (ταξί/transfer) στην Ελλάδα και απαντάς σε μηνύματα WhatsApp.",
    PLATFORM_RULES,
    modeTxt,
    `ΥΦΟΣ: ${config.tone || ""}`,
    config.faq ? `ΠΛΗΡΟΦΟΡΙΕΣ (μόνη πηγή για γενικές ερωτήσεις):\n${config.faq}` : "",
    `ΣΤΟΙΧΕΙΑ ΚΡΑΤΗΣΗΣ ΠΟΥ ΖΗΤΑΣ:\n${fields}`,
    `ΤΡΕΧΟΝ ΠΡΟΣΧΕΔΙΟ: ${JSON.stringify(draft || {})}`,
    `ΛΕΙΠΟΥΝ ΑΚΟΜΑ: ${missing.length ? missing.join(", ") : "τίποτα"}`,
    examples,
    "Εξάγεις στο extracted ΜΟΝΟ όσα ο πελάτης έχει πει ρητά (ποτέ εικασίες). Ημερομηνία σε μορφή ΕΕΕΕ-ΜΜ-ΗΗ αν είναι σαφής, ώρα ΩΩ:ΛΛ.",
    'Απάντησε ΜΟΝΟ με JSON, χωρίς άλλο κείμενο: {"extracted":{<key>:"τιμή"},"involves_airport_or_port":true|false,"language":"el|en|...","reply":"κείμενο ή κενό","needs_human":true|false,"reason":"σύντομα"}',
  ].filter(Boolean).join("\n\n");
}

// Ιστορικό → μηνύματα Anthropic (εναλλασσόμενοι ρόλοι, ξεκινά με user, τελειώνει με user).
function toClaudeMessages(history) {
  const out = [];
  for (const m of history) {
    const role = m.by === "customer" ? "user" : "assistant";
    const text = String(m.text || "").trim();
    if (!text) continue;
    if (out.length && out[out.length - 1].role === role) out[out.length - 1].content += "\n" + text;
    else out.push({ role, content: text });
  }
  while (out.length && out[0].role !== "user") out.shift();
  while (out.length && out[out.length - 1].role !== "user") out.pop();
  return out;
}

// Φράγμα: μπλοκάρει αριθμητική τιμή ή επιβεβαίωση διαθεσιμότητας/κράτησης.
const PRICE_RE = /(?:€|£|\$)\s?\d|\d\s?(?:€|£|\$|eur\b|euro\b|euros\b|ευρώ|ευρω|gbp\b|usd\b)/i;
const CONFIRM_RE = /(?:is|are|will be)\s+available|booking\s+(?:is\s+)?confirmed|(?:is|has been)\s+confirmed|είμαστε\s+διαθέσιμοι|είναι\s+διαθέσιμ|κράτηση\s+(?:έχει\s+)?(?:επιβεβαιώθηκε|κλείστηκε|έκλεισε)|έχει\s+επιβεβαιωθεί/i;

function violatesGuardrails(reply) {
  const r = String(reply || "");
  if (PRICE_RE.test(r)) return "price";
  if (CONFIRM_RE.test(r)) return "confirmation";
  return null;
}

function parseModelJson(text) {
  const m = String(text || "").match(/\{[\s\S]*\}/);
  if (!m) return null;
  try { return JSON.parse(m[0]); } catch (_) { return null; }
}

async function callClaude({ apiKey, system, messages }) {
  const resp = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "x-api-key": apiKey, "anthropic-version": "2023-06-01", "content-type": "application/json" },
    body: JSON.stringify({ model: MODEL, max_tokens: 500, temperature: 0.2, system, messages }),
  });
  const data = await resp.json().catch(() => ({}));
  if (!resp.ok) throw new Error("Claude " + resp.status + " " + JSON.stringify(data.error || data).slice(0, 300));
  const text = (data.content || []).filter((c) => c.type === "text").map((c) => c.text).join("");
  return { text, usage: data.usage || {} };
}

module.exports = { MODEL, PLATFORM_RULES, buildSystemPrompt, toClaudeMessages, violatesGuardrails, parseModelJson, callClaude };
