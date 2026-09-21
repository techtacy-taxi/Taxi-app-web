// functions-assistant/index.js
// ─────────────────────────────────────────────────────────────────────────────
//  ΒΟΗΘΟΣ WHATSAPP — ξεχωριστό codebase ("assistant"), δεν αγγίζει το functions/.
//
//  Ροή:  Meta → waWebhook → (κανόνες tenant) → Claude Haiku → απάντηση/πρόχειρο
//  • Αναγνωρίζει τον tenant από το phone_number_id (assistant_config/*.whatsapp).
//  • Ελληνικοί αριθμοί: όπως ορίζουν οι κανόνες (προεπιλογή: μόνο άνθρωπος).
//    Ξένοι: το AI μαζεύει τα στοιχεία κράτησης, ΔΕΝ λέει ποτέ τιμή/διαθεσιμότητα.
//  • Όταν το προσχέδιο είναι πλήρες → ειδοποίηση στον master/tenantOwner του tenant.
//  • Όταν ο ιδιοκτήτης απαντήσει από την εφαρμογή WhatsApp Business (echo) →
//    το AI σταματά για humanPauseHours ώρες.
//  • Κάθε κλήση Claude περνά από το recordUsage (μετρητής χρέωσης ανά tenant).
//
//  Firestore:
//    assistant_config/{tenantId}            ρυθμίσεις/κανόνες (επεξεργάζεται ο tenant)
//    wa_conversations/{tenantId__phone}     συνομιλία + προσχέδιο κράτησης
//    wa_conversations/{id}/messages/{wamid} μηνύματα
//    wa_stats/{tenantId}/daily/{YYYY-MM-DD} στατιστικά ανά χώρα
//  Secrets: WA_VERIFY_TOKEN, WA_APP_SECRET, ANTHROPIC_API_KEY (πλατφόρμας)
//           tenant-{id}-wa-token (Secret Manager), tenant-{id}-anthropic-key (προαιρετικό)
// ─────────────────────────────────────────────────────────────────────────────

