// lib/whatsapp.js — έλεγχος υπογραφής webhook, αποστολή μηνύματος, κράτηση χώρας.

const crypto = require("crypto");
const { parsePhoneNumberFromString } = require("libphonenumber-js");

const GRAPH = "https://graph.facebook.com/v25.0";

function verifySignature(rawBody, header, appSecret) {
  if (!rawBody || !header || !appSecret) return false;
  const expected = "sha256=" + crypto.createHmac("sha256", appSecret).update(rawBody).digest("hex");
  const a = Buffer.from(expected);
  const b = Buffer.from(String(header));
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

// wa_id (π.χ. "306936123322") → "GR". Άγνωστο → "XX".
function countryOf(waId) {
  try {
    const p = parsePhoneNumberFromString("+" + String(waId).replace(/^\+/, ""));
    return (p && p.country) || "XX";
  } catch (_) {
    return "XX";
  }
}

async function sendText({ phoneNumberId, token, to, body }) {
  const resp = await fetch(`${GRAPH}/${phoneNumberId}/messages`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      messaging_product: "whatsapp",
      recipient_type: "individual",
      to,
      type: "text",
      text: { body, preview_url: false },
    }),
  });
  const data = await resp.json().catch(() => ({}));
  if (!resp.ok) throw new Error("WhatsApp send " + resp.status + " " + JSON.stringify(data.error || data).slice(0, 300));
  return data.messages && data.messages[0] && data.messages[0].id;
}

// Εξαγωγή κειμένου από μήνυμα Meta. supported=false → πρέπει να το δει άνθρωπος.
function extractText(msg) {
  switch (msg.type) {
    case "text":        return { text: (msg.text && msg.text.body) || "", supported: true };
    case "button":      return { text: (msg.button && msg.button.text) || "", supported: true };
    case "interactive": {
      const i = msg.interactive || {};
      const r = i.button_reply || i.list_reply || {};
      return { text: r.title || "", supported: true };
    }
    case "image": case "video": case "document":
      return { text: `[${msg.type}]${(msg[msg.type] && msg[msg.type].caption) ? " " + msg[msg.type].caption : ""}`, supported: false };
    case "location":    return { text: "[τοποθεσία]", supported: false };
    case "audio":       return { text: "[φωνητικό μήνυμα]", supported: false };
    default:            return { text: `[${msg.type || "άγνωστο"}]`, supported: false };
  }
}

module.exports = { GRAPH, verifySignature, countryOf, sendText, extractText };
