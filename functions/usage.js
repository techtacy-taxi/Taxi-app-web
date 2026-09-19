// ═══════════════════════════════════════════════════════════════════════════
//  usage.js — Μετρητής χρήσης & κόστους ανά tenant
//
//  Καταγράφει ΜΟΝΟ ό,τι περνάει από τα ΔΙΚΑ ΜΑΣ κλειδιά. Αν ο tenant έχει
//  δικό του κλειδί για την υπηρεσία (ownKeys), δεν καταγράφεται κόστος.
//
//  Firestore:
//    usage/{tenantId}                    → αθροίσματα ΟΛΟΥ του χρόνου
//        costTotalEur, chargeTotalEur
//    usage/{tenantId}/monthly/{YYYY-MM}  → ανά μήνα και ανά υπηρεσία
//        services.{service}: { units, costEur, chargeEur, ownKeyUnits }
//        totalCostEur, totalChargeEur
//    platform/pricing                    → τιμές (rates), επεξεργάσιμες από εσένα
//    tenants/{tenantId}/billing/settings → ρυθμίσεις ΑΝΑ tenant:
//        billingMode: "markup" | "none"
//        markup: { claude: 30, google: 20, resend: 30, aerodatabox: 20, default: 0 }
//        ownKeys: { claude: false, resend: true, google: false, aerodatabox: true }
//        limits: { monthlyUsageEur: 50, warnAtPercent: 80, hardStop: false }
//    tenants/{tenantId}/billing/account  → χειροκίνητα από εσένα (master):
//        creditGrantedEur (πακέτο/προπληρωμή που δόθηκε)
//        paidEur          (ό,τι έχει πληρώσει)
//        feeChargedEur    (μηνιαίες συνδρομές· τις προσθέτει το accrueTenantSubscriptions)
//        Υπόλοιπο = creditGrantedEur + paidEur − chargeTotalEur − feeChargedEur
//        (θετικό = πίστωση που περισσεύει, αρνητικό = οφείλει). ΔΕΝ μηδενίζεται.
//
//  Χρήση:
//    const { recordUsage, tenantIdForUid, claudeUsage } = require("./usage");
//    await recordUsage(tenantId, "resend", { units: 1 });
//    await recordUsage(tenantId, "claude", claudeUsage(resp.usage));
//
//  Η recordUsage ΠΟΤΕ δεν πετάει exception (best-effort).
// ═══════════════════════════════════════════════════════════════════════════

const { getFirestore, FieldValue } = require("firebase-admin/firestore");

// Τιμές ΚΑΤΑΛΟΓΟΥ σε USD ανά κλήση — πρώτο επίπεδο τιμής, ΧΩΡΙΣ δωρεάν όρια
// (κόστος σαν να μην υπήρχε δώρο). Πηγές: Google Maps Platform price list
// (ενημ. 2026-09-17), Resend pricing, Anthropic. Μετατρέπονται σε EUR με το
// usdToEur. Αλλάζουν από την εφαρμογή (Τιμές υπηρεσιών → platform/pricing.rates).
const DEFAULT_RATES = {
  usdToEur: 0.92,                                         // ενδεικτική ισοτιμία — άλλαξέ την
  claude: { inUsdPerMTok: 1.0, outUsdPerMTok: 5.0 },      // Haiku 4.5
  perUnitUsd: {
    resend: 0.0004,               // Pro: $20 / 50.000 emails (υπέρβαση $0.90/1000)
    places_autocomplete: 0,       // ΕΝΤΟΣ session (η εφαρμογή στέλνει sessionToken): δωρεάν.
                                  // Εγκαταλειμμένο session: $2.83/1000 — δεν το μετράμε.
    places_details: 0.017,        // Place Details Pro ($17/1000) — ζητάμε displayName
    routes: 0.01,                 // Compute Routes Pro ($10/1000) — traffic-aware
    geocode: 0.005,               // Geocoding ($5/1000)
    aerodatabox: 0.01,            // ⚠️ ΕΞΑΡΤΑΤΑΙ ΑΠΟ ΤΟ ΠΛΑΝΟ ΣΟΥ στο RapidAPI — όρισέ το
    sms: 0.05,                    // ⚠️ ενδεικτικό
    whatsapp: 0,                  // δίνεται το πραγματικό κόστος από το webhook της Meta
  },
};