const { onRequest, onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const { initializeApp } = require("firebase-admin/app");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");

const { withDefaults, decideAction, isOffHours } = require("./lib/config");
const { mergeDraft, missingFields, isComplete, summary } = require("./lib/booking");
const { buildSystemPrompt, toClaudeMessages, violatesGuardrails, parseModelJson, callClaude } = require("./lib/claude");
const { verifySignature, countryOf, sendText, extractText } = require("./lib/whatsapp");
const { tenantSecretId, readSecret } = require("./lib/secrets");
const { recordUsage, claudeUsage } = require("./lib/usage");

initializeApp();

const WA_VERIFY_TOKEN   = defineSecret("WA_VERIFY_TOKEN");
const WA_APP_SECRET     = defineSecret("WA_APP_SECRET");
const ANTHROPIC_API_KEY = defineSecret("ANTHROPIC_API_KEY");

const SUPER_ADMIN_EMAIL = "techtacy@gmail.com";
const HOUR = 3600 * 1000;

// ── Μικρά βοηθητικά ─────────────────────────────────────────────────────────
const _cache = new Map();
async function cached(key, ttlMs, loader) {
  const hit = _cache.get(key);
  if (hit && Date.now() - hit.t < ttlMs) return hit.v;
  const v = await loader();
  _cache.set(key, { t: Date.now(), v });
  return v;
}

function dayKey() {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Athens" }).format(new Date()); // YYYY-MM-DD
}

const millis = (t) => (t && typeof t.toMillis === "function" ? t.toMillis() : 0);

async function tenantByPhoneNumberId(phoneNumberId) {
  if (!phoneNumberId) return null;
  return cached("pn:" + phoneNumberId, 60 * 1000, async () => {
    const snap = await getFirestore().collection("assistant_config")
      .where("whatsapp.phoneNumberId", "==", String(phoneNumberId)).limit(1).get();
    return snap.empty ? null : snap.docs[0].id;
  });
}

async function loadConfig(tenantId) {
  return cached("cfg:" + tenantId, 30 * 1000, async () => {
    const s = await getFirestore().collection("assistant_config").doc(tenantId).get();
    return s.exists ? { ...withDefaults(s.data()), _whatsapp: s.data().whatsapp || {} } : null;
  });
}

async function billingSettings(tenantId) {
  return cached("bs:" + tenantId, 60 * 1000, async () => {
    const s = await getFirestore().collection("tenants").doc(tenantId).collection("billing").doc("settings").get();
    return s.exists ? s.data() : {};
  });
}

async function claudeKeyFor(tenantId) {
  const tb = await billingSettings(tenantId);
  if (tb.ownKeys && tb.ownKeys.claude === true) {
    return await readSecret(tenantSecretId(tenantId, "anthropic-key")); // δικό του κλειδί — ποτέ το δικό μας
  }
  return ANTHROPIC_API_KEY.value();
}

// ── Στατιστικά ανά χώρα (φωλιασμένα πεδία — ΟΧΙ κλειδιά με τελεία) ───────────
async function bumpStats(tenantId, country, inc) {
  try {
    const c = {};
    for (const [k, v] of Object.entries(inc)) c[k] = FieldValue.increment(v);
    await getFirestore().collection("wa_stats").doc(tenantId).collection("daily").doc(dayKey())
      .set({ byCountry: { [country || "XX"]: c }, updatedAt: FieldValue.serverTimestamp() }, { merge: true });
  } catch (e) {
    console.error("bumpStats:", e && e.message ? e.message : e);
  }
}

// ── Ειδοποίηση στον master/tenantOwner του tenant (ορατή ειδοποίηση συστήματος) ─
async function notifyTenant(tenantId, title, body, conversationId) {
  try {
    const db = getFirestore();
    // Μόνο όσοι μπορούν να δουν τις συνομιλίες (master / tenantOwner του tenant).
    const qs = await Promise.all([
      db.collection("presence").where("master", "==", true).get(),
      db.collection("presence").where("tenantOwner", "==", true).get(),
    ]);
    const tokens = new Set();
    for (const snap of qs) {
      for (const d of snap.docs) {
        const p = d.data();
        if ((p.tenantId || "default") === tenantId && p.fcmToken) tokens.add(p.fcmToken);
      }
    }
    if (!tokens.size) return;
    await getMessaging().sendEachForMulticast({
      tokens: [...tokens],
      notification: { title, body },
      data: { type: "assistant", conversationId: String(conversationId || "") },
      android: { priority: "high" },
    });
  } catch (e) {
    console.error("notifyTenant:", e && e.message ? e.message : e);
  }
}

// ── Πρώτη απάντηση (για στατιστικό χρόνου απόκρισης) ────────────────────────
async function markFirstResponse(convRef, conv, tenantId, country) {
  if (conv.firstResponseAt || !conv.firstInboundAt) return;
  const ms = Math.max(0, Date.now() - millis(conv.firstInboundAt));
  await convRef.set({ firstResponseAt: Timestamp.now(), responseMs: ms }, { merge: true });
  await bumpStats(tenantId, country, { responded: 1, responseMsTotal: ms });
}

// ════════════════════════════════════════════════════════════════════════════
//  Εισερχόμενο μήνυμα πελάτη
// ════════════════════════════════════════════════════════════════════════════
async function handleInbound({ msg, contactName, phoneNumberId }) {
  const db = getFirestore();
  const tenantId = await tenantByPhoneNumberId(phoneNumberId);
  if (!tenantId) { console.warn("handleInbound: άγνωστο phone_number_id", phoneNumberId); return; }
  const config = await loadConfig(tenantId);
  if (!config || config.enabled !== true) return;

  const waId = String(msg.from || "");
  const country = countryOf(waId);
  const convId = `${tenantId}__${waId}`;
  const convRef = db.collection("wa_conversations").doc(convId);
  const ts = Timestamp.fromMillis(Number(msg.timestamp || 0) * 1000 || Date.now());
  const { text, supported } = extractText(msg);

  // 1) Αποθήκευση μηνύματος (idempotent: το ίδιο wamid δεν ξαναεπεξεργάζεται).
  const msgRef = convRef.collection("messages").doc(String(msg.id));
  try {
    await msgRef.create({ tenantId, dir: "in", by: "customer", type: msg.type || "text", text, waId, ts });
  } catch (e) {
    if (e && (e.code === 6 || /ALREADY_EXISTS/i.test(String(e.message)))) return;
    throw e;
  }

  // 2) Συνομιλία: ανάγνωση + ενημέρωση. Παλιά ολοκληρωμένη συνομιλία → νέο νήμα.
  const snap = await convRef.get();
  let conv = snap.exists ? snap.data() : {};
  const isNewConv = !snap.exists;
  let newThread = isNewConv;
  if (!isNewConv && ["booked", "closed"].includes(conv.status) &&
      Date.now() - millis(conv.lastInboundAt) > 12 * HOUR) {
    conv = { ...conv, status: "collecting", draft: {}, notifiedReadyAt: null, pendingReply: null, firstResponseAt: null, firstInboundAt: null };
    newThread = true;
    await convRef.set({ status: "collecting", draft: {}, notifiedReadyAt: null, pendingReply: null,
      firstResponseAt: null, firstInboundAt: null }, { merge: true });
  }
  const now = Timestamp.now();
  const base = {
    tenantId, phone: waId, country, lastMessageAt: now, lastInboundAt: now, unread: true,
    ...(contactName ? { name: contactName } : {}),
    ...(isNewConv ? { createdAt: now, status: "collecting" } : {}),
    ...(newThread ? { firstInboundAt: now } : {}),
  };
  await convRef.set(base, { merge: true });
  conv = { ...conv, ...base };
  await bumpStats(tenantId, country, { messages: 1, ...(newThread ? { conversations: 1 } : {}) });

  // 3) Ποιος απαντά;
  const ctx = { country, text, offHours: isOffHours(config) };
  let decision = decideAction(config, ctx);
  const humanActive = millis(conv.humanUntil) > Date.now();
  if (humanActive) return;                                            // ο ιδιοκτήτης μιλά ήδη
  if (["booked"].includes(conv.status)) decision = { action: "human_only", reason: "booked" };
  if (!supported) decision = { action: "human_only", reason: "unsupported_type" };
  if (decision.action === "human_only") {
    if (decision.reason.startsWith("escalate")) {
      await convRef.set({ status: "human", handledBy: "human" }, { merge: true });
      await maybeNotifyHuman(tenantId, convRef, conv, convId, "Χρειάζεται εσένα", `${conv.name || waId}: ${text.slice(0, 90)}`);
    }
    return;
  }
  if (config.offHoursReply && ctx.offHours && conv.offHoursSentAt === undefined) {
    // Εκτός ωραρίου: μία φορά ανά νήμα στέλνουμε το προκαθορισμένο μήνυμα.
    await sendAndStore({ tenantId, convRef, conv, waId, country, phoneNumberId, text: config.offHoursReply, by: "ai" });
    await convRef.set({ offHoursSentAt: Timestamp.now() }, { merge: true });
  }

  // 4) Βοηθός (Claude)
  await runAssistant({ tenantId, config, conv, convRef, convId, waId, country, phoneNumberId, action: decision.action });
}

async function maybeNotifyHuman(tenantId, convRef, conv, convId, title, body) {
  if (Date.now() - millis(conv.lastNotifiedAt) < 30 * 60 * 1000) return;
  await convRef.set({ lastNotifiedAt: Timestamp.now() }, { merge: true });
  await notifyTenant(tenantId, title, body, convId);
}

async function sendAndStore({ tenantId, convRef, conv, waId, country, phoneNumberId, text, by }) {
  const token = await readSecret(tenantSecretId(tenantId, "wa-token"));
  if (!token) throw new Error("Λείπει το wa-token του tenant " + tenantId);
  const id = await sendText({ phoneNumberId, token, to: waId, body: text });
  await convRef.collection("messages").doc(String(id || `out_${Date.now()}`)).set({
    tenantId, dir: "out", by, type: "text", text, waId, ts: Timestamp.now(),
  });
  await convRef.set({ lastMessageAt: Timestamp.now() }, { merge: true });
  await recordUsage(tenantId, "whatsapp", { units: 1, costEur: 0 });   // υπηρεσιακό μήνυμα: χωρίς χρέωση Meta
  if (by === "ai") await bumpStats(tenantId, country, { aiReplies: 1 });
  await markFirstResponse(convRef, conv, tenantId, country);
  return id;
}

async function runAssistant({ tenantId, config, conv, convRef, convId, waId, country, phoneNumberId, action }) {
  const missing = missingFields(config, conv.draft);
  const hist = await convRef.collection("messages").orderBy("ts", "desc").limit(12).get();
  const history = hist.docs.map((d) => d.data()).reverse();
  const messages = toClaudeMessages(history);
  if (!messages.length) return;

  const apiKey = await claudeKeyFor(tenantId);
  if (!apiKey) {
    await convRef.set({ status: "human", handledBy: "human", aiNote: "no_claude_key" }, { merge: true });
    await maybeNotifyHuman(tenantId, convRef, conv, convId, "Ο βοηθός δεν δουλεύει", "Λείπει το κλειδί Claude.");
    return;
  }

  let parsed = null;
  try {
    const system = buildSystemPrompt(config, conv.draft, missing, action === "collect" ? "collect" : "auto");
    const r = await callClaude({ apiKey, system, messages });
    await recordUsage(tenantId, "claude", claudeUsage(r.usage));
    parsed = parseModelJson(r.text);
  } catch (e) {
    console.error("runAssistant Claude:", e && e.message ? e.message : e);
  }
  if (!parsed) {
    await convRef.set({ status: "human", handledBy: "human", aiNote: "ai_failed" }, { merge: true });
    await maybeNotifyHuman(tenantId, convRef, conv, convId, "Χρειάζεται εσένα", `${conv.name || waId}: ο βοηθός δεν κατάφερε να απαντήσει.`);
    return;
  }

  const draft = mergeDraft(config, conv.draft, parsed.extracted, parsed.involves_airport_or_port);
  const complete = isComplete(config, draft);
  let reply = String(parsed.reply || "").trim().slice(0, 1000);
  const violation = violatesGuardrails(reply);
  if (violation) reply = "";
  const needsHuman = parsed.needs_human === true || !!violation;

  const patch = { draft, lang: String(parsed.language || conv.lang || "").slice(0, 8), aiNote: violation ? "guardrail:" + violation : (parsed.reason || "").slice(0, 120) };
  if (complete) patch.status = "ready";
  else if (needsHuman) patch.status = "human";
  else if (conv.status !== "booked") patch.status = "collecting";
  await convRef.set(patch, { merge: true });

  // Απάντηση: auto/collect → αποστολή· draft → πρόχειρο για έγκριση.
  if (reply) {
    if (action === "draft") {
      await convRef.set({ pendingReply: reply }, { merge: true });
    } else {
      try {
        await sendAndStore({ tenantId, convRef, conv, waId, country, phoneNumberId, text: reply, by: "ai" });
      } catch (e) {
        console.error("runAssistant send:", e && e.message ? e.message : e);
        await convRef.set({ pendingReply: reply, aiNote: "send_failed" }, { merge: true });
      }
    }
  }

  // Ειδοποιήσεις
  if (complete && !conv.notifiedReadyAt) {
    await convRef.set({ notifiedReadyAt: Timestamp.now() }, { merge: true });
    await bumpStats(tenantId, country, { complete: 1 });
    await notifyTenant(tenantId, "Νέα κράτηση έτοιμη για εσένα", `${conv.name || waId} (${country}) · ${summary(config, draft)}`, convId);
  } else if (needsHuman) {
    await maybeNotifyHuman(tenantId, convRef, conv, convId, "Χρειάζεται εσένα", `${conv.name || waId}: ${violation ? "μπλοκαρίστηκε απάντηση με τιμή/διαθεσιμότητα" : (parsed.reason || "ζητά άνθρωπο")}`);
  }
}

// ════════════════════════════════════════════════════════════════════════════
//  Μήνυμα που έστειλε ο ίδιος ο ιδιοκτήτης από την εφαρμογή WhatsApp Business
// ════════════════════════════════════════════════════════════════════════════
async function handleEcho({ echo, phoneNumberId }) {
  const db = getFirestore();
  const tenantId = await tenantByPhoneNumberId(phoneNumberId);
  if (!tenantId) return;
  const config = await loadConfig(tenantId);
  if (!config || config.enabled !== true) return;

  const waId = String(echo.to || "");
  const country = countryOf(waId);
  const convRef = db.collection("wa_conversations").doc(`${tenantId}__${waId}`);
  const { text } = extractText(echo);
  try {
    await convRef.collection("messages").doc(String(echo.id)).create({
      tenantId, dir: "out", by: "human", type: echo.type || "text", text, waId,
      ts: Timestamp.fromMillis(Number(echo.timestamp || 0) * 1000 || Date.now()),
    });
  } catch (e) {
    if (e && (e.code === 6 || /ALREADY_EXISTS/i.test(String(e.message)))) return;   // δικό μας μήνυμα (API) — αγνόησέ το
    throw e;
  }
  const snap = await convRef.get();
  const conv = snap.exists ? snap.data() : {};
  await convRef.set({
    tenantId, phone: waId, country, handledBy: "human", unread: false, pendingReply: null,
    lastMessageAt: Timestamp.now(),
    humanUntil: Timestamp.fromMillis(Date.now() + (Number(config.humanPauseHours) || 6) * HOUR),
  }, { merge: true });
  await markFirstResponse(convRef, conv, tenantId, country);
}

// ════════════════════════════════════════════════════════════════════════════
//  WEBHOOK (Meta)
// ════════════════════════════════════════════════════════════════════════════
exports.waWebhook = onRequest(
  { region: "us-central1", secrets: [WA_VERIFY_TOKEN, WA_APP_SECRET, ANTHROPIC_API_KEY],
    memory: "512MiB", timeoutSeconds: 120, maxInstances: 10 },
  async (req, res) => {
    // Επαλήθευση URL από τη Meta
    if (req.method === "GET") {
      if (req.query["hub.mode"] === "subscribe" && req.query["hub.verify_token"] === WA_VERIFY_TOKEN.value()) {
        return res.status(200).send(String(req.query["hub.challenge"] || ""));
      }
      return res.status(403).send("forbidden");
    }
    if (req.method !== "POST") return res.status(405).send("method not allowed");

    if (!verifySignature(req.rawBody, req.get("x-hub-signature-256"), WA_APP_SECRET.value())) {
      console.warn("waWebhook: άκυρη υπογραφή");
      return res.status(401).send("bad signature");
    }

    const body = req.body || {};
    try {
      for (const entry of body.entry || []) {
        for (const ch of entry.changes || []) {
          const v = ch.value || {};
          const pnid = v.metadata && v.metadata.phone_number_id;
          if (ch.field === "messages") {
            const name = v.contacts && v.contacts[0] && v.contacts[0].profile && v.contacts[0].profile.name;
            for (const m of v.messages || []) {
              try { await handleInbound({ msg: m, contactName: name, phoneNumberId: pnid }); }
              catch (e) { console.error("handleInbound:", e && e.stack ? e.stack : e); }
            }
          } else if (ch.field === "smb_message_echoes") {
            for (const e of v.message_echoes || []) {
              try { await handleEcho({ echo: e, phoneNumberId: pnid }); }
              catch (err) { console.error("handleEcho:", err && err.stack ? err.stack : err); }
            }
          }
          // history / smb_app_state_sync: θα διαβαστούν σε επόμενη φάση (εισαγωγή ιστορικού).
        }
      }
    } catch (e) {
      console.error("waWebhook:", e && e.stack ? e.stack : e);
    }
    return res.status(200).send("ok");
  }
);

// ════════════════════════════════════════════════════════════════════════════
//  Αποστολή απάντησης από την εφαρμογή (πρόχειρο βοηθού ή δική σου)
// ════════════════════════════════════════════════════════════════════════════
exports.waSendReply = onCall({ region: "us-central1" }, async (request) => {
  const uid = request.auth && request.auth.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Απαιτείται σύνδεση.");
  const conversationId = String((request.data && request.data.conversationId) || "");
  const text = String((request.data && request.data.text) || "").trim().slice(0, 1000);
  if (!conversationId || !text) throw new HttpsError("invalid-argument", "Λείπει συνομιλία ή κείμενο.");

  const db = getFirestore();
  const convRef = db.collection("wa_conversations").doc(conversationId);
  const conv = (await convRef.get()).data();
  if (!conv) throw new HttpsError("not-found", "Δεν βρέθηκε η συνομιλία.");

  const isSuper = request.auth.token.email === SUPER_ADMIN_EMAIL;
  if (!isSuper) {
    const p = (await db.collection("presence").doc(uid).get()).data() || {};
    const sameTenant = (p.tenantId || "default") === conv.tenantId;
    if (!(sameTenant && (p.master === true || p.tenantOwner === true))) {
      throw new HttpsError("permission-denied", "Δεν έχεις πρόσβαση σε αυτή τη συνομιλία.");
    }
  }
  if (Date.now() - millis(conv.lastInboundAt) > 24 * HOUR) {
    throw new HttpsError("failed-precondition", "outside_window");   // εκτός 24ώρου: χρειάζεται template
  }
  const cfg = await loadConfig(conv.tenantId);
  const phoneNumberId = cfg && cfg._whatsapp && cfg._whatsapp.phoneNumberId;
  if (!phoneNumberId) throw new HttpsError("failed-precondition", "Δεν έχει συνδεθεί WhatsApp.");

  const id = await sendAndStore({ tenantId: conv.tenantId, convRef, conv, waId: conv.phone,
    country: conv.country, phoneNumberId, text, by: "human" });
  await convRef.set({
    handledBy: "human", unread: false, pendingReply: null,
    humanUntil: Timestamp.fromMillis(Date.now() + ((cfg && Number(cfg.humanPauseHours)) || 6) * HOUR),
  }, { merge: true });
  return { ok: true, id };
});

