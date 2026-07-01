const { onDocumentCreated, onDocumentUpdated } = require("firebase-functions/v2/firestore");
const { initializeApp }   = require("firebase-admin/app");
const { getFirestore, FieldValue }    = require("firebase-admin/firestore");
const { getMessaging }    = require("firebase-admin/messaging");

initializeApp();

// ─── Helper: στέλνει DATA-ONLY FCM σε λίστα tokens ──────────────────────────
async function sendDataOnly(tokens, data) {
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
        ttl:      60 * 1000,                 // 60s (δουλειές είναι time-sensitive)
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
  const tokens = [];
  for (const doc of snap.docs) {
    const d = doc.data();
    // Φίλτρο οχήματος — ο master το παρακάμπτει (λαμβάνει κάθε δουλειά ανεξαρτήτως οχήματος)
    if (d.master !== true && job.vehicleType && job.vehicleType !== "any") {
      if (d.vehicleType !== job.vehicleType) continue;
    }
    // Φίλτρο βάσης
    if (baseSet && !baseSet.has(doc.id)) continue;
    if (d.fcmToken) tokens.push(d.fcmToken);
  }
  return tokens;
}

// ─── Helper: φτιάχνει data payload για δουλειά ──────────────────────────────
// ΠΡΟΣΟΧΗ: "from", "notification", "message_type" κλπ. είναι reserved από FCM.
function jobDataPayload(jobId, job, type, title) {
  return {
    type:        String(type),
    jobId:       String(jobId),
    title:       String(title),
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

// ─── Επιβίβαση: ειδοποίηση στον admin που έβγαλε τη δουλειά ──────────────────
// Χτυπάει όταν status: * → "boarded". Στέλνει ΜΟΝΟ στον createdBy.
exports.onJobBoarded = onDocumentUpdated("jobs/{jobId}", async (event) => {
  const before = event.data.before.data();
  const after  = event.data.after.data();
  if (!before || !after) return;
  if (before.status === "boarded" || after.status !== "boarded") return;

  const tokens = await getTokensForUid(after.createdBy);
  if (!tokens.length) {
    console.log("onJobBoarded: no token for admin", after.createdBy);
    return;
  }

  await sendDataOnly(tokens, {
    type:        "boarded",
    jobId:       String(event.params.jobId),
    title:       "🚗 Επιβίβαση πελάτη",
    driverName:  String(after.takenByName || ""),
    fromAddr:    String(after.from || ""),
    toAddr:      String(after.to   || ""),
    price:       String(after.price != null ? after.price : ""),
    scheduledAt: after.scheduledAt
      ? String(after.scheduledAt.toMillis())
      : "",
    click_action: "FLUTTER_NOTIFICATION_CLICK",
  });
  console.log("onJobBoarded: notified admin", after.createdBy);
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
async function findMasterUid() {
  const snap = await getFirestore().collection("presence")
    .where("master", "==", true).limit(1).get();
  return snap.empty ? null : snap.docs[0].id;
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
  async () => { await runMonthlyCharges(); }
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

// ── Νυχτερινό τιμολόγιο 23:30–05:30 ──────────────────────────────────────────
function isNightWindow(naiveDate) {
  const mins = naiveDate.getUTCHours() * 60 + naiveDate.getUTCMinutes();
  return mins >= 23 * 60 + 30 || mins < 5 * 60 + 30;
}

// ── Μπλάκαουτ: μόνο το ΑΜΕΣΩΣ επόμενο παράθυρο 22:30–08:00 από «τώρα» ───────
function nearestBlackoutWindow(simNaive) {
  const mins = simNaive.getUTCHours() * 60 + simNaive.getUTCMinutes();
  const start = new Date(simNaive);
  start.setUTCHours(22, 30, 0, 0);
  if (mins < 8 * 60) start.setUTCDate(start.getUTCDate() - 1);
  const end = new Date(start);
  end.setUTCDate(end.getUTCDate() + 1);
  end.setUTCHours(8, 0, 0, 0);
  return { start, end };
}

// ── Λόγοι μπλοκαρίσματος υποβολής (μπλάκαουτ / προθεσμία / μεγάλη παραγγελία)
function computeGate(simNaive, scheduledNaive, persons, luggage) {
  const reasons = [];
  if (!scheduledNaive) return reasons;
  const bw = nearestBlackoutWindow(simNaive);
  if (scheduledNaive >= bw.start && scheduledNaive < bw.end) reasons.push("blackout");
  const leadHours = (scheduledNaive - simNaive) / 3600000;
  if (leadHours < 2) reasons.push("lead_time");
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

// ── Ασφαλής υπολογιστής προσαρμοσμένου τύπου ────────────────────────────────
// Επιτρέπονται ΜΟΝΟ: αριθμοί, οι μεταβλητές km/min/luggage/seats/base/perKm/
// perMin, οι πράξεις + - * / ( ) και κενά. Οτιδήποτε άλλο απορρίπτεται —
// έτσι κανείς δεν μπορεί να «τρέξει» επικίνδυνο κώδικα μέσω του τύπου.
function evalCustomFormula(formula, vars) {
  if (!formula || typeof formula !== "string" || formula.trim() === "") return null;
  const allowedNames = ["km", "min", "luggage", "seats", "base", "perKm", "perMin"];
  // Αντικατάσταση ονομάτων μεταβλητών με τις τιμές τους.
  let expr = formula;
  for (const name of allowedNames) {
    expr = expr.replace(new RegExp("\\b" + name + "\\b", "g"), "(" + Number(vars[name] || 0) + ")");
  }
  // Μετά την αντικατάσταση, επιτρέπονται ΜΟΝΟ ψηφία, . + - * / ( ) και κενά.
  if (!/^[0-9.+\-*/()\s]+$/.test(expr)) {
    console.warn("evalCustomFormula: rejected unsafe formula:", formula);
    return null;
  }
  try {
    // eslint-disable-next-line no-new-func
    const result = Function('"use strict"; return (' + expr + ");")();
    return (typeof result === "number" && isFinite(result)) ? result : null;
  } catch (e) {
    console.warn("evalCustomFormula: eval error:", e);
    return null;
  }
}

// ── Πραγματική απόσταση/διάρκεια μέσω Routes API (κλειδί ΜΟΝΟ server-side) ──
async function routesDistanceDuration(origin, dest, apiKey) {
  if (!apiKey) return null;
  try {
    const resp = await fetch("https://routes.googleapis.com/directions/v2:computeRoutes", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Goog-Api-Key": apiKey,
        "X-Goog-FieldMask": "routes.distanceMeters,routes.duration",
      },
      body: JSON.stringify({
        origin: { location: { latLng: { latitude: origin.lat, longitude: origin.lng } } },
        destination: { location: { latLng: { latitude: dest.lat, longitude: dest.lng } } },
        travelMode: "DRIVE",
        routingPreference: "TRAFFIC_AWARE",
      }),
    });
    const data = await resp.json();
    const route = data && data.routes && data.routes[0];
    if (!route) return null;
    return {
      distanceKm: Number(route.distanceMeters || 0) / 1000,
      durationMin: parseInt(route.duration, 10) / 60,
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

// ── Ταίριασμα σημείου σε ζώνη (μέσα στην ακτίνα της, η πιο κοντινή αν πολλές)
function matchZone(lat, lng, zones) {
  let best = null, bestKm = Infinity;
  for (const z of zones) {
    if (z.lat == null || z.lng == null) continue;
    const dKm = haversineKm({ lat, lng }, { lat: z.lat, lng: z.lng });
    if (dKm * 1000 <= Number(z.radius || 0) && dKm < bestKm) { best = z; bestKm = dKm; }
  }
  return best;
}

// ── Ρυθμίσεις τιμολόγησης (ζώνες + διαδρομές + δυναμικός τύπος), cache 60″ ──
let _pricingCache = null;
let _pricingCacheAt = 0;
async function getPricingData() {
  const now = Date.now();
  if (_pricingCache && now - _pricingCacheAt < 60000) return _pricingCache;
  const db = getFirestore();
  const [zonesSnap, routesSnap, cfgDoc] = await Promise.all([
    db.collection("pricing_zones").get(),
    db.collection("pricing_routes").get(),
    db.collection("app_settings").doc("pricing").get(),
  ]);
  const zones = zonesSnap.docs.map((d) => ({ id: d.id, ...d.data() }));
  const routes = {};
  routesSnap.docs.forEach((d) => {
    const r = d.data();
    if (r.fromZoneId && r.toZoneId) routes[r.fromZoneId + ">" + r.toZoneId] = r;
  });
  const cfg = Object.assign(
    {
      base: 3.5, perKm: 1.0, perKmOutside: 2.0, perMin: 0.2,
      minCharge: 25, minChargeNight: 35,
      nightPctTaxi: 30, nightPctVan: 25, vanPct: 90,
      luggagePer: 0, seatPrice: 5,
      nightAppliesToZones: true,
      customFormula: "", // κενό = προεπιλεγμένος τύπος
    },
    cfgDoc.exists ? cfgDoc.data() : {}
  );
  _pricingCache = { zones, routes, cfg };
  _pricingCacheAt = now;
  return _pricingCache;
}

// ── Κεντρικός υπολογισμός τιμής (ζώνη ή δυναμικός τύπος + νυχτερινό) ───────
// Επιπλέον υπολογίζει την «αρχική τιμή» (πριν την έκπτωση γνωριμίας 8%) που
// εμφανίζεται διαγραμμένη δίπλα στην τελική τιμή. Για διαδρομές όπου ο
// Έλληνας πελάτης έχει ήδη χαμηλότερη τιμή από τον ξένο, χρησιμοποιούμε ΤΗΝ
// ΙΔΙΑ «αρχική» με του ξένου και υπολογίζουμε πόσο % έκπτωση βγαίνει αυτό
// (στρογγυλό, όχι δεκαδικό) — άρα ο Έλληνας βλέπει μεγαλύτερο ποσοστό.
async function computeEstimate({
  fromLat, fromLng, toLat, toLng, persons, luggage, childSeatCount,
  vehicleType, isGreek, scheduledNaive, apiKey,
}) {
  const { zones, routes, cfg } = await getPricingData();
  const forced = persons >= 5 || luggage >= 5;
  const vehicle = forced ? "van" : (vehicleType === "van" ? "van" : "taxi");

  const fromZone = fromLat != null && fromLng != null ? matchZone(fromLat, fromLng, zones) : null;
  const toZone = toLat != null && toLng != null ? matchZone(toLat, toLng, zones) : null;

  let basePrice = 0;        // τιμή αυτού του πελάτη, πριν το νυχτερινό
  let baseOtherPrice = null; // τιμή που θα είχε ο «άλλος τύπος» πελάτη (αν υπάρχει διαφοροποίηση)
  let zoneMatch = false;
  let minChargeApplied = false;
  let outsideAttica = false;

  if (fromZone && toZone) {
    const route = routes[fromZone.id + ">" + toZone.id];
    if (route) {
      zoneMatch = true;
      const ownField = vehicle === "van" ? "van" : "taxi";
      const foreignField = vehicle === "van" ? "vanForeign" : "taxiForeign";
      const ownPrice = Number(route[ownField] || 0);
      const foreignPrice = route[foreignField] != null ? Number(route[foreignField]) : null;
      if (foreignPrice != null && isGreek) {
        basePrice = ownPrice;
        baseOtherPrice = foreignPrice; // ο ξένος είναι η βάση αναφοράς (τυπικό -8%)
      } else if (foreignPrice != null && !isGreek) {
        basePrice = foreignPrice;
      } else {
        basePrice = ownPrice;
      }
    }
  }

  if (!zoneMatch) {
    let distanceKm = 0, durationMin = 0;
    if (fromLat != null && fromLng != null && toLat != null && toLng != null) {
      const rd = await routesDistanceDuration({ lat: fromLat, lng: fromLng }, { lat: toLat, lng: toLng }, apiKey);
      if (rd) {
        distanceKm = rd.distanceKm;
        durationMin = rd.durationMin;
      } else {
        distanceKm = haversineKm({ lat: fromLat, lng: fromLng }, { lat: toLat, lng: toLng }) * 1.3;
        durationMin = (distanceKm / 45) * 60;
      }
    }
    outsideAttica = isOutsideAttica(fromLat, fromLng) || isOutsideAttica(toLat, toLng);
    const perKmNow = outsideAttica ? (cfg.perKmOutside ?? 2.0) : cfg.perKm;

    let p;
    // Αν έχει οριστεί προσαρμοσμένος τύπος και είναι έγκυρος, τον χρησιμοποιούμε.
    const custom = evalCustomFormula(cfg.customFormula, {
      km: distanceKm, min: durationMin, luggage, seats: childSeatCount,
      base: cfg.base, perKm: perKmNow, perMin: cfg.perMin,
    });
    if (custom != null) {
      p = custom;
    } else {
      p = cfg.base + distanceKm * perKmNow + durationMin * cfg.perMin;
    }
    const luggageExtra = luggage * (cfg.luggagePer ?? 0); // επεξεργάσιμη χρέωση βαλίτσας (default 0)
    const seatsExtra = childSeatCount * cfg.seatPrice;
    p += luggageExtra + seatsExtra;
    if (vehicle === "van") p = p * (1 + cfg.vanPct / 100); // Βαν = Ταξί + vanPct%
    basePrice = p; // ΧΩΡΙΣ ελάχιστη ακόμα — αυτή εφαρμόζεται ΜΕΤΑ το νυχτερινό (βλ. παρακάτω)
  }

  const nightApplies = !!scheduledNaive && isNightWindow(scheduledNaive) && (!zoneMatch || cfg.nightAppliesToZones);
  const nightMult = nightApplies ? 1 + (vehicle === "van" ? cfg.nightPctVan : cfg.nightPctTaxi) / 100 : 1;

  let price = basePrice * nightMult;
  let referencePriceRaw = baseOtherPrice != null ? baseOtherPrice * nightMult : price;

  // Η ελάχιστη χρέωση (25€ μέρα / 35€ νύχτα) εφαρμόζεται στο ΤΕΛΙΚΟ ποσό —
  // αυτό που θα πληρώσει ο πελάτης — όχι στη βάση πριν το νυχτερινό.
  if (!zoneMatch) {
    const isNightNow = !!scheduledNaive && isNightWindow(scheduledNaive);
    const minChargeNow = isNightNow ? cfg.minChargeNight : cfg.minCharge;
    if (price < minChargeNow) minChargeApplied = true;
    price = Math.max(price, minChargeNow);
    referencePriceRaw = Math.max(referencePriceRaw, minChargeNow);
  }

  price = Math.floor(price);
  const referencePrice = Math.floor(referencePriceRaw);

  // «Αρχική τιμή» = αυτή που, με -8% έκπτωση γνωριμίας, δίνει ακριβώς την
  // τιμή αναφοράς (του ξένου πελάτη, ή τη δική του τιμή αν δεν υπάρχει
  // διαφοροποίηση). Ο Έλληνας βλέπει την ΙΔΙΑ αρχική με τον ξένο, οπότε το
  // πραγματικό του ποσοστό έκπτωσης βγαίνει μεγαλύτερο.
  const displayOriginal = Math.round((referencePrice / 0.92) * 100) / 100;
  let discountPercent = displayOriginal > 0 ? Math.round((1 - price / displayOriginal) * 100) : 8;
  if (!isFinite(discountPercent)) discountPercent = 8;

  return { price, nightApplies, vehicle, zoneMatch, minChargeApplied, displayOriginal, discountPercent, outsideAttica };
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
      const vehicleType = s(b.vehicleType) === "van" ? "van" : "taxi";
      const lang = s(b.lang) || "el";
      const dialCode = s(b.dialCode);
      const isGreek = lang === "el" ? true : dialCode === "+30";

      let scheduledNaive = null, gateReasons = [];
      const date = s(b.date), time = s(b.time);
      if (date && time) {
        scheduledNaive = athensNaiveFromDateTimeStrings(date, time);
        const simNaive = athensNaiveDate(new Date());
        gateReasons = computeGate(simNaive, scheduledNaive, persons, luggage);
      }

      const result = await computeEstimate({
        fromLat, fromLng, toLat, toLng, persons, luggage, childSeatCount,
        vehicleType, isGreek, scheduledNaive, apiKey: ROUTES_API_KEY.value(),
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

// ── helper: στέλνει email με .ics μέσω Gmail API (refresh token του master) ──
async function sendBookingEmail(masterUid, toEmail, subject, bodyText, icsContent) {
  const accessToken = await freshAccessTokenFor(masterUid);
  if (!accessToken) { console.warn("sendBookingEmail: δεν βρέθηκε access token master"); return false; }

  const boundary = "athenstaxi_" + Date.now();
  const icsB64 = Buffer.from(icsContent, "utf8").toString("base64");

  const mime = [
    'Content-Type: multipart/mixed; boundary="' + boundary + '"',
    "MIME-Version: 1.0",
    "to: " + toEmail,
    "subject: =?UTF-8?B?" + Buffer.from(subject, "utf8").toString("base64") + "?=",
    "",
    "--" + boundary,
    'Content-Type: text/plain; charset="UTF-8"',
    "Content-Transfer-Encoding: base64",
    "",
    Buffer.from(bodyText, "utf8").toString("base64"),
    "",
    "--" + boundary,
    'Content-Type: text/calendar; charset="UTF-8"; method=PUBLISH; name="booking.ics"',
    "Content-Transfer-Encoding: base64",
    'Content-Disposition: attachment; filename="booking.ics"',
    "",
    icsB64,
    "",
    "--" + boundary + "--",
  ].join("\r\n");

  const raw = Buffer.from(mime, "utf8")
    .toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

  const res = await fetch("https://gmail.googleapis.com/gmail/v1/users/me/messages/send", {
    method: "POST",
    headers: { Authorization: "Bearer " + accessToken, "Content-Type": "application/json" },
    body: JSON.stringify({ raw }),
  });
  if (!res.ok) { console.error("Gmail send error:", await res.text()); return false; }
  return true;
}

exports.submitPublicBooking = onRequest(
  { region: "us-central1", cors: BOOKING_ALLOWED_ORIGINS, memory: "256MiB",
    secrets: [GCAL_CLIENT_SECRET, ROUTES_API_KEY] },
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
      const vehicleType = (s(b.vehicleType) === "van") ? "van" : "taxi";
      const email = s(b.email), flight = s(b.flight), note = s(b.note);
      const lang = s(b.lang) || "el";

      // Συντεταγμένες (αν επιλέχθηκαν από autocomplete/χάρτη)
      const num = (v) => (v == null || v === "" || isNaN(Number(v))) ? null : Number(v);
      const fromLat = num(b.fromLat), fromLng = num(b.fromLng);
      const toLat = num(b.toLat), toLng = num(b.toLng);

      // ── Έλεγχος μπλάκαουτ/ελάχιστης προθεσμίας/μεγάλης παραγγελίας/εκτός
      //    Αττικής — ελέγχεται ΚΑΙ εδώ (όχι μόνο client-side): ένα POST
      //    απευθείας στο API δεν μπορεί να προσπεράσει τους κανόνες.
      const scheduledNaive = athensNaiveFromDateTimeStrings(date, time);
      const simNaive = athensNaiveDate(new Date());
      const gateReasons = computeGate(simNaive, scheduledNaive, persons, luggage);

      // Έλληνας/ξένος πελάτης: πρώτα η γλώσσα σελίδας, δεύτερο fallback ο
      // κωδικός χώρας του τηλεφώνου.
      const dialCode = (phone.match(/^\+\d+/) || [""])[0];
      const isGreek = lang === "el" ? true : dialCode === "+30";

      const estimate = await computeEstimate({
        fromLat, fromLng, toLat, toLng, persons, luggage, childSeatCount,
        vehicleType, isGreek, scheduledNaive, apiKey: ROUTES_API_KEY.value(),
      });
      if (estimate.outsideAttica && !gateReasons.includes("outside_attica")) {
        gateReasons.push("outside_attica");
      }
      if (gateReasons.length) {
        return res.status(400).json({ ok: false, error: "outside_booking_window", reasons: gateReasons });
      }

      const masterUid = await findMasterUid();
      if (!masterUid) {
        console.error("submitPublicBooking: δεν βρέθηκε master");
        return res.status(500).json({ ok: false, error: "no_master" });
      }
      const me = await getFirestore().collection("presence").doc(masterUid).get();
      const masterName = (me.exists && me.data().name) ? me.data().name : "Master";

      // Ραντεβού σε ώρα Ελλάδας → JS Date.
      // Το date/time έρχονται ως τοπική ώρα Ελλάδας. Φτιάχνουμε ISO με offset.
      // (Απλό & ασφαλές: θεωρούμε Europe/Athens. Για ακρίβεια DST, ο master
      //  βλέπει ούτως ή άλλως το ραντεβού στην εφαρμογή πριν στείλει.)
      const scheduledIso = date + "T" + time + ":00";
      const scheduledAtMs = Date.parse(scheduledIso); // local-naive → ms (UTC approx)
      const startDate = isNaN(scheduledAtMs) ? new Date() : new Date(scheduledAtMs);

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
      const savedRef = await getFirestore().collection("saved_jobs").add({
        origin:         "public_form",   // ← ΣΗΜΑΔΙ «ΑΠΟ ΦΟΡΜΑ»
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
        vehicleType:    vehicleType,     // 'taxi' | 'van'
        note:           fullNote,
        price:          estimate.price,   // υπολογισμένη τιμή (ζώνη ή δυναμικός τύπος)
        scheduledAt:    Timestamp.fromDate(startDate),  // ραντεβού (Job.fromDoc)
        lang:           lang,
        ownerUid:       masterUid,
        ownerName:      masterName,
        savedAt:        FieldValue.serverTimestamp(),
        createdAt:      FieldValue.serverTimestamp(),
      });

      // ── 2) Email + .ics στον master ────────────────────────────────────────
      const summary = "🚕 Νέα κράτηση: " + from + " → " + to;
      const whenStr = date + " " + time;
      const emailBody =
        "Νέα κράτηση από τη φόρμα της ιστοσελίδας.\n\n" +
        "Διαδρομή: " + from + " → " + to + "\n" +
        "Ραντεβού: " + whenStr + "\n" +
        "Πελάτης: " + name + " (" + phone + ")\n" +
        (email ? "Email: " + email + "\n" : "") +
        (flight ? "Πτήση/Πλοίο: " + flight + "\n" : "") +
        "Άτομα: " + persons + " · Βαλίτσες: " + luggage +
        (childSeatCount ? " · Παιδικά καθίσματα: " + childSeatCount : "") + "\n" +
        "Όχημα: " + (vehicleType === "van" ? "Βαν" : "Ταξί") + "\n" +
        (note ? "Σχόλια: " + note + "\n" : "") +
        "\nΗ δουλειά αποθηκεύτηκε στις «Αποθηκευμένες» της εφαρμογής.";

      const ics = buildIcs({
        from, to, startDate, durationMin: 60,
        summary, description: emailBody,
      });

      // Email στον master. (toEmail: το email του master)
      const masterEmail = (me.exists && me.data().email) ? me.data().email : "techtacy@gmail.com";
      sendBookingEmail(masterUid, masterEmail, summary, emailBody, ics)
        .catch((e) => console.error("booking email failed:", e));

      // ── 3) FCM στον master (ξεχωριστό type/εικονίδιο) ──────────────────────
      try {
        const tokens = await getMasterTokens();
        await sendDataOnly(tokens, {
          type:       "public_booking",          // ← το owner_alerts το ξεχωρίζει
          savedJobId: savedRef.id,
          from, to,
          clientName: name,
          when:       whenStr,
          title:      "Νέα κράτηση από φόρμα",
          body:       from + " → " + to + " · " + name,
        });
      } catch (e) {
        console.error("booking FCM failed:", e);
      }

      return res.status(200).json({ ok: true, id: savedRef.id });
    } catch (e) {
      console.error("submitPublicBooking error:", e);
      return res.status(500).json({ ok: false, error: "server_error" });
    }
  }
);