// Ομάδα υπηρεσίας → για τα ownKeys και το markup.
const GROUP = {
  claude: "claude",
  resend: "resend",
  places_autocomplete: "google",
  places_details: "google",
  routes: "google",
  geocode: "google",
  aerodatabox: "aerodatabox",
  sms: "sms",
  whatsapp: "whatsapp",
};

// ── Cache 60" (τα functions ξαναδιαβάζουν τα ίδια docs συνέχεια) ─────────────
const _cache = new Map();
async function cached(key, loader) {
  const hit = _cache.get(key);
  if (hit && Date.now() - hit.t < 60000) return hit.v;
  const v = await loader();
  _cache.set(key, { t: Date.now(), v });
  return v;
}

const round6 = (n) => Math.round(n * 1e6) / 1e6;

function monthKey(d = new Date()) {
  // Ώρα Ελλάδας, ώστε ο μήνας να αλλάζει τα μεσάνυχτα της Ελλάδας.
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Europe/Athens", year: "numeric", month: "2-digit",
  }).formatToParts(d);
  const y = parts.find((p) => p.type === "year").value;
  const m = parts.find((p) => p.type === "month").value;
  return y + "-" + m;
}

async function loadRates() {
  return cached("rates", async () => {
    const snap = await getFirestore().collection("platform").doc("pricing").get();
    const r = snap.exists ? (snap.data().rates || {}) : {};
    const usdToEur = r.usdToEur ?? DEFAULT_RATES.usdToEur;
    // Προεπιλογές: τιμή καταλόγου USD × ισοτιμία. Ό,τι έχεις ορίσει εσύ (perUnitEur) υπερισχύει.
    const perUnitEur = {};
    for (const k of Object.keys(DEFAULT_RATES.perUnitUsd)) {
      perUnitEur[k] = DEFAULT_RATES.perUnitUsd[k] * usdToEur;
    }
    return {
      usdToEur,
      claude: { ...DEFAULT_RATES.claude, ...(r.claude || {}) },
      perUnitEur: { ...perUnitEur, ...(r.perUnitEur || {}) },
    };
  });
}

async function loadTenantBilling(tenantId) {
  return cached("tb:" + tenantId, async () => {
    const snap = await getFirestore()
      .collection("tenants").doc(tenantId)
      .collection("billing").doc("settings").get();
    return snap.exists ? snap.data() : {};
  });
}

// Μετατρέπει το `usage` της απάντησης του Claude API σε ορίσματα για recordUsage.
function claudeUsage(usage) {
  return {
    tokensIn: (usage && usage.input_tokens) || 0,
    tokensOut: (usage && usage.output_tokens) || 0,
    units: 1,
  };
}

// Βρίσκει τον tenant ενός συνδεδεμένου χρήστη (για callables χωρίς tenantId).
async function tenantIdForUid(uid) {
  if (!uid) return "default";
  return cached("uid:" + uid, async () => {
    const snap = await getFirestore().collection("presence").doc(uid).get();
    return (snap.exists && snap.data().tenantId) || "default";
  });
}

