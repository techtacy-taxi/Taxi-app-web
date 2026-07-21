const { onDocumentCreated, onDocumentUpdated, onDocumentDeleted } = require("firebase-functions/v2/firestore");
const { initializeApp }   = require("firebase-admin/app");
const { getFirestore, FieldValue }    = require("firebase-admin/firestore");
const { getMessaging }    = require("firebase-admin/messaging");
const { getAuth }         = require("firebase-admin/auth");
const { SecretManagerServiceClient } = require("@google-cloud/secret-manager");

initializeApp();

// ─── Helper: στέλνει DATA-ONLY FCM σε λίστα tokens ──────────────────────────
async function sendDataOnly(tokens, data, opts = {}) {
  if (!tokens.length) return;

  const chunks = [];
  for (let i = 0; i < tokens.length; i += 500) {
    chunks.push(tokens.slice(i, i + 500));
  }

  const deadTokens = [];

  for (const chunk of chunks) {
    const res = await getMessaging().sendEachForMulticast({
      tokens: chunk,
      data,                                  // ΜΟΝΟ data field — όχι notification
      android: {
        priority: "high",                    // ξυπνάει συσκευή ακόμη και σε doze
        // Προεπιλογή 60s (οι δουλειές προς οδηγούς είναι time-sensitive), ΑΛΛΑ
        // οι ειδοποιήσεις κράτησης στον master θέλουν ΜΕΓΑΛΟ TTL: σε βαθύ Doze
        // η παράδοση μπορεί να αργήσει λεπτά — με 60s το μήνυμα ΠΕΤΙΟΤΑΝ και
        // η ειδοποίηση δεν ερχόταν ΠΟΤΕ.
        ttl:      opts.ttlMs || 60 * 1000,
      },
    });

    res.responses.forEach((r, idx) => {
      if (!r.success) {
        const err = r.error;
        const code = err && err.code;
        if (
          code === "messaging/invalid-registration-token" ||
          code === "messaging/registration-token-not-registered"
        ) {
          deadTokens.push(chunk[idx]);
        } else if (err) {
          console.warn("FCM send error:", code, err.message);
        }
      }
    });
  }

  // Καθάρισμα stale tokens από το Firestore
  if (deadTokens.length) {
    const db = getFirestore();
    const snap = await db
      .collection("presence")
      .where("fcmToken", "in", deadTokens.slice(0, 30))
      .get();
    const batch = db.batch();
    snap.docs.forEach((d) => batch.update(d.ref, { fcmToken: null }));
    await batch.commit();
  }
}

// ─── Στάδια κλιμάκωσης μιας δουλειάς ────────────────────────────────────────
// Κάθε στάδιο: { base: bool (μόνο ομάδα/επιλεγμένοι), avail: bool (μόνο διαθέσιμοι) }
//  • ΟΜΑΔΑ / ΣΥΓΚΕΚΡΙΜΕΝΟΙ ΟΔΗΓΟΙ
//     με «πρώτα διαθέσιμοι»: διαθέσιμοι βάσης → όλη η βάση → όλοι οι οδηγοί
//     χωρίς:                 όλη η βάση → όλοι οι οδηγοί
//  • ΟΛΟΙ ΟΙ ΟΔΗΓΟΙ
//     με «πρώτα διαθέσιμοι»: όλοι οι διαθέσιμοι → όλοι
//     χωρίς:                 όλοι (ένα στάδιο)
function escalationPlan(job) {
  const hasTargets =
    Array.isArray(job.targetUids) && job.targetUids.length > 0;
  const hasBase =
    hasTargets || (job.groupId && String(job.groupId).length > 0);
  const avail = job.availableOnly === true;
  const exclusive = job.exclusiveTarget === true;

  if (hasBase) {
    // Αποκλειστική αποστολή: ΜΟΝΟ στη βάση, χωρίς κλιμάκωση σε «όλους».
    if (exclusive) {
      // Συγκεκριμένοι οδηγοί (όχι ομάδα): το «πρώτα διαθέσιμοι» ΔΕΝ έχει νόημα
      // — οι επιλεγμένοι πρέπει να τη δουν ούτως ή άλλως. Ένα μόνο στάδιο,
      // ώστε να ΜΗΝ ξαναχτυπάει η ίδια δουλειά (αλλιώς εμφανίζεται 2 φορές).
      if (hasTargets) {
        return [{ base: true, avail: false }];
      }
      return avail
        ? [
            { base: true, avail: true  },
            { base: true, avail: false },
          ]
        : [
            { base: true, avail: false },
          ];
    }
    return avail
      ? [
          { base: true,  avail: true  },
          { base: true,  avail: false },
          { base: false, avail: false },
        ]
      : [
          { base: true,  avail: false },
          { base: false, avail: false },
        ];
  }
  return avail
    ? [
        { base: false, avail: true  },
        { base: false, avail: false },
      ]
    : [{ base: false, avail: false }];
}

function stageOf(job) {
  const plan = escalationPlan(job);
  let i = job.escalationStage || 0;
  if (i < 0) i = 0;
  if (i >= plan.length) i = plan.length - 1;
  return plan[i];
}

// ─── Helper: tokens οδηγών για ΣΥΓΚΕΚΡΙΜΕΝΟ στάδιο μιας δουλειάς ─────────────
// Χωρητικότητα οδηγού ανά δηλωμένο όχημα — Ταξί 4, Van 8, Λεωφορείο έως
// busMaxSeats (ρύθμιση tenant, προεπιλογή 20). Ο οδηγός δηλώνει hasBus=true
// στο προφίλ του (ΕΠΙΠΛΕΟΝ στο κανονικό Ταξί/Van, όχι αντικατάσταση).
function driverCapacity(d, busMaxSeats) {
  if (d.hasBus === true) return busMaxSeats;
  return d.vehicleType === "van" ? 8 : 4;
}

async function getTokensForStage(job, stage) {
  const db = getFirestore();
  let q = db.collection("presence").where("isApproved", "==", true);
  if (stage.avail) q = q.where("available", "==", true);

  // Σύνολο βάσης (ομάδα ή συγκεκριμένοι οδηγοί) — μόνο αν το στάδιο περιορίζεται
  let baseSet = null;
  if (stage.base) {
    if (Array.isArray(job.targetUids) && job.targetUids.length > 0) {
      baseSet = new Set(job.targetUids.map(String));
    } else if (job.groupId) {
      const g = await db.collection("groups").doc(String(job.groupId)).get();
      baseSet = new Set((g.data() && g.data().memberUids) || []);
    } else {
      baseSet = new Set(); // βάση χωρίς στόχο → κανείς
    }
  }

  const snap = await q.get();
  // Ζώνες & Τιμές: μέγιστες θέσεις λεωφορείου του tenant (προεπιλογή 20).
  let busMaxSeats = 20;
  if (job.vehicleType === "shuttle" || job.vehicleType === "bus") {
    try {
      const { cfg } = await getPricingData(job.tenantId || "default");
      busMaxSeats = Number(cfg.busMaxSeats) || 20;
    } catch (_) {}
  }
  const persons = Number(job.persons) || 1;
  const tokens = [];
  for (const doc of snap.docs) {
    const d = doc.data();
    if (d.master !== true) {
      if (job.vehicleType === "shuttle") {
        // Υπηρεσία, όχι συγκεκριμένο αμάξι — προτείνεται σε ΟΠΟΙΟΝΔΗΠΟΤΕ οδηγό
        // μπορεί να εξυπηρετήσει τόσα άτομα (Ταξί/Van/Λεωφορείο).
        if (driverCapacity(d, busMaxSeats) < persons) continue;
      } else if (job.vehicleType === "bus") {
        // Ρητά Λεωφορείο: ΜΟΝΟ όσοι έχουν δηλώσει hasBus, με αρκετές θέσεις.
        if (d.hasBus !== true || busMaxSeats < persons) continue;
      } else if (job.vehicleType && job.vehicleType !== "any") {
        // Ταξί/Van: ίδια λογική με πριν (ακριβές ταίριασμα).
        if (d.vehicleType !== job.vehicleType) continue;
      }
    }
    // Φίλτρο βάσης
    if (baseSet && !baseSet.has(doc.id)) continue;
    if (d.fcmToken) tokens.push(d.fcmToken);
  }
  return tokens;
}

// ─── Helper: φτιάχνει data payload για δουλειά ──────────────────────────────
// ΠΡΟΣΟΧΗ: "from", "notification", "message_type" κλπ. είναι reserved από FCM.
// Τίτλος με σήμανση ομαδικής (Shuttle/Λεωφορείο) — «🚐 Shuttle · 3 κρατήσεις»
function groupAwareTitle(job, fallback) {
  if (job && job.isShuttleContainer === true) {
    const n = Array.isArray(job.shuttleStops) ? job.shuttleStops.length : 0;
    const veh = job.vehicleType === "bus" ? "Λεωφορείο" : "Shuttle";
    return `🚐 ${veh} · ${n} κρατήσεις`;
  }
  return fallback;
}

function jobDataPayload(jobId, job, type, title) {
  return {
    type:        String(type),
    jobId:       String(jobId),
    title:       String(groupAwareTitle(job, title)),
    stopsCount:  String(Array.isArray(job.shuttleStops) ? job.shuttleStops.length : 0),
    fromAddr:    String(job.from || ""),
    toAddr:      String(job.to   || ""),
    price:       String(job.price != null ? job.price : ""),
    vehicleType: String(job.vehicleType || "any"),
    click_action: "FLUTTER_NOTIFICATION_CLICK",
  };
}

// ─── Owner (admin/master που έβγαλε τη δουλειά): ειδοποιήσεις ────────────────
// Στέλνει ΜΟΝΟ στον createdBy. Τα owner_* events βαράνε ΠΑΝΤΑ (και σε σίγαση)
// — η συσκευή τα χειρίζεται σε ξεχωριστό «owner» channel.
async function notifyOwner(jobId, job, type, title, body) {
  const ownerUid = String(job.createdBy || "");
  if (!ownerUid) return;
  const tokens = await getTokensForUid(ownerUid);
  if (!tokens.length) {
    console.log(`notifyOwner(${type}): no token for owner`, ownerUid);
    return;
  }
  await sendDataOnly(tokens, {
    type:         String(type),
    jobId:        String(jobId),
    title:        String(title),
    body:         String(body || ""),
    fromAddr:     String(job.from || ""),
    toAddr:       String(job.to   || ""),
    price:        String(job.price != null ? job.price : ""),
    driverName:   String(job.takenByName || ""),
    stageNumber:  String((job.escalationStage || 0) + 1),
    click_action: "FLUTTER_NOTIFICATION_CLICK",
  });
  console.log(`notifyOwner(${type}): sent to owner ${ownerUid}`);
}

// Περιγραφή κοινού του ΤΡΕΧΟΝΤΟΣ σταδίου (για το μήνυμα κλιμάκωσης).
function stageAudienceLabel(job) {
  const stage = stageOf(job);
  if (stage.base) {
    return stage.avail ? "διαθέσιμους της βάσης" : "όλη τη βάση";
  }
  return stage.avail ? "διαθέσιμους οδηγούς" : "όλους τους οδηγούς";
}

// ─── Helper: token(s) ενός συγκεκριμένου χρήστη (uid) ───────────────────────
async function getTokensForUid(uid) {
  if (!uid) return [];
  const db = getFirestore();
  const doc = await db.collection("presence").doc(String(uid)).get();
  const d = doc.exists ? doc.data() : null;
  return d && d.fcmToken ? [d.fcmToken] : [];
}

// ─── Helper: token(s) όλων των masters ──────────────────────────────────────
async function getMasterTokens() {
  const db = getFirestore();
  const snap = await db
    .collection("presence")
    .where("master", "==", true)
    .get();
  const tokens = [];
  for (const doc of snap.docs) {
    const d = doc.data();
    if (d.fcmToken) tokens.push(d.fcmToken);
  }
  return tokens;
}

// ─── Νέα δουλειά ─────────────────────────────────────────────────────────────
exports.onNewJob = onDocumentCreated("jobs/{jobId}", async (event) => {
  const job = event.data.data();
  if (!job || job.status !== "open" || job.stopped === true) return;

  // Δουλειά που ανήκει σε batch (ομαδική αποστολή σε 1 οδηγό) → ΔΕΝ στέλνουμε
  // μεμονωμένη ειδοποίηση εδώ· στέλνεται ΜΙΑ ομαδική από το onBatchCreated.
  if (job.batchId && String(job.batchId).length > 0) {
    console.log("onNewJob: skip (batch job)", event.params.jobId);
    return;
  }

  const stage  = stageOf(job);
  const tokens = await getTokensForStage(job, stage);
  if (!tokens.length) {
    console.log("onNewJob: no tokens for job", event.params.jobId);
    return;
  }

  await sendDataOnly(
    tokens,
    jobDataPayload(event.params.jobId, job, "new_job", "🚖 Νέα Δουλειά!")
  );
  console.log(`onNewJob: sent to ${tokens.length} drivers (stage 0)`);
});

// ─── Ομαδική ανάθεση σε 1 οδηγό → ΜΙΑ ειδοποίηση ────────────────────────────
// Το app γράφει job_batches/{batchId} μία φορά ανά ομαδική αποστολή σε έναν
// συγκεκριμένο οδηγό. Στέλνουμε ΜΙΑ ειδοποίηση (αντί για N μεμονωμένες).
// Στο tap → ο οδηγός βλέπει τη λίστα «Αποδοχή όλων».
exports.onBatchCreated = onDocumentCreated("job_batches/{batchId}", async (event) => {
  const b = event.data.data();
  if (!b || !b.driverUid) return;

  const tokens = await getTokensForUid(b.driverUid);
  if (!tokens.length) {
    console.log("onBatchCreated: no token for driver", b.driverUid);
    return;
  }

  const count = b.count != null ? Number(b.count) : 0;
  const total = b.totalPrice != null ? Number(b.totalPrice) : 0;

  await sendDataOnly(tokens, {
    type:         "new_batch",
    batchId:      String(event.params.batchId),
    title:        "🚖 Πρόγραμμα δουλειών για σένα",
    count:        String(count),
    totalPrice:   String(total),
    vehicleType:  String(b.vehicleType || "any"),
    click_action: "FLUTTER_NOTIFICATION_CLICK",
  });
  console.log(`onBatchCreated: notified driver ${b.driverUid} (${count} jobs)`);
});

// ─── Χτύπημα δουλειάς: νέο στάδιο κλιμάκωσης ή επανέκδοση ────────────────────
// Χτυπάει κάθε φορά που αλλάζει το στάδιο (stageStartedAt/escalationStage) ή
// όταν μια δουλειά ξαναγίνεται open. ΔΕΝ χτυπάει αν είναι σταματημένη (stopped).
exports.onJobRing = onDocumentUpdated("jobs/{jobId}", async (event) => {
  const before = event.data.before.data();
  const after  = event.data.after.data();
  if (!before || !after) return;
  if (after.status !== "open") return;   // taken/done/cancelled → καμία ειδοποίηση
  if (after.stopped === true) return;    // σταματημένη → καμία ειδοποίηση

  const beforeStart = before.stageStartedAt ? before.stageStartedAt.toMillis() : 0;
  const afterStart  = after.stageStartedAt  ? after.stageStartedAt.toMillis()  : 0;
  const stageChanged =
    (before.escalationStage || 0) !== (after.escalationStage || 0) ||
    beforeStart !== afterStart;
  const reopened = before.status !== "open" && after.status === "open";

  if (!stageChanged && !reopened) return;

  const stage  = stageOf(after);
  const tokens = await getTokensForStage(after, stage);
  if (!tokens.length) return;

  const title = (after.escalationStage || 0) > 0
    ? "🚖 Δουλειά ξανά διαθέσιμη!"
    : "🚖 Νέα Δουλειά!";

  await sendDataOnly(
    tokens,
    jobDataPayload(event.params.jobId, after, "job_reopened", title)
  );
  console.log(
    `onJobRing: sent to ${tokens.length} drivers (stage ${after.escalationStage || 0})`
  );

  // Ειδοποίησε τον owner ΜΟΝΟ όταν προχώρησε σε νέο στάδιο (όχι σε απλό reopen).
  if ((before.escalationStage || 0) !== (after.escalationStage || 0)) {
    await notifyOwner(
      event.params.jobId,
      after,
      "owner_stage",
      "⏱️ Έληξε ο χρόνος",
      `Η δουλειά βγαίνει τώρα σε ${stageAudienceLabel(after)}.`
    );
  }
});

// ─── Όλοι οι πιθανοί παραλήπτες μιας δουλειάς (για ΑΚΥΡΩΣΗ ήχου) ─────────────
// Επιστρέφει tokens όλων των approved οδηγών που ταιριάζουν στο όχημα και (αν
// υπάρχει βάση) στη βάση — αγνοώντας στάδιο/διαθεσιμότητα, ώστε να σταματήσει
// ο ήχος σε ΟΠΟΙΟΝ τυχόν χτυπάει.
async function getAllJobAudienceTokens(job) {
  const db = getFirestore();
  const snap = await db.collection("presence")
    .where("isApproved", "==", true).get();

  let baseSet = null;
  if (Array.isArray(job.targetUids) && job.targetUids.length > 0) {
    baseSet = new Set(job.targetUids.map(String));
  } else if (job.groupId) {
    const g = await db.collection("groups").doc(String(job.groupId)).get();
    baseSet = new Set((g.data() && g.data().memberUids) || []);
  }

  const tokens = [];
  for (const doc of snap.docs) {
    const d = doc.data();
    // Ο master δέχεται ακύρωση ήχου για κάθε δουλειά (όπως και το χτύπημα)
    if (d.master !== true && job.vehicleType && job.vehicleType !== "any") {
      if (d.vehicleType !== job.vehicleType) continue;
    }
    if (baseSet && !baseSet.has(doc.id)) continue;
    if (d.fcmToken) tokens.push(d.fcmToken);
  }
  return tokens;
}

// ─── Ακύρωση ήχου: όταν η δουλειά ΦΕΥΓΕΙ από "open" (taken/boarded/done/
// cancelled) ή γίνεται stopped, στέλνει cancel_job ώστε να σταματήσει αμέσως
// ο επαναλαμβανόμενος ήχος (FLAG_INSISTENT) σε όλες τις συσκευές. ──────────────
exports.onJobClosed = onDocumentUpdated("jobs/{jobId}", async (event) => {
  const before = event.data.before.data();
  const after  = event.data.after.data();
  if (!before || !after) return;

  const wasOpen = before.status === "open" && before.stopped !== true;
  const nowClosed =
    after.status !== "open" || after.stopped === true;

  // Μόνο όταν περνά από «ανοιχτή & ηχεί» → «κλειστή/σταματημένη».
  if (!wasOpen || !nowClosed) return;

  const tokens = await getAllJobAudienceTokens(after);
  if (!tokens.length) return;

  await sendDataOnly(tokens, {
    type:         "cancel_job",
    jobId:        String(event.params.jobId),
    click_action: "FLUTTER_NOTIFICATION_CLICK",
  });
  console.log(
    `onJobClosed: cancel sent to ${tokens.length} devices for job ${event.params.jobId}`
  );
});

// ─── Ακύρωση κράτησης που είχε ήδη εκδοθεί παραστατικό ──────────────────────
// Η ακύρωση σήμερα σημαίνει ΔΙΑΓΡΑΦΗ του saved_job doc (όχι αλλαγή status) —
// γι' αυτό «ακούμε» onDelete. ΔΕΝ εκδίδουμε αυτόματα πιστωτικό/διορθωτικό
// παραστατικό εδώ — η ακριβής μορφή XML για διόρθωση/ακύρωση αποδείξεων
// λιανικής στο myDATA χρειάζεται δική της, ξεχωριστή επιβεβαίωση σχήματος
// πριν αυτοματοποιηθεί (ίδιο σκεπτικό με το αρχικό παραστατικό — δεν θέλουμε
// να «μαντέψουμε» κάτι τόσο ευαίσθητο). Αντ' αυτού, ειδοποιούμε τον
// υπεύθυνο (master/tenant-owner) να το χειριστεί ο ίδιος στο myDATA, με όλα
// τα στοιχεία έτοιμα μπροστά του.
exports.onSavedJobDeleted = onDocumentDeleted("saved_jobs/{savedJobId}", async (event) => {
  const data = event.data && event.data.data();
  if (!data || !data.invoiceMark) return; // δεν είχε εκδοθεί παραστατικό — τίποτα να γίνει

  try {
    const tenantId = data.tenantId || "default";
    const tDoc = await getFirestore().collection("tenants").doc(tenantId).get();
    const t = tDoc.exists ? tDoc.data() : {};

    // ── Αυτόματο πιστωτικό — myDATA (11.4) ή Oxygen (pistlianiki/pistotiko).
    // Epsilon Smart: το e-Shop API δεν έχει μέθοδο πιστωτικού (γίνεται μόνο
    // από το UI με «Μετασχηματισμό») — μένει χειροκίνητο με ειδοποίηση.
    let credit = await tryIssueMydataCreditNote({ tenantId, t, savedJobData: data });
    if (!credit) {
      credit = await tryIssueOxygenCreditNote({ tenantId, t, savedJobData: data });
    }

    const masterUid = await findMasterUid(tenantId);
    if (!masterUid) return;
    const tokens = await getTokensForUid(masterUid);
    if (!tokens.length) return;

    if (credit && credit.ok) {
      await sendDataOnly(tokens, {
        type: "invoice_credit_issued",
        savedJobId: String(event.params.savedJobId),
        title: "✅ Εκδόθηκε αυτόματα πιστωτικό",
        body: "Booking #" + (data.bookingNumber || "-") + " ακυρώθηκε — πιστωτικό MARK: " + credit.mark +
          " (αρχικό: " + data.invoiceMark + ").",
      });
    } else {
      await sendDataOnly(tokens, {
        type: "invoice_cancellation_needed",
        savedJobId: String(event.params.savedJobId),
        title: "⚠️ Ακυρώθηκε κράτηση με ήδη εκδομένο παραστατικό",
        body: "Booking #" + (data.bookingNumber || "-") + " · MARK: " + data.invoiceMark +
          (credit ? " — αποτυχία αυτόματου πιστωτικού, χρειάζεται χειροκίνητα στον πάροχο (" + (data.invoiceProvider || "-") + ")." : " — πάροχος " + (data.invoiceProvider || "-") + ", χρειάζεται χειροκίνητα."),
      });
    }
    console.log("onSavedJobDeleted: ολοκληρώθηκε, MARK:", data.invoiceMark, "credit:", credit);
  } catch (e) {
    console.error("onSavedJobDeleted error:", e);
  }
});


// Χτυπάει όταν status: * → "boarded". Στέλνει ΜΟΝΟ στον createdBy.
exports.onJobBoarded = onDocumentUpdated("jobs/{jobId}", async (event) => {
  const before = event.data.before.data();
  const after  = event.data.after.data();
  if (!before || !after) return;
  if (before.status === "boarded" || after.status !== "boarded") return;

  const driver = String(after.takenByName || "ένας οδηγός");
  // ΣΗΜΑΝΤΙΚΟ: χρησιμοποιούμε το ΙΔΙΟ notifyOwner() που ήδη χρησιμοποιεί το
  // onJobTaken — ίδιο ακριβώς στυλ ειδοποίησης (native insistent notification
  // + το ίδιο in-app popup με ΟΚ, βλ. owner_alerts.dart) σε κάθε σελίδα.
  await notifyOwner(
    event.params.jobId,
    after,
    "owner_boarded",
    "🚗 Επιβίβαση πελάτη",
    `Ο/Η ${driver} επιβίβασε τον πελάτη.`
  );
});

// ─── Δουλειά πιάστηκε: ειδοποίηση στον owner (createdBy) ─────────────────────
// Χτυπάει όταν status: open → taken. Στέλνει ΜΟΝΟ στον createdBy.
exports.onJobTaken = onDocumentUpdated("jobs/{jobId}", async (event) => {
  const before = event.data.before.data();
  const after  = event.data.after.data();
  if (!before || !after) return;
  if (before.status === "taken" || after.status !== "taken") return;

  const driver = String(after.takenByName || "ένας οδηγός");
  await notifyOwner(
    event.params.jobId,
    after,
    "owner_taken",
    "✅ Η δουλειά ανατέθηκε",
    `Ο/Η ${driver} πήρε τη δουλειά.`
  );
});

// ─── Δουλειά έληξε χωρίς οδηγό: ειδοποίηση στον owner ────────────────────────
// Χτυπάει όταν status: open → expired (το γράφει η εφαρμογή του admin όταν
// τελειώσουν όλα τα στάδια χωρίς διεκδίκηση). Στέλνει ΜΟΝΟ στον createdBy.
exports.onJobExpired = onDocumentUpdated("jobs/{jobId}", async (event) => {
  const before = event.data.before.data();
  const after  = event.data.after.data();
  if (!before || !after) return;
  if (before.status === "expired" || after.status !== "expired") return;

  await notifyOwner(
    event.params.jobId,
    after,
    "owner_expired",
    "⚠️ Καμία εξυπηρέτηση",
    "Έληξαν όλα τα στάδια και κανείς δεν πήρε τη δουλειά."
  );
});

// ─── Νέος χρήστης προς έγκριση: ειδοποίηση στους masters ────────────────────
// Χτυπάει όταν δημιουργείται presence doc με isApproved == false.
exports.onPendingApprovalCreated = onDocumentCreated(
  "presence/{uid}",
  async (event) => {
    const d = event.data.data();
    if (!d || d.isApproved === true) return;
    // Στέλνουμε μόνο όταν υπάρχουν στοιχεία (μετά την αποθήκευση φόρμας),
    // όχι για κενό doc που μπορεί να δημιουργηθεί νωρίτερα.
    if (!d.displayName && !d.lastName && !d.phone) return;

    const tokens = await getMasterTokens();
    if (!tokens.length) return;

    const name = `${d.displayName || ""} ${d.lastName || ""}`.trim();
    await sendDataOnly(tokens, {
      type:         "approval",
      title:        "👤 Νέο αίτημα έγκρισης",
      pendingName:  String(name),
      phone:        String(d.phone || ""),
      vehicleModel: String(d.vehicleModel || ""),
      plateNumber:  String(d.plateNumber || ""),
      vehicleType:  String(d.vehicleType || ""),
      referredBy:   String(d.referredBy || ""),
      click_action: "FLUTTER_NOTIFICATION_CLICK",
    });
    console.log("onPendingApprovalCreated: notified", tokens.length, "masters");
  }
);

// ─── Έγκριση που γίνεται σε δεύτερο χρόνο (false → false αλλάζει αλλιώς) ─────
// Καλύπτει την περίπτωση που το presence doc υπάρχει ήδη και απλώς
// ξαναγίνεται isApproved:false (σπάνιο, αλλά ασφαλές).
exports.onPendingApprovalUpdated = onDocumentUpdated(
  "presence/{uid}",
  async (event) => {
    const before = event.data.before.data();
    const after  = event.data.after.data();
    if (!before || !after) return;
    if (after.isApproved === true) return; // εγκεκριμένος → όχι ειδοποίηση

    // Στέλνουμε όταν ο pending χρήστης ΜΟΛΙΣ συμπλήρωσε στοιχεία:
    // πριν δεν είχε όνομα/τηλέφωνο, τώρα έχει (αποθήκευση φόρμας).
    const hadDetails  = !!(before.displayName || before.lastName || before.phone);
    const hasDetails  = !!(after.displayName  || after.lastName  || after.phone);
    if (hadDetails || !hasDetails) return;

    const tokens = await getMasterTokens();
    if (!tokens.length) return;

    const name = `${after.displayName || ""} ${after.lastName || ""}`.trim();
    await sendDataOnly(tokens, {
      type:         "approval",
      title:        "👤 Νέο αίτημα έγκρισης",
      pendingName:  String(name),
      phone:        String(after.phone || ""),
      vehicleModel: String(after.vehicleModel || ""),
      plateNumber:  String(after.plateNumber || ""),
      vehicleType:  String(after.vehicleType || ""),
      referredBy:   String(after.referredBy || ""),
      click_action: "FLUTTER_NOTIFICATION_CLICK",
    });
    console.log("onPendingApprovalUpdated: notified", tokens.length, "masters");
  }
);

// ─── Helper: tokens ΟΛΩΝ των εγκεκριμένων οδηγών ────────────────────────────
async function getAllApprovedTokens() {
  const db = getFirestore();
  const snap = await db
    .collection("presence")
    .where("isApproved", "==", true)
    .get();
  const tokens = [];
  for (const doc of snap.docs) {
    const d = doc.data();
    if (d.fcmToken) tokens.push(d.fcmToken);
  }
  return tokens;
}

// ─── Broadcast αναβάθμισης από master → push σε ΟΛΟΥΣ ──────────────────────
// Το app γράφει app_broadcasts/current { type:'upgrade', sentAt, sentBy }.
// Στέλνουμε high-priority data-only FCM ώστε να χτυπήσει ακόμη και με
// τελείως κλειστή εφαρμογή (όπως οι δουλειές). Ο Firestore listener στο app
// παραμένει ως fallback όταν η εφαρμογή είναι ανοιχτή.
async function handleBroadcast(data) {
  if (!data || data.type !== "upgrade") return;
  const tokens = await getAllApprovedTokens();
  if (!tokens.length) {
    console.log("broadcast upgrade: no tokens");
    return;
  }
  await sendDataOnly(tokens, {
    type:  "upgrade",
    title: "⬆️ Νέα αναβάθμιση!",
    body:  "Διαθέσιμη νέα έκδοση της εφαρμογής. Παρακαλώ αναβαθμιστείτε.",
    click_action: "FLUTTER_NOTIFICATION_CLICK",
  });
  console.log(`broadcast upgrade: sent to ${tokens.length} drivers`);
}

exports.onBroadcastCreated = onDocumentCreated(
  "app_broadcasts/{docId}",
  async (event) => {
    await handleBroadcast(event.data && event.data.data());
  }
);

// Επαναποστολή όταν το ίδιο doc ('current') ξαναγράφεται με νέο sentAt.
exports.onBroadcastUpdated = onDocumentUpdated(
  "app_broadcasts/{docId}",
  async (event) => {
    const before = event.data.before.data() || {};
    const after  = event.data.after.data()  || {};
    const bMs = before.sentAt && before.sentAt.toMillis
      ? before.sentAt.toMillis() : 0;
    const aMs = after.sentAt && after.sentAt.toMillis
      ? after.sentAt.toMillis() : 0;
    if (aMs <= bMs) return; // όχι νέα αποστολή
    await handleBroadcast(after);
  }
);

// ═══════════════════════════════════════════════════════════════════════════
//  GOOGLE CALENDAR — server-side refresh token flow (σύνδεση «μία φορά»)
// ═══════════════════════════════════════════════════════════════════════════
//
//  Ροή:
//   1) Το app κάνει authorizeServer([calendar.readonly]) → παίρνει serverAuthCode
//      και το στέλνει στο exchangeCalendarCode (μία φορά).
//   2) Το function ανταλλάσσει code+secret → refresh_token, που αποθηκεύεται
//      στο calendar_tokens/{uid} (το βλέπει ΜΟΝΟ ο server).
//   3) Το getCalendarEvents χρησιμοποιεί το refresh_token → φρέσκο access_token
//      → φέρνει τα events. Το app ΔΕΝ ξαναμπλέκει με Google sign-in.

const { onCall, HttpsError } = require("firebase-functions/v2/https");

// Web client ID (ΔΕΝ είναι μυστικό — client IDs είναι δημόσια).
const GCAL_CLIENT_ID =
  "566987559821-tlphsu640nfhfdhtevutr7kj58tpu2vq.apps.googleusercontent.com";

// ⚠️ ΤΟ SECRET ΔΕΝ ΕΙΝΑΙ ΠΛΕΟΝ ΣΤΟΝ ΚΩΔΙΚΑ.
// Αποθηκεύεται ως Firebase Secret (GCAL_CLIENT_SECRET) και διαβάζεται runtime
// μέσω GCAL_CLIENT_SECRET.value(). Κάθε function που το χρησιμοποιεί το δηλώνει
// στο { secrets: [GCAL_CLIENT_SECRET] }.
// Όρισέ το μία φορά με:
//   firebase functions:secrets:set GCAL_CLIENT_SECRET
const { defineSecret } = require("firebase-functions/params");
const GCAL_CLIENT_SECRET = defineSecret("GCAL_CLIENT_SECRET");

// ── Resend (email επιβεβαίωσης στον ΠΕΛΑΤΗ μετά από πληρωμή) ────────────────
// Ορίζεται με: firebase functions:secrets:set RESEND_API_KEY
const RESEND_API_KEY = defineSecret("RESEND_API_KEY");

// Στέλνει email μέσω Resend. Best-effort — ποτέ δεν πετάει exception προς τα
// έξω (η αποτυχία εδώ δεν πρέπει ΠΟΤΕ να μπλοκάρει την επιβεβαίωση πληρωμής).
async function sendCustomerEmailViaResend({ to, subject, html, fromName, fromEmail, apiKeyOverride, attachments }) {
  try {
    const apiKey = apiKeyOverride || RESEND_API_KEY.value();
    if (!apiKey || !to) return false;
    const body = {
      from: (fromName || "Athens Taxi Booking") + " <" + (fromEmail || "bookings@taxiathenstransfers.com") + ">",
      to: [to],
      subject,
      html,
    };
    // attachments: [{ filename, content }] — content = base64 string (χωρίς data: πρόθεμα).
    if (Array.isArray(attachments) && attachments.length) {
      body.attachments = attachments;
    }
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { "Authorization": "Bearer " + apiKey, "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (!res.ok) {
      console.error("Resend send error:", res.status, await res.text());
      return false;
    }
    return true;
  } catch (e) {
    console.error("Resend send exception:", e);
    return false;
  }
}

// Ανταλλαγή serverAuthCode → refresh_token. Αποθήκευση στο Firestore.
exports.exchangeCalendarCode = onCall({ secrets: [GCAL_CLIENT_SECRET] }, async (request) => {
  const uid = request.auth && request.auth.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Απαιτείται σύνδεση.");

  const code = request.data && request.data.serverAuthCode;
  if (!code) throw new HttpsError("invalid-argument", "Λείπει ο κωδικός.");

  // redirect_uri: Android στέλνει κενό· Web (GIS popup) στέλνει 'postmessage'.
  const redirectUri = (request.data && request.data.redirectUri) || "";

  // Ανταλλαγή με το token endpoint της Google.
  const body = new URLSearchParams({
    code:          code,
    client_id:     GCAL_CLIENT_ID,
    client_secret: GCAL_CLIENT_SECRET.value(),
    redirect_uri:  redirectUri,
    grant_type:    "authorization_code",
  });

  const resp = await fetch("https://oauth2.googleapis.com/token", {
    method:  "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body:    body.toString(),
  });
  const tok = await resp.json();

  if (!resp.ok) {
    console.error("exchangeCalendarCode error:", tok);
    throw new HttpsError("internal",
      "Αποτυχία ανταλλαγής: " + (tok.error_description || tok.error || ""));
  }

  // refresh_token δίνεται ΜΟΝΟ την πρώτη φορά. Αν λείπει, κράτα το παλιό.
  const update = {
    accessToken:  tok.access_token || "",
    expiresAt:    Date.now() + ((tok.expires_in || 3600) * 1000),
    updatedAt:    Date.now(),
  };
  if (tok.refresh_token) update.refreshToken = tok.refresh_token;

  await getFirestore().collection("calendar_tokens").doc(uid)
    .set(update, { merge: true });

  return { ok: true };
});

// Επιστρέφει events [timeMin, timeMax) χρησιμοποιώντας το αποθηκευμένο token.
exports.getCalendarEvents = onCall({ secrets: [GCAL_CLIENT_SECRET] }, async (request) => {
  const uid = request.auth && request.auth.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Απαιτείται σύνδεση.");

  const timeMin = request.data && request.data.timeMin;
  const timeMax = request.data && request.data.timeMax;
  if (!timeMin || !timeMax) {
    throw new HttpsError("invalid-argument", "Λείπει το χρονικό διάστημα.");
  }

  const ref  = getFirestore().collection("calendar_tokens").doc(uid);
  const snap = await ref.get();
  if (!snap.exists) {
    throw new HttpsError("failed-precondition", "NOT_CONNECTED");
  }
  const data = snap.data() || {};

  // Φρέσκο access token αν έληξε (ή κοντά στη λήξη).
  let accessToken = data.accessToken;
  if (!accessToken || Date.now() > (data.expiresAt || 0) - 60000) {
    if (!data.refreshToken) {
      throw new HttpsError("failed-precondition", "NOT_CONNECTED");
    }
    const body = new URLSearchParams({
      client_id:     GCAL_CLIENT_ID,
      client_secret: GCAL_CLIENT_SECRET.value(),
      refresh_token: data.refreshToken,
      grant_type:    "refresh_token",
    });
    const r = await fetch("https://oauth2.googleapis.com/token", {
      method:  "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body:    body.toString(),
    });
    const tok = await r.json();
    if (!r.ok) {
      console.error("refresh error:", tok);
      // Αν το refresh token ακυρώθηκε (π.χ. ο χρήστης αφαίρεσε πρόσβαση):
      throw new HttpsError("failed-precondition", "NOT_CONNECTED");
    }
    accessToken = tok.access_token;
    await ref.set({
      accessToken: accessToken,
      expiresAt:   Date.now() + ((tok.expires_in || 3600) * 1000),
      updatedAt:   Date.now(),
    }, { merge: true });
  }

  // Κλήση Google Calendar API.
  const url = new URL(
    "https://www.googleapis.com/calendar/v3/calendars/primary/events");
  url.searchParams.set("timeMin",      timeMin);
  url.searchParams.set("timeMax",      timeMax);
  url.searchParams.set("singleEvents", "true");
  url.searchParams.set("orderBy",      "startTime");
  url.searchParams.set("maxResults",   "250");

  const evResp = await fetch(url.toString(), {
    headers: { Authorization: "Bearer " + accessToken },
  });
  if (!evResp.ok) {
    const txt = await evResp.text();
    console.error("calendar api error:", evResp.status, txt);
    throw new HttpsError("internal", "Σφάλμα ημερολογίου: " + evResp.status);
  }
  const body = await evResp.json();
  const items = Array.isArray(body.items) ? body.items : [];

  // Επιστρέφουμε μόνο τα απαραίτητα πεδία.
  const events = items.map((m) => {
    const start = m.start || {};
    return {
      id:          m.id || "",
      title:       m.summary || "(χωρίς τίτλο)",
      description: m.description || null,
      location:    m.location || null,
      startDateTime: start.dateTime || null,
      startDate:     start.date || null,
      colorId:     m.colorId || null,
    };
  });

  return { events };
});

// Αποσύνδεση ημερολογίου: σβήνει τα αποθηκευμένα tokens.
exports.disconnectCalendar = onCall(async (request) => {
  const uid = request.auth && request.auth.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Απαιτείται σύνδεση.");
  await getFirestore().collection("calendar_tokens").doc(uid).delete();
  return { ok: true };
});

// ═════════════════════════════════════════════════════════════════════════════
// ΜΗΝΙΑΙΑ ΑΝΑΦΟΡΑ PDF → GOOGLE DRIVE ΤΟΥ MASTER
// ═════════════════════════════════════════════════════════════════════════════
// • monthlyReport: τρέχει αυτόματα κάθε 1η του μήνα 06:00 (ώρα Ελλάδας) και
//   φτιάχνει PDF αναφορά του ΠΡΟΗΓΟΥΜΕΝΟΥ μήνα.
// • generateMonthlyReport (onCall): χειροκίνητη παραγωγή για όποιον μήνα θες
//   (μόνο master) — χρήσιμο για δοκιμή και για παλιούς μήνες.
//
// Το PDF ανεβαίνει στο Google Drive του master, σε φάκελο
// «AthensTaxi Αναφορές» (δημιουργείται αυτόματα). Χρησιμοποιείται το ΙΔΙΟ
// refresh token με το Ημερολόγιο (calendar_tokens/{uid}) — απαιτεί το scope
// drive.file, άρα ο master πρέπει να κάνει ΜΙΑ φορά Αποσύνδεση→Σύνδεση
// ημερολογίου μετά το update της εφαρμογής. Αν το Drive αποτύχει, το PDF
// σώζεται εφεδρικά στο Firebase Storage (reports/).
//
// Απαιτήσεις deploy: στον φάκελο functions →  npm install pdfkit
// και τα fonts DejaVuSans.ttf / DejaVuSans-Bold.ttf στο functions/fonts/.

const { onSchedule } = require("firebase-functions/v2/scheduler");
const path = require("path");
const fs   = require("fs");

// ─── Φρέσκο access token για χρήστη από calendar_tokens (refresh flow) ───────
async function freshAccessTokenFor(uid) {
  const ref  = getFirestore().collection("calendar_tokens").doc(uid);
  const snap = await ref.get();
  if (!snap.exists) return null;
  const data = snap.data() || {};

  if (data.accessToken && Date.now() < (data.expiresAt || 0) - 60000) {
    return data.accessToken;
  }
  if (!data.refreshToken) return null;

  const body = new URLSearchParams({
    client_id:     GCAL_CLIENT_ID,
    client_secret: GCAL_CLIENT_SECRET.value(),
    refresh_token: data.refreshToken,
    grant_type:    "refresh_token",
  });
  const r = await fetch("https://oauth2.googleapis.com/token", {
    method:  "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body:    body.toString(),
  });
  const tok = await r.json();
  if (!r.ok) {
    console.error("freshAccessTokenFor refresh error:", tok);
    return null;
  }
  await ref.set({
    accessToken: tok.access_token,
    expiresAt:   Date.now() + ((tok.expires_in || 3600) * 1000),
    updatedAt:   Date.now(),
  }, { merge: true });
  return tok.access_token;
}

// ─── Βρες τον (πρώτο) master ─────────────────────────────────────────────────
// ─── Όνομα εμφάνισης του master/tenant-owner για ownerName σε saved_jobs ────
// ΠΡΟΣΟΧΗ: το presence ΔΕΝ έχει πεδίο "name" — έχει displayName/lastName.
// Για tenant owner προτιμάμε το businessName του tenant (πιο αναγνωρίσιμο
// στο dropdown «Δημιουργός» απ' το να λέει γενικά «Master» για όλους).
// ─── Όνομα εμφάνισης του master/tenant-owner για ownerName σε saved_jobs ────
// ΠΡΟΤΙΜΑΤΑΙ το προσωπικό όνομα (displayName+lastName) — όχι το όνομα
// επιχείρησης, γιατί κάποιες δουλειές θα μπαίνουν και εκτός φόρμας (ή η
// φόρμα ενδέχεται να κλείσει στο μέλλον), οπότε το προσωπικό όνομα είναι πιο
// σταθερό αναγνωριστικό στο dropdown «Δημιουργός». Business name μόνο αν δεν
// υπάρχει καθόλου προσωπικό όνομα καταχωρημένο.
// ─── Μοναδικός, αυξανόμενος αριθμός κράτησης — ΞΕΧΩΡΙΣΤΗ αρίθμηση ανά tenant
// (κάθε επιχείρηση ξεκινά από το #1, όχι κοινό μετρητή για όλους) ───────────
async function nextBookingNumber(tenantId) {
  const db = getFirestore();
  const ref = db.collection("counters").doc(tenantId || "default");
  return await db.runTransaction(async (tx) => {
    const doc = await tx.get(ref);
    const next = (doc.exists ? (doc.data().value || 0) : 0) + 1;
    tx.set(ref, { value: next }, { merge: true });
    return next;
  });
}

// ── Ξεχωριστός μετρητής παραστατικών (myDATA/Epsilon) — ΠΡΕΠΕΙ να είναι
// αυστηρά συνεχόμενος, χωρίς κενά, ξεκινώντας από 1, ανά tenant ΚΑΙ ανά
// σειρά (series) ξεχωριστά. ΔΕΝ πρέπει να μπερδεύεται με το bookingNumber
// (που μπορεί να έχει κενά αν διαγραφεί μια κράτηση) — το myDATA απορρίπτει
// παραστατικά με κενά στην αρίθμηση.
async function nextInvoiceNumber(tenantId, series) {
  const db = getFirestore();
  const key = (tenantId || "default") + "__invoice__" + (series || "A");
  const ref = db.collection("counters").doc(key);
  return await db.runTransaction(async (tx) => {
    const doc = await tx.get(ref);
    const next = (doc.exists ? (doc.data().value || 0) : 0) + 1;
    tx.set(ref, { value: next }, { merge: true });
    return next;
  });
}

async function resolveOwnerDisplayName(tenantId, presenceData) {
  const pd = presenceData || {};
  const full = [pd.displayName, pd.lastName].filter(Boolean).join(" ").trim();
  if (full) return full;
  if (tenantId && tenantId !== "default") {
    try {
      const tDoc = await getFirestore().collection("tenants").doc(tenantId).get();
      if (tDoc.exists && tDoc.data().businessName) return tDoc.data().businessName;
    } catch (e) { /* fallback παρακάτω */ }
  }
  return pd.name || "Master";
}

async function findMasterUid(tenantId) {
  const tid = tenantId || "default";
  const db = getFirestore();
  const masterSnap = await db.collection("presence")
    .where("master", "==", true)
    .where("tenantId", "==", tid)
    .limit(1).get();
  if (!masterSnap.empty) return masterSnap.docs[0].id;

  // ── Ανθεκτικό fallback για tenant "default": αν ο master (εσύ) δεν έχει
  // (ακόμα) ρητό tenantId:'default' στο presence του — π.χ. δεν έτρεξε ποτέ
  // backfillDefaultTenantId — το query με tenantId=='default' ΔΕΝ ταιριάζει
  // (το Firestore δεν ταιριάζει missing πεδίο με ==), οπότε επιστρέφει null
  // και ΧΑΝΕΤΑΙ ολόκληρη η κράτηση (π.χ. δεν φτάνει ποτέ στα saved_jobs).
  // Πραγματικά υπάρχει ΕΝΑΣ master, οπότε για default ψάξε τον ΧΩΡΙΣ φίλτρο
  // tenantId σαν τελευταία προσπάθεια.
  if (tid === "default") {
    const anyMaster = await db.collection("presence")
      .where("master", "==", true)
      .limit(1).get();
    if (!anyMaster.empty) return anyMaster.docs[0].id;
  }

  // Fallback: ο tenant δεν έχει master (νέο μοντέλο multi-tenant — ο
  // πελάτης είναι admin + tenantOwner, όχι master) — ειδοποιούμε τον
  // πρώτο admin που βρεθεί σε αυτόν τον tenant.
  const adminSnap = await db.collection("presence")
    .where("admin", "==", true)
    .where("tenantId", "==", tid)
    .limit(1).get();
  return adminSnap.empty ? null : adminSnap.docs[0].id;
}

// ─── Μήνας/έτος ΣΕ ΩΡΑ ΕΛΛΑΔΑΣ για ένα Date ─────────────────────────────────
function athensYM(date) {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Europe/Athens", year: "numeric", month: "2-digit",
  }).formatToParts(date);
  const y = Number(parts.find((p) => p.type === "year").value);
  const m = Number(parts.find((p) => p.type === "month").value);
  return { y, m };
}

// Κλειδί ΠΡΟΗΓΟΥΜΕΝΟΥ μήνα (π.χ. τρέχει 1/6 → "2026-05")
function prevMonthKey(now) {
  let { y, m } = athensYM(now || new Date());
  m -= 1;
  if (m === 0) { m = 12; y -= 1; }
  return `${y}-${String(m).padStart(2, "0")}`;
}

const GREEK_MONTHS = ["", "Ιανουάριος", "Φεβρουάριος", "Μάρτιος", "Απρίλιος",
  "Μάιος", "Ιούνιος", "Ιούλιος", "Αύγουστος", "Σεπτέμβριος", "Οκτώβριος",
  "Νοέμβριος", "Δεκέμβριος"];
const GREEK_DAYS = ["Κυριακή", "Δευτέρα", "Τρίτη", "Τετάρτη",
  "Πέμπτη", "Παρασκευή", "Σάββατο"];

function monthLabel(key) {
  const [y, m] = key.split("-").map(Number);
  return `${GREEK_MONTHS[m]} ${y}`;
}

// Το monthKey ("YYYY-MM") ενός Firestore Timestamp σε ώρα Ελλάδας.
function tsMonthKey(ts) {
  if (!ts || !ts.toDate) return "";
  const { y, m } = athensYM(ts.toDate());
  return `${y}-${String(m).padStart(2, "0")}`;
}

// ─── Συγκέντρωση στατιστικών μήνα ────────────────────────────────────────────
async function aggregateMonth(key) {
  const db = getFirestore();
  const [y, m] = key.split("-").map(Number);
  // Ευρύ UTC παράθυρο (±1 ημέρα) — το ακριβές φίλτρο γίνεται με tsMonthKey
  // σε ώρα Ελλάδας, ώστε να μη χρειάζεται composite index.
  const start = new Date(Date.UTC(y, m - 1, 1) - 24 * 3600e3);
  const end   = new Date(Date.UTC(y, m, 1)     + 24 * 3600e3);

  // ── Ολοκληρωμένες δουλειές ──
  const doneSnap = await db.collection("jobs")
    .where("doneAt", ">=", start).where("doneAt", "<", end).get();

  // Ονόματα ομάδων (μικρή συλλογή — ένα read ανά αναφορά)
  const groupNames = new Map();
  const gSnap = await db.collection("groups").get();
  for (const g of gSnap.docs) {
    groupNames.set(g.id, String((g.data() || {}).name || g.id));
  }

  const drivers  = new Map();   // uid → {name, jobs, turnover, source, app,
                                //        bySource: Map("Πηγή → Παραλήπτης"→amt)}
  const admins   = new Map();   // uid → {name, posted}
  const sources  = new Map();   // name → {jobs, turnover}
  const groups   = new Map();   // gid → {name, jobs, turnover, source, app}
  const routes   = new Map();   // "Από → Προς" → count
  const jobGroup = new Map();   // jobId → gid (για απόδοση billing σε ομάδα)
  const drvGroup = new Map();   // uid → Map(gid → τζίρος μέσα στην ομάδα)
  const dayCount = [0, 0, 0, 0, 0, 0, 0];
  const vehCount = { taxi: 0, van: 0 };
  let doneJobs = 0, turnover = 0;

  for (const doc of doneSnap.docs) {
    const d = doc.data();
    if (d.status !== "done") continue;
    if (tsMonthKey(d.doneAt) !== key) continue;
    doneJobs += 1;
    const price = Number(d.price || 0);
    // Αρνητικό γιαούρτι = ο διαχειριστής έβαλε λεφτά από την τσέπη του → ο
    // οδηγός εισέπραξε πραγματικά price + |γιαούρτι|. Το θετικό γιαούρτι
    // (προμήθεια) ΔΕΝ αλλάζει τον τζίρο. effPrice = price - min(commission, 0).
    const jobComm  = Number(d.commission || 0);
    const effPrice = price - Math.min(jobComm, 0);
    turnover  += effPrice;

    const dUid  = String(d.takenBy || "");
    const dName = String(d.takenByName || "—");
    if (!drivers.has(dUid)) {
      drivers.set(dUid, { name: dName, jobs: 0, turnover: 0,
                          source: 0, app: 0, bySource: new Map() });
    }
    const drv = drivers.get(dUid);
    drv.jobs += 1; drv.turnover += effPrice;

    // Ομάδα της δουλειάς (κενό = broadcast/χωρίς ομάδα)
    const gid = String(d.groupId || "");
    jobGroup.set(doc.id, gid);
    if (!groups.has(gid)) {
      groups.set(gid, {
        name: gid ? (groupNames.get(gid) || gid) : "Χωρίς ομάδα / Όλοι",
        jobs: 0, turnover: 0, source: 0, app: 0,
      });
    }
    const grp = groups.get(gid);
    grp.jobs += 1; grp.turnover += effPrice;

    // Τζίρος του οδηγού ΜΕΣΑ στη συγκεκριμένη ομάδα (για ποσοστά μεριδίου)
    if (!drvGroup.has(dUid)) drvGroup.set(dUid, new Map());
    const dg = drvGroup.get(dUid);
    dg.set(gid, (dg.get(gid) || 0) + effPrice);

    // Δημοφιλείς διαδρομές (κρατάμε την πραγματική τιμή διαδρομής)
    const routeKey = `${String(d.from || "").trim()} → ${String(d.to || "").trim()}`;
    const rr = routes.get(routeKey) || { count: 0, total: 0 };
    rr.count += 1; rr.total += price;
    routes.set(routeKey, rr);

    const aUid  = String(d.createdBy || "");
    const aName = String(d.createdByName || "—");
    if (!admins.has(aUid)) admins.set(aUid, { name: aName, posted: 0 });
    admins.get(aUid).posted += 1;

    const sName = String(d.sourceName || "Standard Rate");
    if (!sources.has(sName)) sources.set(sName, { jobs: 0, turnover: 0 });
    const src = sources.get(sName);
    src.jobs += 1; src.turnover += effPrice;

    const wd = new Intl.DateTimeFormat("en-US", {
      timeZone: "Europe/Athens", weekday: "short",
    }).format(d.doneAt.toDate());
    const dow = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"].indexOf(wd);
    if (dow >= 0) dayCount[dow] += 1;

    if ((d.vehicleType || "taxi") === "van") vehCount.van += 1;
    else vehCount.taxi += 1;
  }

  // ── Ακυρωμένες ──
  const cancSnap = await db.collection("jobs")
    .where("cancelledAt", ">=", start).where("cancelledAt", "<", end).get();
  let cancelled = 0;
  for (const doc of cancSnap.docs) {
    const d = doc.data();
    if (d.status !== "cancelled") continue;
    if (tsMonthKey(d.cancelledAt) !== key) continue;
    cancelled += 1;
  }

  // ── Billing (γιαούρτι / app / συνδρομές / πληρωμές) ──
  const txSnap = await db.collection("billing_tx")
    .where("monthKey", "==", key).get();
  let sourceCommTotal = 0, appCommTotal = 0;
  let subsTotal = 0, calSubsTotal = 0, paymentsTotal = 0;
  const adminYogurt = new Map();  // recipientName → ποσό γιαουρτιού

  for (const doc of txSnap.docs) {
    const t = doc.data();
    if (t.voided === true) continue;
    const amt = Number(t.amount || 0);
    const cat = String(t.category || "");
    const uid = String(t.uid || "");
    const txGid = jobGroup.get(String(t.jobId || ""));
    if (cat === "source_commission") {
      sourceCommTotal += amt;
      const rn = String(t.recipientName || "—");
      adminYogurt.set(rn, (adminYogurt.get(rn) || 0) + amt);
      if (drivers.has(uid)) {
        const drv = drivers.get(uid);
        drv.source += amt;
        // Σε ποια πηγή & σε ποιον πήγε το γιαούρτι αυτού του οδηγού
        const k = `${String(t.sourceName || "Standard Rate")} → ${rn}`;
        drv.bySource.set(k, (drv.bySource.get(k) || 0) + amt);
      }
      if (txGid !== undefined && groups.has(txGid)) {
        groups.get(txGid).source += amt;
      }
    } else if (cat === "app_commission") {
      appCommTotal += amt;
      if (drivers.has(uid)) drivers.get(uid).app += amt;
      if (txGid !== undefined && groups.has(txGid)) {
        groups.get(txGid).app += amt;
      }
    } else if (cat === "subscription") {
      subsTotal += amt;
    } else if (cat === "calendar_subscription") {
      calSubsTotal += amt;
    } else if (cat === "payment" || t.type === "payment") {
      paymentsTotal += amt;
    }
  }

  return {
    key, doneJobs, cancelled, turnover,
    avgPrice: doneJobs > 0 ? turnover / doneJobs : 0,
    sourceCommTotal, appCommTotal, subsTotal, calSubsTotal, paymentsTotal,
    drivers: [...drivers.entries()]
      .map(([uid, d]) => ({
        ...d,
        bySource: [...d.bySource.entries()]
          .map(([label, amt]) => ({ label, amt }))
          .sort((a, b) => b.amt - a.amt),
        // Μερίδιο του οδηγού σε κάθε ομάδα όπου δούλεψε
        groupShares: [...(drvGroup.get(uid) || new Map()).entries()]
          .map(([gid, amt]) => {
            const g = groups.get(gid);
            return {
              name: g ? g.name : (gid || "Χωρίς ομάδα"),
              amt,
              pct: g && g.turnover > 0 ? (amt / g.turnover) * 100 : 0,
            };
          })
          .sort((a, b) => b.amt - a.amt),
      }))
      .sort((a, b) => b.turnover - a.turnover),
    groups: [...groups.values()].sort((a, b) => b.turnover - a.turnover),
    topRoutes: [...routes.entries()]
      .map(([route, v]) => ({ route, count: v.count, total: v.total }))
      .sort((a, b) => (b.count - a.count) || (b.total - a.total))
      .slice(0, 5),
    admins:  [...admins.values()].sort((a, b) => b.posted - a.posted),
    adminYogurt: [...adminYogurt.entries()]
      .map(([name, amt]) => ({ name, amt }))
      .sort((a, b) => b.amt - a.amt),
    sources: [...sources.entries()]
      .map(([name, v]) => ({ name, ...v }))
      .sort((a, b) => b.turnover - a.turnover),
    dayCount, vehCount,
  };
}

// ─── Δημιουργία PDF (Buffer) ─────────────────────────────────────────────────
function buildReportPdf(agg, cmp) {
  // Lazy require: αν λείπει το pdfkit, σκάει μόνο αυτή η function στο runtime
  // — όχι όλο το deploy.
  const PDFDocument = require("pdfkit");

  const regular = path.join(__dirname, "fonts", "DejaVuSans.ttf");
  const bold    = path.join(__dirname, "fonts", "DejaVuSans-Bold.ttf");
  if (!fs.existsSync(regular) || !fs.existsSync(bold)) {
    throw new Error("Λείπουν τα fonts: functions/fonts/DejaVuSans(.ttf/-Bold.ttf)");
  }

  const eur = (n) => `${Number(n).toFixed(2)}€`;
  const pct = (part, total) =>
      total > 0 ? `${((part / total) * 100).toFixed(1)}%` : "—";
  const doc = new PDFDocument({ size: "A4", margin: 46 });
  const chunks = [];
  doc.on("data", (c) => chunks.push(c));

  const W = doc.page.width - doc.page.margins.left - doc.page.margins.right;
  const L = doc.page.margins.left;

  // Header
  doc.font(bold).fontSize(22).fillColor("#1A1A1A")
     .text("AthensTaxi — Μηνιαία Αναφορά", { align: "center" });
  doc.font(regular).fontSize(14).fillColor("#555555")
     .text(monthLabel(agg.key), { align: "center" });
  doc.moveDown(0.4);
  doc.moveTo(L, doc.y).lineTo(L + W, doc.y)
     .strokeColor("#FFC107").lineWidth(2).stroke();
  doc.moveDown(0.8);

  // ── Σύνοψη ──
  function summaryRow(label, value) {
    doc.font(regular).fontSize(11).fillColor("#444444")
       .text(label, L, doc.y, { continued: true, width: W });
    doc.font(bold).fillColor("#1A1A1A").text(value, { align: "right" });
    doc.moveDown(0.15);
  }
  doc.font(bold).fontSize(14).fillColor("#1A1A1A").text("Σύνοψη");
  doc.moveDown(0.3);
  const allJobs = agg.doneJobs + agg.cancelled;
  summaryRow("Ολοκληρωμένες δουλειές",
      `${agg.doneJobs} (${pct(agg.doneJobs, allJobs)})`);
  summaryRow("Ακυρωμένες δουλειές",
      `${agg.cancelled} (${pct(agg.cancelled, allJobs)})`);
  summaryRow("Συνολικός τζίρος", eur(agg.turnover));
  summaryRow("Μέση τιμή διαδρομής", eur(agg.avgPrice));
  summaryRow("Σύνολο γιαουρτιού (προμήθειες πηγής)", eur(agg.sourceCommTotal));
  summaryRow("Σύνολο προμήθειας App", eur(agg.appCommTotal));
  summaryRow("Συνδρομές", eur(agg.subsTotal));
  summaryRow("Συνδρομές ημερολογίου", eur(agg.calSubsTotal));
  summaryRow("Πληρωμές που εισπράχθηκαν", eur(agg.paymentsTotal));
  summaryRow("Δουλειές με ταξί / βαν",
      `${agg.vehCount.taxi} (${pct(agg.vehCount.taxi, agg.doneJobs)}) / ` +
      `${agg.vehCount.van} (${pct(agg.vehCount.van, agg.doneJobs)})`);
  summaryRow("Γιαούρτι ως % τζίρου", pct(agg.sourceCommTotal, agg.turnover));
  summaryRow("Προμήθεια App ως % τζίρου", pct(agg.appCommTotal, agg.turnover));

  // Σύγκριση με τον προηγούμενο μήνα
  if (cmp) {
    const delta = (cur, prev, isEur) => {
      const d = cur - prev;
      const pct = prev > 0 ? ` (${d >= 0 ? "+" : ""}${(d / prev * 100).toFixed(1)}%)` : "";
      const v = isEur ? eur(Math.abs(d)) : String(Math.abs(d));
      return `${d >= 0 ? "▲ +" : "▼ -"}${v}${pct}`;
    };
    doc.moveDown(0.4);
    doc.font(bold).fontSize(12).fillColor("#1A1A1A")
       .text(`Σύγκριση με ${monthLabel(cmp.key)}`);
    doc.moveDown(0.2);
    summaryRow("Δουλειές", delta(agg.doneJobs, cmp.doneJobs, false));
    summaryRow("Τζίρος",   delta(agg.turnover, cmp.turnover, true));
    summaryRow("Γιαούρτι", delta(agg.sourceCommTotal, cmp.sourceCommTotal, true));
    summaryRow("Προμήθεια App",
        delta(agg.appCommTotal, cmp.appCommTotal, true));
  }
  doc.moveDown(0.8);

  // ── Γενικός πίνακας ──
  function table(title, headers, widths, rows) {
    if (!rows.length) return;
    if (doc.y > doc.page.height - 160) doc.addPage();
    doc.font(bold).fontSize(14).fillColor("#1A1A1A").text(title, L, doc.y);
    doc.moveDown(0.35);

    const rowH = 18;
    let y = doc.y;
    // Επικεφαλίδες
    doc.rect(L, y - 3, W, rowH).fill("#FFF3CD");
    let x = L + 4;
    doc.font(bold).fontSize(9.5).fillColor("#7A5B00");
    headers.forEach((h, i) => {
      doc.text(h, x, y, { width: widths[i] - 8,
          align: i === 0 ? "left" : "right" });
      x += widths[i];
    });
    y += rowH;

    doc.font(regular).fontSize(9.5).fillColor("#333333");
    for (const row of rows) {
      // Υπολόγισε το πραγματικό ύψος της σειράς (κελιά που τυλίγονται σε >1 γραμμή)
      let cellH = rowH;
      row.forEach((cell, i) => {
        const h = doc.heightOfString(String(cell), { width: widths[i] - 8 });
        if (h + 6 > cellH) cellH = h + 6;
      });
      if (y + cellH > doc.page.height - 70) {
        doc.addPage(); y = doc.page.margins.top;
      }
      x = L + 4;
      row.forEach((cell, i) => {
        doc.text(String(cell), x, y, { width: widths[i] - 8,
            align: i === 0 ? "left" : "right" });
        x += widths[i];
      });
      y += cellH;
      doc.moveTo(L, y - 4).lineTo(L + W, y - 4)
         .strokeColor("#EEEEEE").lineWidth(0.5).stroke();
    }
    doc.y = y + 10;
    doc.x = L;
  }

  // Ανά οδηγό
  table("Ανά οδηγό",
    ["Οδηγός", "Δουλ.", "Τζίρος", "% τζίρου", "Γιαούρτι", "App", "Καθαρό"],
    [W * 0.26, W * 0.09, W * 0.14, W * 0.11, W * 0.14, W * 0.11, W * 0.15],
    agg.drivers.map((d) => [
      d.name, d.jobs, eur(d.turnover), pct(d.turnover, agg.turnover),
      eur(d.source), eur(d.app), eur(d.turnover - d.source - d.app),
    ]));

  // ── Αναλυτικά ανά οδηγό (μπλοκ με ανάλυση πηγών) ──
  doc.addPage();
  doc.font(bold).fontSize(15).fillColor("#1A1A1A")
     .text("Αναλυτικά ανά οδηγό", L, doc.y);
  doc.moveDown(0.5);
  for (const d of agg.drivers) {
    const blockH = 64 + d.bySource.length * 14;
    if (doc.y + blockH > doc.page.height - 70) doc.addPage();

    // Κεφαλίδα οδηγού
    doc.rect(L, doc.y - 2, W, 20).fill("#FFF8E1");
    doc.font(bold).fontSize(11).fillColor("#1A1A1A")
       .text(d.name, L + 6, doc.y + 1, { continued: true, width: W - 12 });
    doc.font(regular).fillColor("#555555")
       .text(`  —  ${((d.turnover / (agg.turnover || 1)) * 100).toFixed(1)}% του τζίρου`,
             { align: "right" });
    doc.moveDown(0.5);

    doc.font(regular).fontSize(10).fillColor("#333333").text(
      `Δουλειές: ${d.jobs}   •   Τζίρος: ${eur(d.turnover)}   •   ` +
      `Μέση τιμή: ${eur(d.jobs ? d.turnover / d.jobs : 0)}`, L + 6, doc.y,
      { width: W - 12 });
    const dPct = (n) => d.turnover > 0
      ? ` (${((n / d.turnover) * 100).toFixed(1)}%)` : "";
    doc.text(
      `Γιαούρτι: ${eur(d.source)}${dPct(d.source)}   •   ` +
      `Προμήθεια App: ${eur(d.app)}${dPct(d.app)}   •   ` +
      `Καθαρό: ${eur(d.turnover - d.source - d.app)}`, L + 6, doc.y,
      { width: W - 12 });

    // Μερίδιο του οδηγού στον τζίρο κάθε ομάδας όπου δούλεψε
    if (d.groupShares && d.groupShares.length) {
      const shares = d.groupShares
        .map((g) => `${g.name}: ${g.pct.toFixed(1)}% (${eur(g.amt)})`)
        .join("   •   ");
      doc.font(regular).fontSize(9.5).fillColor("#1565C0")
         .text(`Μερίδιο ανά ομάδα:  ${shares}`, L + 6, doc.y,
               { width: W - 12 });
    }

    // Ανάλυση: σε ποια πηγή & σε ποιον έδωσε γιαούρτι
    if (d.bySource.length) {
      doc.font(bold).fontSize(9).fillColor("#7A5B00")
         .text("Γιαούρτι ανά πηγή:", L + 6, doc.y + 2);
      doc.font(regular).fontSize(9).fillColor("#555555");
      for (const bs of d.bySource) {
        doc.text(`   •  ${bs.label}: ${eur(bs.amt)}`, L + 6, doc.y,
                 { width: W - 12 });
      }
    }
    doc.moveDown(0.7);
    doc.x = L;
  }
  doc.moveDown(0.3);

  // Ανά ομάδα
  const gp = (n, t) => t > 0 ? ` (${((n / t) * 100).toFixed(1)}%)` : "";
  table("Ανά ομάδα",
    ["Ομάδα", "Δουλ.", "Τζίρος", "% τζίρου", "Γιαούρτι", "App"],
    [W * 0.30, W * 0.10, W * 0.16, W * 0.12, W * 0.16, W * 0.16],
    agg.groups.map((g) => [
      g.name, g.jobs, eur(g.turnover), pct(g.turnover, agg.turnover),
      `${eur(g.source)}${gp(g.source, g.turnover)}`,
      `${eur(g.app)}${gp(g.app, g.turnover)}`,
    ]));

  // Ανά εργολάβο
  table("Ανά εργολάβο (ποιος έβγαλε τις δουλειές)",
    ["Εργολάβος", "Δουλειές", "% δουλειών", "Γιαούρτι που δικαιούται"],
    [W * 0.40, W * 0.16, W * 0.16, W * 0.28],
    agg.admins.map((a) => {
      const yog = agg.adminYogurt.find((x) => x.name === a.name);
      const amt = yog ? yog.amt : 0;
      return [a.name, a.posted, pct(a.posted, agg.doneJobs),
              `${eur(amt)}${gp(amt, agg.turnover)}`];
    }));

  // Ανά πηγή
  table("Ανά πηγή",
    ["Πηγή", "Δουλειές", "Τζίρος", "% τζίρου"],
    [W * 0.42, W * 0.16, W * 0.22, W * 0.20],
    agg.sources.map((s) => [
      s.name, s.jobs, eur(s.turnover), pct(s.turnover, agg.turnover)]));

  // Top διαδρομές
  table("Top 5 διαδρομές",
    ["Διαδρομή", "Φορές", "Τζίρος"],
    [W * 0.66, W * 0.14, W * 0.20],
    agg.topRoutes.map((r) => [r.route, r.count, eur(r.total)]));

  // Κατανομή ανά ημέρα
  table("Κατανομή ανά ημέρα εβδομάδας",
    ["Ημέρα", "Δουλειές", "%"],
    [W * 0.5, W * 0.25, W * 0.25],
    GREEK_DAYS.map((name, i) => [
      name, agg.dayCount[i], pct(agg.dayCount[i], agg.doneJobs)]));

  // Footer
  doc.moveDown(1);
  doc.font(regular).fontSize(8).fillColor("#999999")
     .text(`Δημιουργήθηκε αυτόματα από το AthensTaxi — ` +
           `${new Date().toLocaleString("el-GR", { timeZone: "Europe/Athens" })}`,
           L, doc.page.height - 60, { width: W, align: "center" });

  doc.end();
  return new Promise((resolve) => {
    doc.on("end", () => resolve(Buffer.concat(chunks)));
  });
}

// ─── Upload στο Google Drive του master ──────────────────────────────────────
const DRIVE_FOLDER_NAME = "AthensTaxi Αναφορές";

async function driveEnsureFolder(token) {
  const q = encodeURIComponent(
    `name='${DRIVE_FOLDER_NAME}' and ` +
    `mimeType='application/vnd.google-apps.folder' and trashed=false`);
  const r = await fetch(
    `https://www.googleapis.com/drive/v3/files?q=${q}&fields=files(id)`,
    { headers: { Authorization: `Bearer ${token}` } });
  const j = await r.json();
  if (!r.ok) throw new Error("Drive search: " + JSON.stringify(j));
  if (j.files && j.files.length) return j.files[0].id;

  const c = await fetch("https://www.googleapis.com/drive/v3/files", {
    method:  "POST",
    headers: { Authorization: `Bearer ${token}`,
               "Content-Type": "application/json" },
    body: JSON.stringify({
      name: DRIVE_FOLDER_NAME,
      mimeType: "application/vnd.google-apps.folder",
    }),
  });
  const cj = await c.json();
  if (!c.ok) throw new Error("Drive create folder: " + JSON.stringify(cj));
  return cj.id;
}

// Πόσους μήνες πίσω από τον τρέχοντα είναι ένα monthKey (0 = τρέχων).
function monthsAgo(key) {
  const [y, m] = key.split("-").map(Number);
  const now = new Date();
  return (now.getFullYear() - y) * 12 + (now.getMonth() + 1 - m);
}

// Διατηρούμε δεδομένα Firestore για τους τελευταίους 3 μήνες (+ τρέχων).
// Ό,τι είναι παλιότερο διαγράφεται (αφού περαστεί στο μηνιαίο PDF).
// ΣΗΜΕΙΩΣΗ: τα PDF στο Drive δεν διαγράφονται ποτέ.
const REPORT_RETENTION_MONTHS = 3;

async function driveUploadPdf(token, folderId, filename, buffer) {
  // Αν υπάρχει ήδη αναφορά ΙΔΙΟΥ μήνα (π.χ. ξανατρέξαμε χειροκίνητα),
  // ενημέρωσε το περιεχόμενό της αντί να δημιουργηθεί διπλότυπο.
  const safeName = filename.replace(/'/g, "\\'");
  const exQ = encodeURIComponent(
    `name='${safeName}' and '${folderId}' in parents and trashed=false`);
  const ex = await fetch(
    `https://www.googleapis.com/drive/v3/files?q=${exQ}&fields=files(id)`,
    { headers: { Authorization: `Bearer ${token}` } });
  const exJ = await ex.json();
  if (ex.ok && exJ.files && exJ.files.length) {
    const id = exJ.files[0].id;
    const u = await fetch(
      `https://www.googleapis.com/upload/drive/v3/files/${id}` +
      `?uploadType=media&fields=id,webViewLink`, {
        method:  "PATCH",
        headers: { Authorization: `Bearer ${token}`,
                   "Content-Type": "application/pdf" },
        body: buffer,
      });
    const uJ = await u.json();
    if (!u.ok) throw new Error("Drive update: " + JSON.stringify(uJ));
    console.log(`driveUploadPdf: updated existing report (${id})`);
    return uJ;
  }

  const boundary = "athens_taxi_report_" + Date.now();
  const meta = JSON.stringify({
    name: filename, parents: [folderId], mimeType: "application/pdf",
  });
  const head = Buffer.from(
    `--${boundary}\r\n` +
    `Content-Type: application/json; charset=UTF-8\r\n\r\n${meta}\r\n` +
    `--${boundary}\r\nContent-Type: application/pdf\r\n\r\n`);
  const tail = Buffer.from(`\r\n--${boundary}--`);
  const body = Buffer.concat([head, buffer, tail]);

  const r = await fetch(
    "https://www.googleapis.com/upload/drive/v3/files" +
    "?uploadType=multipart&fields=id,webViewLink", {
      method:  "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": `multipart/related; boundary=${boundary}`,
      },
      body,
    });
  const j = await r.json();
  if (!r.ok) throw new Error("Drive upload: " + JSON.stringify(j));
  return j; // {id, webViewLink}
}

// ─── Κοινή ροή: aggregate → PDF → Drive (με fallback Storage) ────────────────
// Κλειδί του μήνα ΠΡΙΝ από ένα δοσμένο monthKey
function monthKeyBefore(key) {
  let [y, m] = key.split("-").map(Number);
  m -= 1;
  if (m === 0) { m = 12; y -= 1; }
  return `${y}-${String(m).padStart(2, "0")}`;
}

async function runMonthlyReport(monthKey) {
  const agg = await aggregateMonth(monthKey);
  // Σύγκριση με τον προηγούμενο μήνα (best-effort — αν αποτύχει, χωρίς αυτήν)
  let cmp = null;
  try {
    cmp = await aggregateMonth(monthKeyBefore(monthKey));
  } catch (e) {
    console.warn("runMonthlyReport: no comparison month:", e.message || e);
  }
  const pdf = await buildReportPdf(agg, cmp);
  // Όνομα ανά μήνα (π.χ. «AthensTaxi Αναφορά Μάιος 2026.pdf») —
  // κάθε μήνας έχει ΔΙΚΟ του αρχείο, δεν γίνεται ποτέ overwrite άλλου μήνα.
  const filename = `AthensTaxi Αναφορά ${monthLabel(monthKey)}.pdf`;

  let link = null, where = "";
  const masterUid = await findMasterUid();
  if (masterUid) {
    const token = await freshAccessTokenFor(masterUid);
    if (token) {
      try {
        const folderId = await driveEnsureFolder(token);
        const file = await driveUploadPdf(token, folderId, filename, pdf);
        link  = file.webViewLink || null;
        where = "Google Drive";
        console.log(`monthlyReport: uploaded to Drive (${file.id})`);
      } catch (e) {
        console.error("monthlyReport Drive failed:", e.message || e);
      }
    } else {
      console.warn("monthlyReport: no Drive token — χρειάζεται " +
        "επανασύνδεση ημερολογίου με το νέο scope.");
    }
  }

  // Fallback: Firebase Storage
  if (!link) {
    try {
      const { getStorage } = require("firebase-admin/storage");
      const f = getStorage().bucket().file(`reports/${filename}`);
      await f.save(pdf, { contentType: "application/pdf" });
      where = "Firebase Storage (reports/)";
      console.log("monthlyReport: saved to Storage fallback");
    } catch (e) {
      console.error("monthlyReport Storage fallback failed:", e.message || e);
      throw e;
    }
  }

  // Ειδοποίηση στους masters
  try {
    const tokens = await getMasterTokens();
    await sendDataOnly(tokens, {
      type:  "monthly_report",
      title: `📊 Αναφορά ${monthLabel(monthKey)} έτοιμη`,
      body:  `Αποθηκεύτηκε στο ${where}.`,
      link:  String(link || ""),
      click_action: "FLUTTER_NOTIFICATION_CLICK",
    });
  } catch (_) { /* μη κρίσιμο */ }

  return { ok: true, monthKey, where, link,
           jobs: agg.doneJobs, turnover: agg.turnover };
}

// ─── Scheduled: κάθε 1η του μήνα, 06:00 ώρα Ελλάδας ─────────────────────────
exports.monthlyReport = onSchedule(
  { schedule: "0 6 1 * *", timeZone: "Europe/Athens",
    memory: "512MiB", timeoutSeconds: 300, secrets: [GCAL_CLIENT_SECRET] },
  async () => {
    const key = prevMonthKey(new Date());
    console.log("monthlyReport: generating for", key);
    await runMonthlyReport(key);

    // Μετά το report: αυτόματη διαγραφή παλιών δεδομένων (>3 μήνες), αλλά μόνο
    // αν δεν χρωστάει κανείς. Αν χρωστάει, ειδοποίησε τον master να το κάνει
    // χειροκίνητα αφού ξεχρεώσουν.
    try {
      const res = await purgeOldData();
      if (res.blocked) {
        const pending = await countPurgeableJobs();
        if (pending > 0) {
          const tokens = await getMasterTokens();
          await sendDataOnly(tokens, {
            type:  "purge_reminder",
            title: "🗄️ Εκκρεμεί καθαρισμός δεδομένων",
            body:  `Υπάρχουν ${pending} παλιές δουλειές (>3 μήνες) προς ` +
                   "διαγραφή, αλλά κάποιος χρωστάει. Καθάρισέ τες χειροκίνητα " +
                   "από το μενού αφού ξεχρεώσουν.",
            click_action: "FLUTTER_NOTIFICATION_CLICK",
          });
        }
      }
    } catch (e) {
      console.error("monthlyReport purge failed:", e.message || e);
    }
  });

// ─── Χειροκίνητη παραγωγή (μόνο master) ─────────────────────────────────────
exports.generateMonthlyReport = onCall(
  { memory: "512MiB", timeoutSeconds: 300, secrets: [GCAL_CLIENT_SECRET] },
  async (request) => {
    const uid = request.auth && request.auth.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Απαιτείται σύνδεση.");
    const me = await getFirestore().collection("presence").doc(uid).get();
    if (!me.exists || me.data().master !== true) {
      throw new HttpsError("permission-denied", "Μόνο για τον master.");
    }
    const key = (request.data && request.data.monthKey) ||
                prevMonthKey(new Date());
    if (!/^\d{4}-\d{2}$/.test(key)) {
      throw new HttpsError("invalid-argument", "monthKey: YYYY-MM");
    }
    return runMonthlyReport(key);
  });

// ─── Άνοιγμα του φακέλου Drive με τις μηνιαίες αναφορές (χωρίς να φτιάχνει
//     καινούργιο PDF) — έτσι ο master βλέπει όλους τους μήνες με ένα κλικ,
//     χωρίς να χρειάζεται να ξαναπατήσει «δημιουργία» κάθε φορά. ─────────────
exports.getReportsFolderLink = onCall(
  { memory: "256MiB", timeoutSeconds: 60, secrets: [GCAL_CLIENT_SECRET] },
  async (request) => {
    const uid = request.auth && request.auth.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Απαιτείται σύνδεση.");
    const me = await getFirestore().collection("presence").doc(uid).get();
    if (!me.exists || me.data().master !== true) {
      throw new HttpsError("permission-denied", "Μόνο για τον master.");
    }
    const masterUid = await findMasterUid();
    if (!masterUid) {
      throw new HttpsError("failed-precondition", "Δεν βρέθηκε master.");
    }
    const token = await freshAccessTokenFor(masterUid);
    if (!token) {
      throw new HttpsError("failed-precondition",
        "Δεν υπάρχει σύνδεση με το Google Drive — χρειάζεται επανασύνδεση " +
        "ημερολογίου (Ρυθμίσεις → Ημερολόγιο) για να αποκτηθεί το scope του Drive.");
    }
    const folderId = await driveEnsureFolder(token);
    return { link: `https://drive.google.com/drive/folders/${folderId}` };
  });

// ─── Διαγραφή παλιών δεδομένων Firestore (>3 μήνες) ─────────────────────────
//
// Στρατηγική χώρου: τα PDF στο Drive μένουν για πάντα (είναι το μόνιμο αρχείο),
// αλλά τα ωμά δεδομένα του Firestore (ολοκληρωμένες δουλειές + οι εγγραφές
// billing τους) διαγράφονται όταν περάσουν 3 μήνες, ΑΦΟΥ έχουν περαστεί στο
// μηνιαίο PDF. Έτσι δεν φουσκώνει το Firestore.
//
// ΚΡΙΣΙΜΗ ΦΡΑΓΗ: αν ΟΠΟΙΟΣΔΗΠΟΤΕ χρήστης έχει appDebt > 0, ΔΕΝ διαγράφεται
// τίποτα — γιατί οι παλιές εγγραφές μπορεί να τεκμηριώνουν αυτό το χρέος.
// Πρώτα ξεχρεώνουν όλοι, μετά καθαρίζουμε.
//
// Όταν διαγράφεται μια ολοκληρωμένη δουλειά, μειώνεται και ο τζίρος (turnover)
// του οδηγού κατά το ποσό της — ώστε τα running totals να μένουν συνεπή με τα
// δεδομένα που απομένουν.

// Αρχή του μήνα που είναι REPORT_RETENTION_MONTHS πίσω: ό,τι έχει doneAt πριν
// από αυτό διαγράφεται.
function purgeCutoffDate() {
  const now = new Date();
  // Πήγαινε στην 1η του τρέχοντος μήνα, μετά πίσω 3 μήνες.
  return new Date(now.getFullYear(), now.getMonth() - REPORT_RETENTION_MONTHS,
    1, 0, 0, 0);
}

// Υπάρχει έστω ένας χρήστης που χρωστάει; (φραγή διαγραφής)
async function anyoneHasDebt() {
  const db = getFirestore();
  const snap = await db.collection("presence")
    .where("appDebt", ">", 0).limit(1).get();
  return !snap.empty;
}

// Πόσες παλιές ολοκληρωμένες δουλειές υπάρχουν (>3 μήνες) — για υπενθύμιση.
async function countPurgeableJobs() {
  const db = getFirestore();
  const cutoff = purgeCutoffDate();
  const snap = await db.collection("jobs")
    .where("status", "==", "done")
    .where("doneAt", "<", cutoff)
    .count().get();
  return snap.data().count;
}

// Εκτελεί τη διαγραφή. Επιστρέφει {ok, deleted, turnoverRemoved} ή
// {blocked:true} αν κάποιος χρωστάει.
async function purgeOldData() {
  if (await anyoneHasDebt()) {
    console.warn("purgeOldData: αναβλήθηκε — υπάρχει εκκρεμές χρέος.");
    return { blocked: true, deleted: 0 };
  }

  const db = getFirestore();
  const cutoff = purgeCutoffDate();
  let deleted = 0;
  const turnoverByUid = {};   // πόσο τζίρο να αφαιρέσουμε ανά οδηγό

  // Δούλεψε σε σελίδες ώστε να μη φορτώσουμε χιλιάδες docs μαζί.
  // eslint-disable-next-line no-constant-condition
  while (true) {
    const page = await db.collection("jobs")
      .where("status", "==", "done")
      .where("doneAt", "<", cutoff)
      .limit(300)
      .get();
    if (page.empty) break;

    const batch = db.batch();
    for (const doc of page.docs) {
      const j = doc.data();
      const driverUid = j.takenBy;
      const price = Number(j.price) || 0;
      if (driverUid && price > 0) {
        turnoverByUid[driverUid] = (turnoverByUid[driverUid] || 0) + price;
      }

      // Διαγραφή των billing_tx αυτής της δουλειάς (αν υπάρχουν).
      const txs = await db.collection("billing_tx")
        .where("jobId", "==", doc.id).get();
      for (const t of txs.docs) batch.delete(t.ref);

      batch.delete(doc.ref);
      deleted++;
    }
    await batch.commit();
    if (page.size < 300) break;
  }

  // Μείωσε τον τζίρο κάθε οδηγού κατά το άθροισμα που διαγράφηκε.
  let turnoverRemoved = 0;
  for (const [uid, sum] of Object.entries(turnoverByUid)) {
    try {
      await db.collection("presence").doc(uid).update({
        turnover: FieldValue.increment(-sum),
      });
      turnoverRemoved += sum;
    } catch (e) {
      console.warn(`purgeOldData: turnover update failed for ${uid}:`,
        e.message || e);
    }
  }

  console.log(`purgeOldData: deleted ${deleted} jobs, ` +
    `removed €${turnoverRemoved.toFixed(2)} turnover.`);
  return { ok: true, deleted, turnoverRemoved };
}

// Χειροκίνητη εκτέλεση από τον master (κουμπί στο μενού).
exports.purgeOldDataNow = onCall(
  { memory: "512MiB", timeoutSeconds: 300 },
  async (request) => {
    const uid = request.auth && request.auth.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Απαιτείται σύνδεση.");
    const me = await getFirestore().collection("presence").doc(uid).get();
    if (!me.exists || me.data().master !== true) {
      throw new HttpsError("permission-denied", "Μόνο για τον master.");
    }
    const res = await purgeOldData();
    if (res.blocked) {
      throw new HttpsError("failed-precondition",
        "Υπάρχει εκκρεμές χρέος — δεν διαγράφηκε τίποτα. " +
        "Πρώτα να ξεχρεώσουν όλοι.");
    }
    return res;
  });

// Πληροφορία για το αν εκκρεμεί διαγραφή (για κουμπί/υπενθύμιση στο menu).
exports.purgeStatus = onCall(async (request) => {
  const uid = request.auth && request.auth.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Απαιτείται σύνδεση.");
  const me = await getFirestore().collection("presence").doc(uid).get();
  if (!me.exists || me.data().master !== true) {
    throw new HttpsError("permission-denied", "Μόνο για τον master.");
  }
  const [count, debt] = await Promise.all([
    countPurgeableJobs(),
    anyoneHasDebt(),
  ]);
  return { purgeableJobs: count, blockedByDebt: debt };
});

// ═══════════════════════════════════════════════════════════════════════════
//  onJobBilling — Server-side billing όταν η δουλειά γίνεται "done" (TRIGGER)
//
//  ΓΙΑΤΙ TRIGGER (όχι callable): Ο client απλώς γράφει status:"done" + doneAt
//  στη δουλειά — αυτό δουλεύει ΚΑΙ offline (Firestore offline persistence).
//  Μόλις συγχρονιστεί, αυτός ο trigger πυροδοτείται και κάνει ΟΛΟ το billing
//  με Admin SDK. Έτσι ο οδηγός ΠΟΤΕ δεν γράφει ο ίδιος appDebt/turnover, και
//  η ολοκλήρωση λειτουργεί ακόμα και χωρίς σήμα τη στιγμή που πατιέται.
//
//  ΠΥΡΟΔΟΤΗΣΗ: status: (οτιδήποτε ≠ done) → "done".
//
//  ΛΟΓΙΚΗ (ίδια ακριβώς με το παλιό client completeJob):
//   • collector: ομάδα δουλειάς → σπιτική → 1η ομάδα → poster (fallback)
//   • γιαούρτι (source commission): παραλείπεται αν ο οδηγός πήρε ΔΙΚΗ του δουλειά
//   • προμήθεια App: παραλείπεται αν ο οδηγός είναι master
//   • turnover += price (πάντα), appDebt += billedTotal (μόνο ό,τι χρεώνεται)
//
//  ΑΣΦΑΛΕΣ ΣΕ ΕΠΑΝΑΛΗΨΗ (idempotent): χρησιμοποιεί σημαία billedAt στο job.
//  Αν υπάρχει ήδη billedAt, δεν ξαναχρεώνει (triggers μπορεί να τρέξουν >1 φορά).
// ═══════════════════════════════════════════════════════════════════════════

const MASTER_RECIPIENT = "MASTER";

function _monthKeyJS(d) {
  const dt = d || new Date();
  const m = String(dt.getMonth() + 1).padStart(2, "0");
  return `${dt.getFullYear()}-${m}`;
}

async function _nameOfJS(db, uid) {
  if (!uid) return "";
  try {
    const d = (await db.collection("presence").doc(uid).get()).data();
    if (!d) return "";
    return `${d.displayName || ""} ${d.lastName || ""}`.trim();
  } catch (_) {
    return "";
  }
}

// Ο admin (collector) που μαζεύει φυσικά από τον οδηγό για ΑΥΤΗ τη δουλειά.
async function _resolveCollectorJS(db, { driverUid, jobGroupId, posterUid, posterName }) {
  try {
    const presence = (await db.collection("presence").doc(driverUid).get()).data() || {};
    const homeGroupId = presence.homeGroupId || "";

    const groupsSnap = await db.collection("groups").get();
    const driverGroups = {};
    groupsSnap.forEach((g) => {
      const members = Array.isArray(g.data().memberUids) ? g.data().memberUids : [];
      if (members.includes(driverUid)) driverGroups[g.id] = g.data();
    });

    let pick = null;
    if (jobGroupId && driverGroups[jobGroupId]) {
      pick = jobGroupId;
    } else if (homeGroupId && driverGroups[homeGroupId]) {
      pick = homeGroupId;
    } else if (Object.keys(driverGroups).length > 0) {
      pick = Object.keys(driverGroups)[0];
    }

    if (pick) {
      const g = driverGroups[pick];
      let adminUid = g.createdBy || "";
      if (!adminUid) {
        const admins = Array.isArray(g.adminUids) ? g.adminUids : [];
        if (admins.length > 0) adminUid = admins[0];
      }
      if (adminUid) {
        return { uid: adminUid, name: await _nameOfJS(db, adminUid) };
      }
    }
  } catch (_) {}
  return { uid: posterUid || "", name: posterName || "" };
}

exports.onJobBilling = onDocumentUpdated("jobs/{jobId}", async (event) => {
  const before = event.data.before.data();
  const after  = event.data.after.data();
  if (!before || !after) return;

  // Πυροδότηση ΜΟΝΟ στη μετάβαση → "done"
  if (before.status === "done" || after.status !== "done") return;

  // Idempotent: αν έχει ήδη χρεωθεί (billedAt), μην ξαναχρεώσεις.
  // (Triggers μπορεί να εκτελεστούν παραπάνω από μία φορά — at-least-once.)
  if (after.billedAt) return;

  const jobId = String(event.params.jobId);
  const db    = getFirestore();
  const ref   = db.collection("jobs").doc(jobId);
  const pre   = after;

  const driverUid = pre.takenBy || "";
  if (!driverUid) {
    console.log("onJobBilling: job", jobId, "χωρίς οδηγό — παράλειψη billing");
    // Σημείωσε ότι το είδαμε ώστε να μην ξαναπροσπαθεί.
    try { await ref.update({ billedAt: FieldValue.serverTimestamp() }); } catch (_) {}
    return;
  }

  // collector (reads εκτός transaction — όπως & στον client)
  const collector = await _resolveCollectorJS(db, {
    driverUid,
    jobGroupId: pre.groupId || "",
    posterUid:  pre.createdBy,
    posterName: pre.createdByName,
  });

  // Είναι ο οδηγός master; (δεν χρεώνεται προμήθεια App)
  let driverIsMaster = false;
  try {
    const pdoc = await db.collection("presence").doc(driverUid).get();
    driverIsMaster = pdoc.exists && pdoc.data().master === true;
  } catch (_) {}

  const result = await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) return { ok: false };
    const job = snap.data();

    // Διπλός έλεγχος μέσα στο transaction (race-safe): ήδη χρεωμένη;
    if (job.billedAt) return { ok: true, alreadyDone: true };

    // Σφραγίζουμε τη δουλειά ως «χρεωμένη» (idempotency marker)
    tx.update(ref, {
      billedAt: FieldValue.serverTimestamp(),
    });

    const price         = Number(job.price)         || 0;
    const commission    = Number(job.commission)    || 0;
    const appCommission = Number(job.appCommission) || 0;

    // ── ΕΙΔΙΚΗ ΠΕΡΙΠΤΩΣΗ: δουλειά πλήρως προπληρωμένη online (Viva) ──
    // Ο οδηγός ΔΕΝ εισέπραξε τίποτα σε μετρητά (όλο το ποσό είναι ήδη στον
    // master). Άρα ΔΕΝ ισχύει η κανονική ροή «ο οδηγός χρωστάει προμήθεια» —
    // αντίστροφα, ο master χρωστάει στον οδηγό το κέρδος του
    // (τιμή − commission − appCommission), ως ΠΙΣΤΩΣΗ (αρνητικό appDebt).
    if (job.fullyPaid === true) {
      const driverEarning = price - Math.max(commission, 0) - Math.max(appCommission, 0);
      const driverRef = db.collection("presence").doc(driverUid);
      // ΔΕΝ αγγίζουμε turnover (ο οδηγός δεν εισέπραξε μετρητά)· μόνο πίστωση.
      if (driverEarning !== 0) {
        tx.update(driverRef, { appDebt: FieldValue.increment(-driverEarning) });
        tx.set(db.collection("billing_tx").doc(), {
          uid:           driverUid,
          uidName:       job.takenByName || "",
          monthKey:      _monthKeyJS(job.doneAt ? job.doneAt.toDate() : new Date()),
          type:          "credit",
          sourceId:      job.sourceId   || "",
          sourceName:    job.sourceName || "Standard Rate",
          adminUid:      job.createdBy,
          adminName:     job.createdByName,
          collectorUid:  collector.uid,
          collectorName: collector.name,
          jobId:         String(jobId),
          note:          `Πλήρης προπληρωμή online — ${job.from || ""} → ${job.to || ""}`,
          voided:        false,
          createdAt:     FieldValue.serverTimestamp(),
          createdBy:     "SYSTEM",
          category:      "fully_prepaid_payout",
          amount:        -driverEarning, // αρνητικό = πίστωση προς τον οδηγό
          recipientUid:  driverUid,
          recipientName: job.takenByName || "",
        });
      }
      return { ok: true, billed: -driverEarning, fullyPrepaid: true };
    }

    const selfPosted   = job.createdBy === driverUid;
    // ΑΡΝΗΤΙΚΟ γιαούρτι = ο διαχειριστής χρωστάει στον οδηγό → μειώνει appDebt.
    // Γι' αυτό ελέγχουμε != 0 (όχι > 0).
    const chargeSource = commission    !== 0 && !selfPosted;
    const chargeApp    = appCommission  >  0 && !driverIsMaster;
    const billedTotal  = (chargeSource ? commission : 0) +
                         (chargeApp    ? appCommission : 0);

    const driverRef = db.collection("presence").doc(driverUid);
    // Αρνητικό γιαούρτι → προστίθεται στον τζίρο (ο οδηγός το εισέπραξε).
    const effPrice  = price - Math.min(commission, 0);
    const driverUpd = { turnover: FieldValue.increment(effPrice) };
    // billedTotal μπορεί να είναι αρνητικό → μειώνει το χρέος (συμψηφισμός).
    if (billedTotal !== 0) driverUpd.appDebt = FieldValue.increment(billedTotal);
    tx.update(driverRef, driverUpd);

    // Αν δεν υπάρχει ούτε χρέωση ούτε πίστωση → τέλος.
    if (!chargeSource && !chargeApp) return { ok: true, billed: 0 };

    const monthKey = _monthKeyJS(job.doneAt ? job.doneAt.toDate() : new Date());
    const base = {
      uid:           driverUid,
      uidName:       job.takenByName || "",
      monthKey,
      type:          "charge",
      sourceId:      job.sourceId   || "",
      sourceName:    job.sourceName || "Standard Rate",
      adminUid:      job.createdBy,
      adminName:     job.createdByName,
      collectorUid:  collector.uid,
      collectorName: collector.name,
      jobId:         String(jobId),
      note:          `${job.from || ""} → ${job.to || ""}`,
      voided:        false,
      createdAt:     FieldValue.serverTimestamp(),
      createdBy:     "SYSTEM",
    };

    if (chargeSource) {
      // amount μπορεί να είναι αρνητικό (πίστωση προς τον οδηγό).
      tx.set(db.collection("billing_tx").doc(), {
        ...base,
        category:      "source_commission",
        amount:        commission,
        recipientUid:  job.createdBy,
        recipientName: job.createdByName,
      });
    }
    if (chargeApp) {
      tx.set(db.collection("billing_tx").doc(), {
        ...base,
        category:      "app_commission",
        amount:        appCommission,
        recipientUid:  MASTER_RECIPIENT,
        recipientName: "Master",
      });
    }

    return { ok: true, billed: billedTotal };
  });

  console.log("onJobBilling: job", jobId, "→", JSON.stringify(result));
});

// ═══════════════════════════════════════════════════════════════════════════
//  monthlyCharges — Μηνιαίες συνδρομές server-side (SCHEDULED, 1η του μήνα)
//
//  ΓΙΑΤΙ: Παλιά η συνδρομή χρεωνόταν client-side «κατά το άνοιγμα της εφαρμογής».
//  Πρόβλημα 1: ο οδηγός έγραφε ο ίδιος το appDebt του (ίδια τρύπα ασφαλείας).
//  Πρόβλημα 2: όποιος δεν άνοιγε την εφαρμογή, δεν χρεωνόταν.
//  Εδώ τρέχει στον server την 1η κάθε μήνα και χρεώνει ΟΛΟΥΣ (λογιστικά σωστό).
//
//  Χρεώνει 2 πράγματα, ΣΤΟ ΙΔΙΟ scheduled job (= κρατάμε 2/3 δωρεάν scheduler):
//    • Βασική συνδρομή (settings.subscription) — σε όλους πλην master.
//    • Συνδρομή Ημερολογίου (settings.calendarSubscription) — μόνο σε όσους
//      έχουν calendarEnabled == true ΚΑΙ το ποσό > 0.
//
//  IDEMPOTENT: σημαίες lastSubscriptionMonth / lastCalendarSubMonth στο presence.
//  Αν ξανατρέξει τον ίδιο μήνα, δεν ξαναχρεώνει.
//
//  Τρέχει 05:30 (πριν το monthlyReport στις 06:00) ώστε οι συνδρομές να
//  μπαίνουν στο report του τρέχοντος μήνα.
// ═══════════════════════════════════════════════════════════════════════════

// Collector για συνδρομή: admin σπιτικής ομάδας· αλλιώς ο master κεντρικά.
async function _subCollectorJS(db, presenceData) {
  let collectorUid  = MASTER_RECIPIENT;
  let collectorName = "Master";
  const homeGroupId = (presenceData && presenceData.homeGroupId) || "";
  if (homeGroupId) {
    try {
      const g = (await db.collection("groups").doc(homeGroupId).get()).data();
      if (g) {
        let aUid = g.createdBy || "";
        if (!aUid) {
          const admins = Array.isArray(g.adminUids) ? g.adminUids : [];
          if (admins.length > 0) aUid = admins[0];
        }
        if (aUid) {
          collectorUid  = aUid;
          collectorName = await _nameOfJS(db, aUid);
        }
      }
    } catch (_) {}
  }
  return { collectorUid, collectorName };
}

async function runMonthlyCharges() {
  const db       = getFirestore();
  const monthKey = _monthKeyJS(new Date());

  // Ρυθμίσεις ποσών
  let subAmount = 5.0;
  let calAmount = 0.0;
  try {
    const s = (await db.collection("app_settings").doc("config").get()).data();
    if (s) {
      if (typeof s.subscription === "number") subAmount = s.subscription;
      if (typeof s.calendarSubscription === "number") calAmount = s.calendarSubscription;
    }
  } catch (_) {}

  const presSnap = await db.collection("presence").get();
  let basic = 0;
  let calend = 0;

  for (const doc of presSnap.docs) {
    const uid  = doc.id;
    const data = doc.data() || {};
    if (data.master === true) continue; // ο master δεν χρεώνεται

    const name = `${data.displayName || ""} ${data.lastName || ""}`.trim();
    const { collectorUid, collectorName } = await _subCollectorJS(db, data);

    // ── Βασική συνδρομή ──
    if (subAmount > 0 && data.lastSubscriptionMonth !== monthKey) {
      try {
        await db.runTransaction(async (tx) => {
          const fresh = await tx.get(doc.ref);
          if (fresh.data() && fresh.data().lastSubscriptionMonth === monthKey) return;
          tx.update(doc.ref, {
            appDebt: FieldValue.increment(subAmount),
            lastSubscriptionMonth: monthKey,
          });
          tx.set(db.collection("billing_tx").doc(), {
            uid, uidName: name, monthKey, type: "charge",
            category: "subscription", amount: subAmount,
            sourceId: "", sourceName: "", adminUid: "", adminName: "",
            recipientUid: MASTER_RECIPIENT, recipientName: "Master",
            collectorUid, collectorName,
            jobId: "", note: `Συνδρομή μηνός ${monthKey}`,
            voided: false, createdAt: FieldValue.serverTimestamp(),
            createdBy: "SYSTEM",
          });
        });
        basic++;
      } catch (e) {
        console.error("monthlyCharges sub failed for", uid, e.message || e);
      }
    }

    // ── Συνδρομή Ημερολογίου ──
    if (calAmount > 0 && data.calendarEnabled === true &&
        data.lastCalendarSubMonth !== monthKey) {
      try {
        await db.runTransaction(async (tx) => {
          const fresh = await tx.get(doc.ref);
          if (fresh.data() && fresh.data().lastCalendarSubMonth === monthKey) return;
          tx.update(doc.ref, {
            appDebt: FieldValue.increment(calAmount),
            lastCalendarSubMonth: monthKey,
          });
          tx.set(db.collection("billing_tx").doc(), {
            uid, uidName: name, monthKey, type: "charge",
            category: "calendar_subscription", amount: calAmount,
            sourceId: "", sourceName: "", adminUid: "", adminName: "",
            recipientUid: MASTER_RECIPIENT, recipientName: "Master",
            collectorUid, collectorName,
            jobId: "", note: `Συνδρομή Ημερολογίου ${monthKey}`,
            voided: false, createdAt: FieldValue.serverTimestamp(),
            createdBy: "SYSTEM",
          });
        });
        calend++;
      } catch (e) {
        console.error("monthlyCharges calendar sub failed for", uid, e.message || e);
      }
    }
  }

  console.log(`monthlyCharges ${monthKey}: ${basic} βασικές, ${calend} ημερολογίου`);
  return { monthKey, basic, calendar: calend };
}

// Αυτόματο: 1η του μήνα, 05:30 Αθήνα (πριν το report)
exports.monthlyCharges = onSchedule(
  { schedule: "30 5 1 * *", timeZone: "Europe/Athens",
    memory: "256MiB", timeoutSeconds: 300 },
  async () => {
    await runMonthlyCharges();
    // Πλήρες σκούπισμα pending_bookings >48h — piggyback στο ΙΔΙΟ scheduled
    // job (κανένας νέος scheduler). Batches των 300, μέχρι 20 γύρους.
    await cleanupStalePendingBookings(getFirestore(), { limit: 300, maxLoops: 20 });
  }
);

// Χειροκίνητο (μόνο master) — για δοκιμή ή αν χρειαστεί επανεκτέλεση.
exports.runMonthlyChargesNow = onCall(async (request) => {
  const uid = request.auth && request.auth.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Απαιτείται σύνδεση.");
  const me = await getFirestore().collection("presence").doc(uid).get();
  if (!me.exists || me.data().master !== true) {
    throw new HttpsError("permission-denied", "Μόνο για τον master.");
  }
  return await runMonthlyCharges();
});

// ════════════════════════════════════════════════════════════════════════════
// ΔΗΜΟΣΙΑ ΦΟΡΜΑ ΚΡΑΤΗΣΗΣ  (booking.html στο taxiathenstransfers.com)
// ────────────────────────────────────────────────────────────────────────────
// Ο πελάτης ΔΕΝ έχει Firebase login. Η φόρμα κάνει POST εδώ. Η function:
//   1) γράφει τη δουλειά ΩΣ ΑΠΟΘΗΚΕΥΜΕΝΗ στο saved_jobs (origin:'public_form')
//      με owner = ο master — ΔΕΝ μπαίνει στο jobs, ΔΕΝ ειδοποιεί οδηγούς.
//      Ο master αποφασίζει μετά αν θα την κάνει / στείλει / επεξεργαστεί.
//   2) στέλνει email με .ics στον master (Gmail API, ίδιο refresh token).
//   3) στέλνει FCM (type:'public_booking') στον master — ξεχωριστό εικονίδιο.
//
// ΦΑΣΗ 1: price = 0 (την βάζει ο master). Καμία χρέωση, καμία billing λογική.
//
// ⚠️ ΑΠΑΙΤΕΙΤΑΙ scope gmail.send στο OAuth του master (μία επανασύνδεση).
//    Αν λείπει, το email αποτυγχάνει σιωπηλά αλλά η δουλειά + το FCM περνούν.
// ════════════════════════════════════════════════════════════════════════════
const { onRequest } = require("firebase-functions/v2/https");

// Domain(s) που επιτρέπονται να καλέσουν τη function (CORS).
const BOOKING_ALLOWED_ORIGINS = [
  "https://taxiathenstransfers.com",
  "https://www.taxiathenstransfers.com",
  "https://booking2-template.pages.dev",
  // Καλύπτει ΟΛΑ τα Cloudflare Pages sites (και τα preview URLs με τυχαίο
  // prefix, π.χ. b3f904ca.booking2-template.pages.dev) — έτσι κάθε νέο site
  // πελάτη που φτιάχνεις σε Cloudflare Pages δουλεύει αυτόματα, χωρίς να
  // χρειάζεται να ξαναγυρίσεις εδώ κάθε φορά.
  /^https:\/\/([a-z0-9-]+\.)*pages\.dev$/,
];

// ── helper: ασφαλές κείμενο (όχι undefined/null) ────────────────────────────
function s(v) { return (v == null ? "" : String(v)).trim(); }

// ════════════════════════════════════════════════════════════════════════════
//  ΤΙΜΟΛΟΓΗΣΗ ΔΗΜΟΣΙΑΣ ΦΟΡΜΑΣ (estimatePrice + submitPublicBooking)
//
//  Ζώνες (πάγιες τιμές γνωστών διαδρομών) + δυναμικός τύπος για ό,τι δεν
//  ταιριάζει σε ζώνη + νυχτερινό τιμολόγιο + μπλάκαουτ/ελάχιστη προθεσμία.
//  Το κλειδί Google (Routes API) ΔΕΝ φεύγει ποτέ από τον server — secret.
// ════════════════════════════════════════════════════════════════════════════
const ROUTES_API_KEY = defineSecret("ROUTES_API_KEY");

// ── Ώρα Ελλάδας ως «naive» Date (τα UTC getters δείχνουν ελληνική ώρα) ──────
// Έτσι οι συγκρίσεις (προθεσμία, νυχτερινό, μπλάκαουτ) δουλεύουν σωστά χωρίς
// να εξαρτώνται από τη ζώνη ώρας του server.
function athensNaiveDate(realDate) {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Europe/Athens", year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false,
  }).formatToParts(realDate);
  const get = (t) => Number(parts.find((p) => p.type === t).value);
  return new Date(Date.UTC(get("year"), get("month") - 1, get("day"), get("hour"), get("minute"), get("second")));
}
function athensNaiveFromDateTimeStrings(dateStr, timeStr) {
  const [y, m, d] = s(dateStr).split("-").map(Number);
  const [hh, mm] = (s(timeStr) || "00:00").split(":").map(Number);
  if (!y || !m || !d) return null;
  return new Date(Date.UTC(y, m - 1, d, hh || 0, mm || 0, 0));
}
// Μετατρέπει ένα "naive" Athens Date (βλ. πάνω) σε ΠΡΑΓΜΑΤΙΚΟ UTC Date, ώστε να
// μπορεί να σταλεί ως departureTime στο Google Routes API (πρόβλεψη κίνησης
// για τη ΣΥΓΚΕΚΡΙΜΕΝΗ ώρα ραντεβού, όχι για τώρα). Ο υπολογισμός offset
// βασίζεται στο σημερινό offset Αθήνας (καλή προσέγγιση — μικρό ρίσκο μόνο
// στις 1-2 μέρες γύρω από αλλαγή ώρας θερινή/χειμερινή).
function athensNaiveToRealDate(naive) {
  const now = new Date();
  const nowNaive = athensNaiveDate(now);
  const offsetMs = nowNaive.getTime() - now.getTime();
  return new Date(naive.getTime() - offsetMs);
}

// ── Νυχτερινό τιμολόγιο 23:30–05:30 ──────────────────────────────────────────
function isNightWindow(naiveDate) {
  const mins = naiveDate.getUTCHours() * 60 + naiveDate.getUTCMinutes();
  return mins >= 23 * 60 + 30 || mins < 5 * 60 + 30;
}

// ── Μπλάκαουτ ξημερωμάτων — ΣΩΣΤΗ λογική:
// Το μπλοκάρισμα έχει νόημα ΜΟΝΟ όταν το ΤΩΡΑ είναι ήδη μέσα στο παράθυρο
// ξημερώματος (δηλ. ο πελάτης/οδηγός είναι ήδη σε ώρα ύπνου) ΚΑΙ η ζητούμενη
// ώρα πέφτει πριν τελειώσει αυτή η ΤΡΕΧΟΥΣΑ βάρδια ξημερώματος — δεν υπάρχει
// αρκετός χρόνος να το δει/προετοιμαστεί.
// Αν το ΤΩΡΑ είναι ΕΚΤΟΣ παραθύρου (δηλ. είναι μέρα), ΠΑΝΤΑ επιτρέπεται —
// υπάρχει όλη η μέρα μπροστά για προετοιμασία, ακόμα κι αν η διαδρομή πέφτει
// μέσα στο επερχόμενο βραδινό παράθυρο.
// Αν το ΤΩΡΑ είναι ΜΕΣΑ στο παράθυρο, αλλά η ζητούμενη ώρα είναι για την
// ΕΠΟΜΕΝΗ βάρδια ξημερώματος (π.χ. αύριο βράδυ) — πάλι επιτρέπεται, γιατί
// θα έχει ξυπνήσει και θα προλάβει.
//
// Παραδείγματα (παράθυρο 22:30–08:00):
//   τώρα 21:00, ζητά 03:00 (ίδια νύχτα)     → ΕΠΙΤΡΕΠΕΤΑΙ (τώρα εκτός παραθύρου)
//   τώρα 22:30, ζητά 03:00 (ίδια νύχτα)     → ΜΠΛΟΚΑΡΕΤΑΙ (τώρα μέσα, πολύ κοντά)
//   τώρα 23:30, ζητά αύριο 22:30            → ΕΠΙΤΡΕΠΕΤΑΙ (επόμενη βάρδια, θα ξυπνήσει)
//   τώρα 06:00, ζητά σήμερα 22:30           → ΕΠΙΤΡΕΠΕΤΑΙ (επόμενη βάρδια, θα ξυπνήσει)
function isBlackedOut(simNaive, scheduledNaive, startH, startM, endH, endM) {
  const nowMins = simNaive.getUTCHours() * 60 + simNaive.getUTCMinutes();
  const startMins = startH * 60 + startM;
  const endMins = endH * 60 + endM;

  // Το παράθυρο διασχίζει τα μεσάνυχτα (π.χ. 22:30–08:00) — αυτή είναι η
  // μόνη περίπτωση που υποστηρίζεται (ο διακόπτης είναι για ξημερώματα).
  const nowInsideWindow = nowMins >= startMins || nowMins < endMins;
  if (!nowInsideWindow) return false; // είναι μέρα — πάντα επιτρέπεται

  // Βρες πότε ΤΕΛΕΙΩΝΕΙ η βάρδια ξημερώματος που είναι ΕΝΕΡΓΗ τώρα.
  const occurrenceEnd = new Date(simNaive);
  occurrenceEnd.setUTCHours(endH, endM, 0, 0);
  if (nowMins >= startMins) {
    // Είμαστε στο βραδινό κομμάτι (π.χ. 22:30–23:59) → το τέλος είναι ΑΥΡΙΟ.
    occurrenceEnd.setUTCDate(occurrenceEnd.getUTCDate() + 1);
  }
  // Αν nowMins < endMins (π.χ. 03:00), το occurrenceEnd μένει ΣΗΜΕΡΑ endH:endM.

  return scheduledNaive < occurrenceEnd;
}

// ── Λόγοι μπλοκαρίσματος υποβολής (μπλάκαουτ / προθεσμία / μεγάλη παραγγελία)
// cfg: leadTimeMinutes, blackoutEnabled, blackoutStartHour/Minute, blackoutEndHour/Minute
function computeGate(simNaive, scheduledNaive, persons, luggage, cfg) {
  const reasons = [];
  if (!scheduledNaive) return reasons;
  const c = cfg || {};
  if (c.blackoutEnabled !== false) {
    const blocked = isBlackedOut(
      simNaive, scheduledNaive,
      c.blackoutStartHour ?? 22, c.blackoutStartMinute ?? 30,
      c.blackoutEndHour ?? 8, c.blackoutEndMinute ?? 0,
    );
    if (blocked) reasons.push("blackout");
  }
  const leadMinutes = (scheduledNaive - simNaive) / 60000;
  const minLeadMinutes = c.leadTimeMinutes ?? 120;
  if (leadMinutes < minLeadMinutes) reasons.push("lead_time");
  if (persons >= 5 || luggage >= 5) reasons.push("large_order");
  return reasons;
}

// ── Απόσταση ευθείας γραμμής (fallback αν αποτύχει το Routes API) ──────────
function haversineKm(a, b) {
  const R = 6371, toRad = (d) => (d * Math.PI) / 180;
  const dLat = toRad(b.lat - a.lat), dLng = toRad(b.lng - a.lng);
  const x = Math.sin(dLat / 2) ** 2 + Math.cos(toRad(a.lat)) * Math.cos(toRad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(x), Math.sqrt(1 - x));
}

// ── Ταίριασμα διαδρομής με αποθηκευμένο πελάτη (Αγαπημένοι προορισμοί) ──────
// Αν το «Από» Ή το «Προς» πέφτει κοντά στη βάση ενός πελάτη (≤400μ), ΚΑΙ το
// ΑΛΛΟ άκρο πέφτει κοντά σε μία από τις αποθηκευμένες διαδρομές του ίδιου
// πελάτη, χρησιμοποιούμε ΤΗ ΔΙΚΗ ΤΟΥ τιμή — αγνοώντας ζώνη/δυναμικό τύπο.
// Δουλεύει ΚΑΙ προς τις δύο κατευθύνσεις (πελάτης στο «από» ή στο «προς»).
const CLIENT_MATCH_KM = 0.4; // 400 μέτρα ανοχή
async function findClientRouteMatch(fromLat, fromLng, toLat, toLng, tenantId) {
  if (fromLat == null || fromLng == null || toLat == null || toLng == null) return null;
  try {
    const db = getFirestore();
    const q = tenantId && tenantId !== "default"
      ? db.collection("clients").where("tenantId", "==", tenantId)
      : db.collection("clients");
    const snap = await q.get();
    for (const doc of snap.docs) {
      const c = doc.data();
      if (c.fromLat == null || c.fromLng == null || !Array.isArray(c.routes)) continue;
      const base = { lat: c.fromLat, lng: c.fromLng };
      const distFrom = haversineKm({ lat: fromLat, lng: fromLng }, base);
      const distTo = haversineKm({ lat: toLat, lng: toLng }, base);
      let otherLat = null, otherLng = null;
      if (distFrom <= CLIENT_MATCH_KM) { otherLat = toLat; otherLng = toLng; }
      else if (distTo <= CLIENT_MATCH_KM) { otherLat = fromLat; otherLng = fromLng; }
      else continue;
      for (const r of c.routes) {
        if (r.toLat == null || r.toLng == null) continue;
        const d = haversineKm({ lat: otherLat, lng: otherLng }, { lat: r.toLat, lng: r.toLng });
        if (d <= CLIENT_MATCH_KM) {
          const n = (v) => (v == null ? null : Number(v));
          return {
            price: Number(r.price) || 0,
            nightPrice: n(r.nightPrice),
            priceForeign: n(r.priceForeign),
            nightPriceForeign: n(r.nightPriceForeign),
            van: n(r.van), vanNight: n(r.vanNight),
            vanForeign: n(r.vanForeign), vanNightForeign: n(r.vanNightForeign),
            bus: n(r.bus), busNight: n(r.busNight),
            busForeign: n(r.busForeign), busNightForeign: n(r.busNightForeign),
            shuttlePP: n(r.shuttlePP), shuttleNightPP: n(r.shuttleNightPP),
            shuttlePPForeign: n(r.shuttlePPForeign), shuttleNightPPForeign: n(r.shuttleNightPPForeign),
            clientName: c.name || "",
          };
        }
      }
    }
    return null;
  } catch (e) {
    console.error("findClientRouteMatch error:", e);
    return null;
  }
}


async function routesDistanceDuration(origin, dest, apiKey, departureTime) {
  if (!apiKey) return null;
  try {
    const body = {
      origin: { location: { latLng: { latitude: origin.lat, longitude: origin.lng } } },
      destination: { location: { latLng: { latitude: dest.lat, longitude: dest.lng } } },
      travelMode: "DRIVE",
      routingPreference: "TRAFFIC_AWARE",
    };
    // Αν έχουμε συγκεκριμένη μελλοντική ώρα ραντεβού, ζητάμε πρόβλεψη κίνησης
    // ΓΙ' ΕΚΕΙΝΗ την ώρα (όχι για τώρα) — TRAFFIC_AWARE_OPTIMAL υποστηρίζει
    // departureTime στο μέλλον.
    if (departureTime instanceof Date && !isNaN(departureTime.getTime()) &&
        departureTime.getTime() > Date.now()) {
      body.routingPreference = "TRAFFIC_AWARE_OPTIMAL";
      body.departureTime = departureTime.toISOString();
    }
    const resp = await fetch("https://routes.googleapis.com/directions/v2:computeRoutes", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Goog-Api-Key": apiKey,
        "X-Goog-FieldMask": "routes.distanceMeters,routes.duration,routes.polyline.encodedPolyline",
      },
      body: JSON.stringify(body),
    });
    const data = await resp.json();
    const route = data && data.routes && data.routes[0];
    if (!route) return null;
    return {
      distanceKm: Number(route.distanceMeters || 0) / 1000,
      durationMin: parseInt(route.duration, 10) / 60,
      polyline: (route.polyline && route.polyline.encodedPolyline) || null,
    };
  } catch (e) {
    console.error("routesDistanceDuration error:", e);
    return null;
  }
}

// ── Πρόχειρα όρια Αττικής (bounding box) — για να ξέρουμε πότε μια διαδρομή
// βγαίνει έξω και χρειάζεται 2€/χλμ + υποχρεωτική επικοινωνία μέσω WhatsApp.
const ATTICA_BOUNDS = { south: 37.55, north: 38.35, west: 23.10, east: 24.10 };
function isOutsideAttica(lat, lng) {
  if (lat == null || lng == null) return false;
  return lat < ATTICA_BOUNDS.south || lat > ATTICA_BOUNDS.north ||
         lng < ATTICA_BOUNDS.west || lng > ATTICA_BOUNDS.east;
}

// ── Έλεγχος αν ένα σημείο είναι μέσα σε μια ζώνη ────────────────────────────
// Υποστηρίζει: νέο μοντέλο ορθογωνίου (north/south/east/west) με προαιρετική
// περιστροφή rotationDeg γύρω από το κέντρο, ΚΑΙ το παλιό μοντέλο κύκλου
// (lat/lng/radius) για ζώνες που δεν έχουν ξανααποθηκευτεί με το νέο UI.
function pointInZone(lat, lng, z) {
  // ── ΝΕΟ μοντέλο: ελεύθερο ΠΟΛΥΓΩΝΟ (8 σημεία — «περίεργο οκτάγωνο»).
  // Ray-casting: μετράμε πόσες πλευρές τέμνει μια οριζόντια ακτίνα από το
  // σημείο — μονός αριθμός = μέσα. Δουλεύει για ΟΠΟΙΟΔΗΠΟΤΕ (και μη κυρτό)
  // πολύγωνο. Αν η ζώνη έχει points, ΑΥΤΑ μετράνε (τα παλιά bounds μένουν
  // μόνο ως πληροφορία/χάρτης-fit).
  if (Array.isArray(z.points) && z.points.length >= 3) {
    let inside = false;
    const pts = z.points;
    for (let i = 0, j = pts.length - 1; i < pts.length; j = i++) {
      const yi = Number(pts[i].lat), xi = Number(pts[i].lng);
      const yj = Number(pts[j].lat), xj = Number(pts[j].lng);
      if (!isFinite(yi) || !isFinite(xi) || !isFinite(yj) || !isFinite(xj)) continue;
      const intersects = ((yi > lat) !== (yj > lat)) &&
        (lng < (xj - xi) * (lat - yi) / (yj - yi) + xi);
      if (intersects) inside = !inside;
    }
    return inside;
  }
  if (z.north != null && z.south != null && z.east != null && z.west != null) {
    const rot = Number(z.rotationDeg || 0);
    if (!rot) {
      return lat <= z.north && lat >= z.south && lng <= z.east && lng >= z.west;
    }
    // Περιστραμμένο ορθογώνιο: φέρνουμε το σημείο στο «τοπικό» σύστημα του
    // ορθογωνίου (αντίστροφη περιστροφή γύρω από το κέντρο, σε μέτρα) και
    // συγκρίνουμε με το μισό πλάτος/ύψος.
    const cLat = (z.north + z.south) / 2;
    const cLng = (z.east + z.west) / 2;
    const mPerDegLat = 111320;
    const cosLat = Math.max(0.01, Math.abs(Math.cos(cLat * Math.PI / 180)));
    const halfH = (z.north - z.south) / 2 * mPerDegLat;
    const halfW = (z.east - z.west) / 2 * mPerDegLat * cosLat;
    const dyM = (lat - cLat) * mPerDegLat;
    const dxM = (lng - cLng) * mPerDegLat * cosLat;
    const rad = -rot * Math.PI / 180;
    const lx = dxM * Math.cos(rad) - dyM * Math.sin(rad);
    const ly = dxM * Math.sin(rad) + dyM * Math.cos(rad);
    return Math.abs(lx) <= halfW && Math.abs(ly) <= halfH;
  }
  if (z.lat == null || z.lng == null) return false;
  const dKm = haversineKm({ lat, lng }, { lat: z.lat, lng: z.lng });
  return dKm * 1000 <= Number(z.radius || 0);
}

// ── Ταίριασμα σημείου σε ζώνη (μέσα στα όριά της, η πιο κοντινή στο κέντρο
// αν το σημείο πέφτει μέσα σε παραπάνω από μία) ─────────────────────────────
function matchZone(lat, lng, zones) {
  let best = null, bestKm = Infinity;
  for (const z of zones) {
    if (z.lat == null || z.lng == null) continue;
    if (!pointInZone(lat, lng, z)) continue;
    const dKm = haversineKm({ lat, lng }, { lat: z.lat, lng: z.lng });
    if (dKm < bestKm) { best = z; bestKm = dKm; }
  }
  return best;
}

// ── Κλειδί ομαδοποίησης Shuttle — «ίδια ζώνη-σε-ζώνη + κοντινή ώρα» ώστε
// πολλές κρατήσεις Shuttle (π.χ. από 3 κοντινά Airbnb προς το αεροδρόμιο)
// να μπορούν να φανούν οπτικά μαζί στις Αποθηκευμένες και να «συγχωνευτούν»
// σε ΜΙΑ δουλειά. Το «κάδος ώρας» είναι 30λεπτος (00 ή 30) — ραντεβού μέσα
// στο ίδιο μισάωρο πιάνουν το ΙΔΙΟ κλειδί. null αν δεν βρέθηκε ζωνικό
// ταίριασμα και στα δύο άκρα (δεν έχει νόημα ομαδοποίηση εκτός ζωνών).
async function computeShuttleGroupKey({ fromLat, fromLng, toLat, toLng, scheduledNaive, tenantId }) {
  if (fromLat == null || fromLng == null || toLat == null || toLng == null || !scheduledNaive) return null;
  const { zones } = await getPricingData(tenantId);
  const fromZone = matchZone(fromLat, fromLng, zones);
  const toZone = matchZone(toLat, toLng, zones);
  if (!fromZone || !toZone) return null;

  const bucket = new Date(scheduledNaive);
  bucket.setUTCMinutes(bucket.getUTCMinutes() < 30 ? 0 : 30, 0, 0);
  const bucketKey = bucket.getUTCFullYear() + "-" + (bucket.getUTCMonth() + 1) + "-" +
    bucket.getUTCDate() + "T" + bucket.getUTCHours() + ":" + bucket.getUTCMinutes();

  return fromZone.id + ">" + toZone.id + "|" + bucketKey;
}

// ── Ρυθμίσεις τιμολόγησης (ζώνες + διαδρομές + δυναμικός τύπος), cache 60″ ──
// ΝΕΟ (multi-tenant, Φάση 3): ξεχωριστό cache + ξεχωριστά δεδομένα ανά
// tenantId. Ο δικός σου tenant ("default") συνεχίζει να χρησιμοποιεί
// ΑΚΡΙΒΩΣ τα ίδια docs που χρησιμοποιούσε πάντα (app_settings/pricing,
// pricing_zones/pricing_routes ΧΩΡΙΣ tenantId filter — για συμβατότητα με
// τα δικά σου δεδομένα πριν το backfillDefaultTenantId).
const _pricingCacheByTenant = new Map(); // tenantId -> { data, at }
// ── Βρίσκει τις 2 πλησιέστερες ώρες (πριν/μετά) από το σταθερό πρόγραμμα
// Shuttle, εφαρμόσιμες σε αυτή τη ζώνη (ή γενικές, χωρίς ζώνη). requestedMin
// = λεπτά από τα μεσάνυχτα (π.χ. 9:15 → 555). Επιστρέφει null αν δεν υπάρχει
// ΚΑΝΕΝΑ εφαρμόσιμο δρομολόγιο.
function nearestShuttleSlots(requestedMin, slots, fromZoneId, toZoneId) {
  const applicable = (slots || []).filter((s) =>
    !s.zoneId || s.zoneId === fromZoneId || s.zoneId === toZoneId);
  if (!applicable.length) return null;
  const toMin = (t) => {
    const parts = String(t).split(":");
    return (Number(parts[0]) || 0) * 60 + (Number(parts[1]) || 0);
  };
  const sorted = applicable
    .map((s) => ({ time: s.time, mins: toMin(s.time) }))
    .sort((a, b) => a.mins - b.mins);
  let before = null, after = null;
  for (const s of sorted) {
    if (s.mins <= requestedMin) before = s;
    if (s.mins >= requestedMin && !after) after = s;
  }
  if (!after) after = sorted[0];   // «μετά» τυλίγεται στο πρώτο δρομολόγιο της επόμενης μέρας
  if (!before) before = sorted[sorted.length - 1];
  // ── Αν πριν == μετά αλλά ΥΠΑΡΧΕΙ και δεύτερη διαφορετική ώρα στο
  // πρόγραμμα, δώσε την επόμενη διαφορετική ως «μετά» — έτσι ο πελάτης
  // βλέπει πάντα 2 πραγματικές επιλογές όταν υπάρχουν, αντί να «κλειδώνει»
  // σε μία. Αν το πρόγραμμα έχει όντως ΜΙΑ ώρα, μένει μία (η φόρμα δείχνει
  // ένα κουμπί).
  if (before.time === after.time) {
    const distinct = sorted.filter((s) => s.time !== before.time);
    if (distinct.length) {
      const next = distinct.find((s) => s.mins > before.mins) || distinct[0];
      after = next;
    }
  }
  return { before: before.time, after: after.time };
}

// Global προμήθεια app ανά κράτηση — ΙΔΙΟ doc (app_settings/config) με τη
// σελίδα «Διαχειριστές» στο Flutter (JobService.getAppSettings). Αφορά τις
// online κρατήσεις από τις δημόσιες φόρμες (χωρίς επιλεγμένη «πηγή»).
// Spam filters (SpamAssassin SUBJ_ALL_CAPS) υποβαθμίζουν emails με θέμα σε
// ΟΛΟΚΛΗΡΑ κεφαλαία. Οι διευθύνσεις "Από/Προς" έρχονται όπως τις γράφει ο
// πελάτης — αν τύχει να είναι όλο κεφαλαία, το ΘΕΜΑ (όχι το σώμα) τις δείχνει
// σε Title Case, ώστε να μη «μυρίζει» spam.
function titleCaseIfAllCaps(str) {
  const s2 = String(str || "");
  if (s2 === s2.toUpperCase() && /[A-ZΑ-Ω]/.test(s2)) {
    return s2.toLowerCase().replace(/(^|\s)(\S)/g, (m, sp, c) => sp + c.toUpperCase());
  }
  return s2;
}

async function getGlobalAppCommission() {
  try {
    const doc = await getFirestore().collection("app_settings").doc("config").get();
    return Number(doc.data()?.appCommission) || 0;
  } catch (e) {
    console.error("getGlobalAppCommission error:", e.message);
    return 0;
  }
}

async function getPricingData(tenantId) {
  const tid = tenantId || "default";
  const now = Date.now();
  const cached = _pricingCacheByTenant.get(tid);
  if (cached && now - cached.at < 60000) return cached.data;

  const db = getFirestore();
  const zonesQuery = tid === "default"
    ? db.collection("pricing_zones")
    : db.collection("pricing_zones").where("tenantId", "==", tid);
  const routesQuery = tid === "default"
    ? db.collection("pricing_routes")
    : db.collection("pricing_routes").where("tenantId", "==", tid);
  const cfgDocRef = tid === "default"
    ? db.collection("app_settings").doc("pricing")
    : db.collection("tenant_pricing_settings").doc(tid);

  const [zonesSnap, routesSnap, cfgDoc] = await Promise.all([
    zonesQuery.get(), routesQuery.get(), cfgDocRef.get(),
  ]);
  const zones = zonesSnap.docs.map((d) => ({ id: d.id, ...d.data() }));
  const routes = {};
  routesSnap.docs.forEach((d) => {
    const r = d.data();
    if (r.fromZoneId && r.toZoneId) routes[r.fromZoneId + ">" + r.toZoneId] = r;
  });
  const cfg = Object.assign(
    {
      base: 3.5, perKm: 1.0, perKmOutside: 1.2, perKmOutsideVan: 2.0, perMin: 0.2,
      minCharge: 25, minChargeNight: 35,
      nightPctTaxi: 30, nightPctVan: 25, vanPct: 90,
      luggagePer: 0, seatPrice: 5,
      nightAppliesToZones: true,
      // ── Ελάχιστη προθεσμία κράτησης (ώρες:λεπτά, π.χ. 1:15 = 75 λεπτά) ──
      leadTimeMinutes: 120, // προεπιλογή: 2 ώρες (ίδιο με πριν)
      // ── Μπλάκαουτ ξημερωμάτων (αν ενεργό, μπλοκάρει ραντεβού μέσα σε
      // αυτό το παράθυρο ώρας, ό,τι κι αν είναι η προθεσμία) ──
      blackoutEnabled: true, // προεπιλογή: ενεργό (ίδιο με πριν)
      blackoutStartHour: 22, blackoutStartMinute: 30,
      blackoutEndHour: 8, blackoutEndMinute: 0,
      // ── Ποσοστό προκαταβολής — προεπιλογή 10%, ρυθμίζεται ανά tenant ──
      depositPercent: 10,
      // Αν false, κρύβεται εντελώς η επιλογή «Πλήρης πληρωμή» στη φόρμα.
      fullPaymentEnabled: true,
      // ── Έκπτωση «γνωριμίας» στη δυναμική τιμολόγηση (εκτός ζωνών, εκτός
      // Shuttle) — προεπιλογή 8%. 0 = δείξε κατευθείαν την τελική τιμή.
      dynamicDiscountPercent: 8,
    },
    cfgDoc.exists ? cfgDoc.data() : {}
  );
  const result = { zones, routes, cfg };
  _pricingCacheByTenant.set(tid, { data: result, at: now });
  return result;
}

// ── Κεντρικός υπολογισμός τιμής (ζώνη ή δυναμικός τύπος + νυχτερινό) ───────
// Επιπλέον υπολογίζει την «αρχική τιμή» (πριν την έκπτωση γνωριμίας 8%) που
// εμφανίζεται διαγραμμένη δίπλα στην τελική τιμή. Για διαδρομές όπου ο
// Έλληνας πελάτης έχει ήδη χαμηλότερη τιμή από τον ξένο, χρησιμοποιούμε ΤΗΝ
// ΙΔΙΑ «αρχική» με του ξένου και υπολογίζουμε πόσο % έκπτωση βγαίνει αυτό
// (στρογγυλό, όχι δεκαδικό) — άρα ο Έλληνας βλέπει μεγαλύτερο ποσοστό.
//
// Κάθε τιμή του δυναμικού τύπου (base, perKm, perKmOutside, perMin, minCharge,
// minChargeNight, nightPctTaxi, nightPctVan, vanPct, luggagePer, seatPrice)
// μπορεί προαιρετικά να έχει ξεχωριστή τιμή για ξένους πελάτες, αποθηκευμένη
// στο ίδιο όνομα + "Foreign" (π.χ. perKmForeign). Αν δεν υπάρχει (null), οι
// ξένοι χρησιμοποιούν την ίδια τιμή με τους Έλληνες — καμία αλλαγή στη
// συμπεριφορά μέχρι ο master να ενεργοποιήσει συγκεκριμένο διακοπτάκι.
async function computeEstimate({
  fromLat, fromLng, toLat, toLng, persons, luggage, childSeatCount,
  vehicleType, isGreek, scheduledNaive, apiKey,
  cachedDistanceKm, cachedDurationMin, cachedRoutePolyline, needMap,
  tenantId, clientsOnlyMode,
}) {
  const { zones, routes, cfg } = await getPricingData(tenantId);
  const forced = persons >= 5 || luggage >= 5;

  const fromZone = fromLat != null && fromLng != null ? matchZone(fromLat, fromLng, zones) : null;
  const toZone = toLat != null && toLng != null ? matchZone(toLat, toLng, zones) : null;
  const zoneRoute = (fromZone && toZone) ? routes[fromZone.id + ">" + toZone.id] : null;

  // ── Τιμή πελάτη: υπολογίζεται ΝΩΡΙΣ (μία φορά) ώστε να τη βλέπουν ΟΛΟΙ οι
  // κλάδοι — Ταξί/Βαν (όπως πριν), και πλέον Λεωφορείο & Shuttle που μπορούν
  // να έχουν δικές τους τιμές ανά διαδρομή πελάτη.
  const clientMatch = await findClientRouteMatch(fromLat, fromLng, toLat, toLng, tenantId);

  // ── Shuttle: διαθέσιμο αν υπάρχει ζωνική τιμή/άτομο ΓΙΑ ΑΥΤΟ το ζεύγος
  // ζωνών Ή τιμή/άτομο στη διαδρομή πελάτη που ταίριαξε.
  const clientShuttlePP = clientMatch && Number(clientMatch.shuttlePP) > 0
    ? Number(clientMatch.shuttlePP) : 0;
  const shuttleAvailable =
    !!(zoneRoute && Number(zoneRoute.shuttlePricePerPerson) > 0) || clientShuttlePP > 0;

  if (vehicleType === "shuttle") {
    if (!shuttleAvailable) {
      return {
        price: 0, nightApplies: false, vehicle: "shuttle", zoneMatch: false,
        minChargeApplied: false, displayOriginal: 0, discountPercent: 0,
        outsideAttica: false, distanceKm: 0, durationMin: 0, routePolyline: null,
        shuttleAvailable: false,
      };
    }
    const departureTime = scheduledNaive ? athensNaiveToRealDate(scheduledNaive) : null;
    let distanceKm = 0, durationMin = 0, routePolyline = null;
    if (needMap && fromLat != null && fromLng != null && toLat != null && toLng != null) {
      if (cachedDistanceKm != null && Number(cachedDistanceKm) > 0) {
        distanceKm = Number(cachedDistanceKm);
        durationMin = Number(cachedDurationMin) || 0;
        routePolyline = cachedRoutePolyline || null;
      } else {
        const rd = await routesDistanceDuration(
          { lat: fromLat, lng: fromLng }, { lat: toLat, lng: toLng }, apiKey, departureTime);
        if (rd) { distanceKm = rd.distanceKm; durationMin = rd.durationMin; routePolyline = rd.polyline; }
      }
    }

    const isNightNow = !!scheduledNaive && isNightWindow(scheduledNaive);
    // ── Τιμή/άτομο: προτεραιότητα στη διαδρομή ΠΕΛΑΤΗ (αν έχει shuttle τιμή),
    // αλλιώς η ζωνική. Νύχτα/ξένος: αντίστοιχα πεδία αν υπάρχουν.
    let perPerson, minType, minValue;
    if (clientShuttlePP > 0) {
      const gDay = clientShuttlePP;
      const gNight = Number(clientMatch.shuttleNightPP) > 0 ? Number(clientMatch.shuttleNightPP) : gDay;
      const fDay = Number(clientMatch.shuttlePPForeign) > 0 ? Number(clientMatch.shuttlePPForeign) : null;
      const fNight = Number(clientMatch.shuttleNightPPForeign) > 0
        ? Number(clientMatch.shuttleNightPPForeign) : fDay;
      if (!isGreek && (isNightNow ? fNight : fDay) != null) {
        perPerson = isNightNow ? fNight : fDay;
      } else {
        perPerson = isNightNow ? gNight : gDay;
      }
      minType = "price"; minValue = 0; // καμία ελάχιστη χρέωση για shuttle πελάτη
    } else {
      perPerson = (isNightNow && Number(zoneRoute.shuttleNightPricePerPerson) > 0)
        ? Number(zoneRoute.shuttleNightPricePerPerson)
        : Number(zoneRoute.shuttlePricePerPerson);
      minType = zoneRoute.shuttleMinType === "persons" ? "persons" : "price";
      minValue = Number(zoneRoute.shuttleMinValue) || 0;
    }

    let billedPersons = persons;
    let minChargeApplied = false;
    if (minType === "persons" && minValue > persons) {
      billedPersons = minValue;
      minChargeApplied = true;
    }
    let price = billedPersons * perPerson;
    if (minType === "price" && price < minValue) {
      price = minValue;
      minChargeApplied = true;
    }
    price = Math.ceil(price);

    let shuttleSlotOptions = null;
    if (scheduledNaive) {
      const reqMin = scheduledNaive.getUTCHours() * 60 + scheduledNaive.getUTCMinutes();
      shuttleSlotOptions = nearestShuttleSlots(
        reqMin, cfg.shuttleTimeSlots,
        fromZone ? fromZone.id : null, toZone ? toZone.id : null);
    }

    return {
      price, nightApplies: isNightNow, vehicle: "shuttle", zoneMatch: true,
      minChargeApplied, displayOriginal: price, discountPercent: 0,
      outsideAttica: false, distanceKm, durationMin, routePolyline,
      shuttleAvailable: true, shuttlePricePerPerson: perPerson,
      shuttleSlotOptions,
    };
  }

  // ── Ποσοστιαία τιμή Λεωφορείου/Βαν πάνω από την ΚΑΝΟΝΙΚΗ (ελληνική) τιμή
  // Ταξί της ίδιας διαδρομής (ζωνική ή δυναμική) — fallback όταν δεν υπάρχει
  // ρητή τιμή. Το ποσοστό ξένου (…Foreign) υπολογίζεται ΚΙ ΑΥΤΟ πάνω στην
  // κανονική τιμή ταξί — π.χ. Ταξί+120% ο Έλληνας, Ταξί+140% ο ξένος.
  // Νύχτα: επιπλέον ποσοστό πάνω στην τιμή ΗΜΕΡΑΣ του οχήματος.
  async function pctOverTaxiEstimate(kind /* 'bus' | 'van' */) {
    const dayPct = Number(kind === "bus" ? cfg.busPctOverTaxi : cfg.vanPctOverTaxi) || 0;
    if (dayPct <= 0) return null;
    const dayPctForeign = Number(kind === "bus" ? cfg.busPctOverTaxiForeign : cfg.vanPctOverTaxiForeign) || 0;
    const nightExtra = Number(kind === "bus" ? cfg.busNightExtraPct : cfg.vanNightExtraPct) || 0;
    const nightExtraForeign = Number(kind === "bus" ? cfg.busNightExtraPctForeign : cfg.vanNightExtraPctForeign) || 0;
    // Τιμή Ταξί ΗΜΕΡΑΣ Έλληνα: ίδια διαδρομή, ώρα 12:00 ώστε η βάση να μην
    // περιέχει νυχτερινή προσαύξηση (η νύχτα μπαίνει με το δικό της ποσοστό).
    const noonNaive = scheduledNaive
      ? new Date(Date.UTC(scheduledNaive.getUTCFullYear(), scheduledNaive.getUTCMonth(), scheduledNaive.getUTCDate(), 12, 0, 0))
      : null;
    const taxiRes = await computeEstimate({
      fromLat, fromLng, toLat, toLng, persons, luggage, childSeatCount,
      vehicleType: "taxi", isGreek: true, scheduledNaive: noonNaive, apiKey,
      cachedDistanceKm, cachedDurationMin, cachedRoutePolyline, needMap,
      tenantId, clientsOnlyMode,
    });
    if (!taxiRes || !(taxiRes.price > 0) || taxiRes.noRouteAvailable) return null;
    const isNightNowPct = !!scheduledNaive && isNightWindow(scheduledNaive);
    const usePct = (!isGreek && dayPctForeign > 0) ? dayPctForeign : dayPct;
    const useNightExtra = (!isGreek && nightExtraForeign > 0) ? nightExtraForeign : nightExtra;
    let price = taxiRes.price * (1 + usePct / 100);
    if (isNightNowPct && useNightExtra > 0) price = price * (1 + useNightExtra / 100);
    price = Math.ceil(price);
    return {
      price, nightApplies: isNightNowPct, vehicle: kind, zoneMatch: !!taxiRes.zoneMatch,
      minChargeApplied: false, displayOriginal: price, discountPercent: 0,
      outsideAttica: !!taxiRes.outsideAttica, distanceKm: taxiRes.distanceKm || 0,
      durationMin: taxiRes.durationMin || 0, routePolyline: taxiRes.routePolyline || null,
      shuttleAvailable, noRouteAvailable: false,
    };
  }

  if (vehicleType === "bus") {
    // ── Λεωφορείο. Σειρά προτεραιότητας:
    // 0) Έλεγχος θέσεων: busMaxSeats <= 0 → ΠΑΝΤΑ WhatsApp. Άτομα πάνω από
    //    τις θέσεις → επίσης WhatsApp (noRouteAvailable, όπως πριν).
    // 1) Ρητή ζωνική τιμή (με προαιρετικά ξένου/νύχτας).
    // 2) Ποσοστό πάνω από Ταξί (γενική ρύθμιση busPctOverTaxi).
    // 3) Τίποτα → noRouteAvailable → η φόρμα δείχνει «στείλε WhatsApp».
    const busNoQuote = {
      price: 0, nightApplies: false, vehicle: "bus", zoneMatch: false,
      minChargeApplied: false, displayOriginal: 0, discountPercent: 0,
      outsideAttica: false, distanceKm: 0, durationMin: 0, routePolyline: null,
      shuttleAvailable: false, noRouteAvailable: true,
    };
    const busMaxSeats = cfg.busMaxSeats == null ? 20 : Number(cfg.busMaxSeats);
    if (busMaxSeats <= 0 || persons > busMaxSeats) return busNoQuote;

    const isNightNowBus = !!scheduledNaive && isNightWindow(scheduledNaive);
    // 1α) Τιμή λεωφορείου από διαδρομή ΠΕΛΑΤΗ — υπερισχύει της ζωνικής.
    if (clientMatch && Number(clientMatch.bus) > 0) {
      const gDay = Number(clientMatch.bus);
      const gNight = Number(clientMatch.busNight) > 0 ? Number(clientMatch.busNight) : gDay;
      const fDay = Number(clientMatch.busForeign) > 0 ? Number(clientMatch.busForeign) : null;
      const fNight = Number(clientMatch.busNightForeign) > 0
        ? Number(clientMatch.busNightForeign) : fDay;
      let busPrice;
      if (!isGreek && (isNightNowBus ? fNight : fDay) != null) {
        busPrice = isNightNowBus ? fNight : fDay;
      } else {
        busPrice = isNightNowBus ? gNight : gDay;
      }
      return {
        price: Math.ceil(busPrice), nightApplies: isNightNowBus, vehicle: "bus", zoneMatch: true,
        minChargeApplied: false, displayOriginal: Math.ceil(busPrice), discountPercent: 0,
        outsideAttica: false, distanceKm: 0, durationMin: 0, routePolyline: null,
        shuttleAvailable: false, noRouteAvailable: false,
      };
    }
    if (zoneRoute && Number(zoneRoute.busPrice) > 0) {
      const gDay = Number(zoneRoute.busPrice);
      const gNight = Number(zoneRoute.busNightPrice) > 0 ? Number(zoneRoute.busNightPrice) : gDay;
      const fDay = Number(zoneRoute.busForeign) > 0 ? Number(zoneRoute.busForeign) : null;
      const fNight = Number(zoneRoute.busNightForeign) > 0
        ? Number(zoneRoute.busNightForeign)
        : fDay; // ξένος χωρίς δική του νυχτερινή → η δική του ημέρας (αν έχει)
      let busPrice;
      if (!isGreek && (isNightNowBus ? fNight : fDay) != null) {
        busPrice = isNightNowBus ? fNight : fDay;
      } else {
        busPrice = isNightNowBus ? gNight : gDay;
      }
      return {
        price: Math.ceil(busPrice), nightApplies: isNightNowBus, vehicle: "bus", zoneMatch: true,
        minChargeApplied: false, displayOriginal: Math.ceil(busPrice), discountPercent: 0,
        outsideAttica: false, distanceKm: 0, durationMin: 0, routePolyline: null,
        shuttleAvailable: false, noRouteAvailable: false,
      };
    }
    const viaPct = await pctOverTaxiEstimate("bus");
    if (viaPct) return Object.assign({}, viaPct, { shuttleAvailable: false });
    return busNoQuote;
  }

  const vehicle = forced ? "van" : (vehicleType === "van" ? "van" : "taxi");

  // Επιλογή τιμής ανά εθνικότητα για τον δυναμικό τύπο.
  function pick(key, useGreek) {
    const foreignVal = cfg[key + "Foreign"];
    if (!useGreek && foreignVal != null) return Number(foreignVal);
    return Number(cfg[key]);
  }

  let basePrice = 0;         // τιμή αυτού του πελάτη, πριν το νυχτερινό
  let baseOtherPrice = null; // τιμή που θα είχε ο «άλλος τύπος» πελάτη (για το reference/έκπτωση)
  let zoneMatch = false;
  let minChargeApplied = false;
  let outsideAttica = false;
  let distanceKm = 0, durationMin = 0;
  let routePolyline = null; // για εμφάνιση στον χάρτη (booking.html)
  const departureTime = scheduledNaive ? athensNaiveToRealDate(scheduledNaive) : null;

  // ── Νυχτερινό — υπολογίζεται ΝΩΡΙΣ γιατί χρειάζεται ήδη εδώ για να
  // διαλέξουμε σταθερή νυχτερινή τιμή διαδρομής, αν υπάρχει ορισμένη.
  const isNightNow = !!scheduledNaive && isNightWindow(scheduledNaive);
  const nightApplies = isNightNow && (!zoneRoute || cfg.nightAppliesToZones);

  let usedFixedNightPrice = false;

  // ── Τιμή πελάτη (Αγαπημένοι προορισμοί) — αν το «Από» ή το «Προς» ταιριάζει
  // με πελάτη ΚΑΙ το άλλο άκρο με μία αποθηκευμένη διαδρομή του, η τιμή ΤΟΥ
  // υπερισχύει ΠΑΝΤΑ ζώνης/δυναμικού τύπου. (Το clientMatch υπολογίστηκε ήδη
  // νωρίτερα, μία φορά, ώστε να το βλέπουν και Λεωφορείο/Shuttle.)

  // ── Λειτουργία «μόνο πελάτες» (Places απενεργοποιημένο για τον tenant) —
  // χωρίς πραγματική διεύθυνση Google, ΔΕΝ έχει νόημα ζωνική/δυναμική τιμή.
  // Αν δεν βρέθηκε ΤΙΠΟΤΑ στους πελάτες, στέλνουμε κατευθείαν σε WhatsApp
  // (ίδιος μηχανισμός με το «λεωφορείο χωρίς διαδρομή»).
  if (clientsOnlyMode && !clientMatch) {
    return {
      price: 0, nightApplies: false, vehicle, zoneMatch: false,
      minChargeApplied: false, displayOriginal: 0, discountPercent: 0,
      outsideAttica: false, distanceKm: 0, durationMin: 0, routePolyline: null,
      shuttleAvailable: false, noRouteAvailable: true, clientMatchedName: null,
    };
  }

  // ── Βαν με ποσοστό πάνω από Ταξί (fallback) — ΜΟΝΟ όταν δεν υπάρχει τιμή
  // πελάτη, ούτε ρητή ζωνική τιμή Βαν για τη διαδρομή, και έχει οριστεί
  // ποσοστό (vanPctOverTaxi) στους δυναμικούς τύπους. Αλλιώς όλα όπως πριν.
  if (vehicle === "van" && !clientMatch && !(zoneRoute && Number(zoneRoute.van) > 0)) {
    const vanViaPct = await pctOverTaxiEstimate("van");
    if (vanViaPct) return vanViaPct;
  }

  if (clientMatch) {
    zoneMatch = true; // ώστε να παρακαμφθεί ο δυναμικός τύπος παρακάτω
    // ── Ανά όχημα: το Βαν χρησιμοποιεί τα δικά του πεδία αν υπάρχουν,
    // αλλιώς πέφτει στα (παλιά) πεδία Ταξί — ίδια συμπεριφορά με πριν.
    // Ξένος: αντίστοιχα Foreign πεδία αν υπάρχουν, αλλιώς η κανονική τιμή.
    const isVan = vehicle === "van";
    const pos = (v) => (v != null && Number(v) > 0 ? Number(v) : null);
    const dayG = isVan ? (pos(clientMatch.van) ?? clientMatch.price) : clientMatch.price;
    const nightG = isVan ? (pos(clientMatch.vanNight) ?? pos(clientMatch.nightPrice)) : pos(clientMatch.nightPrice);
    const dayF = isVan ? (pos(clientMatch.vanForeign) ?? pos(clientMatch.priceForeign)) : pos(clientMatch.priceForeign);
    const nightF = isVan ? (pos(clientMatch.vanNightForeign) ?? pos(clientMatch.nightPriceForeign)) : pos(clientMatch.nightPriceForeign);
    const day = (!isGreek && dayF != null) ? dayF : dayG;
    const nightVal = (!isGreek && nightF != null) ? nightF : nightG;
    const useNight = isNightNow && nightVal != null;
    basePrice = useNight ? nightVal : day;
    usedFixedNightPrice = useNight; // η τιμή ΕΙΝΑΙ ήδη η νυχτερινή — μη ξαναπολλαπλασιάσεις
  } else if (zoneRoute) {
    zoneMatch = true;
    const ownField = vehicle === "van" ? "van" : "taxi";
    const foreignField = vehicle === "van" ? "vanForeign" : "taxiForeign";
    // ── Σταθερή νυχτερινή τιμή διαδρομής (προαιρετική, ανά ζώνη-σε-ζώνη).
    // Αν οριστεί, ΑΝΤΙΚΑΘΙΣΤΑ εντελώς το ποσοστιαίο νυχτερινό των δυναμικών
    // τύπων — γι' αυτή τη διαδρομή. Αν ΔΕΝ οριστεί, ισχύει το κανονικό
    // ποσοστό (cfg.nightPctTaxi/nightPctVan), όπως πάντα.
    const ownNightField = vehicle === "van" ? "vanNight" : "taxiNight";
    const foreignNightField = vehicle === "van" ? "vanNightForeign" : "taxiNightForeign";
    const hasFixedNight = isNightNow && Number(zoneRoute[ownNightField]) > 0;
    usedFixedNightPrice = hasFixedNight;

    const ownPrice = hasFixedNight ? Number(zoneRoute[ownNightField]) : Number(zoneRoute[ownField] || 0);
    let foreignPrice = null;
    if (hasFixedNight) {
      foreignPrice = zoneRoute[foreignNightField] != null ? Number(zoneRoute[foreignNightField]) : null;
    } else {
      foreignPrice = zoneRoute[foreignField] != null ? Number(zoneRoute[foreignField]) : null;
    }

    if (foreignPrice != null && isGreek) {
      basePrice = ownPrice;
      baseOtherPrice = foreignPrice; // ο ξένος είναι η βάση αναφοράς (τυπικό -8%)
    } else if (foreignPrice != null && !isGreek) {
      basePrice = foreignPrice;
    } else {
      basePrice = ownPrice;
    }
  }

  // ── Cache διαδρομής: αν ο client μας έστειλε ήδη υπολογισμένα km/λεπτά/
  // polyline για την ΙΔΙΑ διαδρομή (μόνο ημερομηνία/ώρα/άτομα άλλαξαν),
  // τα χρησιμοποιούμε ΑΝΤΙ να ξαναρωτήσουμε τη Google — εξοικονομεί Routes
  // API κλήσεις σημαντικά.
  const useCache = cachedDistanceKm != null && Number(cachedDistanceKm) > 0;

  // ── Ζωνική διαδρομή: η ΤΙΜΗ είναι σταθερή (πάγια) — η απόσταση/χρόνος/
  // polyline χρειάζονται ΜΟΝΟ για εμφάνιση στον χάρτη. Αν ο client δεν τα
  // χρειάζεται ακόμα (needMap===false, π.χ. δεν έχει μπει όνομα στη φόρμα),
  // ΔΕΝ καλούμε καθόλου τη Google — εξοικονομεί ολόκληρη την κλήση.
  if (zoneMatch && needMap && fromLat != null && fromLng != null && toLat != null && toLng != null) {
    if (useCache) {
      distanceKm = Number(cachedDistanceKm);
      durationMin = Number(cachedDurationMin) || 0;
      routePolyline = cachedRoutePolyline || null;
    } else {
      const rd = await routesDistanceDuration(
        { lat: fromLat, lng: fromLng }, { lat: toLat, lng: toLng }, apiKey, departureTime);
      if (rd) {
        distanceKm = rd.distanceKm;
        durationMin = rd.durationMin;
        routePolyline = rd.polyline;
      }
    }
  }

  if (!zoneMatch) {
    if (fromLat != null && fromLng != null && toLat != null && toLng != null) {
      if (useCache) {
        distanceKm = Number(cachedDistanceKm);
        durationMin = Number(cachedDurationMin) || 0;
        routePolyline = cachedRoutePolyline || null;
      } else {
        const rd = await routesDistanceDuration(
          { lat: fromLat, lng: fromLng }, { lat: toLat, lng: toLng }, apiKey, departureTime);
        if (rd) {
          distanceKm = rd.distanceKm;
          durationMin = rd.durationMin;
          routePolyline = rd.polyline;
        } else {
          distanceKm = haversineKm({ lat: fromLat, lng: fromLng }, { lat: toLat, lng: toLng }) * 1.3;
          durationMin = (distanceKm / 45) * 60;
        }
      }
    }
    outsideAttica = isOutsideAttica(fromLat, fromLng) || isOutsideAttica(toLat, toLng);

    // Υπολογίζει την πλήρη δυναμική τιμή (πριν νυχτερινό/ελάχιστη) για τη
    // δοσμένη εθνικότητα — χρησιμοποιείται ΚΑΙ για τον ίδιο τον πελάτη ΚΑΙ
    // για το reference (ώστε να δείχνεται σωστή έκπτωση γνωριμίας).
    function dynamicPrice(useGreek) {
      const base = pick("base", useGreek);
      const perMinNow = pick("perMin", useGreek);
      const luggagePerNow = pick("luggagePer", useGreek);
      const vanPctNow = pick("vanPct", useGreek);

      // ── Χιλιομετρική χρέωση ─────────────────────────────────────────────
      // ΕΝΤΟΣ Αττικής: όπως πριν — ενιαίο perKm, μπαίνει στο άθροισμα που
      // παίρνει τη γενική προσαύξηση βαν (vanPct) μαζί με base/χρόνο/βαλίτσες.
      // ΕΚΤΟΣ Αττικής: ΣΤΑΘΕΡΗ τιμή ανά όχημα (1,2€/χλμ ταξί, 2€/χλμ βαν),
      // η οποία ΔΕΝ παίρνει επιπλέον προσαύξηση vanPct από πάνω — το 2€ του
      // βαν είναι ήδη η τελική τιμή.
      let kmCost;
      if (outsideAttica) {
        const perKmOutsideField = vehicle === "van" ? "perKmOutsideVan" : "perKmOutside";
        kmCost = distanceKm * pick(perKmOutsideField, useGreek);
      } else {
        kmCost = distanceKm * pick("perKm", useGreek);
      }

      let p = base + durationMin * perMinNow + luggage * luggagePerNow;
      if (!outsideAttica) p += kmCost; // εντός Αττικής: μπαίνει ΠΡΙΝ το van markup, όπως πριν
      // ΣΗΜΕΙΩΣΗ: η επιβάρυνση παιδικού καθίσματος ΔΕΝ μπαίνει εδώ πια —
      // προστίθεται ξεχωριστά, ΠΑΝΤΑ σταθερή, ΜΕΤΑ την ελάχιστη χρέωση
      // (βλ. seatFeeOwn/seatFeeOther παρακάτω), ώστε να μην «χάνεται» μέσα
      // στην ελάχιστη χρέωση όταν η βασική τιμή είναι μικρή.
      if (vehicle === "van") p = p * (1 + vanPctNow / 100);

      if (outsideAttica) p += kmCost; // εκτός Αττικής: σταθερό ανά όχημα, ΧΩΡΙΣ vanPct πάνω του
      return p;
    }

    basePrice = dynamicPrice(isGreek);
    baseOtherPrice = dynamicPrice(!isGreek); // πάντα υπολογίζεται, ώστε να δείχνεται σωστή έκπτωση
  }

  // ── Επιβάρυνση παιδικού καθίσματος — ΠΑΝΤΑ σταθερή (π.χ. +7€/κάθισμα),
  // ΔΕΝ επηρεάζεται από νυχτερινή προσαύξηση ούτε απορροφάται από την
  // ελάχιστη χρέωση. Προστίθεται στο τέλος, πάνω από ό,τι κι αν προκύψει.
  const seatFeeOwn   = childSeatCount * pick("seatPrice", isGreek);
  const seatFeeOther = childSeatCount * pick("seatPrice", !isGreek);

  // ── Νυχτερινό — για ζώνες κοινό ποσοστό (η διαφοροποίηση Έλληνα/ξένου
  // γίνεται ήδη μέσω taxi/taxiForeign στη διαδρομή), για δυναμικό τύπο ανά
  // εθνικότητα αν έχει οριστεί ξεχωριστό ποσοστό. (isNightNow/nightApplies
  // υπολογίστηκαν ΝΩΡΙΤΕΡΑ, πριν την επιλογή τιμής ζώνης.)
  function nightMultFor(useGreek) {
    if (!nightApplies) return 1;
    if (usedFixedNightPrice) return 1; // η τιμή ΕΙΝΑΙ ήδη η σταθερή νυχτερινή — δεν ξαναπολλαπλασιάζουμε
    const pct = zoneMatch
      ? (vehicle === "van" ? cfg.nightPctVan : cfg.nightPctTaxi)
      : pick(vehicle === "van" ? "nightPctVan" : "nightPctTaxi", useGreek);
    return 1 + pct / 100;
  }

  let price = basePrice * nightMultFor(isGreek);
  let referencePriceRaw = baseOtherPrice != null ? baseOtherPrice * nightMultFor(!isGreek) : price;

  // Η ελάχιστη χρέωση (25€ μέρα / 35€ νύχτα, ή οι ξένες τιμές αν έχουν
  // οριστεί) εφαρμόζεται στο ΤΕΛΙΚΟ ποσό — μετά το νυχτερινό, όχι πριν.
  if (!zoneMatch) {
    const minKey = isNightNow ? "minChargeNight" : "minCharge";
    const minOwn = pick(minKey, isGreek);
    const minOther = pick(minKey, !isGreek);
    if (price < minOwn) minChargeApplied = true;
    price = Math.max(price, minOwn);
    referencePriceRaw = Math.max(referencePriceRaw, minOther);
  }

  // ── Επιβάρυνση παιδικού καθίσματος πάνω από ΟΤΙΔΗΠΟΤΕ έχει προκύψει μέχρι
  // τώρα (ζωνική τιμή, δυναμικός τύπος, ή ελάχιστη χρέωση) — σταθερή,
  // ανεξάρτητη από νυχτερινό/ελάχιστο, όπως ζητήθηκε.
  price += seatFeeOwn;
  referencePriceRaw += seatFeeOther;

  price = Math.floor(price);
  const referencePrice = Math.floor(referencePriceRaw);

  // «Αρχική τιμή» = αυτή που, με -Χ% ρυθμιζόμενη έκπτωση γνωριμίας, δίνει
  // ακριβώς την τιμή αναφοράς (του ξένου πελάτη, ή τη δική του τιμή αν δεν
  // υπάρχει διαφοροποίηση). Ο Έλληνας βλέπει την ΙΔΙΑ αρχική με τον ξένο,
  // οπότε το πραγματικό του ποσοστό έκπτωσης βγαίνει μεγαλύτερο.
  // Αν discountPct είναι 0, ΔΕΝ δείχνουμε καθόλου «αρχική»/έκπτωση — η
  // displayOriginal γίνεται ίση με την τελική τιμή (καμία διαγραφή στη φόρμα).
  const discountPct = Number(cfg.dynamicDiscountPercent);
  const discountFrac = isFinite(discountPct) && discountPct > 0 ? discountPct / 100 : 0;
  let displayOriginal, discountPercent;
  if (discountFrac <= 0) {
    displayOriginal = price;
    discountPercent = 0;
  } else {
    displayOriginal = Math.round((referencePrice / (1 - discountFrac)) * 100) / 100;
    discountPercent = displayOriginal > 0 ? Math.round((1 - price / displayOriginal) * 100) : discountPct;
    if (!isFinite(discountPercent)) discountPercent = discountPct;
  }

  return { price, nightApplies, vehicle, zoneMatch, minChargeApplied, displayOriginal, discountPercent, outsideAttica, distanceKm, durationMin, routePolyline, shuttleAvailable, clientMatchedName: clientMatch ? clientMatch.clientName : null };
}

// ── estimatePrice: καλείται ζωντανά από τη φόρμα καθώς συμπληρώνει ο πελάτης ─
exports.estimatePrice = onRequest(
  { region: "us-central1", cors: BOOKING_ALLOWED_ORIGINS, memory: "256MiB", secrets: [ROUTES_API_KEY] },
  async (req, res) => {
    if (req.method !== "POST") return res.status(405).json({ ok: false, error: "method_not_allowed" });
    try {
      const b = req.body || {};
      const num = (v) => (v == null || v === "" || isNaN(Number(v)) ? null : Number(v));
      const fromLat = num(b.fromLat), fromLng = num(b.fromLng);
      const toLat = num(b.toLat), toLng = num(b.toLng);
      const persons = Math.max(1, parseInt(b.persons, 10) || 1);
      const luggage = Math.max(0, parseInt(b.luggage, 10) || 0);
      const childSeatCount = Math.max(0, parseInt(b.childSeatCount, 10) || 0);
      const vehicleType = s(b.vehicleType) === "van" ? "van" : (s(b.vehicleType) === "shuttle" ? "shuttle" : (s(b.vehicleType) === "bus" ? "bus" : "taxi"));
      const lang = s(b.lang) || "el";
      const dialCode = s(b.dialCode);
      const isGreek = lang === "el" ? true : dialCode === "+30";
      const tenantId = s(b.tenantId) || "default";
      const { cfg } = await getPricingData(tenantId);
      // Ελαφρύ query — ΜΟΝΟ για να ξέρει η φόρμα αν να δείξει την επιλογή
      // «Θέλω Τιμολόγιο» (μόνο αν ο tenant έχει ενεργό invoiceEnabled+mydata).
      let tenantInvoiceCfg = {};
      try {
        const tDoc = await getFirestore().collection("tenants").doc(tenantId).get();
        if (tDoc.exists) tenantInvoiceCfg = tDoc.data();
      } catch (e) { /* αγνόησε — απλά δεν θα φανεί η επιλογή */ }

      let scheduledNaive = null, gateReasons = [];
      const date = s(b.date), time = s(b.time);
      if (date && time) {
        scheduledNaive = athensNaiveFromDateTimeStrings(date, time);
        const simNaive = athensNaiveDate(new Date());
        gateReasons = computeGate(simNaive, scheduledNaive, persons, luggage, cfg);
      }

      const result = await computeEstimate({
        fromLat, fromLng, toLat, toLng, persons, luggage, childSeatCount,
        vehicleType, isGreek, scheduledNaive, apiKey: ROUTES_API_KEY.value(),
        cachedDistanceKm: num(b.cachedDistanceKm),
        cachedDurationMin: num(b.cachedDurationMin),
        cachedRoutePolyline: b.cachedRoutePolyline || null,
        needMap: b.needMap === true,
        tenantId: s(b.tenantId) || "default",
        clientsOnlyMode: cfg.clientsOnlyBooking === true,
      });
      if (result.outsideAttica && !gateReasons.includes("outside_attica")) {
        gateReasons.push("outside_attica");
      }

      return res.status(200).json({
        ok: true,
        price: result.price,
        nightApplies: result.nightApplies,
        vehicle: result.vehicle,
        blocked: gateReasons.length > 0,
        reasons: gateReasons,
        displayOriginal: result.displayOriginal,
        discountPercent: result.discountPercent,
        minChargeApplied: result.minChargeApplied,
        distanceKm: result.distanceKm,
        durationMin: result.durationMin,
        routePolyline: result.routePolyline,
        depositPercent: (cfg.depositPercent === null || cfg.depositPercent === undefined)
          ? 10 : Number(cfg.depositPercent),
        fullPaymentEnabled: cfg.fullPaymentEnabled !== false,
        shuttleAvailable: !!result.shuttleAvailable,
        shuttlePricePerPerson: result.shuttlePricePerPerson || null,
        shuttleSlotOptions: result.shuttleSlotOptions || null,
        noRouteAvailable: !!result.noRouteAvailable,
        invoiceEnabled: tenantInvoiceCfg.invoiceEnabled === true,
        invoiceProvider: tenantInvoiceCfg.invoiceProvider || "none",
        clientMatchedName: result.clientMatchedName || null,
        paymentProvider: resolvePaymentProvider(tenantInvoiceCfg),
      });
    } catch (e) {
      console.error("estimatePrice error:", e);
      return res.status(500).json({ ok: false, error: "server_error" });
    }
  }
);

// ── helper: φτιάχνει .ics για τη δουλειά (ώρα Ελλάδας) ───────────────────────
function buildIcs({ from, to, startDate, durationMin, summary, description }) {
  // startDate: JS Date (UTC). Μορφή ICS σε UTC (Z).
  const pad = (n) => String(n).padStart(2, "0");
  const fmt = (d) =>
    d.getUTCFullYear() + pad(d.getUTCMonth() + 1) + pad(d.getUTCDate()) +
    "T" + pad(d.getUTCHours()) + pad(d.getUTCMinutes()) + pad(d.getUTCSeconds()) + "Z";
  const end = new Date(startDate.getTime() + (durationMin || 60) * 60000);
  const uid = "booking-" + Date.now() + "@athenstaxi";
  const esc = (t) => s(t).replace(/\\/g, "\\\\").replace(/;/g, "\\;").replace(/,/g, "\\,").replace(/\n/g, "\\n");
  return [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//AthensTaxi//Booking//EL",
    "CALSCALE:GREGORIAN",
    "METHOD:PUBLISH",
    "BEGIN:VEVENT",
    "UID:" + uid,
    "DTSTAMP:" + fmt(new Date()),
    "DTSTART:" + fmt(startDate),
    "DTEND:" + fmt(end),
    "SUMMARY:" + esc(summary),
    "LOCATION:" + esc(from + " → " + to),
    "DESCRIPTION:" + esc(description),
    "END:VEVENT",
    "END:VCALENDAR",
  ].join("\r\n");
}

// ── (Αφαιρέθηκε: sendBookingEmail — έστελνε email+.ics στον master μέσω Gmail
// API για κάθε κράτηση από φόρμα. Καταργήθηκε πλήρως κατ' απαίτηση — ο master
// πλέον ενημερώνεται ΜΟΝΟ μέσω FCM (push notification/ήχος) και βλέπει τη
// δουλειά στις «Αποθηκευμένες». Το email επιβεβαίωσης προς τον ΠΕΛΑΤΗ (Resend)
// παραμένει, είναι ξεχωριστό.)

exports.submitPublicBooking = onRequest(
  { region: "us-central1", cors: BOOKING_ALLOWED_ORIGINS, memory: "256MiB",
    // RESEND_API_KEY: απαραίτητο για το email επιβεβαίωσης χωρίς πληρωμή —
    // χωρίς αυτό το binding, το .value() σκάει και το email δεν φεύγει ΠΟΤΕ.
    secrets: [GCAL_CLIENT_SECRET, ROUTES_API_KEY, RESEND_API_KEY] },
  async (req, res) => {
    // CORS preflight το χειρίζεται το cors:[...] παραπάνω.
    if (req.method !== "POST") {
      return res.status(405).json({ ok: false, error: "method_not_allowed" });
    }

    try {
      const b = req.body || {};
      const from = s(b.from), to = s(b.to);
      const name = s(b.name), phone = s(b.phone);
      const date = s(b.date), time = s(b.time);   // YYYY-MM-DD , HH:MM

      // Ελάχιστη επικύρωση
      if (!from || !to || !name || !phone || !date || !time) {
        return res.status(400).json({ ok: false, error: "missing_fields" });
      }

      const persons = Math.max(1, parseInt(b.persons, 10) || 1);
      const luggage = Math.max(0, parseInt(b.luggage, 10) || 0);
      const childSeatCount = Math.max(0, parseInt(b.childSeatCount, 10) || 0);
      const vehicleType = (s(b.vehicleType) === "van") ? "van" : ((s(b.vehicleType) === "shuttle") ? "shuttle" : ((s(b.vehicleType) === "bus") ? "bus" : "taxi"));
      const email = s(b.email), flight = s(b.flight), note = s(b.note);
      const lang = s(b.lang) || "el";

      // Συντεταγμένες (αν επιλέχθηκαν από autocomplete/χάρτη)
      const num = (v) => (v == null || v === "" || isNaN(Number(v))) ? null : Number(v);
      const fromLat = num(b.fromLat), fromLng = num(b.fromLng);
      const toLat = num(b.toLat), toLng = num(b.toLng);

      // ── Έλεγχος μπλάκαουτ/ελάχιστης προθεσμίας/μεγάλης παραγγελίας/εκτός
      //    Αττικής — ελέγχεται ΚΑΙ εδώ (όχι μόνο client-side): ένα POST
      //    απευθείας στο API δεν μπορεί να προσπεράσει τους κανόνες.
      const tenantId = s(b.tenantId) || "default";
      const { cfg } = await getPricingData(tenantId);
      const scheduledNaive = athensNaiveFromDateTimeStrings(date, time);
      const simNaive = athensNaiveDate(new Date());
      const gateReasons = computeGate(simNaive, scheduledNaive, persons, luggage, cfg);

      // Έλληνας/ξένος πελάτης: πρώτα η γλώσσα σελίδας, δεύτερο fallback ο
      // κωδικός χώρας του τηλεφώνου.
      const dialCode = (phone.match(/^\+\d+/) || [""])[0];
      const isGreek = lang === "el" ? true : dialCode === "+30";

      const estimate = await computeEstimate({
        fromLat, fromLng, toLat, toLng, persons, luggage, childSeatCount,
        vehicleType, isGreek, scheduledNaive, apiKey: ROUTES_API_KEY.value(),
        // ⚠️ BUGFIX: χωρίς tenantId, η ΤΕΛΙΚΗ τιμή της κράτησης υπολογιζόταν
        // με τις τιμές/ζώνες του DEFAULT tenant αντί του tenant της φόρμας.
        tenantId,
        clientsOnlyMode: cfg.clientsOnlyBooking === true,
      });
      if (estimate.outsideAttica && !gateReasons.includes("outside_attica")) {
        gateReasons.push("outside_attica");
      }
      if (gateReasons.length) {
        return res.status(400).json({ ok: false, error: "outside_booking_window", reasons: gateReasons });
      }

      const masterUid = await findMasterUid(tenantId);
      if (!masterUid) {
        console.error("submitPublicBooking: δεν βρέθηκε master", { tenantId });
        return res.status(500).json({ ok: false, error: "no_master" });
      }
      const me = await getFirestore().collection("presence").doc(masterUid).get();
      const masterName = await resolveOwnerDisplayName(tenantId, me.exists ? me.data() : null);

      // Ραντεβού σε ώρα Ελλάδας → JS Date.
      // Το date/time έρχονται ως τοπική ώρα Ελλάδας. Φτιάχνουμε ISO με offset.
      // (Απλό & ασφαλές: θεωρούμε Europe/Athens. Για ακρίβεια DST, ο master
      //  βλέπει ούτως ή άλλως το ραντεβού στην εφαρμογή πριν στείλει.)
      // ⚠️ BUGFIX: το Date.parse σε ISO χωρίς offset ερμηνεύεται ως UTC στους
      // servers (UTC timezone) → το 11:00 Ελλάδας σωζόταν ως 11:00 UTC και η
      // εφαρμογή το έδειχνε 14:00. Σωστή μετατροπή: ώρα Αθήνας → πραγματικό UTC.
      const schedNaive = athensNaiveFromDateTimeStrings(date, time);
      const startDate = schedNaive ? athensNaiveToRealDate(schedNaive) : new Date();

      // Σύνθεση σημειώσεων για τη δουλειά
      const noteLines = [];
      noteLines.push("📝 Από φόρμα ιστοσελίδας");
      noteLines.push("Πελάτης: " + name + " · " + phone);
      if (email)  noteLines.push("Email: " + email);
      if (flight) noteLines.push("Πτήση/Πλοίο: " + flight);
      noteLines.push("Άτομα: " + persons + " · Βαλίτσες: " + luggage +
                     (childSeatCount ? " · Παιδικά καθ.: " + childSeatCount : ""));
      noteLines.push("Όχημα: " + (vehicleType === "van" ? "Βαν" : "Ταξί"));
      if (note) noteLines.push("Σχόλια: " + note);
      const fullNote = noteLines.join("\n");

      // ── 1) Γράψιμο στο saved_jobs (draft, owner = master) ──────────────────
      // ΣΗΜΑΝΤΙΚΟ: τα keys πρέπει να ταιριάζουν ΑΚΡΙΒΩΣ με το Job.fromDoc
      // (from/to/persons/flightOrShip/scheduledAt:Timestamp), αλλιώς η δουλειά
      // εμφανίζεται κενή στην εφαρμογή.
      const { Timestamp } = require("firebase-admin/firestore");
      const bookingNumber = await nextBookingNumber(tenantId);
      const shuttleGroupKey = vehicleType === "shuttle"
        ? await computeShuttleGroupKey({ fromLat, fromLng, toLat, toLng, scheduledNaive, tenantId })
        : null;
      const savedRef = await getFirestore().collection("saved_jobs").add({
        origin:         "public_form",   // ← ΣΗΜΑΔΙ «ΑΠΟ ΦΟΡΜΑ»
        tenantId:       tenantId,        // ← ΚΡΙΣΙΜΟ: για tenant isolation (rules + φίλτρα)
        bookingNumber:  bookingNumber,   // ← μοναδικός αύξων αριθμός (ανά tenant)
        ...(shuttleGroupKey ? { shuttleGroupKey } : {}),
        from:           from,
        to:             to,
        fromLat:        fromLat,
        fromLng:        fromLng,
        toLat:          toLat,
        toLng:          toLng,
        clientName:     name,
        clientPhone:    phone,
        clientEmail:    email,
        flightOrShip:   flight,
        persons:        persons,
        luggage:        luggage,
        childSeatCount: childSeatCount,
        childSeat:      childSeatCount > 0,
        vehicleType:    vehicleType,     // 'taxi' | 'van'
        note:           fullNote,
        price:          estimate.price,   // υπολογισμένη τιμή (ζώνη ή δυναμικός τύπος)
        // Προμήθεια app ανά κράτηση, δηλωμένη από τον master.
        // Global προμήθεια app (ίδιο doc με τη σελίδα «Διαχειριστές» στο Flutter) —
        // ΟΧΙ ανά tenant.
        appCommission:  await getGlobalAppCommission(),
        scheduledAt:    Timestamp.fromDate(startDate),  // ραντεβού (Job.fromDoc)
        lang:           lang,
        ownerUid:       masterUid,
        ownerName:      masterName,
        savedAt:        FieldValue.serverTimestamp(),
        createdAt:      FieldValue.serverTimestamp(),
      });

      // ── 2) FCM στον master/tenant-owner ΤΟΥ ΣΥΓΚΕΚΡΙΜΕΝΟΥ tenant (ΟΧΙ πάντα
      // στον super-admin) — ξεχωριστό type/εικονίδιο, πιάνεται από το
      // public_booking_alert.dart (ownerUid==myUid φίλτρο, βλ. εκεί).
      const whenStr = date + " " + time;
      try {
        const tokens = await getTokensForUid(masterUid);
        await sendDataOnly(tokens, {
          type:       "public_booking",          // ← το owner_alerts το ξεχωρίζει
          savedJobId: savedRef.id,
          // ⚠️ "from"/"to" είναι RESERVED keys στο FCM data payload — η
          // αποστολή ΑΠΟΡΡΙΠΤΟΤΑΝ ολόκληρη (messaging/invalid-argument) και
          // η ειδοποίηση δεν έφτανε ΠΟΤΕ στη συσκευή.
          fromAddr: from, toAddr: to,
          clientName: name,
          when:       whenStr,
          title:      "Νέα κράτηση #" + bookingNumber + " από φόρμα",
          body:       from + " → " + to + " · " + name,
        }, { ttlMs: 6 * 3600 * 1000 });
      } catch (e) {
        console.error("booking FCM failed:", e);
      }

      // ── 2β) Email επιβεβαίωσης στον ΠΕΛΑΤΗ — ΚΑΙ χωρίς online πληρωμή
      // (πληρώνει απευθείας τον οδηγό). Ίδιο στυλ/branding (λογότυπο, στοιχεία
      // επιχείρησης, WhatsApp) με το email μετά από πληρωμή Viva/Stripe.
      if (email) {
        try {
          const t = await getFirestore().collection("tenants").doc(tenantId).get()
            .then((d) => d.data() || {});
          const noKeyAtAll = !t.hasOwnResendKey && t.emailsEnabled === false;
          if (!noKeyAtAll) {
            const businessName = t.businessName || (tenantId === "default" ? "TaxiAthensTransfers.com" : "Taxi Transfers");
            const whatsapp     = (t.whatsappNumber || (tenantId === "default" ? "306936123322" : "")).replace(/[^0-9]/g, "");
            const logoUrl      = t.logoUrl || "";
            const footerPhone  = t.contactPhone || (tenantId === "default" ? "+30 693 612 3322" : "");
            const footerEmail  = t.contactEmail || (tenantId === "default" ? "info@taxiathenstransfers.com" : "");
            const fromEmail    = tenantId === "default" ? "booking@taxiathenstransfers.com" : "info@taxiathenstransfers.com";
            let apiKeyOverride = null;
            if (t.hasOwnResendKey && t.emailsEnabled !== true) {
              try { apiKeyOverride = await readSecret(tenantSecretId(tenantId, "resend-api-key")); } catch (_) {}
            }
            const isEl = (lang || "el") === "el";
            const waLine = whatsapp
              ? (isEl
                  ? "Θα είμαστε σε επικοινωνία μαζί σας μέσω WhatsApp για οποιαδήποτε ενημέρωση χρειαστεί: <a href=\"https://wa.me/" + whatsapp + "\">+" + whatsapp + "</a>"
                  : "We'll be in touch with you via WhatsApp for any updates you may need: <a href=\"https://wa.me/" + whatsapp + "\">+" + whatsapp + "</a>")
              : "";
            const subjFrom = titleCaseIfAllCaps(from), subjTo = titleCaseIfAllCaps(to);
            const subject = isEl
              ? "✅ Κράτηση #" + bookingNumber + " καταχωρήθηκε — " + subjFrom + " → " + subjTo
              : "✅ Booking #" + bookingNumber + " received — " + subjFrom + " → " + subjTo;
            const logoHtml = logoUrl
              ? "<img src=\"" + logoUrl + "\" alt=\"" + businessName + "\" style=\"max-height:56px;margin-bottom:16px;\"><br>"
              : "";
            const footerContactLine = [footerPhone, footerEmail].filter(Boolean).join(" · ");
            const footerHtml =
              "<table style=\"margin-top:28px;border-top:1px solid #eee;padding-top:16px;\"><tr>" +
              (logoUrl ? "<td style=\"padding-right:14px;vertical-align:middle;\"><img src=\"" + logoUrl + "\" alt=\"\" style=\"max-height:44px;\"></td>" : "") +
              "<td style=\"vertical-align:middle;color:#666;font-size:13px;\">" +
              "<b style=\"color:#333;\">" + businessName + "</b>" +
              (footerContactLine ? "<br>" + footerContactLine : "") +
              "</td></tr></table>";
            const vehicleLabelEl = vehicleType === "van" ? "Βαν" : vehicleType === "shuttle" ? "Shuttle" : vehicleType === "bus" ? "Λεωφορείο" : "Ταξί";
            const vehicleLabelEn = vehicleType === "van" ? "Van" : vehicleType === "shuttle" ? "Shuttle" : vehicleType === "bus" ? "Bus" : "Taxi";
            const bodyEl =
              "<h2 style=\"color:#1a1a2e;\">Η κράτησή σας καταχωρήθηκε!</h2>" +
              "<p>Γεια σας " + name + ",</p>" +
              "<p>Δεν χρειάζεται καμία online πληρωμή — πληρώνετε απευθείας τον οδηγό.</p>" +
              "<table style=\"border-collapse:collapse;margin:12px 0;\">" +
              "<tr><td style=\"padding:4px 12px 4px 0;color:#666;\">Booking ID:</td><td><b>#" + bookingNumber + "</b></td></tr>" +
              "<tr><td style=\"padding:4px 12px 4px 0;color:#666;\">Διαδρομή:</td><td><b>" + from + " → " + to + "</b></td></tr>" +
              "<tr><td style=\"padding:4px 12px 4px 0;color:#666;\">Ημερομηνία/ώρα:</td><td>" + whenStr + "</td></tr>" +
              "<tr><td style=\"padding:4px 12px 4px 0;color:#666;\">Άτομα/Βαλίτσες:</td><td>" + persons + " / " + luggage + (childSeatCount ? " · Παιδικά καθ.: " + childSeatCount : "") + "</td></tr>" +
              "<tr><td style=\"padding:4px 12px 4px 0;color:#666;\">Όχημα:</td><td>" + vehicleLabelEl + "</td></tr>" +
              (flight ? "<tr><td style=\"padding:4px 12px 4px 0;color:#666;\">Πτήση/Πλοίο:</td><td>" + flight + "</td></tr>" : "") +
              "<tr><td style=\"padding:4px 12px 4px 0;color:#666;\">Θα πληρώσετε στον οδηγό:</td><td><b>" + estimate.price.toFixed(2) + "€</b></td></tr>" +
              (note ? "<tr><td style=\"padding:4px 12px 4px 0;color:#666;\">Σχόλια:</td><td>" + note + "</td></tr>" : "") +
              "</table>" +
              "<p>" + waLine + "</p>";
            const bodyEn =
              "<h2 style=\"color:#1a1a2e;\">Your booking has been received!</h2>" +
              "<p>Hi " + name + ",</p>" +
              "<p>No online payment is required — you pay the driver directly.</p>" +
              "<table style=\"border-collapse:collapse;margin:12px 0;\">" +
              "<tr><td style=\"padding:4px 12px 4px 0;color:#666;\">Booking ID:</td><td><b>#" + bookingNumber + "</b></td></tr>" +
              "<tr><td style=\"padding:4px 12px 4px 0;color:#666;\">Route:</td><td><b>" + from + " → " + to + "</b></td></tr>" +
              "<tr><td style=\"padding:4px 12px 4px 0;color:#666;\">Date/time:</td><td>" + whenStr + "</td></tr>" +
              "<tr><td style=\"padding:4px 12px 4px 0;color:#666;\">Persons/Luggage:</td><td>" + persons + " / " + luggage + (childSeatCount ? " · Child seats: " + childSeatCount : "") + "</td></tr>" +
              "<tr><td style=\"padding:4px 12px 4px 0;color:#666;\">Vehicle:</td><td>" + vehicleLabelEn + "</td></tr>" +
              (flight ? "<tr><td style=\"padding:4px 12px 4px 0;color:#666;\">Flight/Ship:</td><td>" + flight + "</td></tr>" : "") +
              "<tr><td style=\"padding:4px 12px 4px 0;color:#666;\">To pay the driver:</td><td><b>€" + estimate.price.toFixed(2) + "</b></td></tr>" +
              (note ? "<tr><td style=\"padding:4px 12px 4px 0;color:#666;\">Comments:</td><td>" + note + "</td></tr>" : "") +
              "</table>" +
              "<p>" + waLine + "</p>";
            const html =
              "<div style=\"font-family:sans-serif;font-size:15px;color:#222;max-width:520px;margin:0 auto;\">" +
              logoHtml + (isEl ? bodyEl : bodyEn) + footerHtml + "</div>";
            await sendCustomerEmailViaResend({
              to: email, subject, html, fromName: businessName, fromEmail, apiKeyOverride,
            });
          }
        } catch (e) {
          console.error("submitPublicBooking: customer email failed:", e);
        }
      }

      return res.status(200).json({ ok: true, id: savedRef.id, bookingNumber });
    } catch (e) {
      console.error("submitPublicBooking error:", e);
      return res.status(500).json({ ok: false, error: "server_error" });
    }
  }
);

// ════════════════════════════════════════════════════════════════════════════
// PLACES / ROUTES / GEOCODING PROXY  (για την εφαρμογή — Android & Web admin)
// ────────────────────────────────────────────────────────────────────────────
// Η εφαρμογή (places_service.dart) ΔΕΝ καλεί πλέον τη Google απευθείας από
// τον client. Λόγος: το Places API (New) καλείται με απλή HTTP/REST κλήση
// (όχι μέσω του native Android SDK), και η Google ΔΕΝ μπορεί να επαληθεύσει
// "Android apps" restriction (package+SHA-1) σε τέτοιες κλήσεις — άρα ένα
// Android-restricted κλειδί απορρίπτει ΠΑΝΤΑ με 403, ενώ ένα unrestricted
// κλειδί θα ήταν εκτεθειμένο στο APK.
//
// Λύση: οι 4 συναρτήσεις εδώ κάνουν proxy προς τη Google με το ΥΠΑΡΧΟΝ
// server-side secret ROUTES_API_KEY (ίδιο με του estimatePrice). Το κλειδί
// ΔΕΝ φεύγει ποτέ από τον server. Απαιτείται σύνδεση (Firebase Auth) — μόνο
// οι χρήστες της εφαρμογής (οδηγοί/admin/master) μπορούν να τις καλέσουν.
//
// ⚠️ ΑΠΑΙΤΕΙΤΑΙ: στο GCP κλειδί που αντιστοιχεί στο secret ROUTES_API_KEY,
// πρόσθεσε στα API restrictions και: "Places API (New)" + "Geocoding API"
// (το "Routes API" μάλλον είναι ήδη ενεργό αφού το χρησιμοποιεί ήδη το
// estimatePrice). Το κλειδί αυτό είναι ήδη server-side only, οπότε είναι
// ασφαλές να έχει App restriction "None" — δεν εκτίθεται ποτέ σε client.
// ════════════════════════════════════════════════════════════════════════════

function requireSignedIn(request) {
  const uid = request.auth && request.auth.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Απαιτείται σύνδεση.");
  return uid;
}

// ── Αναζήτηση σημείων/οδών — Places API (New) :autocomplete ─────────────────
exports.placesAutocomplete = onCall(
  { secrets: [ROUTES_API_KEY] },
  async (request) => {
    requireSignedIn(request);
    const input = s(request.data && request.data.input);
    const sessionToken = request.data && request.data.sessionToken
      ? String(request.data.sessionToken) : undefined;
    if (input.length < 2) return { suggestions: [] };

    const resp = await fetch("https://places.googleapis.com/v1/places:autocomplete", {
      method: "POST",
      headers: {
        "Content-Type":   "application/json",
        "X-Goog-Api-Key": ROUTES_API_KEY.value(),
      },
      body: JSON.stringify({
        input,
        languageCode: "el",
        regionCode:   "gr",
        includedRegionCodes: ["gr"],
        ...(sessionToken ? { sessionToken } : {}),
      }),
    });
    if (!resp.ok) {
      console.error("placesAutocomplete error:", resp.status, await resp.text());
      throw new HttpsError("internal", "Places autocomplete failed (" + resp.status + ")");
    }
    return await resp.json();
  }
);

// ── Λεπτομέρειες σημείου → συντεταγμένες — Places API (New) GET /v1/places/{id}
exports.placesDetails = onCall(
  { secrets: [ROUTES_API_KEY] },
  async (request) => {
    requireSignedIn(request);
    const placeId = s(request.data && request.data.placeId);
    const sessionToken = request.data && request.data.sessionToken
      ? String(request.data.sessionToken) : undefined;
    if (!placeId) throw new HttpsError("invalid-argument", "Λείπει placeId.");

    const qs = new URLSearchParams({ languageCode: "el" });
    if (sessionToken) qs.set("sessionToken", sessionToken);

    const resp = await fetch(
      "https://places.googleapis.com/v1/places/" + encodeURIComponent(placeId) + "?" + qs.toString(),
      {
        headers: {
          "X-Goog-Api-Key":   ROUTES_API_KEY.value(),
          "X-Goog-FieldMask": "location,formattedAddress,displayName",
        },
      }
    );
    if (!resp.ok) {
      console.error("placesDetails error:", resp.status, await resp.text());
      throw new HttpsError("internal", "Place details failed (" + resp.status + ")");
    }
    return await resp.json();
  }
);

// ── Διαδρομή οδήγησης (χλμ + λεπτά + polyline) — Routes API computeRoutes ───
exports.placesRoute = onCall(
  { secrets: [ROUTES_API_KEY] },
  async (request) => {
    requireSignedIn(request);
    const d = request.data || {};
    const fromLat = Number(d.fromLat), fromLng = Number(d.fromLng);
    const toLat   = Number(d.toLat),   toLng   = Number(d.toLng);
    if ([fromLat, fromLng, toLat, toLng].some((v) => !isFinite(v))) {
      throw new HttpsError("invalid-argument", "Λείπουν συντεταγμένες.");
    }
    // departureTime: ISO string, ΜΟΝΟ αν είναι στο μέλλον (όπως στο Dart).
    let useDeparture = false;
    let departureIso = null;
    if (d.departureTimeIso) {
      const dep = new Date(d.departureTimeIso);
      if (!isNaN(dep.getTime()) && dep.getTime() > Date.now()) {
        useDeparture = true;
        departureIso = dep.toISOString();
      }
    }

    const resp = await fetch("https://routes.googleapis.com/directions/v2:computeRoutes", {
      method: "POST",
      headers: {
        "Content-Type":     "application/json",
        "X-Goog-Api-Key":   ROUTES_API_KEY.value(),
        "X-Goog-FieldMask":
          "routes.distanceMeters,routes.duration,routes.polyline.encodedPolyline",
      },
      body: JSON.stringify({
        origin:      { location: { latLng: { latitude: fromLat, longitude: fromLng } } },
        destination: { location: { latLng: { latitude: toLat,   longitude: toLng   } } },
        travelMode:        "DRIVE",
        routingPreference: useDeparture ? "TRAFFIC_AWARE_OPTIMAL" : "TRAFFIC_AWARE",
        languageCode:      "el",
        units:             "METRIC",
        ...(useDeparture ? { departureTime: departureIso } : {}),
      }),
    });
    if (!resp.ok) {
      console.error("placesRoute error:", resp.status, await resp.text());
      throw new HttpsError("internal", "Route calculation failed (" + resp.status + ")");
    }
    return await resp.json();
  }
);

// ── Plus Code Google Maps (π.χ. "M3W4+9W Λαύριο") → συντεταγμένες ───────────
// Το Places Autocomplete (New) δεν "καταλαβαίνει" καλά τους Plus Codes σαν
// ελεύθερο κείμενο αναζήτησης· το Geocoding API όμως τους δέχεται απευθείας
// στην παράμετρο address (και τη σύντομη μορφή με τοπωνύμιο, π.χ.
// "M3W4+9W Lavrio", και την πλήρη global μορφή, π.χ. "8FVC9G8F+6X").
//
// ΣΗΜΑΝΤΙΚΟ: όταν κάποιος κάνει copy-paste μια τοποθεσία απευθείας από το
// Google Maps, συχνά έρχεται σαν "M3W4+9W, Λαύριο 195 00" (με ΚΟΜΜΑ και
// ΤΑΧΥΔΡΟΜΙΚΟ ΚΩΔΙΚΑ στο τέλος). Το Geocoding API με αυτή τη μορφή συχνά
// γυρνάει ZERO_RESULTS (καμία στην πραγματικότητα HTTP error — η κλήση
// "πετυχαίνει" αλλά χωρίς αποτελέσματα) — καθαρίζουμε το κείμενο πριν το
// στείλουμε, και αν παρόλα αυτά αποτύχει ξαναδοκιμάζουμε με τον γυμνό κωδικό.
const PLUS_CODE_RE = /\b[23456789CFGHJMPQRVWX]{4,8}\+[23456789CFGHJMPQRVWX]{2,3}\b/i;

function cleanPlusCodeQuery(raw) {
  const m = PLUS_CODE_RE.exec(raw);
  if (!m) return { bare: raw, compound: raw };
  const bare = m[0];
  let rest = raw.slice(m.index + bare.length);
  rest = rest.replace(/^[\s,]+/, "");
  rest = rest.replace(/[\d\s]{3,}$/, "");
  rest = rest.replace(/[,.\s]+$/, "").trim();
  return { bare, compound: rest ? (bare + " " + rest) : bare };
}

async function geocodeAddress(address) {
  const qs = new URLSearchParams({
    address,
    key:      ROUTES_API_KEY.value(),
    language: "el",
    region:   "gr",
  });
  const resp = await fetch("https://maps.googleapis.com/maps/api/geocode/json?" + qs.toString());
  if (!resp.ok) {
    const txt = await resp.text();
    console.error("resolvePlusCode HTTP error:", resp.status, txt);
    throw new HttpsError("internal", "Plus Code resolve failed (" + resp.status + ")");
  }
  return await resp.json();
}

exports.resolvePlusCode = onCall(
  { secrets: [ROUTES_API_KEY] },
  async (request) => {
    requireSignedIn(request);
    const code = s(request.data && request.data.code);
    if (!code) throw new HttpsError("invalid-argument", "Λείπει ο κωδικός τοποθεσίας.");

    const { bare, compound } = cleanPlusCodeQuery(code);
    let json = await geocodeAddress(compound);
    if ((!json.results || !json.results.length) && compound !== bare) {
      // Το τοπωνύμιο (ή ο Τ.Κ. που δεν αφαιρέθηκε σωστά) μπέρδεψε τον Geocoder
      // → ξαναδοκίμασε μόνο με τον γυμνό κωδικό.
      json = await geocodeAddress(bare);
    }
    return json;
  }
);
// ── Αντίστροφη γεωκωδικοποίηση: συντεταγμένες → διεύθυνση (Geocoding API) ───
exports.placesReverseGeocode = onCall(
  { secrets: [ROUTES_API_KEY] },
  async (request) => {
    requireSignedIn(request);
    const lat = Number(request.data && request.data.lat);
    const lng = Number(request.data && request.data.lng);
    if (!isFinite(lat) || !isFinite(lng)) {
      throw new HttpsError("invalid-argument", "Λείπουν συντεταγμένες.");
    }
    const qs = new URLSearchParams({
      latlng: lat + "," + lng,
      key:    ROUTES_API_KEY.value(),
      language: "el",
      region:   "gr",
    });
    const resp = await fetch("https://maps.googleapis.com/maps/api/geocode/json?" + qs.toString());
    if (!resp.ok) {
      console.error("placesReverseGeocode error:", resp.status, await resp.text());
      throw new HttpsError("internal", "Reverse geocode failed (" + resp.status + ")");
    }
    return await resp.json();
  }
);

// ════════════════════════════════════════════════════════════════════════════
//  VIVA SMART CHECKOUT — 10% προκαταβολή στη δημόσια φόρμα κράτησης
//
//  Ροή:
//   1) Η φόρμα (el/booking.html) στέλνει τα στοιχεία κράτησης στο createVivaOrder.
//   2) Εδώ ΞΑΝΑ-υπολογίζουμε την τιμή server-side (ίδια λογική με το
//      submitPublicBooking) — ΠΟΤΕ δεν εμπιστευόμαστε τιμή που στέλνει ο client.
//   3) Αποθηκεύουμε τα στοιχεία της κράτησης σε pending_bookings/{id} με
//      status:'pending' — η δουλειά ΔΕΝ μπαίνει ακόμα στα saved_jobs.
//   4) Δημιουργούμε Viva payment order για το 10% (στρογγυλοποιημένο στο
//      επόμενο ευρώ) και επιστρέφουμε το checkoutUrl στον client.
//   5) Ο πελάτης πληρώνει στη Viva. Η Viva καλεί το webhook vivaWebhook.
//   6) ΜΟΝΟ όταν το webhook επιβεβαιώσει επιτυχημένη πληρωμή, δημιουργούμε
//      την πραγματική δουλειά στα saved_jobs (ό,τι έκανε πριν το
//      submitPublicBooking) + email + FCM στον master.
//   7) Αν ο πελάτης ΔΕΝ πληρώσει (κλείσει τη σελίδα, απορριφθεί η κάρτα,
//      λήξει το paymentTimeout), ΔΕΝ αποθηκεύεται ΤΙΠΟΤΑ — όπως ζητήθηκε.
//      Ο μόνος καθαρισμός που χρειάζεται είναι να σβήνονται periodically τα
//      pending_bookings που έμειναν 'pending' πάνω από π.χ. 2 ώρες (μπορεί να
//      προστεθεί αργότερα σε κάποιο υπάρχον scheduled cleanup — δεν το
//      προσθέτω εδώ για να μην πολλαπλασιάζω τα scheduled functions άσκοπα).
//
//  ⚠️ ΠΡΙΝ ΤΟ DEPLOY χρειάζεται να μπουν 5 secrets (δες οδηγίες στο τέλος):
//     VIVA_CLIENT_ID, VIVA_CLIENT_SECRET   (OAuth2 — Smart Checkout credentials)
//     VIVA_MERCHANT_ID, VIVA_API_KEY       (Basic auth — για επαλήθευση webhook)
//     VIVA_DEMO                            ("true" ή "false" — αλλάζεις χωρίς redeploy)
// ════════════════════════════════════════════════════════════════════════════

const VIVA_CLIENT_ID     = defineSecret("VIVA_CLIENT_ID");
const VIVA_CLIENT_SECRET = defineSecret("VIVA_CLIENT_SECRET");
const VIVA_MERCHANT_ID   = defineSecret("VIVA_MERCHANT_ID");
const VIVA_API_KEY       = defineSecret("VIVA_API_KEY");
const VIVA_DEMO          = defineSecret("VIVA_DEMO"); // "true" | "false"

function vivaIsDemo(v) { return s(v).toLowerCase() !== "false"; } // default demo=true (ασφαλές default)

function vivaHosts(demo) {
  return demo
    ? { accounts: "https://demo-accounts.vivapayments.com", api: "https://demo-api.vivapayments.com", web: "https://demo.vivapayments.com" }
    : { accounts: "https://accounts.vivapayments.com",       api: "https://api.vivapayments.com",       web: "https://www.vivapayments.com" };
}

// ── OAuth2 access token (Smart Checkout Client ID/Secret) ───────────────────
async function getVivaAccessToken(demo, clientId, clientSecret) {
  const hosts = vivaHosts(demo);
  const basic = Buffer.from(clientId + ":" + clientSecret).toString("base64");
  const resp = await fetch(hosts.accounts + "/connect/token", {
    method: "POST",
    headers: {
      "Authorization": "Basic " + basic,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: "grant_type=client_credentials",
  });
  if (!resp.ok) {
    console.error("getVivaAccessToken error:", resp.status, await resp.text());
    return null;
  }
  const data = await resp.json();
  return data.access_token || null;
}

// ── createVivaOrder: επικυρώνει την κράτηση, υπολογίζει το 10% deposit,
//    αποθηκεύει pending_bookings, δημιουργεί Viva order, γυρνάει checkoutUrl ──
// ── Καθαρισμός μπαγιάτικων pending_bookings (>48 ώρες) ──────────────────────
// Τα ολοκληρωμένα υπάρχουν ήδη στα saved_jobs, τα απλήρωτα δεν χρειάζονται
// ποτέ — άρα ΟΛΑ τα docs ηλικίας >48h διαγράφονται, ανεξαρτήτως status.
// Query ΜΟΝΟ σε createdAt (single-field index, υπάρχει αυτόματα — δεν
// χρειάζεται composite). Καλείται:
//  • ευκαιριακά σε κάθε νέο checkout (limit 25 — κόστος ανάλογο της κίνησης,
//    κανένα επιπλέον scheduled function), και
//  • ως πλήρες σκούπισμα μία φορά τον μήνα μέσα στο υπάρχον monthlyCharges.
async function cleanupStalePendingBookings(db, { limit = 25, maxLoops = 1 } = {}) {
  try {
    const { Timestamp } = require("firebase-admin/firestore");
    const cutoff = Timestamp.fromMillis(Date.now() - 48 * 60 * 60 * 1000);
    let total = 0;
    for (let i = 0; i < maxLoops; i++) {
      const snap = await db.collection("pending_bookings")
        .where("createdAt", "<", cutoff)
        .limit(limit)
        .get();
      if (snap.empty) break;
      const batch = db.batch();
      snap.docs.forEach((d) => batch.delete(d.ref));
      await batch.commit();
      total += snap.size;
      if (snap.size < limit) break;
    }
    if (total > 0) console.log("cleanupStalePendingBookings: διαγράφηκαν", total, "docs (>48h)");
    return total;
  } catch (e) {
    console.error("cleanupStalePendingBookings error:", e.message);
    return 0;
  }
}

async function prepareBookingOrder(req) {
  const b = req.body || {};
  const tenantId = s(b.tenantId) || "default";
  const from = s(b.from), to = s(b.to);
  const name = s(b.name), phone = s(b.phone);
  const date = s(b.date), time = s(b.time);
  if (!from || !to || !name || !phone || !date || !time) {
    return { ok: false, status: 400, body: { ok: false, error: "missing_fields" } };
  }

  let tenantCfg = null;
  if (tenantId !== "default") {
    const tenantDoc = await getFirestore().collection("tenants").doc(tenantId).get();
    if (!tenantDoc.exists) {
      return { ok: false, status: 400, body: { ok: false, error: "unknown_tenant" } };
    }
    tenantCfg = tenantDoc.data();
    if (tenantCfg.active === false) {
      return { ok: false, status: 403, body: { ok: false, error: "tenant_inactive" } };
    }
  }

  const persons = Math.max(1, parseInt(b.persons, 10) || 1);
  const luggage = Math.max(0, parseInt(b.luggage, 10) || 0);
  const childSeatCount = Math.max(0, parseInt(b.childSeatCount, 10) || 0);
  const vehicleType = (s(b.vehicleType) === "van") ? "van" : ((s(b.vehicleType) === "shuttle") ? "shuttle" : ((s(b.vehicleType) === "bus") ? "bus" : "taxi"));
  const email = s(b.email), flight = s(b.flight), note = s(b.note);
  const lang = s(b.lang) || "el";

  if (persons > 8 && vehicleType !== "bus") {
    return { ok: false, status: 400, body: {
      ok: false, error: "van_capacity",
      message: lang === "el"
        ? "Πάνω από 8 άτομα χρειάζονται Λεωφορείο — επικοινωνήστε μαζί μας μέσω WhatsApp."
        : "More than 8 people need a Bus — please contact us via WhatsApp.",
    } };
  }

  const num = (v) => (v == null || v === "" || isNaN(Number(v))) ? null : Number(v);
  const fromLat = num(b.fromLat), fromLng = num(b.fromLng);
  const toLat = num(b.toLat), toLng = num(b.toLng);

  const { cfg } = await getPricingData(tenantId);
  const scheduledNaive = athensNaiveFromDateTimeStrings(date, time);
  const simNaive = athensNaiveDate(new Date());
  const gateReasons = computeGate(simNaive, scheduledNaive, persons, luggage, cfg);

  const dialCode = (phone.match(/^\+\d+/) || [""])[0];
  const isGreek = lang === "el" ? true : dialCode === "+30";

  let clientsOnlyBookingForTenant = false;
  try {
    clientsOnlyBookingForTenant = cfg.clientsOnlyBooking === true;
  } catch (e) { }

  const estimate = await computeEstimate({
    fromLat, fromLng, toLat, toLng, persons, luggage, childSeatCount,
    vehicleType, isGreek, scheduledNaive, apiKey: ROUTES_API_KEY.value(),
    needMap: true,
    tenantId,
    clientsOnlyMode: clientsOnlyBookingForTenant,
  });
  if (estimate.noRouteAvailable) {
    return { ok: false, status: 400, body: {
      ok: false, error: "no_client_route",
      message: lang === "el"
        ? "Δεν βρέθηκε ορισμένη διαδρομή πελάτη — επικοινωνήστε μαζί μας μέσω WhatsApp."
        : "No defined client route found — please contact us via WhatsApp.",
    } };
  }
  if (estimate.outsideAttica && !gateReasons.includes("outside_attica")) {
    gateReasons.push("outside_attica");
  }

  if (vehicleType === "shuttle" && scheduledNaive) {
    const { zones: zonesForSlots } = await getPricingData(tenantId);
    const fz = fromLat != null && fromLng != null ? matchZone(fromLat, fromLng, zonesForSlots) : null;
    const tz = toLat != null && toLng != null ? matchZone(toLat, toLng, zonesForSlots) : null;
    const reqMin = scheduledNaive.getUTCHours() * 60 + scheduledNaive.getUTCMinutes();
    const slots = (cfg.shuttleTimeSlots || []).filter((sl) =>
      !sl.zoneId || sl.zoneId === (fz && fz.id) || sl.zoneId === (tz && tz.id));
    const matchesSlot = slots.some((sl) => {
      const parts = String(sl.time).split(":");
      return ((Number(parts[0]) || 0) * 60 + (Number(parts[1]) || 0)) === reqMin;
    });
    if (!matchesSlot) {
      return { ok: false, status: 400, body: {
        ok: false,
        error: "invalid_shuttle_time",
        message: lang === "el"
          ? "Η ώρα του shuttle πρέπει να ταιριάζει με ένα από τα προγραμματισμένα δρομολόγια."
          : "The shuttle time must match one of the scheduled departures.",
      } };
    }
  }

  if (gateReasons.length) {
    return { ok: false, status: 400, body: { ok: false, error: "outside_booking_window", reasons: gateReasons } };
  }

  const payFull = b.payFull === true;
  const depositPct = (cfg.depositPercent === null || cfg.depositPercent === undefined)
    ? 10 : Number(cfg.depositPercent);
  const depositEquivalent = Math.ceil(estimate.price * (depositPct / 100));
  const chargeAmount = payFull ? Math.ceil(estimate.price) : depositEquivalent;

  if (chargeAmount <= 0) {
    return { ok: false, status: 400, body: { ok: false, error: "invalid_amount" } };
  }

  if (b.wantsInvoice === true && !isValidGreekAfm(s(b.invoiceAfm))) {
    return { ok: false, status: 400, body: {
      ok: false, error: "invalid_afm",
      message: lang === "el" ? "Μη έγκυρο ΑΦΜ για το τιμολόγιο." : "Invalid VAT number for the invoice.",
    } };
  }

  const jobPrice = Math.max(0, estimate.price - depositEquivalent);
  const db = getFirestore();
  // Ευκαιριακό καθάρισμα μπαγιάτικων pending (>48h) — best effort, ποτέ δεν
  // μπλοκάρει τη ροή του checkout.
  await cleanupStalePendingBookings(db);
  const pendingRef = await db.collection("pending_bookings").add({
    status: "pending",
    tenantId,
    from, to, fromLat, fromLng, toLat, toLng,
    clientName: name, clientPhone: phone, clientEmail: email,
    flightOrShip: flight, persons, luggage, childSeatCount,
    vehicleType, note, lang,
    date, time,
    price: jobPrice,
    depositAmount: chargeAmount,
    fullyPaid: payFull,
    routeKm: estimate.distanceKm || null,
    routePolyline: estimate.routePolyline || null,
    wantsInvoice: b.wantsInvoice === true,
    invoiceAfm: s(b.invoiceAfm) || null,
    invoiceCompanyName: s(b.invoiceCompanyName) || null,
    invoiceAddress: s(b.invoiceAddress) || null,
    createdAt: FieldValue.serverTimestamp(),
  });

  return {
    ok: true, tenantId, tenantCfg, from, to, name, phone, date, time, lang,
    persons, luggage, childSeatCount, vehicleType, email, flight, note,
    payFull, chargeAmount, pendingRef,
  };
}

exports.createVivaOrder = onRequest(
  {
    region: "us-central1", cors: BOOKING_ALLOWED_ORIGINS, memory: "256MiB",
    secrets: [ROUTES_API_KEY, VIVA_CLIENT_ID, VIVA_CLIENT_SECRET, VIVA_DEMO],
  },
  async (req, res) => {
    if (req.method !== "POST") return res.status(405).json({ ok: false, error: "method_not_allowed" });
    try {
      const prep = await prepareBookingOrder(req);
      if (!prep.ok) return res.status(prep.status).json(prep.body);
      const { tenantId, tenantCfg, from, to, name, phone, date, time, lang,
        vehicleType, email, payFull, chargeAmount, pendingRef } = prep;

      let tenantViva = null;
      if (tenantId !== "default") {
        tenantViva = await getTenantVivaCredentials(tenantId);
        if (!tenantViva.clientId || !tenantViva.clientSecret) {
          await pendingRef.delete().catch(() => {});
          return res.status(500).json({ ok: false, error: "tenant_viva_not_configured" });
        }
      }

      const depositCents = chargeAmount * 100; // Viva θέλει το amount σε λεπτά
      const dialCode = (phone.match(/^\+\d+/) || [""])[0];


      // ΝΕΟ: το default (δικός σου) λογαριασμός διαβάζεται ΖΩΝΤΑΝΑ από το
      // Secret Manager (readSecret) — ΟΧΙ πια από το deployment-locked
      // defineSecret().value(). Έτσι, όταν αλλάζεις τα δικά σου credentials
      // μέσω της σελίδας «Ρυθμίσεις Viva», ισχύουν αμέσως χωρίς deploy.
      const demo = tenantCfg
        ? tenantCfg.vivaDemo !== false
        : vivaIsDemo(await readSecret("VIVA_DEMO"));
      const hosts = vivaHosts(demo);
      const vClientId = tenantViva
        ? tenantViva.clientId
        : await readSecret("VIVA_CLIENT_ID");
      const vClientSecret = tenantViva
        ? tenantViva.clientSecret
        : await readSecret("VIVA_CLIENT_SECRET");
      const accessToken = await getVivaAccessToken(demo, vClientId, vClientSecret);
      if (!accessToken) {
        await pendingRef.delete().catch(() => {});
        return res.status(500).json({ ok: false, error: "viva_auth_error" });
      }

      const orderResp = await fetch(hosts.api + "/checkout/v2/orders", {
        method: "POST",
        headers: { "Authorization": "Bearer " + accessToken, "Content-Type": "application/json" },
        body: JSON.stringify({
          amount: depositCents,
          customerTrns: (lang === "el"
            ? (payFull ? "Πλήρης πληρωμή · " : "Προκαταβολή 10% · ") + from + " → " + to +
              " · " + date + " " + time + (vehicleType === "van" ? " · Βαν" : " · Ταξί")
            : (payFull ? "Full payment · " : "10% deposit · ") + from + " → " + to +
              " · " + date + " " + time + (vehicleType === "van" ? " · Van" : " · Taxi")),
          customer: {
            email: email || undefined,
            fullName: name,
            phone: phone,
            countryCode: dialCode === "+30" ? "GR" : undefined,
            requestLang: lang === "el" ? "el-GR" : "en-GB",
          },
          paymentTimeout: 1800, // 30 λεπτά — μετά λήγει το order (καμία χρέωση)
          merchantTrns: pendingRef.id, // ← ΤΟ ΚΛΕΙΔΙ που συνδέει Viva order ↔ pending_bookings doc
          // ── Το Source Code καθορίζει ΠΟΙΟ success/failure URL θα
          // χρησιμοποιήσει η Viva μετά την πληρωμή (ρυθμίζεται ΜΕΣΑ στο
          // Viva dashboard, ανά Source — βλ. σχόλιο πιο κάτω). Χρειάζονται
          // ΔΥΟ ξεχωριστά Sources στο Viva dashboard, ένα με success/failure
          // URL → .../index.html (Αγγλικά) και ένα → .../el/booking2.html
          // (Ελληνικά) — αλλιώς ο πελάτης της αγγλικής φόρμας θα γυρνάει σε
          // ελληνική σελίδα (ή αντίστροφα) μετά την πληρωμή.
          sourceCode: tenantCfg
            ? (lang === "el"
                ? (tenantCfg.vivaSourceCode || "Default")
                : (tenantCfg.vivaSourceCodeEn || tenantCfg.vivaSourceCode || "Default"))
            : "1325",
        }),
      });
      if (!orderResp.ok) {
        console.error("Viva create order error:", orderResp.status, await orderResp.text());
        await pendingRef.delete().catch(() => {});
        return res.status(500).json({ ok: false, error: "viva_order_error" });
      }
      const orderData = await orderResp.json();
      const orderCode = orderData.orderCode;
      if (!orderCode) {
        await pendingRef.delete().catch(() => {});
        return res.status(500).json({ ok: false, error: "viva_no_order_code" });
      }

      await pendingRef.update({ vivaOrderCode: String(orderCode) });

      const checkoutUrl = hosts.web + "/web/checkout?ref=" + orderCode;
      return res.status(200).json({ ok: true, checkoutUrl, depositAmount: chargeAmount });
    } catch (e) {
      console.error("createVivaOrder error:", e);
      return res.status(500).json({ ok: false, error: "server_error" });
    }
  }
);

exports.createStripeCheckoutSession = onRequest(
  { region: "us-central1", cors: BOOKING_ALLOWED_ORIGINS, memory: "256MiB", secrets: [ROUTES_API_KEY] },
  async (req, res) => {
    if (req.method !== "POST") return res.status(405).json({ ok: false, error: "method_not_allowed" });
    try {
      const prep = await prepareBookingOrder(req);
      if (!prep.ok) return res.status(prep.status).json(prep.body);
      const { tenantId, tenantCfg, from, to, name, phone, date, time, lang,
        vehicleType, email, payFull, chargeAmount, pendingRef } = prep;

      const tenantStripe = await getTenantStripeCredentials(tenantId);
      if (!tenantStripe.secretKey || !tenantStripe.publishableKey) {
        await pendingRef.delete().catch(() => {});
        return res.status(500).json({ ok: false, error: "tenant_stripe_not_configured" });
      }

      const stripe = getStripeClient(tenantStripe.secretKey);
      const amountCents = chargeAmount * 100;

      const b = req.body || {};
      const successUrl = s(b.successUrl) || "https://taxiathenstransfers.com/el/booking.html";
      const cancelUrl = s(b.cancelUrl) || successUrl;

      const label = (lang === "el"
        ? (payFull ? "Πλήρης πληρωμή · " : "Προκαταβολή · ") + from + " → " + to
        : (payFull ? "Full payment · " : "Deposit · ") + from + " → " + to);

      let session;
      try {
        session = await stripe.checkout.sessions.create({
          mode: "payment",
          payment_method_types: ["card"],
          line_items: [{
            price_data: {
              currency: "eur",
              unit_amount: amountCents,
              product_data: { name: label },
            },
            quantity: 1,
          }],
          customer_email: email || undefined,
          client_reference_id: pendingRef.id,
          metadata: { pendingBookingId: pendingRef.id, tenantId },
          success_url: successUrl + (successUrl.includes("?") ? "&" : "?") + "stripe_session_id={CHECKOUT_SESSION_ID}",
          cancel_url: cancelUrl,
          expires_at: Math.floor(Date.now() / 1000) + 1800,
        });
      } catch (e) {
        console.error("Stripe create session error:", e.message);
        await pendingRef.delete().catch(() => {});
        return res.status(500).json({ ok: false, error: "stripe_session_error" });
      }

      await pendingRef.update({ stripeSessionId: session.id });
      return res.status(200).json({ ok: true, checkoutUrl: session.url, depositAmount: chargeAmount });
    } catch (e) {
      console.error("createStripeCheckoutSession error:", e);
      return res.status(500).json({ ok: false, error: "server_error" });
    }
  }
);

async function finalizeSuccessfulPayment(db, pendingRef, pd, providerMeta) {
  const masterUid = await findMasterUid(pd.tenantId);
  if (!masterUid) {
    console.error("finalizeSuccessfulPayment: δεν βρέθηκε master", { tenantId: pd.tenantId });
    return { ok: false, error: "no_master" };
  }
  const me = await db.collection("presence").doc(masterUid).get();
  const masterName = await resolveOwnerDisplayName(pd.tenantId, me.exists ? me.data() : null);

  // ⚠️ BUGFIX (ίδιο με submitPublicBooking): ώρα Αθήνας → πραγματικό UTC,
  // αλλιώς το ραντεβού σωζόταν +3 ώρες μπροστά (11:00 → 14:00).
  const schedNaive = athensNaiveFromDateTimeStrings(pd.date, pd.time);
  const startDate = schedNaive ? athensNaiveToRealDate(schedNaive) : new Date();

  const noteLines = [];
  noteLines.push(pd.fullyPaid
    ? "📝 Από φόρμα ιστοσελίδας · ⚠️ ΠΡΟΠΛΗΡΩΜΕΝΟ ΔΡΟΜΟΛΟΓΙΟ — δεν εισπράττεις τίποτα από τον πελάτη"
    : "📝 Από φόρμα ιστοσελίδας · 💳 Πληρώθηκε προκαταβολή online — εισπράττεις μόνο το υπόλοιπο");
  noteLines.push("Πελάτης: " + pd.clientName + " · " + pd.clientPhone);
  if (pd.clientEmail) noteLines.push("Email: " + pd.clientEmail);
  if (pd.flightOrShip) noteLines.push("Πτήση/Πλοίο: " + pd.flightOrShip);
  noteLines.push("Άτομα: " + pd.persons + " · Βαλίτσες: " + pd.luggage +
                 (pd.childSeatCount ? " · Παιδικά καθ.: " + pd.childSeatCount : ""));
  noteLines.push("Όχημα: " + (pd.vehicleType === "van" ? "Βαν" : "Ταξί"));
  if (pd.note) noteLines.push("Σχόλια: " + pd.note);
  const fullNote = noteLines.join("\n");

  const { Timestamp } = require("firebase-admin/firestore");
  const bookingNumber = await nextBookingNumber(pd.tenantId || "default");
  // Προμήθεια app ανά κράτηση, όπως τη δηλώνει ο master (Ρυθμίσεις Online
  // Φόρμας → Δυναμικοί Τύποι) — ισχύει και σε αυτές τις online κρατήσεις.
  const appCommissionPerBooking = await getGlobalAppCommission();
  const savedRef = await db.collection("saved_jobs").add({
    origin:         "public_form",
    tenantId:       pd.tenantId || "default",
    bookingNumber:  bookingNumber,
    from:           pd.from,
    to:             pd.to,
    fromLat:        pd.fromLat,
    fromLng:        pd.fromLng,
    toLat:          pd.toLat,
    toLng:          pd.toLng,
    clientName:     pd.clientName,
    clientPhone:    pd.clientPhone,
    clientEmail:    pd.clientEmail,
    flightOrShip:   pd.flightOrShip,
    wantsInvoice:   pd.wantsInvoice === true,
    invoiceAfm:     pd.invoiceAfm || null,
    invoiceCompanyName: pd.invoiceCompanyName || null,
    persons:        pd.persons,
    luggage:        pd.luggage,
    childSeatCount: pd.childSeatCount,
    childSeat:      pd.childSeatCount > 0,
    routeKm:        pd.routeKm || null,
    routePolyline:  pd.routePolyline || null,
    vehicleType:    pd.vehicleType,
    note:           fullNote,
    price:          pd.price,
    appCommission:  appCommissionPerBooking,
    scheduledAt:    Timestamp.fromDate(startDate),
    lang:           pd.lang,
    ownerUid:       masterUid,
    ownerName:      masterName,
    savedAt:        FieldValue.serverTimestamp(),
    createdAt:      FieldValue.serverTimestamp(),
    depositPaid:      true,
    depositAmount:    pd.depositAmount,
    fullyPaid:        !!pd.fullyPaid,
    paymentProvider:  providerMeta.paymentProvider,
    ...providerMeta.fields,
  });

  await pendingRef.update({ status: "completed", savedJobId: savedRef.id });

  const whenStr = pd.date + " " + pd.time;

  try {
    const tokens = await getTokensForUid(masterUid);
    await sendDataOnly(tokens, {
      type:       "public_booking",
      savedJobId: savedRef.id,
      fromAddr: pd.from, toAddr: pd.to,   // "from"/"to" = reserved FCM keys
      clientName: pd.clientName,
      when:       whenStr,
      title:      "Νέα κράτηση #" + bookingNumber + " (" + (pd.fullyPaid ? "πληρωμένη πλήρως" : "πληρωμένη προκαταβολή") + ")",
      body:       pd.from + " → " + pd.to + " · " + pd.clientName + " · " + pd.depositAmount + "€",
    }, { ttlMs: 6 * 3600 * 1000 });
  } catch (e) {
    console.error("booking FCM failed:", e);
  }

  let receiptResult = null;
  let tPreloaded = null;
  try {
    const tid2 = pd.tenantId || "default";
    const tDoc2 = await db.collection("tenants").doc(tid2).get();
    tPreloaded = tDoc2.exists ? tDoc2.data() : {};
    const invoiceReq = pd.wantsInvoice
      ? { afm: pd.invoiceAfm, companyName: pd.invoiceCompanyName, address: pd.invoiceAddress }
      : null;
    receiptResult = await tryIssueMydataReceipt({
      tenantId: tid2, t: tPreloaded, grossAmount: pd.depositAmount, bookingNumber,
      invoiceRequest: invoiceReq,
    });
    if (!receiptResult) {
      receiptResult = await tryIssueEpsilonReceipt({
        tenantId: tid2, t: tPreloaded, grossAmount: pd.depositAmount, bookingNumber,
        custName: pd.clientName, custPhone: pd.clientPhone, custEmail: pd.clientEmail,
        invoiceRequest: invoiceReq,
      });
    }
    if (!receiptResult) {
      receiptResult = await tryIssueOxygenReceipt({
        tenantId: tid2, t: tPreloaded, grossAmount: pd.depositAmount, bookingNumber,
        custName: pd.clientName, custPhone: pd.clientPhone, custEmail: pd.clientEmail,
        invoiceRequest: invoiceReq,
      });
    }
    if (receiptResult) {
      await savedRef.update({
        invoiceMark: receiptResult.mark || null,
        invoiceProvider: receiptResult.provider,
        invoiceIssuedAt: FieldValue.serverTimestamp(),
        invoiceGrossAmount: pd.depositAmount,
        // Ήταν Τιμολόγιο ή Απόδειξη; Χρειάζεται στο αυτόματο πιστωτικό
        // (Oxygen: pistotiko/5.1 vs pistlianiki/11.4).
        invoiceIsInvoice: receiptResult.isInvoice === true,
      });
    }
  } catch (e) {
    console.error("receipt issuance failed:", e);
  }

  if (pd.clientEmail) {
    try {
      const tid = pd.tenantId || "default";
      const t = tPreloaded || (await db.collection("tenants").doc(tid).get()).data() || {};

      const useOwnKey = t.hasOwnResendKey && t.emailsEnabled !== true;
      const noKeyAtAll = !t.hasOwnResendKey && t.emailsEnabled === false;

      if (noKeyAtAll) {
        console.log("customer email: χωρίς κανένα διαθέσιμο key για tenant", tid, "— παραλείπεται.");
      } else {
        const businessName   = t.businessName   || (tid === "default" ? "TaxiAthensTransfers.com" : "Taxi Transfers");
        const whatsapp       = (t.whatsappNumber || (tid === "default" ? "306936123322" : "")).replace(/[^0-9]/g, "");
        const logoUrl        = t.logoUrl        || "";
        const footerPhone    = t.contactPhone   || (tid === "default" ? "+30 693 612 3322" : "");
        const footerEmail    = t.contactEmail   || (tid === "default" ? "info@taxiathenstransfers.com" : "");

        const fromEmail = tid === "default"
          ? "booking@taxiathenstransfers.com"
          : "info@taxiathenstransfers.com";

        let apiKeyOverride = null;
        if (useOwnKey) {
          try {
            apiKeyOverride = await readSecret(tenantSecretId(tid, "resend-api-key"));
          } catch (e) {
            console.error("δεν βρέθηκε το δικό key του tenant, fallback στο κοινό:", e.message);
          }
        }

        const isEl = (pd.lang || "el") === "el";
        const waLine = whatsapp
          ? (isEl
              ? "Θα είμαστε σε επικοινωνία μαζί σας μέσω WhatsApp για οποιαδήποτε ενημέρωση χρειαστεί: <a href=\"https://wa.me/" + whatsapp + "\">+" + whatsapp + "</a>"
              : "We'll be in touch with you via WhatsApp for any updates you may need: <a href=\"https://wa.me/" + whatsapp + "\">+" + whatsapp + "</a>")
          : "";
        const subjFrom = titleCaseIfAllCaps(pd.from), subjTo = titleCaseIfAllCaps(pd.to);
        const subject = isEl
          ? "✅ Κράτηση #" + bookingNumber + " επιβεβαιώθηκε — " + subjFrom + " → " + subjTo
          : "✅ Booking #" + bookingNumber + " confirmed — " + subjFrom + " → " + subjTo;

        const logoHtml = logoUrl
          ? "<img src=\"" + logoUrl + "\" alt=\"" + businessName + "\" style=\"max-height:56px;margin-bottom:16px;\"><br>"
          : "";
        const footerContactLine = [footerPhone, footerEmail].filter(Boolean).join(" · ");
        const footerHtml =
          "<table style=\"margin-top:28px;border-top:1px solid #eee;padding-top:16px;\"><tr>" +
          (logoUrl ? "<td style=\"padding-right:14px;vertical-align:middle;\"><img src=\"" + logoUrl + "\" alt=\"\" style=\"max-height:44px;\"></td>" : "") +
          "<td style=\"vertical-align:middle;color:#666;font-size:13px;\">" +
          "<b style=\"color:#333;\">" + businessName + "</b>" +
          (footerContactLine ? "<br>" + footerContactLine : "") +
          "</td></tr></table>";

        const markLineEl = (receiptResult && receiptResult.mark)
          ? "<tr><td style=\"padding:4px 12px 4px 0;color:#666;\">Αρ. Παραστατικού (MARK):</td><td>" + receiptResult.mark + "</td></tr>"
          : "";
        const markLineEn = (receiptResult && receiptResult.mark)
          ? "<tr><td style=\"padding:4px 12px 4px 0;color:#666;\">Receipt No. (MARK):</td><td>" + receiptResult.mark + "</td></tr>"
          : "";
        // ── Oxygen: επίσημο online αντίγραφο του παραστατικού (iView) ──
        const iviewLineEl = (receiptResult && receiptResult.iviewUrl)
          ? "<tr><td style=\"padding:4px 12px 4px 0;color:#666;\">Παραστατικό:</td><td><a href=\"" + receiptResult.iviewUrl + "\">Προβολή online</a></td></tr>"
          : "";
        const iviewLineEn = (receiptResult && receiptResult.iviewUrl)
          ? "<tr><td style=\"padding:4px 12px 4px 0;color:#666;\">Receipt:</td><td><a href=\"" + receiptResult.iviewUrl + "\">View online</a></td></tr>"
          : "";

        const bodyEl =
          "<h2 style=\"color:#1a1a2e;\">Η κράτησή σας επιβεβαιώθηκε!</h2>" +
          "<p>Γεια σας " + pd.clientName + ",</p>" +
          "<p>Η προκαταβολή πληρώθηκε με επιτυχία και η κράτησή σας είναι οριστική.</p>" +
          "<table style=\"border-collapse:collapse;margin:12px 0;\">" +
          "<tr><td style=\"padding:4px 12px 4px 0;color:#666;\">Booking ID:</td><td><b>#" + bookingNumber + "</b></td></tr>" +
          "<tr><td style=\"padding:4px 12px 4px 0;color:#666;\">Διαδρομή:</td><td><b>" + pd.from + " → " + pd.to + "</b></td></tr>" +
          "<tr><td style=\"padding:4px 12px 4px 0;color:#666;\">Ημερομηνία/ώρα:</td><td>" + whenStr + "</td></tr>" +
          "<tr><td style=\"padding:4px 12px 4px 0;color:#666;\">Πληρώθηκε:</td><td>" + pd.depositAmount + "€" + (pd.fullyPaid ? " (πλήρης πληρωμή)" : " (προκαταβολή)") + "</td></tr>" +
          (pd.price > 0.005
            ? "<tr><td style=\"padding:4px 12px 4px 0;color:#666;\">Θα πληρώσετε στον οδηγό:</td><td><b>" + pd.price.toFixed(2) + "€</b></td></tr>"
            : "") +
          markLineEl +
          iviewLineEl +
          "</table>" +
          "<p>" + waLine + "</p>";
        const bodyEn =
          "<h2 style=\"color:#1a1a2e;\">Your booking is confirmed!</h2>" +
          "<p>Hi " + pd.clientName + ",</p>" +
          "<p>Your deposit was paid successfully and your booking is now confirmed.</p>" +
          "<table style=\"border-collapse:collapse;margin:12px 0;\">" +
          "<tr><td style=\"padding:4px 12px 4px 0;color:#666;\">Booking ID:</td><td><b>#" + bookingNumber + "</b></td></tr>" +
          "<tr><td style=\"padding:4px 12px 4px 0;color:#666;\">Route:</td><td><b>" + pd.from + " → " + pd.to + "</b></td></tr>" +
          "<tr><td style=\"padding:4px 12px 4px 0;color:#666;\">Date/time:</td><td>" + whenStr + "</td></tr>" +
          "<tr><td style=\"padding:4px 12px 4px 0;color:#666;\">Paid:</td><td>€" + pd.depositAmount + (pd.fullyPaid ? " (full payment)" : " (deposit)") + "</td></tr>" +
          (pd.price > 0.005
            ? "<tr><td style=\"padding:4px 12px 4px 0;color:#666;\">To pay the driver:</td><td><b>€" + pd.price.toFixed(2) + "</b></td></tr>"
            : "") +
          markLineEn +
          iviewLineEn +
          "</table>" +
          "<p>" + waLine + "</p>";

        const html =
          "<div style=\"font-family:sans-serif;font-size:15px;color:#222;max-width:520px;margin:0 auto;\">" +
          logoHtml +
          (isEl ? bodyEl : bodyEn) +
          footerHtml +
          "</div>";

        let attachments = undefined;
        if (receiptResult && receiptResult.netValue != null) {
          try {
            // Ημερομηνία ΕΚΔΟΣΗΣ = σήμερα (ώρα Αθήνας) — ΟΧΙ η ώρα διαδρομής.
            const issueDateStr = athensNaiveDate(new Date()).toISOString().slice(0, 10)
              .split("-").reverse().join("/");
            const pdfBase64 = await buildReceiptPdfBase64({
              businessName, afm: t.afm, doy: t.doy, taxAddress: t.taxAddress,
              bookingNumber: receiptResult.bookingNumber || bookingNumber,
              issueDate: issueDateStr, mark: receiptResult.mark,
              clientName: pd.clientName, from: pd.from, to: pd.to, whenStr,
              serviceWhenStr: whenStr,
              netValue: receiptResult.netValue, vatAmount: receiptResult.vatAmount,
              vatPercent: receiptResult.vatPercent, grossValue: receiptResult.grossValue,
              isInvoice: receiptResult.isInvoice === true,
              provider: receiptResult.provider,
              custAfm: pd.invoiceAfm || null,
              custCompanyName: pd.invoiceCompanyName || null,
            });
            const fileBase = receiptResult.isInvoice === true ? "timologio-" : "apodeiksi-";
            attachments = [{ filename: fileBase + bookingNumber + ".pdf", content: pdfBase64 }];
          } catch (e) {
            console.error("receipt PDF generation failed:", e);
          }
        }

        await sendCustomerEmailViaResend({
          to: pd.clientEmail, subject, html, fromName: businessName, fromEmail, apiKeyOverride, attachments,
        });
      }
    } catch (e) {
      console.error("customer confirmation email failed:", e);
    }
  }

  return { ok: true, savedJobId: savedRef.id, bookingNumber };
}

// ── vivaWebhook: GET = επαλήθευση URL από Viva. POST = ειδοποίηση πληρωμής ──
exports.vivaWebhook = onRequest(
  {
    region: "us-central1", memory: "256MiB",
    secrets: [GCAL_CLIENT_SECRET, VIVA_MERCHANT_ID, VIVA_API_KEY, VIVA_DEMO, RESEND_API_KEY],
  },
  async (req, res) => {
    // ── Multi-tenant: κάθε tenant καταχωρεί το webhook URL με ?tenantId=xyz
    // στο ΔΙΚΟ ΤΟΥ Viva dashboard, ώστε να ξέρουμε ποια credentials να
    // χρησιμοποιήσουμε για την επαλήθευση GET. Ο δικός σου ("default")
    // tenant συνεχίζει να δουλεύει ΧΩΡΙΣ τίποτα στο URL, όπως πάντα.
    const webhookTenantId = s(req.query && req.query.tenantId) || "default";
    let vMerchantId = await readSecret("VIVA_MERCHANT_ID");
    let vApiKey = await readSecret("VIVA_API_KEY");
    let demo = vivaIsDemo(await readSecret("VIVA_DEMO"));
    if (webhookTenantId !== "default") {
      const tDoc = await getFirestore().collection("tenants").doc(webhookTenantId).get();
      if (tDoc.exists) {
        const t = tDoc.data();
        demo = t.vivaDemo !== false;
        const creds = await getTenantVivaCredentials(webhookTenantId);
        vMerchantId = creds.merchantId || vMerchantId;
        vApiKey = creds.apiKey || vApiKey;
      }
    }
    const hosts = vivaHosts(demo);

    // ── GET: η Viva επαληθεύει ότι ο server μας ελέγχεται από εμάς.
    //    Επιβεβαιωμένο από τα logs: σωστό host+path είναι
    //    [hosts.web]/api/messages/config/token (ΟΧΙ hosts.api).
    if (req.method === "GET") {
      try {
        const basic = Buffer.from(vMerchantId + ":" + vApiKey).toString("base64");
        const resp = await fetch(hosts.web + "/api/messages/config/token", {
          method: "GET",
          headers: { "Authorization": "Basic " + basic },
        });
        const rawText = await resp.text();
        console.log("vivaWebhook verify raw response:", resp.status, rawText);

        let data = null;
        try { data = JSON.parse(rawText); } catch (parseErr) { data = null; }

        if (!data || !data.Key) {
          console.error("vivaWebhook GET verify: δεν βρέθηκε Key στην απάντηση", {
            status: resp.status, body: rawText,
          });
          return res.status(500).json({ error: "verify_error" });
        }
        return res.status(200).json({ key: data.Key });
      } catch (e) {
        console.error("vivaWebhook GET verify error:", e);
        return res.status(500).json({ error: "verify_error" });
      }
    }

    if (req.method !== "POST") return res.status(405).end();

    try {
      const body = req.body || {};
      const ed = body.EventData || body.eventData || {};
      const eventTypeId = body.EventTypeId || body.eventTypeId;
      const statusId = ed.StatusId || ed.statusId;
      const orderCode = String(ed.OrderCode || ed.orderCode || "");
      const merchantTrns = ed.MerchantTrns || ed.merchantTrns || "";
      const amountPaid = Number(ed.Amount || ed.amount || 0);
      const transactionId = ed.TransactionId || ed.transactionId || "";

      // 1796 = Transaction Payment Created. statusId 'F' = επιτυχής πληρωμή.
      if (Number(eventTypeId) !== 1796 || statusId !== "F") {
        return res.status(200).json({ ok: true, ignored: true });
      }
      if (!merchantTrns) return res.status(200).json({ ok: true, ignored: true });

      const db = getFirestore();
      const pendingRef = db.collection("pending_bookings").doc(merchantTrns);
      const pendingDoc = await pendingRef.get();
      if (!pendingDoc.exists) return res.status(200).json({ ok: true, ignored: true }); // ήδη ολοκληρωμένο ή άγνωστο
      const pd = pendingDoc.data();
      if (pd.status !== "pending") return res.status(200).json({ ok: true, ignored: true }); // idempotency — δεν ξαναδημιουργούμε

      // ── Έλεγχος ποσού: πρέπει να ταιριάζει με το deposit που ζητήσαμε ──
      // ── Έλεγχος ποσού: το webhook της Viva στέλνει το ποσό σε ΕΥΡΩ (π.χ. 4
      // για 4,00€) — ΔΙΑΦΟΡΕΤΙΚΑ από το create-order API που θέλει λεπτά.
      // Μη μετατρέπεις σε λεπτά εδώ, σύγκρινε απευθείας σε ευρώ.
      if (Math.abs(amountPaid - pd.depositAmount) > 0.01) {
        console.error("vivaWebhook: amount mismatch", { expected: pd.depositAmount, amountPaid, merchantTrns });
        return res.status(200).json({ ok: true, ignored: true, reason: "amount_mismatch" });
      }

      // ── ΕΠΑΛΗΘΕΥΣΗ στο Viva API (ασφάλεια): δεν εμπιστευόμαστε ΜΟΝΟ το
      // POST body — ζητάμε το transaction από τη Viva (legacy retrieve API,
      // Basic auth MerchantId:ApiKey) και ελέγχουμε StatusId="F" + ποσό.
      // Best-effort: αν το API είναι ΑΠΡΟΣΙΤΟ (network/5xx), ΔΕΝ χάνουμε την
      // κράτηση — συνεχίζουμε με warning. Αν όμως η Viva απαντήσει ΡΗΤΑ ότι
      // το transaction δεν υπάρχει ή διαφέρει, απορρίπτουμε (πλαστό webhook).
      if (transactionId && vMerchantId && vApiKey) {
        try {
          const basic = Buffer.from(vMerchantId + ":" + vApiKey).toString("base64");
          const vResp = await fetch(hosts.web + "/api/transactions/" + encodeURIComponent(transactionId), {
            method: "GET",
            headers: { "Authorization": "Basic " + basic },
          });
          if (vResp.ok) {
            const vData = await vResp.json().catch(() => null);
            const tx = vData && Array.isArray(vData.Transactions) ? vData.Transactions[0] : null;
            if (!tx) {
              console.error("vivaWebhook: transaction ΔΕΝ βρέθηκε στη Viva — απόρριψη", { transactionId, merchantTrns });
              return res.status(200).json({ ok: true, ignored: true, reason: "tx_not_found" });
            }
            const vAmount = Number(tx.Amount || 0);
            const vStatus = String(tx.StatusId || "");
            if (vStatus !== "F" || Math.abs(vAmount - pd.depositAmount) > 0.01) {
              console.error("vivaWebhook: verification mismatch — απόρριψη",
                { transactionId, vStatus, vAmount, expected: pd.depositAmount });
              return res.status(200).json({ ok: true, ignored: true, reason: "tx_verify_mismatch" });
            }
          } else {
            console.warn("vivaWebhook: αδυναμία επαλήθευσης (HTTP " + vResp.status + ") — συνεχίζουμε best-effort");
          }
        } catch (e) {
          console.warn("vivaWebhook: αδυναμία επαλήθευσης (network) — συνεχίζουμε best-effort:", e.message);
        }
      }

      const result = await finalizeSuccessfulPayment(db, pendingRef, pd, {
        paymentProvider: "viva",
        fields: { vivaOrderCode: orderCode, vivaTransactionId: transactionId },
      });
      if (!result.ok) return res.status(200).json({ ok: true, error: result.error });

      return res.status(200).json({ ok: true });
    } catch (e) {
      console.error("vivaWebhook POST error:", e);
      // Επιστρέφουμε 200 ακόμα και σε σφάλμα ΔΙΚΟ ΜΑΣ, ώστε η Viva να μην κάνει
      // αμέτρητα retries για κάτι που δεν θα διορθωθεί μόνο του. Το σφάλμα
      // πάντως καταγράφεται στα logs (console.error) για να το δεις.
      return res.status(200).json({ ok: false, error: "server_error" });
    }
  }
);


exports.stripeWebhook = onRequest(
  { region: "us-central1", memory: "256MiB" },
  async (req, res) => {
    if (req.method !== "POST") return res.status(405).end();

    const webhookTenantId = s(req.query && req.query.tenantId) || "default";
    const tenantStripe = await getTenantStripeCredentials(webhookTenantId);
    if (!tenantStripe.secretKey) {
      console.error("stripeWebhook: no Stripe secret key configured for tenant", webhookTenantId);
      return res.status(400).send("stripe_not_configured");
    }

    const stripe = getStripeClient(tenantStripe.secretKey);
    let event;
    try {
      if (tenantStripe.webhookSecret) {
        event = stripe.webhooks.constructEvent(req.rawBody, req.headers["stripe-signature"], tenantStripe.webhookSecret);
      } else if (tenantStripe.secretKey.startsWith("sk_live")) {
        // ── ΑΣΦΑΛΕΙΑ: σε LIVE mode ΔΕΝ δεχόμαστε webhooks χωρίς υπογραφή —
        // αλλιώς οποιοσδήποτε θα μπορούσε να «επιβεβαιώσει» ψεύτικη πληρωμή.
        // Ο tenant ΠΡΕΠΕΙ να έχει βάλει το stripe-webhook-secret του.
        console.error("stripeWebhook: LIVE key χωρίς webhook secret για tenant", webhookTenantId, "— απόρριψη.");
        return res.status(400).send("webhook_secret_required_in_live_mode");
      } else {
        // Test mode (sk_test): επιτρέπουμε χωρίς υπογραφή για ευκολία δοκιμών.
        event = JSON.parse(req.rawBody.toString("utf8"));
        console.error("stripeWebhook: ΧΩΡΙΣ επαλήθευση υπογραφής (test mode, λείπει webhook secret) για tenant", webhookTenantId);
      }
    } catch (e) {
      console.error("stripeWebhook: signature verification failed:", e.message);
      return res.status(400).send("invalid_signature");
    }

    if (event.type !== "checkout.session.completed") {
      return res.status(200).json({ ok: true, ignored: true });
    }

    try {
      const session = event.data.object;
      const pendingBookingId = session.client_reference_id || (session.metadata && session.metadata.pendingBookingId);
      if (!pendingBookingId) return res.status(200).json({ ok: true, ignored: true });

      const db = getFirestore();
      const pendingRef = db.collection("pending_bookings").doc(pendingBookingId);
      const pendingDoc = await pendingRef.get();
      if (!pendingDoc.exists) return res.status(200).json({ ok: true, ignored: true });
      const pd = pendingDoc.data();
      if (pd.status !== "pending") return res.status(200).json({ ok: true, ignored: true });

      const amountPaidEur = Number(session.amount_total || 0) / 100;
      if (Math.abs(amountPaidEur - pd.depositAmount) > 0.01) {
        console.error("stripeWebhook: amount mismatch", { expected: pd.depositAmount, amountPaidEur, pendingBookingId });
        return res.status(200).json({ ok: true, ignored: true, reason: "amount_mismatch" });
      }

      const result = await finalizeSuccessfulPayment(db, pendingRef, pd, {
        paymentProvider: "stripe",
        fields: {
          stripeSessionId: session.id,
          stripePaymentIntentId: session.payment_intent || null,
        },
      });
      if (!result.ok) return res.status(200).json({ ok: true, error: result.error });

      return res.status(200).json({ ok: true });
    } catch (e) {
      console.error("stripeWebhook processing error:", e);
      return res.status(200).json({ ok: false, error: "server_error" });
    }
  }
);

// ═══════════════════════════════════════════════════════════════════════════
//  MULTI-TENANT — Φάση 1: onboarding νέου tenant
//
//  createTenant — ΜΟΝΟ ο super-admin (εσύ, techtacy@gmail.com) μπορεί να το
//  καλέσει. Δημιουργεί:
//   1) tenants/{tenantId} doc — όνομα επιχείρησης, Viva credentials/source
//      code (ΠΟΤΕ δεν εκτίθενται σε client — μόνο Cloud Functions τα διαβάζουν
//      μέσω Admin SDK, που παρακάμπτει τα Firestore rules).
//   2) presence/{masterUid}.tenantId = tenantId, master:true, isApproved:true
//      — ο νέος πελάτης γίνεται αμέσως master ΤΟΥ ΔΙΚΟΥ ΤΟΥ tenant.
//
//  Ο νέος master πρέπει ΠΡΩΤΑ να έχει κάνει τουλάχιστον ένα login στην
//  εφαρμογή (ώστε να υπάρχει το Firebase Auth account του) — μετά καλείς
//  αυτή τη function με το email του.
//
//  ⚠️ Αυτό ΔΕΝ αγγίζει καθόλου τα δικά σου (tenant "default") δεδομένα.
// ═══════════════════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════════════════
//  MULTI-TENANT — Secret Manager (ασφαλής αποθήκευση Viva credentials)
//
//  ΑΝΤΙ να αποθηκεύουμε τα Viva credentials σαν απλά πεδία στο tenants/{id}
//  Firestore doc, δημιουργούμε ΞΕΧΩΡΙΣΤΟ Google Secret Manager secret ανά
//  credential ανά tenant, δυναμικά (runtime), με το ίδιο επίπεδο προστασίας
//  (κρυπτογράφηση + IAM audit log) που έχουν και τα δικά σου secrets
//  (VIVA_CLIENT_ID κλπ, μέσω defineSecret). Το Firestore tenants/{id} doc
//  κρατάει ΜΟΝΟ μη-ευαίσθητα στοιχεία (όνομα, email, active, sourceCode).
//
//  ⚠️ ΑΠΑΙΤΕΙΤΑΙ: το service account των Cloud Functions
//  (PROJECT_ID@appspot.gserviceaccount.com, ή το compute default SA) χρειάζεται
//  τους ρόλους "Secret Manager Admin" (roles/secretmanager.admin) στο GCP
//  IAM, ώστε να μπορεί να ΔΗΜΙΟΥΡΓΕΙ νέα secrets δυναμικά (όχι μόνο να τα
//  διαβάζει). Χωρίς αυτό το δικαίωμα, το createTenant θα αποτύχει.
// ═══════════════════════════════════════════════════════════════════════════

const _secretManagerClient = new SecretManagerServiceClient();
const _gcpProjectId = process.env.GCLOUD_PROJECT || process.env.GOOGLE_CLOUD_PROJECT || "my-taxi-app-bbc7c";

// Δημιουργεί (αν δεν υπάρχει) ένα secret και προσθέτει μια νέα έκδοση με
// την τιμή του. Ασφαλές να καλείται ξανά (idempotent ως προς τη δημιουργία).
async function upsertSecret(secretId, value) {
  const parent = `projects/${_gcpProjectId}`;
  const secretName = `${parent}/secrets/${secretId}`;
  try {
    await _secretManagerClient.getSecret({ name: secretName });
  } catch (e) {
    // Δεν υπάρχει ακόμα — το δημιουργούμε.
    await _secretManagerClient.createSecret({
      parent,
      secretId,
      secret: { replication: { automatic: {} } },
    });
  }
  await _secretManagerClient.addSecretVersion({
    parent: secretName,
    payload: { data: Buffer.from(value, "utf8") },
  });
  // ⚠️ ΣΗΜΑΝΤΙΚΟ: χωρίς αυτό, μια ζεστή (warm) instance της function θα
  // συνέχιζε να χρησιμοποιεί την ΠΑΛΙΑ τιμή έως 10 λεπτά μετά την αλλαγή —
  // π.χ. tenant διορθώνει Merchant ID/API Key και δοκιμάζει αμέσως, αλλά ο
  // server ακόμα βλέπει το λάθος παλιό κλειδί (401 Unauthorized).
  _secretValueCache.delete(secretId);
}

// Cache 10 λεπτών ανά secret ώστε να μην χτυπάμε το Secret Manager σε κάθε
// μία κράτηση (Secret Manager API έχει και δικό του κόστος ανά πρόσβαση).
const _secretValueCache = new Map(); // secretId -> { value, at }
async function readSecret(secretId) {
  const now = Date.now();
  const cached = _secretValueCache.get(secretId);
  if (cached && now - cached.at < 10 * 60 * 1000) return cached.value;
  try {
    const [version] = await _secretManagerClient.accessSecretVersion({
      name: `projects/${_gcpProjectId}/secrets/${secretId}/versions/latest`,
    });
    const value = version.payload.data.toString("utf8");
    _secretValueCache.set(secretId, { value, at: now });
    return value;
  } catch (e) {
    console.error("readSecret error για", secretId, ":", e.message);
    return null;
  }
}

// Ονόματα secrets ανά tenant (σταθερό, προβλέψιμο μοτίβο — δεν χρειάζεται
// να αποθηκεύουμε τίποτα στο Firestore για να τα ξαναβρούμε).
// ═══════════════════════════════════════════════════════════════════════
// myDATA — απευθείας αποστολή παραστατικού (δωρεάν, χωρίς πάροχο) ─────────
// ⚠️ ΣΗΜΑΝΤΙΚΟ: Πριν ενεργοποιηθεί ΠΟΤΕ σε πραγματική συναλλαγή, χρειάζεται
// δοκιμή στο SANDBOX της ΑΑΔΕ (mydataapidev.aade.gr) με πραγματικό
// subscription key δοκιμαστικού λογαριασμού. Η δομή του XML ακολουθεί το
// επίσημο schema InvoicesDoc v1.0.4. Ο χαρακτηρισμός εσόδων (income
// classification) περιλαμβάνεται αυτόματα — E3_561_003 (Λιανικές, προς
// ιδιώτες) για «Απόδειξη Παροχής Υπηρεσιών» (11.2), E3_561_001 (Χονδρικές)
// για «Τιμολόγιο Παροχής Υπηρεσιών» (2.1) — επιβεβαιωμένοι κωδικοί ΑΑΔΕ.
// ═══════════════════════════════════════════════════════════════════════

function mydataHosts(demo) {
  return demo
    ? "https://mydataapidev.aade.gr"
    : "https://mydatapi.aade.gr/myDATA";
}

// ── Επικύρωση ΑΦΜ (ίδιος επίσημος αλγόριθμος με το client) — ασφάλεια
// server-side, ανεξάρτητα από το αν παρακάμφθηκε ο έλεγχος στη φόρμα.
function isValidGreekAfm(afm) {
  if (!/^\d{9}$/.test(afm || "")) return false;
  let sum = 0;
  for (let i = 0; i < 8; i++) {
    sum += parseInt(afm[i], 10) * Math.pow(2, 8 - i);
  }
  const check = (sum % 11) % 10;
  return check === parseInt(afm[8], 10);
}

function xmlEscape(str) {
  return String(str || "")
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&apos;");
}

// Επιστρέφει {category, type} χαρακτηρισμού εσόδων ανάλογα με τον τύπο
// παραστατικού — επιβεβαιωμένοι κωδικοί ΑΑΔΕ (εγχειρίδιο myDATA):
//   11.2 (Απόδειξη Παροχής Υπηρεσιών, προς ιδιώτες) → E3_561_003 (Λιανικές)
//   2.1  (Τιμολόγιο Παροχής Υπηρεσιών, B2B)          → E3_561_001 (Χονδρικές)
function incomeClassificationFor(invoiceType) {
  return invoiceType === "2.1"
    ? { category: "category1_1", type: "E3_561_001" }
    : { category: "category1_3", type: "E3_561_003" };
}

// Χτίζει το XML ενός απλού παραστατικού (1 γραμμή, 1 τρόπος πληρωμής).
function buildMydataInvoiceXml({
  issuerAfm, series, aa, issueDate, invoiceType, vatCategory,
  netValue, vatAmount, grossValue, correlatedMark, counterpart,
}) {
  const cls = incomeClassificationFor(invoiceType);
  // ── Πιστωτικό (11.4): αναφέρεται στο ΑΡΧΙΚΟ παραστατικό μέσω correlatedInvoices
  // (το MARK του παραστατικού που ακυρώνει/διορθώνει).
  const correlatedXml = correlatedMark
    ? "<correlatedInvoices>" + xmlEscape(correlatedMark) + "</correlatedInvoices>"
    : "";
  // ── Λήπτης (counterpart) — ΜΟΝΟ για Τιμολόγιο (2.1), ΠΟΤΕ για Απόδειξη
  // (11.2/11.4) όπου επιβεβαιωμένα ΔΕΝ επιτρέπεται καν το στοιχείο αυτό.
  // vatNumber+country+branch υποχρεωτικά, name/address προαιρετικά.
  let counterpartXml = "";
  if (counterpart && counterpart.vatNumber) {
    const addr = counterpart.address;
    const addressXml = addr
      ? "<address>" +
        (addr.street ? "<street>" + xmlEscape(addr.street) + "</street>" : "") +
        (addr.postalCode ? "<postalCode>" + xmlEscape(addr.postalCode) + "</postalCode>" : "") +
        (addr.city ? "<city>" + xmlEscape(addr.city) + "</city>" : "") +
        "</address>"
      : "";
    counterpartXml =
      "<counterpart>" +
      "<vatNumber>" + xmlEscape(counterpart.vatNumber) + "</vatNumber>" +
      "<country>GR</country>" +
      "<branch>0</branch>" +
      (counterpart.name ? "<name>" + xmlEscape(counterpart.name) + "</name>" : "") +
      addressXml +
      "</counterpart>";
  }
  return '<?xml version="1.0" encoding="UTF-8"?>' +
    '<InvoicesDoc xmlns="https://www.aade.gr/myDATA/invoice/v1.0" ' +
    'xmlns:icls="https://www.aade.gr/myDATA/invoice/incomeclassification/v1.0">' +
    "<invoice>" +
    "<issuer>" +
    "<vatNumber>" + xmlEscape(issuerAfm) + "</vatNumber>" +
    "<country>GR</country>" +
    "<branch>0</branch>" +
    "</issuer>" +
    counterpartXml +
    "<invoiceHeader>" +
    "<series>" + xmlEscape(series) + "</series>" +
    "<aa>" + xmlEscape(aa) + "</aa>" +
    "<issueDate>" + xmlEscape(issueDate) + "</issueDate>" +
    "<invoiceType>" + xmlEscape(invoiceType) + "</invoiceType>" +
    "<currency>EUR</currency>" +
    correlatedXml +
    "</invoiceHeader>" +
    "<paymentMethods>" +
    "<paymentMethodDetails>" +
    "<type>3</type>" + // 3 = POS/e-POS/Web Banking (ηλεκτρονική πληρωμή)
    "<amount>" + grossValue.toFixed(2) + "</amount>" +
    "</paymentMethodDetails>" +
    "</paymentMethods>" +
    "<invoiceDetails>" +
    "<lineNumber>1</lineNumber>" +
    "<netValue>" + netValue.toFixed(2) + "</netValue>" +
    "<vatCategory>" + xmlEscape(vatCategory) + "</vatCategory>" +
    "<vatAmount>" + vatAmount.toFixed(2) + "</vatAmount>" +
    "<incomeClassification>" +
    "<icls:classificationCategory>" + cls.category + "</icls:classificationCategory>" +
    "<icls:classificationType>" + cls.type + "</icls:classificationType>" +
    "<icls:amount>" + netValue.toFixed(2) + "</icls:amount>" +
    "</incomeClassification>" +
    "</invoiceDetails>" +
    "<invoiceSummary>" +
    "<totalNetValue>" + netValue.toFixed(2) + "</totalNetValue>" +
    "<totalVatAmount>" + vatAmount.toFixed(2) + "</totalVatAmount>" +
    "<totalWithheldAmount>0.00</totalWithheldAmount>" +
    "<totalFeesAmount>0.00</totalFeesAmount>" +
    "<totalStampDutyAmount>0.00</totalStampDutyAmount>" +
    "<totalOtherTaxesAmount>0.00</totalOtherTaxesAmount>" +
    "<totalDeductionsAmount>0.00</totalDeductionsAmount>" +
    "<totalGrossValue>" + grossValue.toFixed(2) + "</totalGrossValue>" +
    "</invoiceSummary>" +
    "</invoice>" +
    "</InvoicesDoc>";
}

// Στέλνει το παραστατικό στο myDATA και επιστρέφει το MARK (ή σφάλμα).
// demo=true -> SANDBOX της ΑΑΔΕ (ασφαλές για δοκιμές, ΔΕΝ μετράει σαν
// πραγματικό παραστατικό). demo=false -> ΠΑΡΑΓΩΓΗ, πραγματικό παραστατικό.
async function sendMydataInvoice({ demo, username, subscriptionKey, xml }) {
  const base = mydataHosts(demo);
  const resp = await fetch(base + "/SendInvoices", {
    method: "POST",
    headers: {
      "Content-Type": "application/xml",
      "aade-user-id": username,
      "ocp-apim-subscription-key": subscriptionKey,
    },
    body: xml,
  });
  const rawText = await resp.text();
  if (!resp.ok) {
    console.error("mydata SendInvoices failed:", resp.status, rawText);
    return { ok: false, error: "mydata_http_" + resp.status, raw: rawText };
  }
  const markMatch = rawText.match(/<mark>(\d+)<\/mark>/);
  const errorMatch = rawText.match(/<message>(.*?)<\/message>/);
  if (!markMatch) {
    console.error("mydata: no MARK in response:", rawText);
    return { ok: false, error: errorMatch ? errorMatch[1] : "no_mark", raw: rawText };
  }
  return { ok: true, mark: markMatch[1], raw: rawText };
}

// Υπολογίζει καθαρή αξία/ΦΠΑ από την τελική (μεικτή) τιμή, ανάλογα με την
// κατηγορία ΦΠΑ (1=24%, 2=13%, 3=6%, 7=χωρίς ΦΠΑ).
function splitVat(grossValue, vatCategory) {
  const rates = { "1": 0.24, "2": 0.13, "3": 0.06, "7": 0 };
  const rate = rates[vatCategory] != null ? rates[vatCategory] : 0.24;
  // ⚠️ Στρογγυλοποίηση με συνέπεια: στρογγυλεύουμε ΠΡΩΤΑ την καθαρή αξία σε
  // 2 δεκαδικά και ο ΦΠΑ προκύπτει ως ΔΙΑΦΟΡΑ από το μεικτό — έτσι ισχύει
  // ΠΑΝΤΑ net + vat === gross στο λεπτό (το myDATA απορρίπτει παραστατικά
  // όπου το invoiceSummary δεν «κουμπώνει» ακριβώς).
  const gross = Math.round((Number(grossValue) || 0) * 100) / 100;
  const netValue = rate > 0 ? Math.round((gross / (1 + rate)) * 100) / 100 : gross;
  const vatAmount = Math.round((gross - netValue) * 100) / 100;
  return { netValue, vatAmount };
}

// ── Κεντρική συνάρτηση: εκδίδει παραστατικό για μια ολοκληρωμένη κράτηση,
// ΜΟΝΟ αν ο tenant έχει invoiceEnabled===true ΚΑΙ invoiceProvider==="mydata".
// Καλείται από το vivaWebhook μετά την επιτυχή πληρωμή — ΠΟΤΕ μπλοκάρει την
// υπόλοιπη ροή (email/saved_jobs) αν αποτύχει, απλά καταγράφει το σφάλμα.
async function tryIssueMydataReceipt({ tenantId, t, grossAmount, bookingNumber, invoiceRequest }) {
  try {
    if (!t.invoiceEnabled || t.invoiceProvider !== "mydata") return null;
    if (!t.afm) {
      console.error("mydata receipt: λείπει ΑΦΜ για tenant", tenantId);
      return null;
    }
    const username = t.mydataUsername;
    const subKey = await readSecret(tenantSecretId(tenantId, "mydata-subscription-key")).catch(() => null);
    if (!username || !subKey) {
      console.error("mydata receipt: λείπουν credentials για tenant", tenantId);
      return null;
    }

    // ── Ο πελάτης μπορεί να ζητήσει ΤΙΜΟΛΟΓΙΟ (2.1, για επιχείρηση) αντί για
    // την κανονική ΑΠΥ (11.2) — ανά κράτηση, ΟΧΙ γενική ρύθμιση tenant.
    // Χρειάζεται ΑΦΜ επιχείρησης-πελάτη· χωρίς αυτό, ΠΑΝΤΑ γίνεται Απόδειξη.
    const wantsInvoice = !!(invoiceRequest && invoiceRequest.afm);
    const invoiceType = wantsInvoice ? "2.1" : (t.mydataInvoiceType || "11.2");
    const counterpart = wantsInvoice
      ? {
          vatNumber: invoiceRequest.afm,
          name: invoiceRequest.companyName || null,
          address: invoiceRequest.address ? { street: invoiceRequest.address } : null,
        }
      : null;

    const vatCategory = t.mydataVatCategory || "2"; // 13% προεπιλογή, επιβεβαιωμένο για ΤΑΞΙ
    const series = t.invoiceSeries || "A";
    const { netValue, vatAmount } = splitVat(Number(grossAmount) || 0, vatCategory);
    const vatPercent = { "1": 24, "2": 13, "3": 6, "7": 0 }[vatCategory] ?? 13;
    const aa = await nextInvoiceNumber(tenantId, series);

    const xml = buildMydataInvoiceXml({
      issuerAfm: t.afm,
      series,
      aa,
      issueDate: athensNaiveDate(new Date()).toISOString().slice(0, 10),
      invoiceType,
      vatCategory,
      netValue,
      vatAmount,
      grossValue: Number(grossAmount) || 0,
      counterpart,
    });

    const demo = t.mydataDemo !== false; // ΞΕΧΩΡΙΣΤΟ demo/live flag από τη Viva — βλ. σχόλιο πάνω
    const result = await sendMydataInvoice({ demo, username, subscriptionKey: subKey, xml });
    if (!result.ok) {
      console.error("mydata receipt failed for tenant", tenantId, result.error);
      return null;
    }
    console.log("mydata receipt issued, MARK:", result.mark, "tenant:", tenantId, "type:", invoiceType);
    return {
      mark: result.mark, provider: "mydata",
      netValue, vatAmount, vatPercent, grossValue: Number(grossAmount) || 0,
      bookingNumber: aa, series, invoiceType,
      isInvoice: wantsInvoice, // ώστε το PDF να τιτλοφορείται «Τιμολόγιο»
    };
  } catch (e) {
    console.error("tryIssueMydataReceipt error:", e);
    return null;
  }
}

// ── Πιστωτικό Στοιχείο Λιανικής (11.4) — αυτόματη ακύρωση/διόρθωση ενός
// ήδη εκδομένου παραστατικού myDATA (11.2), όταν ακυρώνεται η κράτηση.
// Επαναχρησιμοποιεί ΑΚΡΙΒΩΣ τα ίδια ποσά/ΦΠΑ με το αρχικό — «αντιγραφή» του
// αρχικού ως πιστωτικό, ίδια λογική με ό,τι κάνουν τα λογιστικά συστήματα
// (SBZ Systems κ.ά.). Ξεχωριστός αύξων αριθμός (δική του σειρά "series-C"
// ώστε να μη μπερδεύεται η αρίθμηση με τα κανονικά παραστατικά).
async function tryIssueMydataCreditNote({ tenantId, t, savedJobData }) {
  try {
    if (!t.invoiceEnabled || t.invoiceProvider !== "mydata") return null;
    if (!savedJobData.invoiceMark || savedJobData.invoiceProvider !== "mydata") return null;
    if (!t.afm) {
      console.error("mydata credit note: λείπει ΑΦΜ για tenant", tenantId);
      return null;
    }
    const username = t.mydataUsername;
    const subKey = await readSecret(tenantSecretId(tenantId, "mydata-subscription-key")).catch(() => null);
    if (!username || !subKey) {
      console.error("mydata credit note: λείπουν credentials για tenant", tenantId);
      return null;
    }

    const vatCategory = t.mydataVatCategory || "2";
    const baseSeries = t.invoiceSeries || "A";
    const creditSeries = baseSeries + "-C"; // ξεχωριστή σειρά για πιστωτικά, δική της αρίθμηση

    // Ξαναϋπολογίζουμε net/ΦΠΑ από το ΑΚΡΙΒΕΣ ποσό που είχε τιμολογηθεί
    // αρχικά (αποθηκευμένο στο invoiceGrossAmount — μπορεί να ήταν μόνο η
    // προκαταβολή, όχι όλο το job.price).
    const grossValue = Number(savedJobData.invoiceGrossAmount) || 0;
    if (grossValue <= 0) {
      console.error("mydata credit note: άγνωστο ποσό για tenant", tenantId);
      return null;
    }
    const { netValue, vatAmount } = splitVat(grossValue, vatCategory);
    const aa = await nextInvoiceNumber(tenantId, creditSeries);

    const xml = buildMydataInvoiceXml({
      issuerAfm: t.afm,
      series: creditSeries,
      aa,
      issueDate: athensNaiveDate(new Date()).toISOString().slice(0, 10),
      invoiceType: "11.4", // Πιστωτικό Στοιχείο Λιανικής
      vatCategory,
      netValue, vatAmount, grossValue,
      correlatedMark: savedJobData.invoiceMark,
    });

    const demo = t.mydataDemo !== false;
    const result = await sendMydataInvoice({ demo, username, subscriptionKey: subKey, xml });
    if (!result.ok) {
      console.error("mydata credit note failed for tenant", tenantId, result.error);
      return { ok: false, error: result.error };
    }
    console.log("mydata credit note issued, MARK:", result.mark, "original MARK:", savedJobData.invoiceMark);
    return { ok: true, mark: result.mark };
  } catch (e) {
    console.error("tryIssueMydataCreditNote error:", e);
    return { ok: false, error: String(e) };
  }
}

// ═══════════════════════════════════════════════════════════════════════
// Epsilon Smart — e-Shop API (πληρωμένος πάροχος) ────────────────────────
// Επίσημη τεκμηρίωση: kb.epsilonnet.gr/epsilonsmart (ManualEshopAPI.pdf).
// Ροή: 1) LoginToSubscription (myaccount.epsilonnet.gr) -> JWT + smartUrl
//      2) POST {smartUrl}api/Eshop/InsertDocuments με Bearer JWT
// Κάνουμε νέο login σε κάθε έκδοση (χωρίς cache token) — απλούστερο και
// αρκετά γρήγορο για τον όγκο κρατήσεων μας, χωρίς να χρειάζεται να
// αποθηκεύουμε/ανανεώνουμε JWT μεταξύ κλήσεων της cloud function.
// ═══════════════════════════════════════════════════════════════════════

async function epsilonLogin({ subscriptionKey, email, password }) {
  const resp = await fetch("https://myaccount.epsilonnet.gr/api/Account/LoginToSubscription", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ subscriptionKey, email, password }),
  });
  if (!resp.ok) {
    const text = await resp.text().catch(() => "");
    throw new Error("epsilon login failed: " + resp.status + " " + text);
  }
  const data = await resp.json();
  return { jwt: data.jwt, smartUrl: data.url2 };
}

// Χτίζει ένα EshopSale (παραστατικό λιανικής, 1 γραμμή υπηρεσίας).
function buildEpsilonSale({
  itemCode, vatPercent, grossValue, netValue, vatAmount,
  refDocCode, custName, custPhone, custEmail, invoiceRequest,
}) {
  // DocDateTime ΠΡΕΠΕΙ να είναι χωρίς timezone (Unspecified) — π.χ.
  // "2026-07-12T14:30:00.000", ΟΧΙ με Z ή offset.
  const now = athensNaiveDate(new Date());
  const docDateTime = now.toISOString().replace("Z", "");
  // ── Αίτημα Τιμολογίου (ανά κράτηση) — IsRetail=0 (χονδρική/επιχείρηση),
  // CustTIN=ΑΦΜ πελάτη. Χωρίς αυτό, μένει η κανονική Απόδειξη (IsRetail=1).
  const wantsInvoice = !!(invoiceRequest && invoiceRequest.afm);
  return {
    DocDateTime: docDateTime,
    IsRetail: wantsInvoice ? 0 : 1,
    VatStatus: 1, // 1 = μειωμένο καθεστώς ΦΠΑ (13% για ΤΑΞΙ)
    RefDocCode: String(refDocCode || ""),
    PaymentMethod: 2, // 2 = Πιστωτική κάρτα (πληρωμή μέσω Viva)
    CustName: wantsInvoice ? (invoiceRequest.companyName || custName || null) : (custName || null),
    CustTIN: wantsInvoice ? invoiceRequest.afm : null,
    CustStreet: wantsInvoice ? (invoiceRequest.address || null) : null,
    CustPhone1: custPhone || null,
    CustEmail: custEmail || null,
    Justification: "Μεταφορά με ταξί",
    Lines: [
      {
        ItemCode: itemCode,
        VATPercent: vatPercent,
        Qty: 1,
        Price: grossValue,
        NetVal: netValue,
        VATVal: vatAmount,
        TotalVal: grossValue,
      },
    ],
  };
}

async function submitEpsilonSale({ jwt, smartUrl, sale }) {
  const url = smartUrl.endsWith("/") ? smartUrl + "api/Eshop/InsertDocuments"
    : smartUrl + "/api/Eshop/InsertDocuments";
  const resp = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": "Bearer " + jwt,
    },
    body: JSON.stringify([sale]),
  });
  const text = await resp.text().catch(() => "");
  if (!resp.ok) {
    console.error("epsilon InsertDocuments failed:", resp.status, text);
    return { ok: false, error: "epsilon_http_" + resp.status, raw: text };
  }
  return { ok: true, raw: text };
}

// ── Κεντρική συνάρτηση — ίδιο μοτίβο με tryIssueMydataReceipt: best-effort,
// ΠΟΤΕ δεν μπλοκάρει την υπόλοιπη ροή αν αποτύχει.
async function tryIssueEpsilonReceipt({ tenantId, t, grossAmount, bookingNumber, custName, custPhone, custEmail, invoiceRequest }) {
  try {
    if (!t.invoiceEnabled || t.invoiceProvider !== "epsilon") return null;
    if (!t.epsilonItemCode || !t.epsilonEmail) {
      console.error("epsilon receipt: λείπουν στοιχεία (email/item code) για tenant", tenantId);
      return null;
    }
    const subscriptionKey = await readSecret(tenantSecretId(tenantId, "invoice-api-key")).catch(() => null);
    const password = await readSecret(tenantSecretId(tenantId, "epsilon-password")).catch(() => null);
    if (!subscriptionKey || !password) {
      console.error("epsilon receipt: λείπουν credentials για tenant", tenantId);
      return null;
    }

    const vatCategory = t.mydataVatCategory || "2"; // ίδια επιλογή ΦΠΑ με το myDATA tab
    const vatPercent = { "1": 24, "2": 13, "3": 6, "7": 0 }[vatCategory] ?? 13;
    const gross = Number(grossAmount) || 0;
    const rate = vatPercent / 100;
    const netValue = rate > 0 ? gross / (1 + rate) : gross;
    const vatAmount = gross - netValue;

    const { jwt, smartUrl } = await epsilonLogin({
      subscriptionKey, email: t.epsilonEmail, password,
    });
    const sale = buildEpsilonSale({
      itemCode: t.epsilonItemCode,
      vatPercent,
      grossValue: Math.round(gross * 100) / 100,
      netValue: Math.round(netValue * 100) / 100,
      vatAmount: Math.round(vatAmount * 100) / 100,
      refDocCode: bookingNumber,
      custName, custPhone, custEmail, invoiceRequest,
    });
    const result = await submitEpsilonSale({ jwt, smartUrl, sale });
    if (!result.ok) {
      console.error("epsilon receipt failed for tenant", tenantId, result.error);
      return null;
    }
    console.log("epsilon receipt issued for tenant:", tenantId, "invoice:", !!(invoiceRequest && invoiceRequest.afm));
    // ── Επιστρέφουμε και τα ποσά ώστε ο πελάτης να παίρνει PDF στο email
    // (πριν, χωρίς netValue, το PDF παραλειπόταν εντελώς για Epsilon).
    return {
      provider: "epsilon",
      mark: null,
      netValue: Math.round(netValue * 100) / 100,
      vatAmount: Math.round(vatAmount * 100) / 100,
      vatPercent,
      grossValue: Math.round(gross * 100) / 100,
      bookingNumber,
      isInvoice: !!(invoiceRequest && invoiceRequest.afm),
    };
  } catch (e) {
    console.error("tryIssueEpsilonReceipt error:", e);
    return null;
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Oxygen Pelatologio — τρίτος διαθέσιμος πάροχος αποδείξεων/τιμολογίων,
//  ΙΔΙΟ pattern με myDATA/Epsilon (self-service credentials, tenant config,
//  fallback chain). API: https://docs.oxygen.gr/ (Bearer token, OpenAPI 3.1).
//  Ο tenant χρειάζεται να έχει ήδη δημιουργήσει στο δικό του Oxygen account:
//  branch, numbering sequence, payment method — τα IDs τους μπαίνουν στις
//  ρυθμίσεις (tab Oxygen) μαζί με το API key.
// ═══════════════════════════════════════════════════════════════════════════
async function tryIssueOxygenReceipt({ tenantId, t, grossAmount, bookingNumber, custName, custPhone, custEmail, invoiceRequest }) {
  try {
    if (!t.invoiceEnabled || t.invoiceProvider !== "oxygen") return null;
    if (!t.oxygenBranchId || !t.oxygenNumberingSequenceId) {
      console.error("oxygen receipt: λείπουν branch_id/numbering_sequence_id για tenant", tenantId);
      return null;
    }
    const apiKey = await readSecret(tenantSecretId(tenantId, "invoice-api-key")).catch(() => null);
    if (!apiKey) {
      console.error("oxygen receipt: λείπει API key για tenant", tenantId);
      return null;
    }

    const vatCategory = t.mydataVatCategory || "2"; // ίδια επιλογή ΦΠΑ με τα άλλα tabs (myDATA)
    const vatPercent = { "1": 24, "2": 13, "3": 6, "7": 0 }[vatCategory] ?? 13;
    const gross = Number(grossAmount) || 0;
    const rate = vatPercent / 100;
    const netValue = rate > 0 ? gross / (1 + rate) : gross;
    const vatAmount = gross - netValue;

    const wantsInvoice = !!(invoiceRequest && invoiceRequest.afm);
    // document_type: "s" = Τιμολόγιο Παροχής Υπηρεσιών (χρειάζεται ΑΦΜ πελάτη),
    // "rs" = Απόδειξη Λιανικής Παροχής Υπηρεσιών (προεπιλογή, χωρίς ΑΦΜ).
    // ⚠️ Το enum του Oxygen θέλει ΟΛΟΚΛΗΡΟ το string (από το InvoiceItem schema),
    // όχι σκέτο "s"/"rs":
    const documentType = wantsInvoice
      ? "s (Invoice for Services)"
      : "rs (Receipt (issued to private customers) for services)";

    const isSandbox = t.oxygenSandbox === true;
    const baseUrl = isSandbox
      ? "https://sandbox-api.oxygen.gr/v1"
      : "https://api.oxygen.gr/v1";

    const body = {
      numbering_sequence_id: t.oxygenNumberingSequenceId,
      issue_date: new Date().toISOString().slice(0, 10),
      document_type: documentType,
      language: "GR", // enum Oxygen: "GR" | "EN" (ΟΧΙ "el")
      payment_method_id: t.oxygenPaymentMethodId || undefined,
      description: "Μεταφορά " + (bookingNumber ? "#" + bookingNumber : ""),
      branch_id: t.oxygenBranchId,
      is_paid: true,
      comments: wantsInvoice && invoiceRequest.companyName ? invoiceRequest.companyName : undefined,
      items: [{
        description: "Υπηρεσίες μεταφοράς" + (bookingNumber ? " — Κράτηση #" + bookingNumber : ""),
        quantity: 1,
        unit_net_value: Math.round(netValue * 100) / 100,
        net_amount: Math.round(netValue * 100) / 100,
        vat_amount: Math.round(vatAmount * 100) / 100,
      }],
    };

    // Στοιχεία πελάτη — μόνο αν ζητήθηκε τιμολόγιο (χρειάζεται ΑΦΜ)· η απλή
    // απόδειξη λιανικής δεν χρειάζεται contact_id/στοιχεία πελάτη.
    if (wantsInvoice) {
      body.contact_vat = invoiceRequest.afm;
      if (invoiceRequest.companyName) body.contact_display_name = invoiceRequest.companyName;
      if (invoiceRequest.address) body.contact_address = invoiceRequest.address;
    } else if (custName) {
      body.contact_display_name = custName;
    }
    if (custEmail) body.contact_email = custEmail;
    if (custPhone) body.contact_telephone = custPhone;

    let resp, data;
    try {
      resp = await fetch(baseUrl + "/invoices", {
        method: "POST",
        headers: {
          "Authorization": "Bearer " + apiKey,
          "Accept": "application/json",
          "Content-Type": "application/json",
        },
        body: JSON.stringify(body),
      });
      data = await resp.json().catch(() => ({}));
    } catch (e) {
      console.error("oxygen receipt: network error for tenant", tenantId, e.message);
      return null;
    }

    if (!resp.ok) {
      console.error("oxygen receipt failed for tenant", tenantId, resp.status, data.message || data.errors || data);
      return null;
    }

    console.log("oxygen receipt issued for tenant:", tenantId, "iview_code:", data.iview_code, "invoice:", wantsInvoice);
    return {
      // ── Το ΠΡΑΓΜΑΤΙΚΟ MARK της ΑΑΔΕ έρχεται στο mydata.mark (μπορεί να είναι
      // null αν η διαβίβαση εκκρεμεί) — fallback στο iview_code. Το MARK
      // χρειάζεται για το correlated_invoice του πιστωτικού τιμολογίου (5.1).
      mark: (data.mydata && data.mydata.mark) || data.iview_code || null,
      provider: "oxygen",
      netValue: Number(data.net_amount ?? netValue),
      vatAmount: Number(data.vat_amount ?? vatAmount),
      vatPercent,
      grossValue: Number(data.total_amount ?? gross),
      bookingNumber,
      iviewUrl: data.iview_url || null,
      isInvoice: wantsInvoice,
    };
  } catch (e) {
    console.error("tryIssueOxygenReceipt error:", e);
    return null;
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Oxygen — Αυτόματο Πιστωτικό σε ακύρωση κράτησης (POST /credit-notes).
//  Ίδιο μοτίβο με το tryIssueMydataCreditNote: best-effort, ίδια ποσά με το
//  αρχικό παραστατικό, ΠΟΤΕ δεν μπλοκάρει τη ροή.
//
//  Από την τεκμηρίωση του Oxygen API:
//   • document_type "pistlianiki" = Πιστωτικό Λιανικής (κατά απόδειξης,
//     myDATA 11.4) — Η ΣΥΝΗΘΙΣΜΕΝΗ περίπτωση, ΔΕΝ απαιτεί correlated_invoice.
//   • document_type "pistotiko"   = Πιστωτικό Τιμολόγιο (myDATA 5.1) —
//     ΥΠΟΧΡΕΩΤΙΚΟ το correlated_invoice = MARK του αρχικού τιμολογίου.
//  ⚠️ Απαιτεί ΞΕΧΩΡΙΣΤΗ σειρά αρίθμησης πιστωτικών στον λογαριασμό Oxygen
//  του tenant (oxygenCreditNumberingSequenceId) — χωρίς αυτήν επιστρέφει
//  null και μένει η χειροκίνητη ειδοποίηση.
// ═══════════════════════════════════════════════════════════════════════════
async function tryIssueOxygenCreditNote({ tenantId, t, savedJobData }) {
  try {
    if (!t.invoiceEnabled || t.invoiceProvider !== "oxygen") return null;
    if (savedJobData.invoiceProvider !== "oxygen") return null;
    if (!t.oxygenBranchId || !t.oxygenCreditNumberingSequenceId) {
      console.error("oxygen credit note: λείπει branch_id ή ΣΕΙΡΑ ΠΙΣΤΩΤΙΚΩΝ (oxygenCreditNumberingSequenceId) για tenant", tenantId);
      return null;
    }
    const apiKey = await readSecret(tenantSecretId(tenantId, "invoice-api-key")).catch(() => null);
    if (!apiKey) {
      console.error("oxygen credit note: λείπει API key για tenant", tenantId);
      return null;
    }

    const grossValue = Number(savedJobData.invoiceGrossAmount) || 0;
    if (grossValue <= 0) {
      console.error("oxygen credit note: άγνωστο ποσό για tenant", tenantId);
      return null;
    }

    const wantsInvoice = savedJobData.invoiceIsInvoice === true;
    // Πιστωτικό ΚΑΤΑ ΤΙΜΟΛΟΓΙΟΥ (5.1) χωρίς MARK αρχικού δεν γίνεται —
    // πέφτουμε στη χειροκίνητη ειδοποίηση.
    if (wantsInvoice && !savedJobData.invoiceMark) {
      console.error("oxygen credit note: πιστωτικό τιμολογίου χωρίς MARK αρχικού — χειροκίνητα, tenant", tenantId);
      return null;
    }

    const vatCategory = t.mydataVatCategory || "2"; // ίδια επιλογή ΦΠΑ με την έκδοση
    const vatPercent = { "1": 24, "2": 13, "3": 6, "7": 0 }[vatCategory] ?? 13;
    const { netValue, vatAmount } = splitVat(grossValue, vatCategory);

    const isSandbox = t.oxygenSandbox === true;
    const baseUrl = isSandbox
      ? "https://sandbox-api.oxygen.gr/v1"
      : "https://api.oxygen.gr/v1";

    const bookingNumber = savedJobData.bookingNumber || "";
    const body = {
      numbering_sequence_id: t.oxygenCreditNumberingSequenceId,
      issue_date: athensNaiveDate(new Date()).toISOString().slice(0, 10),
      // ⚠️ Enums από το schema του Oxygen:
      //  • document_type = ΟΛΟΚΛΗΡΟ το string (όχι σκέτο "pistlianiki")
      //  • language = "GR" | "EN" (ΟΧΙ "el")
      document_type: wantsInvoice
        ? "pistotiko - Credit note for invoices"
        : "pistlianiki - Credit note for receipts",
      mydata_document_type: wantsInvoice ? "5.1" : "11.4",
      language: "GR",
      payment_method_id: t.oxygenPaymentMethodId || undefined,
      description: "Πιστωτικό — ακύρωση κράτησης" + (bookingNumber ? " #" + bookingNumber : ""),
      branch_id: t.oxygenBranchId,
      correlated_invoice: wantsInvoice ? String(savedJobData.invoiceMark) : undefined,
      comments: savedJobData.invoiceMark
        ? "Αφορά αρχικό παραστατικό: " + savedJobData.invoiceMark
        : undefined,
      items: [{
        description: "Πιστωτικό — Υπηρεσίες μεταφοράς" + (bookingNumber ? " — Κράτηση #" + bookingNumber : ""),
        quantity: 1,
        unit_net_value: Math.round(netValue * 100) / 100,
        net_amount: Math.round(netValue * 100) / 100,
        vat_amount: Math.round(vatAmount * 100) / 100,
      }],
    };

    let resp, data;
    try {
      resp = await fetch(baseUrl + "/credit-notes", {
        method: "POST",
        headers: {
          "Authorization": "Bearer " + apiKey,
          "Accept": "application/json",
          "Content-Type": "application/json",
        },
        body: JSON.stringify(body),
      });
      data = await resp.json().catch(() => ({}));
    } catch (e) {
      console.error("oxygen credit note: network error for tenant", tenantId, e.message);
      return { ok: false, error: "network_error" };
    }

    if (!resp.ok) {
      console.error("oxygen credit note failed for tenant", tenantId, resp.status, data.message || data.errors || data);
      return { ok: false, error: "oxygen_http_" + resp.status };
    }

    console.log("oxygen credit note issued for tenant:", tenantId, "iview_code:", data.iview_code, "original:", savedJobData.invoiceMark);
    return { ok: true, mark: (data.mydata && data.mydata.mark) || data.iview_code || String(data.number || ""), iviewUrl: data.iview_url || null };
  } catch (e) {
    console.error("tryIssueOxygenCreditNote error:", e);
    return { ok: false, error: String(e) };
  }
}


// ═══════════════════════════════════════════════════════════════════════
// PDF Απόδειξης — απλό, καθαρό έγγραφο με στοιχεία επιχείρησης/πελάτη/
// διαδρομής/ποσών + τον αριθμό MARK (αν υπάρχει από το myDATA). ΔΕΝ είναι
// «επίσημο» φορολογικό έντυπο με τη νομική έννοια — είναι η ΟΠΤΙΚΗ απόδειξη
// που κρατάει ο πελάτης, ενώ η ίδια η νομική διαβίβαση έγινε ήδη στο myDATA
// (ή στον πάροχο). Επισυνάπτεται στο email επιβεβαίωσης.
// ═══════════════════════════════════════════════════════════════════════
async function buildReceiptPdfBase64({
  businessName, afm, doy, taxAddress,
  bookingNumber, issueDate, mark,
  clientName, from, to, whenStr,
  netValue, vatAmount, vatPercent, grossValue,
  // ── Νέα προαιρετικά πεδία ──
  isInvoice,        // true = Τιμολόγιο (2.1) — αλλάζει τίτλο + εμφανίζει στοιχεία λήπτη
  provider,         // "mydata" | "epsilon" | "oxygen" — footer ανά πάροχο
  custAfm,          // ΑΦΜ πελάτη (μόνο σε τιμολόγιο)
  custCompanyName,  // Επωνυμία πελάτη-επιχείρησης (μόνο σε τιμολόγιο)
  serviceWhenStr,   // Ημ/νία-ώρα ΕΞΥΠΗΡΕΤΗΣΗΣ (η issueDate είναι πια η έκδοση)
}) {
  const PDFDocument = require("pdfkit");
  const path = require("path");
  const fs = require("fs");
  // ⚠️ ΥΠΟΧΡΕΩΤΙΚΑ DejaVuSans — η ενσωματωμένη Helvetica του pdfkit ΔΕΝ
  // κωδικοποιεί ελληνικά (WinAnsi) και πετούσε exception → το PDF δεν
  // δημιουργούνταν ΠΟΤΕ και το email έφευγε χωρίς συνημμένο.
  const fontRegular = path.join(__dirname, "fonts", "DejaVuSans.ttf");
  const fontBold    = path.join(__dirname, "fonts", "DejaVuSans-Bold.ttf");
  if (!fs.existsSync(fontRegular) || !fs.existsSync(fontBold)) {
    throw new Error("Λείπουν τα fonts: functions/fonts/DejaVuSans(.ttf/-Bold.ttf)");
  }
  return await new Promise((resolve, reject) => {
    try {
      const doc = new PDFDocument({ size: "A5", margin: 36 });
      const chunks = [];
      doc.on("data", (c) => chunks.push(c));
      doc.on("end", () => resolve(Buffer.concat(chunks).toString("base64")));
      doc.on("error", reject);

      doc.fontSize(16).font(fontBold).text(businessName || "Taxi Transfers");
      doc.fontSize(9).font(fontRegular).fillColor("#555");
      const bizLine = [afm ? "ΑΦΜ: " + afm : null, doy ? "ΔΟΥ: " + doy : null].filter(Boolean).join("  ·  ");
      if (bizLine) doc.text(bizLine);
      if (taxAddress) doc.text(taxAddress);
      doc.moveDown(1);

      doc.fillColor("#000").fontSize(13).font(fontBold)
        .text(isInvoice ? "Τιμολόγιο Παροχής Υπηρεσιών" : "Απόδειξη Παροχής Υπηρεσιών");
      doc.moveDown(0.5);

      doc.fontSize(10).font(fontRegular);
      const row = (label, value) => {
        doc.font(fontRegular).fillColor("#555").text(label, { continued: true });
        doc.font(fontBold).fillColor("#000").text("  " + (value || "-"));
      };
      row("Αρ. Παραστατικού:", "#" + bookingNumber);
      row("Ημερομηνία έκδοσης:", issueDate);
      // ── Στοιχεία λήπτη: σε τιμολόγιο εμφανίζονται ΑΦΜ + επωνυμία ──
      if (isInvoice) {
        if (custCompanyName) row("Επωνυμία πελάτη:", custCompanyName);
        if (custAfm) row("ΑΦΜ πελάτη:", custAfm);
        if (clientName && clientName !== custCompanyName) row("Επιβάτης:", clientName);
      } else {
        row("Πελάτης:", clientName);
      }
      row("Διαδρομή:", from + " → " + to);
      row("Ώρα εξυπηρέτησης:", serviceWhenStr || whenStr);
      if (mark) row("Αρ. Παραστατικού (MARK):", mark);

      doc.moveDown(1);
      doc.moveTo(doc.x, doc.y).lineTo(doc.page.width - doc.page.margins.right, doc.y).strokeColor("#ccc").stroke();
      doc.moveDown(0.5);

      row("Καθαρή αξία:", netValue.toFixed(2) + " €");
      row("ΦΠΑ " + vatPercent + "%:", vatAmount.toFixed(2) + " €");
      doc.moveDown(0.3);
      doc.fontSize(13).font(fontBold).fillColor("#000")
        .text("Σύνολο: " + grossValue.toFixed(2) + " €");

      doc.moveDown(1.5);
      // ── Footer ανά πάροχο — μόνο το myDATA δίνει MARK απευθείας στην ΑΑΔΕ·
      // Epsilon/Oxygen είναι πιστοποιημένοι πάροχοι που διαβιβάζουν οι ίδιοι.
      const footerText =
        provider === "epsilon"
          ? "Το παραστατικό εκδόθηκε και διαβιβάστηκε ηλεκτρονικά στην ΑΑΔΕ μέσω του πιστοποιημένου παρόχου Epsilon Smart."
          : provider === "oxygen"
            ? "Το παραστατικό εκδόθηκε και διαβιβάστηκε ηλεκτρονικά στην ΑΑΔΕ μέσω του πιστοποιημένου παρόχου Oxygen."
            : "Η νόμιμη διαβίβαση του παραστατικού έγινε ηλεκτρονικά στο myDATA της ΑΑΔΕ.";
      doc.fontSize(8).fillColor("#999").font(fontRegular)
        .text(footerText, {
          width: doc.page.width - doc.page.margins.left - doc.page.margins.right,
        });

      doc.end();
    } catch (e) {
      reject(e);
    }
  });
}

function tenantSecretId(tenantId, field) {
  return `tenant-${tenantId}-${field}`;
}

async function getTenantVivaCredentials(tenantId) {
  const [clientId, clientSecret, merchantId, apiKey] = await Promise.all([
    readSecret(tenantSecretId(tenantId, "viva-client-id")),
    readSecret(tenantSecretId(tenantId, "viva-client-secret")),
    readSecret(tenantSecretId(tenantId, "viva-merchant-id")),
    readSecret(tenantSecretId(tenantId, "viva-api-key")),
  ]);
  return { clientId, clientSecret, merchantId, apiKey };
}

async function getTenantStripeCredentials(tenantId) {
  const [secretKey, publishableKey, webhookSecret] = await Promise.all([
    readSecret(tenantSecretId(tenantId, "stripe-secret-key")),
    readSecret(tenantSecretId(tenantId, "stripe-publishable-key")),
    readSecret(tenantSecretId(tenantId, "stripe-webhook-secret")),
  ]);
  return { secretKey, publishableKey, webhookSecret };
}

function resolvePaymentProvider(tenantCfg) {
  const p = tenantCfg && s(tenantCfg.paymentProvider);
  return p === "stripe" ? "stripe" : "viva";
}

let _stripeClientCache = new Map();
function getStripeClient(secretKey) {
  if (_stripeClientCache.has(secretKey)) return _stripeClientCache.get(secretKey);
  const Stripe = require("stripe");
  const client = new Stripe(secretKey, { apiVersion: "2024-06-20" });
  _stripeClientCache.set(secretKey, client);
  return client;
}

exports.createTenant = onCall(
  { region: "us-central1" },
  async (request) => {
    // ── Μόνο ο super-admin μπορεί να δημιουργήσει νέο tenant ──
    if (!request.auth || request.auth.token.email !== "techtacy@gmail.com") {
      throw new HttpsError("permission-denied", "Μόνο ο super-admin μπορεί να δημιουργήσει tenant.");
    }

    const d = request.data || {};
    const tenantId = s(d.tenantId);
    const businessName = s(d.businessName);
    const masterEmailInput = s(d.masterEmail);
    if (!tenantId || !businessName || !masterEmailInput) {
      throw new HttpsError("invalid-argument", "Χρειάζονται tenantId, businessName, masterEmail.");
    }
    if (tenantId === "default") {
      throw new HttpsError("invalid-argument", "Το 'default' είναι δεσμευμένο για τον δικό σου λογαριασμό.");
    }

    const db = getFirestore();
    const existing = await db.collection("tenants").doc(tenantId).get();
    if (existing.exists) {
      throw new HttpsError("already-exists", "Υπάρχει ήδη tenant με αυτό το tenantId.");
    }

    // ── Βρες το Firebase Auth uid του νέου master βάσει email ──
    // (πρέπει να έχει ήδη κάνει τουλάχιστον ένα login/signup στην εφαρμογή)
    let masterUid;
    try {
      const userRecord = await getAuth().getUserByEmail(masterEmailInput);
      masterUid = userRecord.uid;
    } catch (e) {
      throw new HttpsError("not-found",
        "Δεν βρέθηκε λογαριασμός με αυτό το email — ο πελάτης πρέπει πρώτα να κάνει login στην εφαρμογή.");
    }

    // ── 1) Δημιουργία tenants/{tenantId} — ΜΟΝΟ μη-ευαίσθητα στοιχεία ──
    // Τα Viva credentials (Client ID/Secret/Merchant ID/API Key) ΔΕΝ
    // αποθηκεύονται εδώ πια — πάνε στο Secret Manager (βλ. παρακάτω).
    await db.collection("tenants").doc(tenantId).set({
      businessName,
      masterEmail: masterEmailInput,
      masterUid,
      active: true, // ⚠️ αν γίνει false, ο tenant ΔΕΝ μπορεί να δεχτεί νέες κρατήσεις/πληρωμές
      vivaSourceCode:   s(d.vivaSourceCode)   || null, // ΔΕΝ είναι μυστικό, μπορεί να μείνει εδώ
      vivaSourceCodeEn: s(d.vivaSourceCodeEn) || null, // δεύτερο Source — success/failure URL στα Αγγλικά
      vivaDemo:         d.vivaDemo !== false, // default true (ασφαλές, demo)
      hasVivaCredentials: !!(s(d.vivaClientId) && s(d.vivaClientSecret)),
      createdAt: FieldValue.serverTimestamp(),
      createdBy: "techtacy@gmail.com",
    });

    // ── 1β) Viva credentials → Secret Manager (ΟΧΙ Firestore) ──
    // Δημιουργούμε δυναμικά ένα ξεχωριστό, κρυπτογραφημένο secret ανά
    // credential — ίδιο επίπεδο προστασίας με τα δικά σου (VIVA_CLIENT_ID
    // κλπ). Αν κάποιο πεδίο λείπει τώρα, μπορεί να προστεθεί αργότερα
    // (κάλεσε ξανά αυτή τη λειτουργία / πρόσθεσε νέο endpoint update).
    const vivaFields = {
      "viva-client-id":     s(d.vivaClientId),
      "viva-client-secret": s(d.vivaClientSecret),
      "viva-merchant-id":   s(d.vivaMerchantId),
      "viva-api-key":       s(d.vivaApiKey),
    };
    for (const [field, value] of Object.entries(vivaFields)) {
      if (value) {
        try {
          await upsertSecret(tenantSecretId(tenantId, field), value);
        } catch (e) {
          console.error("createTenant: αποτυχία αποθήκευσης secret", field, e.message);
          throw new HttpsError("internal",
            "Αποτυχία αποθήκευσης Viva credential στο Secret Manager: " + e.message +
            " (έλεγξε ότι το service account έχει τον ρόλο Secret Manager Admin)");
        }
      }
    }

    // ── 2) Ενημέρωση presence/{masterUid} — ΜΟΝΟ tenantId + isApproved.
    // Το admin/tenantOwner ΔΕΝ τα θέτουμε εδώ αυτόματα πια — τα ορίζεις εσύ
    // χειροκίνητα μέσω της σελίδας «Διαχειριστές» (masters_admin_page.dart),
    // ώστε να αποφασίζεις ρητά τι ρόλο/ομάδα θα έχει ο καθένας. Έτσι
    // αποφεύγουμε να δώσουμε πλήρη master δικαιώματα σε κάποιον πελάτη
    // κατά λάθος — γίνεται μόνο admin + tenantOwner, ρητά, από σένα.
    await db.collection("presence").doc(masterUid).set({
      tenantId,
      isApproved: true,
    }, { merge: true });

    console.log("createTenant: νέος tenant", tenantId, "για", masterEmailInput);
    return { ok: true, tenantId, masterUid };
  }
);

// ── setTenantActive: «κλείδωμα»/ενεργοποίηση tenant — μόνο ο super-admin ──
// Όταν active:false, ο tenant ΔΕΝ μπορεί πλέον να δεχτεί νέες κρατήσεις/
// πληρωμές μέσω της δικής του booking.html (ελέγχεται στο createVivaOrder
// στη Φάση 3, όταν το tenantId μπει πλήρως στη ροή). Οι ΥΠΑΡΧΟΥΣΕΣ δουλειές/
// δεδομένα του ΔΕΝ διαγράφονται — απλά «παγώνει» η δυνατότητα νέων.
exports.setTenantActive = onCall(
  { region: "us-central1" },
  async (request) => {
    if (!request.auth || request.auth.token.email !== "techtacy@gmail.com") {
      throw new HttpsError("permission-denied", "Μόνο ο super-admin μπορεί να το αλλάξει.");
    }
    const d = request.data || {};
    const tenantId = s(d.tenantId);
    if (!tenantId || tenantId === "default") {
      throw new HttpsError("invalid-argument", "Μη έγκυρο tenantId.");
    }
    const db = getFirestore();
    const ref = db.collection("tenants").doc(tenantId);
    const doc = await ref.get();
    if (!doc.exists) throw new HttpsError("not-found", "Δεν βρέθηκε αυτός ο tenant.");
    await ref.update({ active: d.active === true });
    return { ok: true, tenantId, active: d.active === true };
  }
);

// ── listTenants: λίστα όλων των tenants — μόνο ο super-admin ──
// ⚠️ Το hasVivaCredentials ΔΕΝ βασίζεται πια μόνο στο flag του Firestore
// (που μπορεί να είναι μπαγιάτικο αν ο tenant έβαλε τα credentials μόνος
// του από παλιότερη έκδοση): ελέγχουμε ΖΩΝΤΑΝΑ το Secret Manager αν
// υπάρχουν viva-client-id + viva-client-secret του tenant, και
// αυτο-διορθώνουμε το flag στο Firestore ώστε να συμφωνεί.
// Επιστρέφουμε επίσης resendConnected (υπάρχει RESEND_API_KEY;) για τη
// γραμμή «Resend email συνδεδεμένο» στην κάρτα του tenant.
exports.listTenants = onCall(
  { region: "us-central1", secrets: [RESEND_API_KEY] },
  async (request) => {
    if (!request.auth || request.auth.token.email !== "techtacy@gmail.com") {
      throw new HttpsError("permission-denied", "Μόνο ο super-admin μπορεί να τα δει.");
    }
    const db = getFirestore();
    const snap = await db.collection("tenants").orderBy("createdAt", "desc").get();

    let resendConnected = false;
    try { resendConnected = !!(RESEND_API_KEY.value() || "").trim(); } catch (e) { /* όχι δεμένο */ }

    const tenants = await Promise.all(snap.docs.map(async (doc) => {
      const t = doc.data();

      // Ζωντανός έλεγχος Secret Manager (με 10λεπτο cache του readSecret —
      // δεν χτυπάμε το API σε κάθε refresh).
      let vivaSecretsExist = false;
      let stripeSecretsExist = false;
      let receiptSecretsExist = false;
      let hasOwnResendKey = false;
      const invoiceProvider = ["mydata", "epsilon", "oxygen"].includes(s(t.invoiceProvider))
        ? s(t.invoiceProvider) : null;
      try {
        const [cid, csec, ssk, invKey, epsPass, mydataKey, ownResend] = await Promise.all([
          readSecret(tenantSecretId(doc.id, "viva-client-id")),
          readSecret(tenantSecretId(doc.id, "viva-client-secret")),
          readSecret(tenantSecretId(doc.id, "stripe-secret-key")),
          readSecret(tenantSecretId(doc.id, "invoice-api-key")),
          readSecret(tenantSecretId(doc.id, "epsilon-password")),
          readSecret(tenantSecretId(doc.id, "mydata-subscription-key")),
          readSecret(tenantSecretId(doc.id, "resend-api-key")),
        ]);
        vivaSecretsExist   = !!(cid && csec);
        stripeSecretsExist = !!ssk;
        hasOwnResendKey    = !!ownResend;
        // Κλειδιά αποδείξεων ανά πάροχο:
        //   myDATA  → mydata-subscription-key
        //   Epsilon → invoice-api-key + epsilon-password
        //   Oxygen  → invoice-api-key
        if (invoiceProvider === "mydata")  receiptSecretsExist = !!mydataKey;
        if (invoiceProvider === "epsilon") receiptSecretsExist = !!(invKey && epsPass);
        if (invoiceProvider === "oxygen")  receiptSecretsExist = !!invKey;
      } catch (e) { /* αν αποτύχει, πέφτουμε στο flag */ }

      const hasViva = vivaSecretsExist || t.hasVivaCredentials === true;

      // Αυτο-διόρθωση μπαγιάτικου flag (secrets υπάρχουν, flag false).
      if (vivaSecretsExist && t.hasVivaCredentials !== true) {
        db.collection("tenants").doc(doc.id)
          .update({ hasVivaCredentials: true }).catch(() => {});
      }

      return {
        tenantId: doc.id,
        businessName: t.businessName || "",
        masterEmail: t.masterEmail || "",
        active: t.active !== false,
        vivaDemo: t.vivaDemo !== false,
        hasVivaCredentials: hasViva,
        mapEnabled: t.mapEnabled !== false,
        placesEnabled: t.placesEnabled !== false,
        hasMapsApiKey: !!(t.mapsApiKey && t.mapsApiKey.trim()),
        resendConnected,
        hasStripeCredentials: stripeSecretsExist,
        paymentProvider: s(t.paymentProvider) === "stripe" ? "stripe" : "viva",
        invoiceEnabled: t.invoiceEnabled === true,
        invoiceProvider: invoiceProvider,
        hasReceiptCredentials: receiptSecretsExist,
        hasOwnResendKey: hasOwnResendKey,
      };
    }));
    return { ok: true, tenants };
  }
);

// ── updateTenantOwnerInfo: διόρθωση businessName/masterEmail ενός tenant —
// ΜΟΝΟ ο super-admin (π.χ. αν έγραψε λάθος το email του πελάτη στη «Νέα
// Online Φόρμα»). Αν αλλάξει το email, ξαναβρίσκουμε το masterUid από το
// Firebase Auth (ο πελάτης πρέπει να έχει ήδη κάνει login με το ΝΕΟ email).
// ── repairTenantOwnerAccess: «επισκευή» με ένα κλικ — ξαναβάζει στο presence
// του master αυτού του tenant ΟΛΑ τα flags που χρειάζεται για να δουλέψει
// ξανά κανονικά (admin/tenantOwner/isApproved/tenantId/webEnabled). Χρήσιμο
// όποτε κάποιος λογαριασμός «σπάει» (π.χ. permission-denied στη δημιουργία
// πελατών) — αντί να ψάχνεις χειροκίνητα στη λίστα Διαχειριστές.
exports.repairTenantOwnerAccess = onCall(
  { region: "us-central1" },
  async (request) => {
    if (!request.auth || request.auth.token.email !== "techtacy@gmail.com") {
      throw new HttpsError("permission-denied", "Μόνο ο super-admin μπορεί να το κάνει.");
    }
    const d = request.data || {};
    const tenantId = s(d.tenantId);
    if (!tenantId || tenantId === "default") {
      throw new HttpsError("invalid-argument", "Μη έγκυρο tenantId.");
    }
    const db = getFirestore();
    const tenantDoc = await db.collection("tenants").doc(tenantId).get();
    if (!tenantDoc.exists) throw new HttpsError("not-found", "Δεν βρέθηκε αυτός ο tenant.");

    // ── Προεπιλογή: ο καταγεγραμμένος master του tenant. Αν δώσεις ΑΛΛΟ
    // email (π.χ. κάποιος υπάλληλος/admin αυτού του tenant που ΔΕΝ είναι ο
    // ίδιος ο ιδιοκτήτης), διορθώνει ΕΚΕΙΝΟΝ αντί για τον master.
    const targetEmail = s(d.email);
    let targetUid;
    if (targetEmail) {
      try {
        const userRecord = await getAuth().getUserByEmail(targetEmail);
        targetUid = userRecord.uid;
      } catch (e) {
        throw new HttpsError("not-found",
          "Δεν βρέθηκε λογαριασμός με αυτό το email — πρέπει να έχει ήδη κάνει login.");
      }
    } else {
      targetUid = tenantDoc.data().masterUid;
      if (!targetUid) {
        throw new HttpsError("failed-precondition",
          "Αυτός ο tenant δεν έχει καταγεγραμμένο masterUid — δώσε συγκεκριμένο email.");
      }
    }

    await db.collection("presence").doc(targetUid).set({
      tenantId,
      isApproved: true,
      admin: true,
      tenantOwner: true,
      webEnabled: true,
    }, { merge: true });

    // Διαγνωστικό: ξαναδιάβασε ό,τι ΠΡΑΓΜΑΤΙΚΑ αποθηκεύτηκε, ώστε να
    // επιβεβαιώνεται στο UI ότι τα flags μπήκαν σωστά.
    const after = (await db.collection("presence").doc(targetUid).get()).data() || {};
    return {
      ok: true,
      tenantId,
      targetUid,
      targetEmail: targetEmail || null,
      saved: {
        admin: after.admin === true,
        tenantOwner: after.tenantOwner === true,
        isApproved: after.isApproved === true,
        webEnabled: after.webEnabled === true,
        tenantId: after.tenantId || null,
      },
    };
  }
);

exports.updateTenantOwnerInfo = onCall(
  { region: "us-central1" },
  async (request) => {
    if (!request.auth || request.auth.token.email !== "techtacy@gmail.com") {
      throw new HttpsError("permission-denied", "Μόνο ο super-admin μπορεί να το αλλάξει.");
    }
    const d = request.data || {};
    const tenantId = s(d.tenantId);
    if (!tenantId || tenantId === "default") {
      throw new HttpsError("invalid-argument", "Μη έγκυρο tenantId.");
    }
    const db = getFirestore();
    const ref = db.collection("tenants").doc(tenantId);
    const doc = await ref.get();
    if (!doc.exists) throw new HttpsError("not-found", "Δεν βρέθηκε αυτός ο tenant.");

    const updates = {};
    if (s(d.businessName)) updates.businessName = s(d.businessName);

    const newEmail = s(d.masterEmail);
    if (newEmail && newEmail !== doc.data().masterEmail) {
      let userRecord;
      try {
        userRecord = await getAuth().getUserByEmail(newEmail);
      } catch (e) {
        throw new HttpsError("not-found",
          "Δεν βρέθηκε λογαριασμός με το νέο email — ο πελάτης πρέπει πρώτα να κάνει login με αυτό.");
      }
      const oldUid = doc.data().masterUid;
      // ⚠️ ΚΡΙΣΙΜΟ: το νέο uid πρέπει να πάρει ΤΑ ΙΔΙΑ δικαιώματα (admin/
      // tenantOwner/κ.λπ.) που είχε το παλιό — αλλιώς ο πελάτης χάνει
      // πρόσβαση (π.χ. permission-denied στη δημιουργία πελατών) γιατί το
      // Firestore isAdmin() ελέγχει το presence.admin του ΝΕΟΥ uid, που θα
      // ήταν κενό/false αν δεν το μεταφέρουμε ρητά εδώ.
      let carryOver = {};
      if (oldUid && oldUid !== userRecord.uid) {
        const oldPresDoc = await db.collection("presence").doc(oldUid).get();
        const oldPres = oldPresDoc.data() || {};
        carryOver = {
          admin: oldPres.admin === true,
          tenantOwner: oldPres.tenantOwner === true,
          webEnabled: oldPres.webEnabled === true,
          icsExportEnabled: oldPres.icsExportEnabled === true,
          calendarEnabled: oldPres.calendarEnabled === true,
        };
        await db.collection("presence").doc(oldUid).set({ tenantId: null }, { merge: true });
      }
      await db.collection("presence").doc(userRecord.uid).set(
        { tenantId, isApproved: true, ...carryOver }, { merge: true });
      updates.masterEmail = newEmail;
      updates.masterUid = userRecord.uid;
    }

    if (Object.keys(updates).length) await ref.update(updates);
    return { ok: true, tenantId };
  }
);

// ── renameTenantEformId: αλλάζει το ίδιο το EformID (π.χ. διόρθωση typo
// αμέσως μετά τη δημιουργία). ΠΡΟΣΟΧΗ: το tenantId είναι το ίδιο το
// Firestore document ID, οπότε «μετακομίζει» το tenants/{tenantId} doc σε
// νέο ID, μεταφέρει τα Viva secrets, και ενημερώνει το presence του master.
// ΔΕΝ αγγίζει άλλα collections (jobs/saved_jobs/clients/sources/billing_tx/
// groups) — γι' αυτό μπλοκάρεται αν ο tenant έχει ήδη πραγματικά δεδομένα
// εκεί. Ασφαλές μόνο λίγο μετά τη δημιουργία, πριν μπει σε χρήση.
exports.renameTenantEformId = onCall(
  { region: "us-central1" },
  async (request) => {
    if (!request.auth || request.auth.token.email !== "techtacy@gmail.com") {
      throw new HttpsError("permission-denied", "Μόνο ο super-admin μπορεί να το αλλάξει.");
    }
    const d = request.data || {};
    const oldId = s(d.tenantId);
    const newId = s(d.newTenantId);
    if (!oldId || oldId === "default") throw new HttpsError("invalid-argument", "Μη έγκυρο τρέχον tenantId.");
    if (!newId || !RegExp("^[a-z0-9_]+$").test(newId)) {
      throw new HttpsError("invalid-argument", "Το νέο EformID: μόνο a-z, 0-9, _.");
    }
    if (newId === "default") throw new HttpsError("invalid-argument", "\"default\" είναι δεσμευμένο.");
    if (newId === oldId) return { ok: true, tenantId: newId };

    const db = getFirestore();
    const oldRef = db.collection("tenants").doc(oldId);
    const oldDoc = await oldRef.get();
    if (!oldDoc.exists) throw new HttpsError("not-found", "Δεν βρέθηκε ο τρέχων tenant.");
    const newRef = db.collection("tenants").doc(newId);
    if ((await newRef.get()).exists) {
      throw new HttpsError("already-exists", "Υπάρχει ήδη tenant με αυτό το EformID.");
    }

    // ── Ασφάλεια: μπλοκάρισμα αν υπάρχουν ήδη πραγματικά δεδομένα με το
    // παλιό tenantId — η μετονομασία δεν τα μεταφέρει (job/πελάτες/χρεώσεις).
    if (!d.force) {
      const checks = await Promise.all(
        ["jobs", "saved_jobs", "clients", "sources", "billing_tx"].map((col) =>
          db.collection(col).where("tenantId", "==", oldId).limit(1).get())
      );
      if (checks.some((snap) => !snap.empty)) {
        throw new HttpsError("failed-precondition",
          "Αυτός ο tenant έχει ήδη δεδομένα (δουλειές/πελάτες/χρεώσεις) — η αλλαγή EformID " +
          "δεν τα μεταφέρει αυτόματα. Ασφαλές μόνο αμέσως μετά τη δημιουργία, πριν μπει σε χρήση.");
      }
    }

    // ── 1) Αντιγραφή tenants/{oldId} → tenants/{newId}, μετά διαγραφή του παλιού.
    await newRef.set(oldDoc.data());
    await oldRef.delete();

    // ── 2) Μεταφορά Viva secrets (Client ID/Secret/Merchant ID/API Key).
    for (const field of ["viva-client-id", "viva-client-secret", "viva-merchant-id", "viva-api-key"]) {
      const value = await readSecret(tenantSecretId(oldId, field));
      if (value) {
        try { await upsertSecret(tenantSecretId(newId, field), value); }
        catch (e) { console.error("renameTenantEformId: αποτυχία μεταφοράς secret", field, e.message); }
      }
    }

    // ── 3) presence ΟΛΩΝ όσων ανήκουν σε αυτόν τον tenant (όχι μόνο ο
    // master) — αλλιώς τυχόν άλλοι admins/οδηγοί του ίδιου tenant μένουν
    // με το ΠΑΛΙΟ tenantId και «χάνονται» από φίλτρα που βασίζονται σε αυτό.
    const presSnap = await db.collection("presence").where("tenantId", "==", oldId).get();
    const batch = db.batch();
    presSnap.docs.forEach((d2) => batch.update(d2.ref, { tenantId: newId }));
    if (!presSnap.empty) await batch.commit();

    console.log("renameTenantEformId:", oldId, "→", newId);
    return { ok: true, tenantId: newId };
  }
);

// ═══════════════════════════════════════════════════════════════════════════
//  MULTI-TENANT — Φάση 2 πρώτο βήμα: εφάπαξ «γέμισμα» tenantId:'default'
//
//  ΚΡΙΣΙΜΟ: το Firestore απορρίπτει ΟΛΟΚΛΗΡΟ ένα query (π.χ. «όλες οι ζώνες
//  τιμών») αν έστω ΕΝΑ doc μέσα στο collection αποτυγχάνει τους κανόνες για
//  τον τρέχοντα χρήστη — ΑΚΟΜΑ ΚΙ ΑΝ ο client δεν το ζήτησε ρητά. Άρα μόλις
//  υπάρξει 2ος tenant με δικά του docs στο ΙΔΙΟ collection (π.χ. pricing_zones),
//  τα δικά σου (χωρίς tenantId) queries θα σταματήσουν να δουλεύουν, ΕΚΤΟΣ αν
//  κάθε doc έχει ήδη ρητά tenantId:'default' ώστε το query να μπορεί να
//  φιλτράρει σωστά με .where('tenantId','==','default').
//
//  Αυτή η function γράφει tenantId:'default' σε ΚΑΘΕ doc που δεν το έχει
//  ήδη, στα σχετικά collections. ΑΣΦΑΛΕΣ να τρέξει πολλές φορές (idempotent).
//  Τρέχεις τη ΜΙΑ φορά, ΤΩΡΑ, πριν δημιουργήσεις τον 2ο πραγματικό tenant.
// ═══════════════════════════════════════════════════════════════════════════

// ── Διόρθωση ownerName σε ΥΠΑΡΧΟΥΣΕΣ saved_jobs (one-time). Ξαναγράφει το
// σωστό όνομα (businessName tenant ή displayName+lastName master) σε όσες
// δουλειές έχουν ownerName κενό ή "Master".
exports.backfillOwnerNames = onCall(
  { region: "us-central1", timeoutSeconds: 300 },
  async (request) => {
    if (!request.auth || request.auth.token.email !== "techtacy@gmail.com") {
      throw new HttpsError("permission-denied", "Μόνο ο super-admin.");
    }
    const db = getFirestore();
    const snap = await db.collection("saved_jobs").get();
    // Cache ανά ownerUid ώστε να μη διαβάζουμε ξανά-ξανά το ίδιο presence/tenant.
    const nameCache = {};
    let updated = 0, batch = db.batch(), inBatch = 0;
    for (const doc of snap.docs) {
      const d = doc.data();
      const cur = (d.ownerName || "").trim();
      if (cur && cur !== "Master") continue; // ήδη σωστό
      const uid = d.ownerUid;
      if (!uid) continue;
      const cacheKey = uid + "|" + (d.tenantId || "default");
      if (nameCache[cacheKey] == null) {
        const pDoc = await db.collection("presence").doc(uid).get();
        nameCache[cacheKey] = await resolveOwnerDisplayName(
          d.tenantId, pDoc.exists ? pDoc.data() : null);
      }
      const newName = nameCache[cacheKey];
      if (newName && newName !== cur) {
        batch.update(doc.ref, { ownerName: newName });
        updated++; inBatch++;
        if (inBatch >= 450) { await batch.commit(); batch = db.batch(); inBatch = 0; }
      }
    }
    if (inBatch > 0) await batch.commit();
    return { ok: true, total: snap.size, updated };
  }
);

exports.backfillDefaultTenantId = onCall(
  { region: "us-central1", timeoutSeconds: 300 },
  async (request) => {
    if (!request.auth || request.auth.token.email !== "techtacy@gmail.com") {
      throw new HttpsError("permission-denied", "Μόνο ο super-admin.");
    }

    const db = getFirestore();
    const collections = [
      "jobs", "saved_jobs", "job_batches", "billing_tx", "settlements",
      "clients", "sources", "pricing_zones", "pricing_routes", "presence",
    ];

    const results = {};
    for (const colName of collections) {
      const snap = await db.collection(colName).get();
      let updated = 0;
      // Batched writes (μέγιστο 500 ανά batch, όριο Firestore)
      let batch = db.batch();
      let inBatch = 0;
      for (const doc of snap.docs) {
        if (doc.data().tenantId == null) {
          batch.update(doc.ref, { tenantId: "default" });
          updated++;
          inBatch++;
          if (inBatch >= 450) {
            await batch.commit();
            batch = db.batch();
            inBatch = 0;
          }
        }
      }
      if (inBatch > 0) await batch.commit();
      results[colName] = { total: snap.size, updated };
      console.log("backfillDefaultTenantId:", colName, results[colName]);
    }

    return { ok: true, results };
  }
);

// ═══════════════════════════════════════════════════════════════════════════
//  fixCapitalization — εφάπαξ διόρθωση Κεφαλαίο/πεζά (Όνομα/Επίθετο/Μοντέλο)
//  για ΗΔΗ εγγεγραμμένους χρήστες. Μόνο ο super-admin το καλεί. Ασφαλές να
//  τρέξει πολλές φορές (idempotent).
// ═══════════════════════════════════════════════════════════════════════════

function properCaseJS(input) {
  const trimmed = String(input || "").trim();
  if (!trimmed) return trimmed;
  return trimmed
    .split(/\s+/)
    .map((w) => {
      if (!w) return w;
      const lower = w.toLowerCase();
      return lower.charAt(0).toUpperCase() + lower.slice(1);
    })
    .join(" ");
}

exports.fixCapitalization = onCall(
  { region: "us-central1", timeoutSeconds: 300 },
  async (request) => {
    if (!request.auth || request.auth.token.email !== "techtacy@gmail.com") {
      throw new HttpsError("permission-denied", "Μόνο ο super-admin.");
    }

    const db = getFirestore();
    const snap = await db.collection("presence").get();
    let updated = 0;
    let batch = db.batch();
    let inBatch = 0;

    for (const doc of snap.docs) {
      const d = doc.data();
      const fixedName  = properCaseJS(d.displayName);
      const fixedLast  = properCaseJS(d.lastName);
      const fixedModel = properCaseJS(d.vehicleModel);
      const changes = {};
      if (d.displayName && d.displayName !== fixedName) changes.displayName = fixedName;
      if (d.lastName && d.lastName !== fixedLast) changes.lastName = fixedLast;
      if (d.vehicleModel && d.vehicleModel !== fixedModel) changes.vehicleModel = fixedModel;
      if (Object.keys(changes).length > 0) {
        batch.update(doc.ref, changes);
        updated++;
        inBatch++;
        if (inBatch >= 450) {
          await batch.commit();
          batch = db.batch();
          inBatch = 0;
        }
      }
    }
    if (inBatch > 0) await batch.commit();

    console.log("fixCapitalization:", { total: snap.size, updated });
    return { ok: true, total: snap.size, updated };
  }
);

// ═══════════════════════════════════════════════════════════════════════════
//  listClients — δημόσιο endpoint (booking.html/booking2.html): «Συχνές
//  διαδρομές». Επιστρέφει τη λίστα γνωστών πελατών (clients) ενός tenant,
//  ΧΩΡΙΣ ευαίσθητα εσωτερικά στοιχεία (τιμές/προμήθειες) — μόνο ονόματα και
//  συντεταγμένες, ώστε ο πελάτης της φόρμας να μπορεί να επιλέξει γρήγορα
//  «AIRSTAY» κλπ αντί να πληκτρολογήσει τη διεύθυνση.
// ═══════════════════════════════════════════════════════════════════════════

exports.listClients = onRequest(
  { region: "us-central1", cors: BOOKING_ALLOWED_ORIGINS, memory: "256MiB" },
  async (req, res) => {
    try {
      const tenantId = s(req.method === "POST" ? (req.body || {}).tenantId : req.query.tenantId) || "default";
      const db = getFirestore();

      // ── «Μάτι» (masterHideOtherClients) — αν ο master αυτού του tenant
      // έχει κλείσει το μάτι στη σελίδα Πελάτες, η δημόσια φόρμα δείχνει
      // ΜΟΝΟ τους δικούς του πελάτες (createdBy == masterUid). Αν είναι
      // ανοιχτό (προεπιλογή), δείχνει ΟΛΟΥΣ τους πελάτες του tenant, όπως πριν.
      let restrictToUid = null;
      try {
        const masterUid = await findMasterUid(tenantId);
        if (masterUid) {
          const mPres = await db.collection("presence").doc(masterUid).get();
          if (mPres.exists && mPres.data().masterHideOtherClients === true) {
            restrictToUid = masterUid;
          }
        }
      } catch (e) {
        console.error("listClients: hideOthers check failed:", e.message || e);
      }

      // ── Default tenant: φέρνουμε ΟΛΟΥΣ και φιλτράρουμε στον κώδικα, ώστε
      // να πιάνονται και ΠΑΛΙΟΙ πελάτες ΧΩΡΙΣ πεδίο tenantId (φτιαγμένοι πριν
      // το multi-tenant) — το where("tenantId","==","default") τους ΕΧΑΝΕ και
      // δεν εμφανίζονταν ποτέ στη φόρμα, ενώ στην εφαρμογή φαίνονταν κανονικά.
      // Ίδια λογική με το findClientRouteMatch (τιμολόγηση διαδρομών πελατών).
      let snapDocs;
      let _totalDocs = 0;
      let _tenantIdSamples = {};
      if (tenantId === "default") {
        const snapAll = await db.collection("clients").get();
        _totalDocs = snapAll.size;
        snapAll.docs.forEach((doc) => {
          const t = doc.data().tenantId;
          const key = t == null ? "(κανένα)" : (t === "" ? "(κενό)" : String(t));
          _tenantIdSamples[key] = (_tenantIdSamples[key] || 0) + 1;
        });
        // Ο master (default φόρμα) βλέπει τους πελάτες ΟΛΩΝ των admins του,
        // ανεξαρτήτως eform/tenantId του πελάτη (π.χ. "seretis_form") — ΙΔΙΑ
        // λογική με το μάτι στην εφαρμογή ΚΑΙ με την τιμολόγηση
        // (findClientRouteMatch: για default φέρνει όλους). Το κλειστό μάτι
        // εξακολουθεί να περιορίζει σε createdBy == master πιο κάτω.
        snapDocs = snapAll.docs;
      } else {
        const snapT = await db.collection("clients").where("tenantId", "==", tenantId).get();
        _totalDocs = snapT.size;
        snapDocs = snapT.docs;
      }
      const _afterTenant = snapDocs.length;
      if (restrictToUid) {
        snapDocs = snapDocs.filter((doc) => doc.data().createdBy === restrictToUid);
      }
      // ── 🌐 Διακοπτάκι ανά πελάτη (showInOnlineForm): αν false, ο πελάτης
      // ΔΕΝ εμφανίζεται στις προτάσεις Από/Προς των online φορμών (booking/
      // booking2/index). Στη φόρμα δουλειάς της ΕΦΑΡΜΟΓΗΣ φαίνεται πάντα —
      // εκείνη δεν περνάει από εδώ. Default (πεδίο απόν): φαίνεται.
      const _afterOwner = snapDocs.length;
      snapDocs = snapDocs.filter((doc) => doc.data().showInOnlineForm !== false);
      const _afterVisibility = snapDocs.length;

      const clients = snapDocs.map((doc) => {
        const d = doc.data();
        const routes = Array.isArray(d.routes)
          ? d.routes
              .filter((r) => r && r.toName)
              .map((r) => ({
                toName: r.toName,
                toLat: r.toLat != null ? r.toLat : null,
                toLng: r.toLng != null ? r.toLng : null,
              }))
          : [];
        return {
          id: doc.id,
          name: d.name || "",
          fromName: d.fromName || "",
          fromLat: d.fromLat != null ? d.fromLat : null,
          fromLng: d.fromLng != null ? d.fromLng : null,
          hasShuttleBus: d.hasShuttleBus === true,
          routes,
        };
      }).filter((c) => c.name && c.fromLat != null && c.fromLng != null);

      // ── ΠΡΟΣΩΡΙΝΟ ΔΙΑΓΝΩΣΤΙΚΟ: ?debug=1 δείχνει πόσοι πελάτες επιβιώνουν
      // σε κάθε φίλτρο, ώστε να εντοπίζεται ΑΜΕΣΩΣ πού «χάνονται». Δεν
      // επιστρέφει προσωπικά δεδομένα — μόνο πλήθη και ονόματα όσων κόπηκαν
      // από το φίλτρο συντεταγμένων.
      if (s(req.query.debug) === "1") {
        const noCoords = snapDocs
          .map((doc) => doc.data())
          .filter((d) => !(d.name && d.fromLat != null && d.fromLng != null))
          .map((d) => ({ name: d.name || "(χωρίς όνομα)", fromLat: d.fromLat ?? null, fromLng: d.fromLng ?? null }));
        return res.json({
          ok: true,
          debug: {
            συνολικάDocs: _totalDocs,
            τιμέςTenantId: _tenantIdSamples,
            μετάΦίλτροTenant: _afterTenant,
            restrictToUid: restrictToUid || "(κανένα — μάτι ανοιχτό)",
            μετάΦίλτροΙδιοκτήτη: _afterOwner,
            μετάΦίλτροΟρατότητας: _afterVisibility,
            τελικοίΜεΣυντεταγμένες: clients.length,
            κομμένοιΧωρίςΣυντεταγμένες: noCoords,
          },
        });
      }

      // ── placesEnabled: ΠΑΛΙΟΣ διακόπτης, ελέγχεται από τον MASTER στο
      // tenants/{id} doc — αν κλειστός, ΔΕΝ αρχικοποιείται καθόλου το widget
      // Google Places Autocomplete (εξοικονόμηση κόστους), αλλά ΠΑΡΑΜΕΝΕΙ
      // ελεύθερη πληκτρολόγηση/πελάτες όπως πριν — ΚΑΜΙΑ σχέση με τα δύο
      // παρακάτω, που είναι ΔΙΚΑ ΤΟΥ tenant, μέσα στους Δυναμικούς Τύπους.
      let placesEnabled = true;
      try {
        const tDoc = await db.collection("tenants").doc(tenantId).get();
        if (tDoc.exists && tDoc.data().placesEnabled === false) placesEnabled = false;
      } catch (e) { /* προεπιλογή true αν αποτύχει */ }

      let clientsOnlyBooking = false, clientsCatalogMode = false;
      try {
        const { cfg } = await getPricingData(tenantId);
        clientsOnlyBooking = cfg.clientsOnlyBooking === true;
        clientsCatalogMode = cfg.clientsCatalogMode === true;
      } catch (e) { /* προεπιλογή false αν αποτύχει */ }

      return res.status(200).json({ ok: true, clients, placesEnabled, clientsOnlyBooking, clientsCatalogMode });
    } catch (e) {
      console.error("listClients error:", e);
      return res.status(500).json({ ok: false, error: "server_error" });
    }
  }
);

// ═══════════════════════════════════════════════════════════════════════════
//  Viva credentials — αυτοεξυπηρέτηση από τον ίδιο τον tenant
//
//  updateTenantVivaCredentials: μπορεί να το καλέσει είτε ο super-admin
//  (για ΟΠΟΙΟΝΔΗΠΟΤΕ tenant), είτε ο ίδιος ο tenant-owner (μόνο για τον
//  ΔΙΚΟ ΤΟΥ tenant — ελέγχεται μέσω presence.tenantId + presence.tenantOwner).
// ═══════════════════════════════════════════════════════════════════════════

// ── updateTenantResendKey: ο tenant βάζει το ΔΙΚΟ ΤΟΥ Resend API key ώστε τα
// email επιβεβαίωσης να στέλνονται μέσω του δικού του λογαριασμού Resend
// (και άρα από το δικό του verified domain) αντί για το κοινό μας. Μόλις το
// βάλει, ενεργοποιείται αυτόματα το emailsEnabled (αν ο master το είχε
// κλείσει προηγουμένως, ξανανοίγει — έχει πλέον τον δικό του μηχανισμό).
// ── updateTenantEmailsEnabled: ο master ανοιγοκλείνει τα αυτόματα email
// επιβεβαίωσης πελάτη για ΣΥΓΚΕΚΡΙΜΕΝΟ tenant (σελίδα Διαχειριστές). Αν ο
// tenant βάλει μετά ΔΙΚΟ ΤΟΥ Resend key, το updateTenantResendKey το
// ξανανοίγει αυτόματα (βλ. εκεί) — ο master δεν χρειάζεται να το ξανακάνει.
exports.updateTenantEmailsEnabled = onCall(
  { region: "us-central1" },
  async (request) => {
    if (!request.auth || request.auth.token.email !== "techtacy@gmail.com") {
      throw new HttpsError("permission-denied", "Μόνο ο master μπορεί να το αλλάξει.");
    }
    const d = request.data || {};
    const tenantId = s(d.tenantId);
    if (!tenantId) throw new HttpsError("invalid-argument", "Μη έγκυρο tenantId.");
    const db = getFirestore();
    const tenantRef = db.collection("tenants").doc(tenantId);
    await tenantRef.set({ emailsEnabled: d.enabled !== false }, { merge: true });
    return { ok: true, emailsEnabled: d.enabled !== false };
  }
);

// ── updateTenantReceiptInfo: φορολογικά στοιχεία + πάροχος ηλεκτρονικής
// τιμολόγησης (tab «Απόδειξη»). Επιτρέπεται και για "default" (ο master
// μπορεί επίσης να θέλει αυτόματο παραστατικό για τις δικές του κρατήσεις).
exports.updateTenantReceiptInfo = onCall(
  { region: "us-central1", secrets: [] },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "Χρειάζεται σύνδεση.");
    const d = request.data || {};
    const tenantId = s(d.tenantId) || "default";

    const isSuperAdmin = request.auth.token.email === "techtacy@gmail.com";
    if (tenantId === "default") {
      if (!isSuperAdmin) throw new HttpsError("permission-denied", "Μόνο ο master μπορεί να το αλλάξει.");
    } else if (!isSuperAdmin) {
      const db0 = getFirestore();
      const presDoc = await db0.collection("presence").doc(request.auth.uid).get();
      const pres = presDoc.data() || {};
      if (!(pres.tenantOwner === true && pres.tenantId === tenantId)) {
        throw new HttpsError("permission-denied",
          "Μόνο ο super-admin ή ο tenant-owner αυτού του tenant μπορεί να το αλλάξει.");
      }
    }

    const db = getFirestore();
    const tenantRef = db.collection("tenants").doc(tenantId);
    if (tenantId !== "default" && !(await tenantRef.get()).exists) {
      throw new HttpsError("not-found", "Άγνωστο tenant.");
    }

    const updates = {};
    if (d.afm != null) updates.afm = s(d.afm) || null;
    if (d.doy != null) updates.doy = s(d.doy) || null;
    if (d.taxAddress != null) updates.taxAddress = s(d.taxAddress) || null;
    if (d.kad != null) updates.kad = s(d.kad) || null;
    if (d.invoiceProvider != null) {
      const p = s(d.invoiceProvider);
      updates.invoiceProvider = ["none", "epsilon", "mydata", "oxygen"].includes(p) ? p : "none";
    }
    if (d.mydataUsername != null) updates.mydataUsername = s(d.mydataUsername) || null;
    if (d.epsilonEmail != null) updates.epsilonEmail = s(d.epsilonEmail) || null;
    if (d.epsilonItemCode != null) updates.epsilonItemCode = s(d.epsilonItemCode) || null;
    if (d.invoiceEnabled != null) updates.invoiceEnabled = d.invoiceEnabled === true;
    if (d.invoiceSeries != null) updates.invoiceSeries = s(d.invoiceSeries) || null;
    if (d.mydataInvoiceType != null) updates.mydataInvoiceType = s(d.mydataInvoiceType) || "11.2";
    if (d.mydataVatCategory != null) updates.mydataVatCategory = s(d.mydataVatCategory) || "2";
    if (d.mydataDemo != null) updates.mydataDemo = d.mydataDemo !== false;
    if (d.oxygenBranchId != null) updates.oxygenBranchId = s(d.oxygenBranchId) || null;
    if (d.oxygenNumberingSequenceId != null) updates.oxygenNumberingSequenceId = s(d.oxygenNumberingSequenceId) || null;
    // ── Ξεχωριστή σειρά αρίθμησης ΓΙΑ ΠΙΣΤΩΤΙΚΑ (τη φτιάχνει ο tenant στο
    // Oxygen του, όπως και την κανονική) — χωρίς αυτήν ΔΕΝ γίνεται αυτόματο
    // πιστωτικό, μένει η χειροκίνητη ειδοποίηση.
    if (d.oxygenCreditNumberingSequenceId != null) updates.oxygenCreditNumberingSequenceId = s(d.oxygenCreditNumberingSequenceId) || null;
    if (d.oxygenPaymentMethodId != null) updates.oxygenPaymentMethodId = s(d.oxygenPaymentMethodId) || null;
    if (d.oxygenSandbox != null) updates.oxygenSandbox = d.oxygenSandbox === true;

    // Κλειδιά — σε Secret Manager, ΠΟΤΕ σε απλό πεδίο Firestore.
    if (d.invoiceApiKey != null) {
      const key = s(d.invoiceApiKey);
      if (key) {
        await upsertSecret(tenantSecretId(tenantId, "invoice-api-key"), key);
        updates.hasInvoiceApiKey = true;
      } else {
        updates.hasInvoiceApiKey = false;
      }
    }
    if (d.mydataSubKey != null) {
      const key = s(d.mydataSubKey);
      if (key) {
        await upsertSecret(tenantSecretId(tenantId, "mydata-subscription-key"), key);
        updates.hasMydataSubKey = true;
      } else {
        updates.hasMydataSubKey = false;
      }
    }
    if (d.epsilonPassword != null) {
      const pw = s(d.epsilonPassword);
      if (pw) {
        await upsertSecret(tenantSecretId(tenantId, "epsilon-password"), pw);
        updates.hasEpsilonPassword = true;
      } else {
        updates.hasEpsilonPassword = false;
      }
    }

    if (Object.keys(updates).length) await tenantRef.set(updates, { merge: true });
    return { ok: true };
  }
);

exports.updateTenantResendKey = onCall(
  { region: "us-central1", secrets: [] },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "Χρειάζεται σύνδεση.");
    const d = request.data || {};
    const tenantId = s(d.tenantId);
    if (!tenantId || tenantId === "default") {
      throw new HttpsError("invalid-argument", "Μη έγκυρο tenantId.");
    }
    const isSuperAdmin = request.auth.token.email === "techtacy@gmail.com";
    if (!isSuperAdmin) {
      const db0 = getFirestore();
      const presDoc = await db0.collection("presence").doc(request.auth.uid).get();
      const pres = presDoc.data() || {};
      if (!(pres.tenantOwner === true && pres.tenantId === tenantId)) {
        throw new HttpsError("permission-denied",
          "Μόνο ο super-admin ή ο tenant-owner αυτού του tenant μπορεί να το αλλάξει.");
      }
    }
    const db = getFirestore();
    const tenantRef = db.collection("tenants").doc(tenantId);
    if (!(await tenantRef.get()).exists) throw new HttpsError("not-found", "Άγνωστο tenant.");

    const key = s(d.resendApiKey);
    if (!key) {
      // Άδειο κλειδί = αφαίρεση δικού του — γυρνάει στο κοινό μας (προεπιλογή).
      await tenantRef.set({ hasOwnResendKey: false, emailsEnabled: true }, { merge: true });
      return { ok: true, hasOwnResendKey: false };
    }
    await upsertSecret(tenantSecretId(tenantId, "resend-api-key"), key);
    // ⚠️ emailsEnabled:false εδώ ΔΕΝ σημαίνει «σβησμένα email» — σημαίνει
    // «μη χρησιμοποιείς το ΚΟΙΝΟ (του master) key». Αφού μόλις απέκτησε
    // δικό του key, η προεπιλογή είναι να ΤΟ χρησιμοποιεί (δεν πληρώνει ο
    // master). Ο master μπορεί χειροκίνητα να "παρακάμψει" αργότερα.
    await tenantRef.set({ hasOwnResendKey: true, emailsEnabled: false }, { merge: true });
    return { ok: true, hasOwnResendKey: true };
  }
);

exports.updateTenantVivaCredentials = onCall(
  { region: "us-central1" },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "Χρειάζεται σύνδεση.");
    const d = request.data || {};
    const tenantId = s(d.tenantId);
    if (!tenantId || tenantId === "default") {
      throw new HttpsError("invalid-argument", "Μη έγκυρο tenantId.");
    }

    const isSuperAdmin = request.auth.token.email === "techtacy@gmail.com";
    if (!isSuperAdmin) {
      // Έλεγχος: είναι ο tenant-owner ΑΥΤΟΥ ΤΟΥ tenant;
      const db0 = getFirestore();
      const presDoc = await db0.collection("presence").doc(request.auth.uid).get();
      const pres = presDoc.data() || {};
      if (!(pres.tenantOwner === true && pres.tenantId === tenantId)) {
        throw new HttpsError("permission-denied",
          "Μόνο ο super-admin ή ο tenant-owner αυτού του tenant μπορεί να το αλλάξει.");
      }
    }

    const db = getFirestore();
    const tenantDoc = await db.collection("tenants").doc(tenantId).get();
    if (!tenantDoc.exists) throw new HttpsError("not-found", "Άγνωστο tenant.");

    const vivaFields = {
      "viva-client-id":     s(d.vivaClientId),
      "viva-client-secret": s(d.vivaClientSecret),
      "viva-merchant-id":   s(d.vivaMerchantId),
      "viva-api-key":       s(d.vivaApiKey),
    };
    let anySet = false;
    for (const [field, value] of Object.entries(vivaFields)) {
      if (value) {
        anySet = true;
        try {
          await upsertSecret(tenantSecretId(tenantId, field), value);
        } catch (e) {
          throw new HttpsError("internal", "Αποτυχία αποθήκευσης: " + e.message);
        }
      }
    }

    const updates = {};
    if (d.vivaSourceCode != null) updates.vivaSourceCode = s(d.vivaSourceCode) || null;
    if (d.vivaSourceCodeEn != null) updates.vivaSourceCodeEn = s(d.vivaSourceCodeEn) || null;
    if (d.vivaDemo != null) updates.vivaDemo = d.vivaDemo !== false;
    if (anySet) updates.hasVivaCredentials = true;
    if (Object.keys(updates).length) {
      await db.collection("tenants").doc(tenantId).update(updates);
    }

    return { ok: true };
  }
);


exports.updateTenantStripeCredentials = onCall(
  { region: "us-central1" },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "Χρειάζεται σύνδεση.");
    const d = request.data || {};
    const tenantId = s(d.tenantId) || "default";

    const isSuperAdmin = request.auth.token.email === "techtacy@gmail.com";
    if (tenantId !== "default" && !isSuperAdmin) {
      const db0 = getFirestore();
      const presDoc = await db0.collection("presence").doc(request.auth.uid).get();
      const pres = presDoc.data() || {};
      if (!(pres.tenantOwner === true && pres.tenantId === tenantId)) {
        throw new HttpsError("permission-denied",
          "Μόνο ο super-admin ή ο tenant-owner αυτού του tenant μπορεί να το αλλάξει.");
      }
    } else if (tenantId === "default" && !isSuperAdmin) {
      throw new HttpsError("permission-denied", "Μόνο ο master μπορεί να το αλλάξει.");
    }

    const db = getFirestore();
    if (tenantId !== "default") {
      const tenantDoc = await db.collection("tenants").doc(tenantId).get();
      if (!tenantDoc.exists) throw new HttpsError("not-found", "Άγνωστο tenant.");
    }

    const stripeFields = {
      "stripe-secret-key":      s(d.stripeSecretKey),
      "stripe-publishable-key": s(d.stripePublishableKey),
      "stripe-webhook-secret":  s(d.stripeWebhookSecret),
    };
    let anySet = false;
    for (const [field, value] of Object.entries(stripeFields)) {
      if (value) {
        anySet = true;
        try {
          await upsertSecret(tenantSecretId(tenantId, field), value);
        } catch (e) {
          throw new HttpsError("internal", "Αποτυχία αποθήκευσης: " + e.message);
        }
      }
    }

    if (anySet) {
      await db.collection("tenants").doc(tenantId).set(
        { hasStripeCredentials: true }, { merge: true }
      );
    }

    return { ok: true };
  }
);

// ═══════════════════════════════════════════════════════════════════════════
//  Oxygen Pelatologio — self-service credentials, ΙΔΙΟ pattern με Viva/Stripe.
//  Το API key αποθηκεύεται στο Secret Manager (ευαίσθητο). Τα branch/
//  numbering-sequence/payment-method IDs είναι απλά αναγνωριστικά (όχι
//  μυστικά) — μπαίνουν κατευθείαν στο tenants/{id} doc.
// ═══════════════════════════════════════════════════════════════════════════
exports.getTenantStripeCredentialsForOwner = onCall(
  { region: "us-central1" },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "Χρειάζεται σύνδεση.");
    const tenantId = s((request.data || {}).tenantId) || "default";
    const isSuperAdmin = request.auth.token.email === "techtacy@gmail.com";
    const db = getFirestore();
    if (tenantId !== "default" && !isSuperAdmin) {
      const presDoc = await db.collection("presence").doc(request.auth.uid).get();
      const pres = presDoc.data() || {};
      if (!(pres.tenantOwner === true && pres.tenantId === tenantId)) {
        throw new HttpsError("permission-denied", "Δεν έχεις πρόσβαση σε αυτόν τον tenant.");
      }
    } else if (tenantId === "default" && !isSuperAdmin) {
      throw new HttpsError("permission-denied", "Μόνο ο master.");
    }

    let paymentProvider = "viva";
    if (tenantId !== "default") {
      const tenantDoc = await db.collection("tenants").doc(tenantId).get();
      if (!tenantDoc.exists) throw new HttpsError("not-found", "Άγνωστο tenant.");
      paymentProvider = resolvePaymentProvider(tenantDoc.data());
    } else {
      const defaultDoc = await db.collection("tenants").doc("default").get();
      paymentProvider = resolvePaymentProvider(defaultDoc.exists ? defaultDoc.data() : {});
    }

    const mask = (v) => (v ? v.slice(0, 7) + "••••••••" : "");
    const creds = await getTenantStripeCredentials(tenantId);
    return {
      ok: true,
      stripeSecretKeyMasked:      mask(creds.secretKey),
      stripePublishableKeyMasked: mask(creds.publishableKey),
      stripeWebhookSecretMasked:  mask(creds.webhookSecret),
      hasStripeCredentials: !!(creds.secretKey && creds.publishableKey),
      paymentProvider,
    };
  }
);

exports.updateTenantPaymentProvider = onCall(
  { region: "us-central1" },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "Χρειάζεται σύνδεση.");
    const d = request.data || {};
    const tenantId = s(d.tenantId) || "default";
    const provider = s(d.paymentProvider) === "stripe" ? "stripe" : "viva";

    const isSuperAdmin = request.auth.token.email === "techtacy@gmail.com";
    if (tenantId !== "default" && !isSuperAdmin) {
      const db0 = getFirestore();
      const presDoc = await db0.collection("presence").doc(request.auth.uid).get();
      const pres = presDoc.data() || {};
      if (!(pres.tenantOwner === true && pres.tenantId === tenantId)) {
        throw new HttpsError("permission-denied",
          "Μόνο ο super-admin ή ο tenant-owner αυτού του tenant μπορεί να το αλλάξει.");
      }
    } else if (tenantId === "default" && !isSuperAdmin) {
      throw new HttpsError("permission-denied", "Μόνο ο master.");
    }

    const db = getFirestore();
    await db.collection("tenants").doc(tenantId).set(
      { paymentProvider: provider }, { merge: true }
    );
    return { ok: true, paymentProvider: provider };
  }
);

// ── getTenantVivaCredentialsForOwner: επιστρέφει (μερικώς κρυμμένα) τα ήδη
// αποθηκευμένα credentials ενός tenant, ΜΟΝΟ στον ίδιο τον tenant-owner ή
// στον super-admin — ώστε να τα βλέπει στη φόρμα του (π.χ. για να τα
// επιβεβαιώσει), χωρίς να εκτίθεται ολόκληρο το Client Secret/API Key.
// ── updateTenantBusinessInfo: τηλέφωνο/email/λογότυπο/WhatsApp — ΔΕΝ είναι
// μυστικά στοιχεία, γι' αυτό μένουν απλά πεδία στο Firestore (όχι Secret
// Manager). Ίδιος έλεγχος πρόσβασης με τα Viva credentials: super-admin ή
// ο ίδιος ο tenant-owner αυτού του tenant.
exports.updateTenantBusinessInfo = onCall(
  { region: "us-central1" },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "Χρειάζεται σύνδεση.");
    const d = request.data || {};
    const tenantId = s(d.tenantId) || "default";

    const isSuperAdmin = request.auth.token.email === "techtacy@gmail.com";
    if (tenantId === "default") {
      // ⚠️ Το "default" (η δική σου σελίδα) ΔΕΝ έχει tenantOwner — μόνο ο
      // super-admin μπορεί να αλλάξει τα δικά του στοιχεία επιχείρησης.
      if (!isSuperAdmin) {
        throw new HttpsError("permission-denied", "Μόνο ο master μπορεί να το αλλάξει.");
      }
    } else if (!isSuperAdmin) {
      const db0 = getFirestore();
      const presDoc = await db0.collection("presence").doc(request.auth.uid).get();
      const pres = presDoc.data() || {};
      if (!(pres.tenantOwner === true && pres.tenantId === tenantId)) {
        throw new HttpsError("permission-denied",
          "Μόνο ο super-admin ή ο tenant-owner αυτού του tenant μπορεί να το αλλάξει.");
      }
    }

    const db = getFirestore();
    const tenantRef = db.collection("tenants").doc(tenantId);
    const tenantDoc = await tenantRef.get();
    // Το "default" (η δική σου σελίδα) δεν έχει ποτέ δημιουργηθεί μέσω
    // createTenant — αν δεν υπάρχει ακόμα το doc, το φτιάχνουμε τώρα εδώ.
    if (!tenantDoc.exists && tenantId !== "default") {
      throw new HttpsError("not-found", "Άγνωστο tenant.");
    }

    const updates = {};
    // Όνομα επιχείρησης — επιτρέπεται και στον ίδιο τον tenant-owner να το
    // διορθώσει (π.χ. αν το έγραψε λάθος αρχικά), όχι μόνο ο super-admin.
    if (d.businessName != null)   updates.businessName   = s(d.businessName) || (tenantDoc.exists ? tenantDoc.data().businessName : null);
    if (d.contactPhone != null)   updates.contactPhone   = s(d.contactPhone) || null;
    if (d.contactEmail != null)   updates.contactEmail   = s(d.contactEmail) || null;
    if (d.whatsappNumber != null) updates.whatsappNumber = s(d.whatsappNumber) || null;
    if (d.logoUrl != null)        updates.logoUrl        = s(d.logoUrl) || null;
    // Google Maps/Places API key — ΔΕΝ είναι μυστικό (τα κλειδιά Google Maps
    // είναι ΠΑΝΤΑ ορατά στον browser, η ασφάλεια έρχεται από τον περιορισμό
    // domain στο ίδιο το Google Cloud Console, όχι από μυστικότητα).
    if (d.mapsApiKey != null)     updates.mapsApiKey     = s(d.mapsApiKey) || null;
    if (Object.keys(updates).length) {
      await tenantRef.set(updates, { merge: true });
    }
    return { ok: true };
  }
);

// ── getTenantBusinessInfo: δημόσιο endpoint (booking2.html το φορτώνει
// αυτόματα στο άνοιγμα της σελίδας) — επιστρέφει τηλέφωνο/email/λογότυπο/
// WhatsApp/όνομα επιχείρησης ενός tenant. ΔΕΝ χρειάζεται authentication —
// είναι δημόσια στοιχεία επικοινωνίας (ίδια που θα έβλεπε ο πελάτης έτσι
// κι αλλιώς μέσα στη σελίδα).
exports.getTenantBusinessInfo = onRequest(
  { region: "us-central1", cors: BOOKING_ALLOWED_ORIGINS, memory: "256MiB" },
  async (req, res) => {
    try {
      const tenantId = s(req.method === "POST" ? (req.body || {}).tenantId : req.query.tenantId) || "default";
      const db = getFirestore();
      const doc = await db.collection("tenants").doc(tenantId).get();
      if (!doc.exists) {
        return res.status(200).json({ ok: true, businessName: null, contactPhone: null,
          contactEmail: null, whatsappNumber: null, logoUrl: null, mapsApiKey: null,
          mapEnabled: true, placesEnabled: true,
          afm: null, doy: null, taxAddress: null, kad: null,
          invoiceProvider: "none", hasInvoiceApiKey: false,
          mydataUsername: null, hasMydataSubKey: false,
          invoiceEnabled: false, invoiceSeries: null,
          mydataInvoiceType: "11.2", mydataVatCategory: "2", mydataDemo: true,
          epsilonEmail: null, epsilonItemCode: null, hasEpsilonPassword: false });
      }
      const t = doc.data();
      return res.status(200).json({
        ok: true,
        businessName:   t.businessName   || null,
        contactPhone:   t.contactPhone   || null,
        contactEmail:   t.contactEmail   || null,
        whatsappNumber: t.whatsappNumber || null,
        logoUrl:        t.logoUrl        || null,
        mapsApiKey:     t.mapsApiKey     || null,
        // ── Διακόπτες master — απενεργοποιούν χάρτη/Places ανά φόρμα.
        // ΠΡΟΕΠΙΛΟΓΗ true (ενεργά) αν δεν έχουν οριστεί ρητά ποτέ.
        mapEnabled:     t.mapEnabled     !== false,
        placesEnabled:  t.placesEnabled  !== false,
        hasOwnResendKey: t.hasOwnResendKey === true,
        emailsEnabled:   t.emailsEnabled  !== false,
        // ── Φορολογικά στοιχεία + πάροχος ηλεκτρονικής τιμολόγησης ──
        afm:            t.afm            || null,
        doy:            t.doy            || null,
        taxAddress:     t.taxAddress     || null,
        kad:            t.kad            || null,
        invoiceProvider: t.invoiceProvider || "none",
        hasInvoiceApiKey: t.hasInvoiceApiKey === true,
        mydataUsername:  t.mydataUsername  || null,
        hasMydataSubKey: t.hasMydataSubKey === true,
        epsilonEmail: t.epsilonEmail || null,
        epsilonItemCode: t.epsilonItemCode || null,
        hasEpsilonPassword: t.hasEpsilonPassword === true,
        // ⚠️ ΠΑΝΤΑ false εξ ορισμού — καμία αυτόματη έκδοση χωρίς ρητή,
        // συνειδητή ενεργοποίηση από τον ίδιο τον tenant.
        invoiceEnabled:  t.invoiceEnabled === true,
        invoiceSeries:   t.invoiceSeries   || null,
        mydataInvoiceType: t.mydataInvoiceType || "11.2",
        mydataVatCategory: t.mydataVatCategory || "2",
        mydataDemo: t.mydataDemo !== false,
      });
    } catch (e) {
      console.error("getTenantBusinessInfo error:", e);
      return res.status(500).json({ ok: false, error: "server_error" });
    }
  }
);

// ── updateTenantFeatureFlags: ενεργοποίηση/απενεργοποίηση χάρτη & Places
// ανά Online Φόρμα — ΜΟΝΟ ο super-admin (εσύ) το αλλάζει, ποτέ ο ίδιος
// ο tenant. Χρήσιμο π.χ. αν κάποιος πελάτης δεν έχει ρυθμίσει ακόμα σωστά
// το δικό του Google API key, ή αν θες προσωρινά να κόψεις κόστος.
exports.updateTenantFeatureFlags = onCall(
  { region: "us-central1" },
  async (request) => {
    if (!request.auth || request.auth.token.email !== "techtacy@gmail.com") {
      throw new HttpsError("permission-denied", "Μόνο ο super-admin.");
    }
    const d = request.data || {};
    const tenantId = s(d.tenantId);
    if (!tenantId || tenantId === "default") {
      throw new HttpsError("invalid-argument", "Μη έγκυρο tenantId.");
    }
    const db = getFirestore();
    const tenantDoc = await db.collection("tenants").doc(tenantId).get();
    if (!tenantDoc.exists) throw new HttpsError("not-found", "Άγνωστο tenant.");

    const updates = {};
    if (d.mapEnabled != null) updates.mapEnabled = d.mapEnabled === true;
    if (d.placesEnabled != null) updates.placesEnabled = d.placesEnabled === true;
    if (Object.keys(updates).length) {
      await db.collection("tenants").doc(tenantId).update(updates);
    }
    return { ok: true };
  }
);

// ── fixClientsForTenant: διορθώνει το tenantId σε πελάτες (clients, π.χ.
// "AIRSTAY") που έφτιαξαν admins/tenant-owners αυτού του tenant ΠΡΙΝ
// ρυθμιστεί σωστά το δικό τους presence.tenantId (ή πριν φτιαχτεί καν το
// multi-tenant σύστημα). Βρίσκει «σε ποιον ανήκει» ο κάθε πελάτης μέσω του
// createdBy, ΟΧΙ μέσω του (πιθανό λάθος) δικού του tenantId.
exports.fixClientsForTenant = onCall(
  { region: "us-central1" },
  async (request) => {
    if (!request.auth || request.auth.token.email !== "techtacy@gmail.com") {
      throw new HttpsError("permission-denied", "Μόνο ο super-admin.");
    }
    const tenantId = s((request.data || {}).tenantId);
    if (!tenantId || tenantId === "default") {
      throw new HttpsError("invalid-argument", "Μη έγκυρο tenantId.");
    }
    const db = getFirestore();

    // 1) Ποιοι χρήστες (uid) ανήκουν σε αυτό το tenant ΤΩΡΑ.
    const presSnap = await db.collection("presence")
      .where("tenantId", "==", tenantId).get();
    const uids = presSnap.docs.map((d) => d.id);
    if (!uids.length) {
      return { ok: true, total: 0, updated: 0, message: "Δεν βρέθηκε κανένας χρήστης σε αυτό το tenant." };
    }

    // 2) Πελάτες που έφτιαξε ΚΑΘΕΝΑΣ από αυτούς (Firestore 'in' — έως 30
    // τιμές ανά ερώτημα, κάνουμε chunks για ασφάλεια σε μεγάλες ομάδες).
    let total = 0, updated = 0;
    const chunkSize = 30;
    for (let i = 0; i < uids.length; i += chunkSize) {
      const chunk = uids.slice(i, i + chunkSize);
      const clientsSnap = await db.collection("clients")
        .where("createdBy", "in", chunk).get();
      total += clientsSnap.size;
      const batch = db.batch();
      let inBatch = 0;
      for (const doc of clientsSnap.docs) {
        if (doc.data().tenantId !== tenantId) {
          batch.update(doc.ref, { tenantId });
          updated++;
          inBatch++;
        }
      }
      if (inBatch > 0) await batch.commit();
    }

    return { ok: true, total, updated };
  }
);

exports.getTenantVivaCredentialsForOwner = onCall(
  { region: "us-central1" },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "Χρειάζεται σύνδεση.");
    const tenantId = s((request.data || {}).tenantId);
    if (!tenantId || tenantId === "default") {
      throw new HttpsError("invalid-argument", "Μη έγκυρο tenantId.");
    }
    const isSuperAdmin = request.auth.token.email === "techtacy@gmail.com";
    const db = getFirestore();
    if (!isSuperAdmin) {
      const presDoc = await db.collection("presence").doc(request.auth.uid).get();
      const pres = presDoc.data() || {};
      if (!(pres.tenantOwner === true && pres.tenantId === tenantId)) {
        throw new HttpsError("permission-denied", "Δεν έχεις πρόσβαση σε αυτόν τον tenant.");
      }
    }
    const tenantDoc = await db.collection("tenants").doc(tenantId).get();
    if (!tenantDoc.exists) throw new HttpsError("not-found", "Άγνωστο tenant.");
    const t = tenantDoc.data();

    const mask = (v) => (v ? v.slice(0, 4) + "••••••••" : "");
    const creds = await getTenantVivaCredentials(tenantId);
    return {
      ok: true,
      vivaClientIdMasked:     mask(creds.clientId),
      vivaClientSecretMasked: mask(creds.clientSecret),
      vivaMerchantIdMasked:   mask(creds.merchantId),
      vivaApiKeyMasked:       mask(creds.apiKey),
      vivaSourceCode:         t.vivaSourceCode || "",
      vivaSourceCodeEn:       t.vivaSourceCodeEn || "",
      vivaDemo:               t.vivaDemo !== false,
      hasVivaCredentials:     t.hasVivaCredentials === true,
    };
  }
);

// ── getSharedDemoVivaCredentials: επιστρέφει τα ΔΙΚΑ ΣΟΥ (Konstantinos)
// demo Viva credentials, ΜΟΝΟ αν ο δικός σου λογαριασμός είναι ήδη σε demo
// mode (ασφαλιστική δικλείδα — ΠΟΤΕ δεν εκθέτει live/πραγματικά στοιχεία).
// Σκοπός: νέος tenant να μπορεί να δοκιμάσει όλη τη ροή πληρωμής χρησιμοποιώντας
// τον ΔΙΚΟ ΣΟΥ demo λογαριασμό, πριν αποκτήσει τον δικό του.
exports.getSharedDemoVivaCredentials = onCall(
  { region: "us-central1" },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "Χρειάζεται σύνδεση.");
    const db = getFirestore();
    const presDoc = await db.collection("presence").doc(request.auth.uid).get();
    const pres = presDoc.data() || {};
    const isSuperAdmin = request.auth.token.email === "techtacy@gmail.com";
    if (!isSuperAdmin && pres.tenantOwner !== true) {
      throw new HttpsError("permission-denied", "Μόνο για tenant-owners.");
    }
    const defaultDemo = await readSecret("VIVA_DEMO");
    if (!vivaIsDemo(defaultDemo)) {
      throw new HttpsError("failed-precondition",
        "Ο κύριος λογαριασμός δεν είναι αυτή τη στιγμή σε demo mode — δεν μοιράζονται στοιχεία.");
    }
    return {
      ok: true,
      vivaClientId:     await readSecret("VIVA_CLIENT_ID"),
      vivaClientSecret: await readSecret("VIVA_CLIENT_SECRET"),
      vivaMerchantId:   await readSecret("VIVA_MERCHANT_ID"),
      vivaApiKey:       await readSecret("VIVA_API_KEY"),
    };
  }
);

// ── updateDefaultVivaCredentials: ενημέρωση των ΔΙΚΩΝ ΣΟΥ (Konstantinos)
// Viva credentials — ΜΟΝΟ super-admin. Πλέον διαβάζονται ΖΩΝΤΑΝΑ (readSecret)
// σε όλο το σύστημα, άρα ισχύουν ΑΜΕΣΩΣ — ΔΕΝ χρειάζεται πια deploy.
exports.updateDefaultVivaCredentials = onCall(
  { region: "us-central1" },
  async (request) => {
    if (!request.auth || request.auth.token.email !== "techtacy@gmail.com") {
      throw new HttpsError("permission-denied", "Μόνο ο super-admin.");
    }
    const d = request.data || {};
    const fieldMap = {
      vivaClientId:     "VIVA_CLIENT_ID",
      vivaClientSecret: "VIVA_CLIENT_SECRET",
      vivaMerchantId:   "VIVA_MERCHANT_ID",
      vivaApiKey:       "VIVA_API_KEY",
    };
    for (const [key, secretId] of Object.entries(fieldMap)) {
      const value = s(d[key]);
      if (value) {
        try {
          await upsertSecret(secretId, value);
        } catch (e) {
          throw new HttpsError("internal", "Αποτυχία αποθήκευσης " + secretId + ": " + e.message);
        }
      }
    }
    if (d.vivaDemo != null) {
      try {
        await upsertSecret("VIVA_DEMO", d.vivaDemo ? "true" : "false");
      } catch (e) {
        throw new HttpsError("internal", "Αποτυχία αποθήκευσης VIVA_DEMO: " + e.message);
      }
    }
    return {
      ok: true,
      needsRedeploy: false,
      message: "Αποθηκεύτηκε και ισχύει ήδη — καμία ανάγκη για deploy.",
    };
  }
);