// ── Η κύρια συνάρτηση ────────────────────────────────────────────────────────
// opts: { units, costEur, tokensIn, tokensOut }
//  - costEur: αν δοθεί, χρησιμοποιείται (π.χ. πραγματικό κόστος WhatsApp).
//  - αλλιώς υπολογίζεται από τις rates (tokens για Claude, units × τιμή για τα υπόλοιπα).
async function recordUsage(tenantId, service, opts = {}) {
  try {
    tenantId = tenantId || "default";
    const units = opts.units ?? 1;
    const group = GROUP[service] || service;
    const [rates, tb] = await Promise.all([loadRates(), loadTenantBilling(tenantId)]);

    const db = getFirestore();
    const monthRef = db.collection("usage").doc(tenantId).collection("monthly").doc(monthKey());
    const rootRef = db.collection("usage").doc(tenantId);

    // Δικό του κλειδί → δεν μας νοιάζει το κόστος, κρατάμε μόνο το πλήθος.
    if (tb.ownKeys && tb.ownKeys[group] === true) {
      await monthRef.set({
        services: { [service]: { ownKeyUnits: FieldValue.increment(units) } },
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
      return;
    }

    // Κόστος που μας χρεώνουν
    let costEur = opts.costEur;
    if (costEur == null) {
      if (service === "claude") {
        const c = rates.claude;
        const usd = ((opts.tokensIn || 0) * c.inUsdPerMTok + (opts.tokensOut || 0) * c.outUsdPerMTok) / 1e6;
        costEur = usd * rates.usdToEur;
      } else {
        costEur = units * (rates.perUnitEur[service] || 0);
      }
    }

    // Ποσό που χρεώνεται ο tenant (markup ΑΝΑ tenant και ανά ομάδα υπηρεσίας)
    let chargeEur = 0;
    if ((tb.billingMode || "markup") !== "none") {
      const mk = tb.markup || {};
      const pct = mk[group] ?? mk.default ?? 0;
      chargeEur = costEur * (1 + pct / 100);
    }
    costEur = round6(costEur);
    chargeEur = round6(chargeEur);

    const svc = {
      units: FieldValue.increment(units),
      costEur: FieldValue.increment(costEur),
      chargeEur: FieldValue.increment(chargeEur),
    };
    if (service === "claude") {
      svc.tokensIn = FieldValue.increment(opts.tokensIn || 0);
      svc.tokensOut = FieldValue.increment(opts.tokensOut || 0);
    }

    const batch = db.batch();
    batch.set(monthRef, {
      services: { [service]: svc },
      totalCostEur: FieldValue.increment(costEur),
      totalChargeEur: FieldValue.increment(chargeEur),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
    batch.set(rootRef, {
      costTotalEur: FieldValue.increment(costEur),
      chargeTotalEur: FieldValue.increment(chargeEur),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
    await batch.commit();
  } catch (e) {
    console.error("recordUsage error:", service, e && e.message ? e.message : e);
  }
}

// ── Όρια ─────────────────────────────────────────────────────────────────────
// Επιστρέφει { blocked, warn, usedEur, limitEur }. Το blocked γίνεται true ΜΟΝΟ
// αν limits.hardStop === true και ξεπεράστηκε το μηνιαίο όριο.
async function checkLimit(tenantId) {
  try {
    tenantId = tenantId || "default";
    const tb = await loadTenantBilling(tenantId);
    const lim = tb.limits || {};
    if (!lim.monthlyUsageEur) return { blocked: false, warn: false, usedEur: 0, limitEur: 0 };
    const snap = await getFirestore().collection("usage").doc(tenantId)
      .collection("monthly").doc(monthKey()).get();
    const used = snap.exists ? (snap.data().totalChargeEur || 0) : 0;
    const pct = (lim.warnAtPercent || 80) / 100;
    return {
      blocked: lim.hardStop === true && used >= lim.monthlyUsageEur,
      warn: used >= lim.monthlyUsageEur * pct,
      usedEur: used,
      limitEur: lim.monthlyUsageEur,
    };
  } catch (e) {
    console.error("checkLimit error:", e && e.message ? e.message : e);
    return { blocked: false, warn: false, usedEur: 0, limitEur: 0 };
  }
}

module.exports = { recordUsage, checkLimit, tenantIdForUid, claudeUsage, monthKey };
