// lib/jobs/job_service.dart

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'client_model.dart';
import 'job_model.dart';
import 'saved_job_service.dart';

class JobService {
  static final _fs      = FirebaseFirestore.instance;
  static const _jobs    = 'jobs';
  static const _sources = 'sources';

  // ─── Jobs ─────────────────────────────────────────────────────────────────

  // Stream ανοιχτών δουλειών (για τον οδηγό).
  //
  // • Δείχνει μια δουλειά μόνο αν φτάνει στον οδηγό στο ΤΡΕΧΟΝ στάδιο
  //   κλιμάκωσης (δες Job.reachesDriver) — ομάδα, συγκεκριμένοι οδηγοί ή όλοι.
  // • Επανεκπέμπει κάθε 20s ώστε όταν αλλάζει στάδιο να εμφανίζεται η δουλειά
  //   σε οδηγούς που είχαν φιλτραριστεί πριν.
  static Stream<List<Job>> openJobsFor({
    required String       uid,
    required String       vehicleType,
    required List<String> groupIds,
  }) {
    late StreamController<List<Job>> controller;
    StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? sub;
    Timer? ticker;
    List<Job> latestRaw = const [];

    void emit() {
      if (controller.isClosed) return;
      final filtered = latestRaw.where((j) {
        // Τύπος οχήματος
        if (j.vehicleType != 'any' && j.vehicleType != vehicleType) {
          return false;
        }
        // Οριστικά ληγμένη → έξω από τη λίστα
        if (j.isPastDeadline) return false;
        // Σταματημένη / μη ανοιχτή / εκτός τρέχοντος σταδίου → δεν φτάνει
        return j.reachesDriver(uid: uid, groupIds: groupIds);
      }).toList();
      controller.add(filtered);
    }

    controller = StreamController<List<Job>>(
      onListen: () {
        sub = _fs
            .collection(_jobs)
            .where('status', isEqualTo: JobStatus.open.name)
            .orderBy('createdAt', descending: true)
            .snapshots()
            .listen((snap) {
          latestRaw = snap.docs.map((d) => Job.fromDoc(d)).toList();
          emit();
        });
        // Επανεκτίμηση κάθε 20s ώστε να πιάνουμε νέα isTimedOut transitions
        ticker = Timer.periodic(const Duration(seconds: 20), (_) => emit());
      },
      onCancel: () async {
        await sub?.cancel();
        ticker?.cancel();
        ticker = null;
      },
    );

    return controller.stream;
  }

  /// Όταν τελειώσει ο χρόνος ενός σταδίου → προχώρα στο επόμενο στάδιο
  /// κλιμάκωσης με ΦΡΕΣΚΟ χρόνο. Race-safe (transaction) — το προχωράει
  /// μόνο ο πρώτος client που θα το πιάσει.
  static Future<void> autoAdvanceStageIfNeeded(Job job) async {
    if (!job.needsStageAdvance) return;
    final ref = _fs.collection(_jobs).doc(job.id);
    try {
      await _fs.runTransaction((tx) async {
        final snap = await tx.get(ref);
        if (!snap.exists) return;
        final fresh = Job.fromDoc(snap);
        if (fresh.status != JobStatus.open) return;
        if (fresh.stopped) return;
        if (!fresh.needsStageAdvance) return; // κάποιος άλλος το προχώρησε ήδη
        tx.update(ref, {
          'escalationStage': fresh.escalationStage + 1,
          'stageStartedAt':  FieldValue.serverTimestamp(),
        });
      });
    } catch (_) {}
  }

  /// Όταν τελειώσει το ΤΕΛΕΥΤΑΙΟ στάδιο χωρίς να την πάρει κανείς → μαρκάρει
  /// τη δουλειά ως expired. Race-safe (transaction): το γράφει μόνο ο πρώτος
  /// client (admin) που θα το πιάσει — μετά μια Cloud Function ειδοποιεί τον
  /// owner. Καλείται από το admin ticker (η ίδια λογική με το stage advance).
  static Future<void> markExpiredIfNeeded(Job job) async {
    if (!job.isPastDeadline) return; // τελευταίο στάδιο & έληξε ο χρόνος
    final ref = _fs.collection(_jobs).doc(job.id);
    try {
      await _fs.runTransaction((tx) async {
        final snap = await tx.get(ref);
        if (!snap.exists) return;
        final fresh = Job.fromDoc(snap);
        // Μόνο αν είναι ακόμη open, δεν είναι σταματημένη, και όντως έληξε.
        if (fresh.status != JobStatus.open) return;
        if (fresh.stopped) return;
        if (fresh.needsStageAdvance) return; // υπάρχει κι άλλο στάδιο
        if (!fresh.isPastDeadline) return;   // κάποιος άλλος το χειρίστηκε ήδη
        tx.update(ref, {'status': JobStatus.expired.name});
      });
    } catch (_) {}
  }

  /// ΣΤΟΠ: ο admin σταματά το χτύπημα & την κλιμάκωση μιας δουλειάς.
  /// Η δουλειά παραμένει ανοιχτή & ορατή στις ανοιχτές δουλειές του admin
  /// (για επεξεργασία ή διαγραφή), αλλά δεν χτυπάει πουθενά αλλού.
  static Future<void> stopJob(String jobId) async {
    await _fs.collection(_jobs).doc(jobId).update({'stopped': true});
  }

  // Stream για admin — όλες οι δουλειές
  static Stream<List<Job>> allJobs({int limit = 50}) {
    return _fs
        .collection(_jobs)
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((snap) => snap.docs.map((d) => Job.fromDoc(d)).toList());
  }

  // Δημιουργία νέας δουλειάς
  static Future<String> createJob(Job job) async {
    final ref = await _fs.collection(_jobs).add(job.toMap());
    return ref.id;
  }

  /// Δημιουργεί ΠΟΛΛΕΣ δουλειές μαζί (από αποθηκευμένες) σε ΕΝΑΝ συγκεκριμένο
  /// οδηγό, αποκλειστικά, μοιράζοντάς τους κοινό batchId ώστε ο οδηγός να τις
  /// δει ως μία λίστα με «Αποδοχή όλων». Κάθε δουλειά παραμένει ΞΕΧΩΡΙΣΤΗ
  /// εγγραφή (σωστό billing/ιστορικό), σαν να τις πήρε μία-μία.
  /// Επιστρέφει το batchId.
  static Future<String> createBatchToDriver({
    required List<Job>  jobs,
    required String     driverUid,
    required String     driverName,
  }) async {
    final batchId = _fs.collection(_jobs).doc().id; // τυχαίο μοναδικό id
    final wb = _fs.batch();
    double total = 0;
    String? vType;
    for (final j in jobs) {
      final ref = _fs.collection(_jobs).doc();
      final map = j.toMap();
      // Επιβολή: αποκλειστική αποστολή σε αυτόν τον 1 οδηγό
      map['targetUids']      = [driverUid];
      map['targetNames']     = [driverName];
      map['groupId']         = null;
      map['exclusiveTarget'] = true;
      map['status']          = JobStatus.open.name;
      map['batchId']         = batchId;
      map['takenBy']         = null;
      map['takenByName']     = null;
      map['escalationStage'] = 0;
      map['stopped']         = false;
      // ΦΡΕΣΚΟΙ χρόνοι — αλλιώς κρατά το stageStartedAt της ώρας αποθήκευσης
      // του draft και η δουλειά γεννιέται ήδη "ληγμένη".
      map['createdAt']       = FieldValue.serverTimestamp();
      map['stageStartedAt']  = FieldValue.serverTimestamp();
      wb.set(ref, map);
      total += j.price;
      vType ??= j.vehicleType;
    }
    // Ένα doc batch → ΜΙΑ ομαδική ειδοποίηση (αντί για N μεμονωμένες).
    // Ο Cloud Function trigger 'onBatchCreated' το διαβάζει & ειδοποιεί 1 φορά.
    final batchRef = _fs.collection('job_batches').doc(batchId);
    wb.set(batchRef, {
      'driverUid':   driverUid,
      'driverName':  driverName,
      'count':       jobs.length,
      'totalPrice':  total,
      'vehicleType': vType ?? 'any',
      'createdAt':   FieldValue.serverTimestamp(),
    });
    await wb.commit();
    return batchId;
  }

  /// Στέλνει ΠΟΛΛΕΣ αποθηκευμένες δουλειές προς ομάδα/όλους/πολλούς οδηγούς.
  /// Κάθε δουλειά βγαίνει ΞΕΧΩΡΙΣΤΑ, μία-μία (κανονική διαδικασία, χωρίς batchId).
  /// Ο παραλήπτης που δίνεται εδώ ΥΠΕΡΙΣΧΥΕΙ ό,τι είχε αποθηκευτεί στη φόρμα.
  ///   • groupId != null      → προς συγκεκριμένη ομάδα
  ///   • targetUids μη κενό    → προς συγκεκριμένους οδηγούς (πολλούς)
  ///   • και τα δύο null/κενά  → προς όλους
  static Future<void> sendDraftsToAudience({
    required List<Job>   jobs,
    String?              groupId,
    List<String>         targetUids  = const [],
    List<String>         targetNames = const [],
    bool                 exclusive   = false,
  }) async {
    final wb = _fs.batch();
    for (final j in jobs) {
      final ref = _fs.collection(_jobs).doc();
      final map = j.toMap();
      map['groupId']         = targetUids.isEmpty ? groupId : null;
      map['targetUids']      = targetUids;
      map['targetNames']     = targetNames;
      map['exclusiveTarget'] = exclusive;
      map['status']          = JobStatus.open.name;
      map['takenBy']         = null;
      map['takenByName']     = null;
      map['escalationStage'] = 0;
      map['stopped']         = false;
      // ΦΡΕΣΚΟΙ χρόνοι (όπως νέα δουλειά) — αλλιώς κρατά τους χρόνους του draft.
      map['createdAt']       = FieldValue.serverTimestamp();
      map['stageStartedAt']  = FieldValue.serverTimestamp();
      map.remove('batchId'); // καμία ομαδοποίηση εδώ
      wb.set(ref, map);
    }
    await wb.commit();
  }

  /// ΞΑΝΑΣΤΕΙΛΕ ΟΛΕΣ: επαναφέρει μια ομάδα αδιεκδίκητων δουλειών «από την αρχή»
  /// (στάδιο 0, φρέσκος χρόνος, όχι σταματημένες). Χρησιμοποιείται για το
  /// κουμπί «Ξαναστείλε όλες» στις Ανοιχτές. Δεν αλλάζει παραλήπτη — ξαναβγαίνουν
  /// όπως ήταν (batch σε 1 οδηγό, ομάδα, ή όλους).
  static Future<void> resendJobs(List<String> jobIds) async {
    if (jobIds.isEmpty) return;
    final wb = _fs.batch();
    for (final id in jobIds) {
      wb.update(_fs.collection(_jobs).doc(id), {
        'status':          JobStatus.open.name,
        'stopped':         false,
        'escalationStage': 0,
        'stageStartedAt':  FieldValue.serverTimestamp(),
        'takenBy':         null,
        'takenByName':     null,
        'takenAt':         null,
      });
    }
    await wb.commit();
  }

  /// AUTO-RETURN: παίρνει αδιεκδίκητες δουλειές που έληξαν οριστικά (πέρασαν
  /// όλα τα στάδια & ο χρόνος), τις ΣΒΗΝΕΙ από τα jobs και τις ΕΠΑΝΑΦΕΡΕΙ στις
  /// «Αποθηκευμένες», ώστε ο admin να τις ξαναστείλει όποτε θέλει.
  ///
  /// ΑΣΦΑΛΕΣ ΓΙΑ BILLING: αδιεκδίκητη δουλειά δεν έχει χρεωθεί τίποτα (γιαούρτι/
  /// προμήθεια χρεώνονται μόνο στο completeJob), οπότε η επαναφορά δεν επηρεάζει
  /// οικονομικές εγγραφές.
  ///
  /// Επιστρέφει πόσες επαναφέρθηκαν. Καλείται από τον admin client όταν βλέπει
  /// τις Ανοιχτές — μία φορά ανά εμφάνιση ληγμένων (όχι σε κάθε tick).
  /// Διαγράφει οριστικά ΑΝΟΙΧΤΑ ραντεβού των οποίων η ώρα πέρασε >1 ώρα και
  /// δεν τα ανέλαβε κανείς οδηγός. Σε αντίθεση με το returnExpiredToSaved (που
  /// επαναφέρει στις «Αποθηκευμένες»), εδώ η δουλειά φεύγει εντελώς — δεν έχει
  /// νόημα να κρατηθεί draft για ραντεβού που πέρασε.
  ///
  /// Επιστρέφει πόσες διαγράφηκαν. Το transaction επαναβεβαιώνει μέσα του ότι η
  /// δουλειά είναι ακόμη ανοιχτή & ληγμένη (αποφυγή race αν κάποιος μόλις την
  /// πήρε ή την επεξεργάστηκε).
  static Future<int> deleteStaleSchedules(List<Job> stale) async {
    if (stale.isEmpty) return 0;
    int deleted = 0;
    for (final j in stale) {
      try {
        await _fs.runTransaction((tx) async {
          final ref  = _fs.collection(_jobs).doc(j.id);
          final snap = await tx.get(ref);
          if (!snap.exists) return;
          final fresh = Job.fromDoc(snap);
          if (!fresh.isStaleSchedule) return; // ξαναελέγχουμε με φρέσκα δεδομένα
          tx.delete(ref);
        });
        deleted++;
      } catch (_) {/* αγνόησε — θα ξαναπροσπαθήσει στο επόμενο φόρτωμα */}
    }
    return deleted;
  }

  static Future<int> returnExpiredToSaved(List<Job> expired) async {
    if (expired.isEmpty) return 0;
    int moved = 0;
    for (final j in expired) {
      try {
        bool deleted = false;
        await _fs.runTransaction((tx) async {
          final ref  = _fs.collection(_jobs).doc(j.id);
          final snap = await tx.get(ref);
          if (!snap.exists) return;
          final fresh = Job.fromDoc(snap);
          // Επαναβεβαίωση μέσα στο transaction (μπορεί κάποιος να την πήρε)
          if (fresh.status != JobStatus.open) return;
          if (fresh.stopped) return;
          if (!fresh.isPastDeadline) return;
          tx.delete(ref);
          deleted = true;
        });
        // Αν διαγράφηκε, αποθήκευσέ την ως draft
        if (deleted) {
          await SavedJobService.save(
            j,
            ownerUid:  j.createdBy,
            ownerName: j.createdByName,
          );
          moved++;
        }
      } catch (_) {/* αγνόησε — θα ξαναπροσπαθήσει στο επόμενο φόρτωμα */}
    }
    return moved;
  }
  static Future<bool> takeJob({
    required String jobId,
    required String uid,
    required String name,
  }) async {
    final ref = _fs.collection(_jobs).doc(jobId);
    return _fs.runTransaction<bool>((tx) async {
      final snap = await tx.get(ref);
      if (!snap.exists) return false;
      final job = Job.fromDoc(snap);
      if (!job.isOpen) return false;
      tx.update(ref, {
        'status':      JobStatus.taken.name,
        'takenBy':     uid,
        'takenByName': name,
        'takenAt':     FieldValue.serverTimestamp(),
      });
      return true;
    });
  }

  // Ο οδηγός πάτησε «Επιβίβασα» — η δουλειά περνά από taken σε boarded.
  static Future<void> markBoarded(String jobId) async {
    final ref = _fs.collection(_jobs).doc(jobId);
    await _fs.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (!snap.exists) return;
      final job = Job.fromDoc(snap);
      if (job.status != JobStatus.taken) return; // μόνο από taken
      tx.update(ref, {
        'status':    JobStatus.boarded.name,
        'boardedAt': FieldValue.serverTimestamp(),
      });
    });
  }

  // Τρέχον κλειδί μήνα 'YYYY-MM'
  static String _monthKey([DateTime? dt]) {
    final d = dt ?? DateTime.now();
    return '${d.year}-${d.month.toString().padLeft(2, '0')}';
  }

  // ─── Recipient / Collector ────────────────────────────────────────────────
  // Σε ποιον ΑΝΗΚΟΥΝ τα app/συνδρομή λεφτά (κεντρικά).
  static const String kMasterRecipient = 'MASTER';

  /// Διαβάζει το όνομα ενός admin/οδηγού από το presence (για ετικέτες).
  static Future<String> _nameOf(String uid) async {
    if (uid.isEmpty) return '';
    try {
      final d = (await _fs.collection('presence').doc(uid).get()).data();
      if (d == null) return '';
      return '${d['displayName'] ?? ''} ${d['lastName'] ?? ''}'.trim();
    } catch (_) {
      return '';
    }
  }

  /// Ο admin (collector) που μαζεύει φυσικά από τον οδηγό για ΑΥΤΗ τη δουλειά.
  /// Κανόνας:
  ///   • δουλειά ομάδας στην οποία ΑΝΗΚΕΙ ο οδηγός  → admin εκείνης της ομάδας
  ///   • αλλιώς (εκτός ομάδας/broadcast)            → admin της ΣΠΙΤΙΚΗΣ ομάδας
  ///   • οδηγός χωρίς καμία ομάδα                    → ο poster της δουλειάς
  /// Επιστρέφει {uid, name}.
  static Future<Map<String, String>> _resolveCollector({
    required String driverUid,
    required String jobGroupId,
    required String posterUid,
    required String posterName,
  }) async {
    try {
      final presence =
          (await _fs.collection('presence').doc(driverUid).get()).data();
      final homeGroupId = (presence?['homeGroupId'] as String?) ?? '';

      // Ομάδες στις οποίες ανήκει ο οδηγός
      final groupsSnap = await _fs.collection('groups').get();
      final driverGroups = <String, Map<String, dynamic>>{};
      for (final g in groupsSnap.docs) {
        final members = List<String>.from(g.data()['memberUids'] ?? []);
        if (members.contains(driverUid)) driverGroups[g.id] = g.data();
      }

      String? pick;
      if (jobGroupId.isNotEmpty && driverGroups.containsKey(jobGroupId)) {
        pick = jobGroupId;                       // δουλειά ομάδας του οδηγού
      } else if (homeGroupId.isNotEmpty &&
          driverGroups.containsKey(homeGroupId)) {
        pick = homeGroupId;                      // εκτός ομάδας → σπιτική
      } else if (driverGroups.isNotEmpty) {
        pick = driverGroups.keys.first;          // fallback: 1η ομάδα
      }

      if (pick != null) {
        final g = driverGroups[pick]!;
        var adminUid = (g['createdBy'] as String?) ?? '';
        if (adminUid.isEmpty) {
          final admins = List<String>.from(g['adminUids'] ?? []);
          if (admins.isNotEmpty) adminUid = admins.first;
        }
        if (adminUid.isNotEmpty) {
          return {'uid': adminUid, 'name': await _nameOf(adminUid)};
        }
      }
    } catch (_) {}
    // Χωρίς ομάδα → ο poster μαζεύει
    return {'uid': posterUid, 'name': posterName};
  }

  /// Ορίζει τη ΣΠΙΤΙΚΗ ομάδα ενός οδηγού (1η φορά που μπαίνει σε ομάδα).
  /// Δεν την αλλάζει αν υπάρχει ήδη.
  static Future<void> ensureHomeGroup(String uid, String groupId) async {
    if (uid.isEmpty || groupId.isEmpty) return;
    try {
      final ref = _fs.collection('presence').doc(uid);
      final cur = (await ref.get()).data()?['homeGroupId'] as String?;
      if (cur == null || cur.isEmpty) {
        await ref.set({'homeGroupId': groupId}, SetOptions(merge: true));
      }
    } catch (_) {}
  }

  /// Διαγράφει ΠΛΗΡΩΣ έναν χρήστη από την εφαρμογή:
  ///  • presence doc
  ///  • συμμετοχές & ρόλους σε ΟΛΕΣ τις ομάδες (memberUids/adminUids, createdBy)
  ///  • τις δικές του εγγραφές billing (χρεώσεις/πληρωμές)
  /// ΣΗΜ.: ο λογαριασμός Firebase Auth ΔΕΝ διαγράφεται από τον client —
  /// αυτό απαιτεί Firebase Console ή Cloud Function (admin SDK).
  static Future<void> deleteUserCompletely(String uid) async {
    if (uid.isEmpty) return;

    // 1. Ομάδες — αφαίρεση από μέλη/admins, καθάρισμα createdBy
    try {
      final groups = await _fs.collection('groups').get();
      final batch  = _fs.batch();
      var writes   = 0;
      for (final g in groups.docs) {
        final members = List<String>.from(g.data()['memberUids'] ?? []);
        final admins  = List<String>.from(g.data()['adminUids']  ?? []);
        final upd     = <String, dynamic>{};
        if (members.remove(uid)) upd['memberUids'] = members;
        if (admins.remove(uid))  upd['adminUids']  = admins;
        if ((g.data()['createdBy'] as String?) == uid) upd['createdBy'] = '';
        if (upd.isNotEmpty) {
          batch.update(g.reference, upd);
          writes++;
        }
      }
      if (writes > 0) await batch.commit();
    } catch (_) {}

    // 2. Billing του χρήστη (δικές του χρεώσεις/πληρωμές)
    try {
      final txs = await _fs
          .collection(_billingTx)
          .where('uid', isEqualTo: uid)
          .get();
      var batch = _fs.batch();
      var n     = 0;
      for (final d in txs.docs) {
        batch.delete(d.reference);
        n++;
        if (n >= 400) { await batch.commit(); batch = _fs.batch(); n = 0; }
      }
      if (n > 0) await batch.commit();
    } catch (_) {}

    // 3. Presence
    try {
      await _fs.collection('presence').doc(uid).delete();
    } catch (_) {}
  }

  // Ολοκλήρωση δουλειάς
  //
  // ΑΛΛΑΓΗ (server-side billing): Ο client πλέον γράφει ΜΟΝΟ status:done +
  // doneAt. Όλο το billing (turnover/appDebt/billing_tx, collector, γιαούρτι,
  // προμήθεια App) το αναλαμβάνει ο Cloud Function trigger `onJobBilling`,
  // που πυροδοτείται στη μετάβαση → "done".
  //
  // ΓΙΑΤΙ: (1) Ασφάλεια — ο οδηγός δεν γράφει πια ο ίδιος το χρέος του.
  //        (2) Offline — αυτό το write μπαίνει σε ουρά του Firestore SDK και
  //            συγχρονίζεται μόλις επανέλθει το σήμα· ο trigger τρέχει τότε.
  static Future<void> completeJob(String jobId) async {
    final ref = _fs.collection(_jobs).doc(jobId);
    await ref.update({
      'status': JobStatus.done.name,
      'doneAt': FieldValue.serverTimestamp(),
    });
  }

  // ─── ΠΑΛΙΟ client-side billing (ΑΝΕΝΕΡΓΟ — διατηρείται μόνο ως αναφορά) ──────
  // Αντικαταστάθηκε από τον trigger onJobBilling. ΜΗΝ το καλείς.
  // ignore: unused_element
  static Future<void> _legacyCompleteJobBilling(String jobId) async {
    final ref = _fs.collection(_jobs).doc(jobId);

    // Προ-ανάγνωση για υπολογισμό collector (χρειάζεται reads ομάδων/presence)
    Job? pre;
    try {
      final s = await ref.get();
      if (s.exists) pre = Job.fromDoc(s);
    } catch (_) {}

    var collector = const {'uid': '', 'name': ''};
    bool driverIsMaster = false;
    if (pre != null && pre.takenBy != null && pre.takenBy!.isNotEmpty) {
      collector = await _resolveCollector(
        driverUid:  pre.takenBy!,
        jobGroupId: pre.groupId ?? '',
        posterUid:  pre.createdBy,
        posterName: pre.createdByName,
      );
      try {
        final pdoc =
            await _fs.collection('presence').doc(pre.takenBy!).get();
        driverIsMaster = (pdoc.data()?['master'] as bool?) ?? false;
      } catch (_) {}
    }

    await _fs.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (!snap.exists) return;
      final job = Job.fromDoc(snap);
      tx.update(ref, {
        'status': JobStatus.done.name,
        'doneAt': FieldValue.serverTimestamp(),
      });

      final driverUid = job.takenBy;
      if (driverUid == null || driverUid.isEmpty) return;

      final monthKey = _monthKey();

      // Ποιες προμήθειες ΧΡΕΩΝΟΝΤΑΙ πραγματικά στον οδηγό:
      //  • Προμήθεια πηγής (γιαούρτι): παραλείπεται μόνο αν ο οδηγός πήρε
      //    δική του δουλειά (θα χρωστούσε στον εαυτό του). Αν ανήκει σε άλλον
      //    admin ή σε πηγή (π.χ. Χιλτον), χρεώνεται κανονικά — ακόμη & ο master.
      //  • Προμήθεια App: παραλείπεται για τον master (ανήκει σ' αυτόν).
      final selfPosted     = job.createdBy == driverUid;
      final chargeSource   = job.commission    > 0 && !selfPosted;
      final chargeApp      = job.appCommission > 0 && !driverIsMaster;
      final billedTotal    = (chargeSource ? job.commission    : 0.0) +
                             (chargeApp    ? job.appCommission : 0.0);

      // Running totals: τζίρος (πάντα) + χρέος (μόνο ό,τι χρεώνεται όντως)
      final driverRef = _fs.collection('presence').doc(driverUid);
      tx.update(driverRef, {
        'turnover': FieldValue.increment(job.price),
        if (billedTotal > 0) 'appDebt': FieldValue.increment(billedTotal),
      });

      if (billedTotal <= 0) return;

      // Κοινά πεδία billing
      final base = {
        'uid':        driverUid,
        'uidName':    job.takenByName ?? '',
        'monthKey':   monthKey,
        'type':       'charge',
        'sourceId':   job.sourceId   ?? '',
        'sourceName': job.sourceName ?? 'Standard Rate',
        'adminUid':   job.createdBy,
        'adminName':  job.createdByName,
        'collectorUid':  collector['uid'],
        'collectorName': collector['name'],
        'jobId':      jobId,
        'note':       '${job.from} → ${job.to}',
        'voided':     false,
        'createdAt':  FieldValue.serverTimestamp(),
        'createdBy':  'SYSTEM',
      };

      // Προμήθεια πηγής (γιαούρτι) → ανήκει στον poster της δουλειάς
      if (chargeSource) {
        tx.set(_fs.collection(_billingTx).doc(), {
          ...base,
          'category':      'source_commission',
          'amount':        job.commission,
          'recipientUid':  job.createdBy,
          'recipientName': job.createdByName,
        });
      }
      // Προμήθεια App → ανήκει κεντρικά στον master (όχι για τον ίδιο τον master)
      if (chargeApp) {
        tx.set(_fs.collection(_billingTx).doc(), {
          ...base,
          'category':      'app_commission',
          'amount':        job.appCommission,
          'recipientUid':  kMasterRecipient,
          'recipientName': 'Master',
        });
      }
    });
  }

  // Ακύρωση δουλειάς — αναιρεί και τις χρεώσεις/τζίρο του οδηγού
  static Future<void> cancelJob(String jobId) async {
    final jobRef = _fs.collection(_jobs).doc(jobId);
    // Διάβασε τη δουλειά για τζίρο/οδηγό
    Job? job;
    try {
      final jdoc = await jobRef.get();
      if (jdoc.exists) job = Job.fromDoc(jdoc);
    } catch (_) {}

    // 1. Αναίρεση billing χρεώσεων αυτής της δουλειάς + τζίρου
    try {
      final charges = await _fs
          .collection(_billingTx)
          .where('jobId', isEqualTo: jobId)
          .get();
      final batch = _fs.batch();
      // Ομαδοποίηση επιστροφών ανά οδηγό
      final refund = <String, double>{};
      for (final d in charges.docs) {
        final data = d.data();
        if (data['voided'] == true) continue;
        if (data['type'] == 'payment') continue; // πληρωμές δεν αναιρούνται
        final uid    = data['uid'] as String? ?? '';
        final amount = (data['amount'] as num?)?.toDouble() ?? 0;
        if (data['type'] == 'charge') {
          refund[uid] = (refund[uid] ?? 0) + amount;
        }
        batch.update(d.reference, {'voided': true});
      }
      refund.forEach((uid, amount) {
        if (uid.isEmpty || amount <= 0) return;
        batch.update(_fs.collection('presence').doc(uid),
            {'appDebt': FieldValue.increment(-amount)});
      });
      // Αφαίρεση τζίρου αν η δουλειά είχε ολοκληρωθεί
      if (job != null &&
          job.status == JobStatus.done &&
          job.takenBy != null && job.takenBy!.isNotEmpty) {
        batch.update(_fs.collection('presence').doc(job.takenBy), {
          'turnover': FieldValue.increment(-job.price),
        });
      }
      await batch.commit();
    } catch (_) {}

    // 2. Σήμανση δουλειάς ως ακυρωμένης
    await jobRef.update({
      'status':        JobStatus.cancelled.name,
      'cancelledAt':   FieldValue.serverTimestamp(),
      'takenBy':       null,
      'takenByName':   null,
      'takenAt':       null,
      'doneAt':        null,
      'commission':    0,
      'appCommission': 0,
    });
  }

  // Επανέκδοση — reset για νέα διεκδίκηση από την αρχή της κλιμάκωσης
  static Future<void> reopenJob(String jobId) async {
    await _fs.collection(_jobs).doc(jobId).update({
      'status':          JobStatus.open.name,
      'takenBy':         null,
      'takenByName':     null,
      'takenAt':         null,
      'doneAt':          null,
      'cancelledAt':     null,
      'stopped':         false,
      'escalationStage': 0,
      'stageStartedAt':  FieldValue.serverTimestamp(),
      'createdAt':       FieldValue.serverTimestamp(),
    });
  }

  // Λήξη δουλειάς
  static Future<void> expireJob(String jobId) async {
    await _fs.collection(_jobs).doc(jobId).update({
      'status': JobStatus.expired.name,
    });
  }

  // Διαγραφή δουλειάς (μόνο admin)
  static Future<void> deleteJob(String jobId) async {
    await _fs.collection(_jobs).doc(jobId).delete();
  }

  /// ΟΛΙΚΗ ΔΙΑΓΡΑΦΗ δουλειάς από το ιστορικό — ΜΟΝΟ master.
  ///
  /// Σε αντίθεση με την ακύρωση (που κρατάει τη δουλειά ορατή ως
  /// «ΑΚΥΡΩΜΕΝΗ»), η ολική διαγραφή εξαφανίζει εντελώς τη δουλειά:
  ///   • αναιρεί τζίρο & χρέος του οδηγού στο presence
  ///   • διαγράφει ΟΛΕΣ τις εγγραφές billing_tx της δουλειάς
  ///   • διαγράφει το ίδιο το έγγραφο της δουλειάς
  /// Έτσι φεύγει τελείως από τα στατιστικά και το μενού «Χρεώσεις».
  static Future<void> purgeJob(String jobId) async {
    final jobRef = _fs.collection(_jobs).doc(jobId);

    // Διάβασε τη δουλειά (για τζίρο/οδηγό)
    Job? job;
    try {
      final jdoc = await jobRef.get();
      if (jdoc.exists) job = Job.fromDoc(jdoc);
    } catch (_) {}

    final batch = _fs.batch();

    // 1. Αναίρεση billing_tx + τζίρου/χρέους οδηγού
    try {
      final txs = await _fs
          .collection(_billingTx)
          .where('jobId', isEqualTo: jobId)
          .get();

      // Επιστροφή χρέους ανά οδηγό (μόνο από μη-ακυρωμένες χρεώσεις)
      final refund = <String, double>{};
      for (final d in txs.docs) {
        final data = d.data();
        if (data['type'] == 'charge' && data['voided'] != true) {
          final uid    = data['uid'] as String? ?? '';
          final amount = (data['amount'] as num?)?.toDouble() ?? 0;
          if (uid.isNotEmpty) {
            refund[uid] = (refund[uid] ?? 0) + amount;
          }
        }
        // Διαγραφή της εγγραφής billing (χρεώσεις & πληρωμές της δουλειάς)
        batch.delete(d.reference);
      }
      refund.forEach((uid, amount) {
        if (amount <= 0) return;
        batch.update(_fs.collection('presence').doc(uid),
            {'appDebt': FieldValue.increment(-amount)});
      });

      // Αφαίρεση τζίρου αν η δουλειά ήταν ολοκληρωμένη
      if (job != null &&
          job.status == JobStatus.done &&
          job.takenBy != null && job.takenBy!.isNotEmpty) {
        batch.update(_fs.collection('presence').doc(job.takenBy), {
          'turnover': FieldValue.increment(-job.price),
        });
      }
    } catch (_) {}

    // 2. Διαγραφή του εγγράφου της δουλειάς
    batch.delete(jobRef);

    try {
      await batch.commit();
    } catch (_) {
      // Fallback: σβήσε τουλάχιστον τη δουλειά
      try { await jobRef.delete(); } catch (_) {}
    }
  }

  // Ενημέρωση δουλειάς (μόνο open)
  static Future<void> updateJob(String jobId, Map<String, dynamic> data) async {
    await _fs.collection(_jobs).doc(jobId).update(data);
  }

  /// Ο MASTER διορθώνει τις χρεώσεις μιας ΟΛΟΚΛΗΡΩΜΕΝΗΣ δουλειάς από το
  /// ιστορικό: τιμή (τζίρος), προμήθεια πηγής (γιαούρτι), προμήθεια App.
  ///
  /// Συγχρονίζει αυτόματα:
  ///   • το έγγραφο της δουλειάς (price/commission/appCommission)
  ///   • τις εγγραφές billing_tx (γιαούρτι + App) → άρα και το μενού «Χρεώσεις»
  ///   • τον τζίρο & το χρέος του οδηγού στο presence
  static Future<void> editJobCharges({
    required String jobId,
    required double newPrice,
    required double newCommission,
    required double newAppCommission,
    String? newSourceId,
    String? newSourceName,
  }) async {
    final jobRef = _fs.collection(_jobs).doc(jobId);

    // Διάβασε την τρέχουσα δουλειά
    Job job;
    try {
      final jdoc = await jobRef.get();
      if (!jdoc.exists) return;
      job = Job.fromDoc(jdoc);
    } catch (_) {
      return;
    }
    // Επιτρέπεται μόνο σε ολοκληρωμένες δουλειές
    if (job.status != JobStatus.done) return;

    final driverUid  = job.takenBy;
    final oldPrice   = job.price;
    final oldComm    = job.commission;
    final oldAppComm = job.appCommission;

    // 1. Ενημέρωση του εγγράφου της δουλειάς
    await jobRef.update({
      'price':         newPrice,
      'commission':    newCommission,
      'appCommission': newAppCommission,
      // Αν ο master διάλεξε έτοιμη πηγή, ενημέρωσε & τα στοιχεία πηγής.
      'sourceId':   ?newSourceId,
      'sourceName': ?newSourceName,
    });

    if (driverUid == null || driverUid.isEmpty) return;

    // 2. Διόρθωση των billing_tx (γιαούρτι + App) της δουλειάς
    final batch = _fs.batch();

    // Υπολογισμός collector (για τυχόν νέες εγγραφές)
    var collector = const {'uid': '', 'name': ''};
    collector = await _resolveCollector(
      driverUid:  driverUid,
      jobGroupId: job.groupId ?? '',
      posterUid:  job.createdBy,
      posterName: job.createdByName,
    );

    try {
      final txs = await _fs
          .collection(_billingTx)
          .where('jobId', isEqualTo: jobId)
          .get();

      var hasSourceTx = false;
      var hasAppTx    = false;
      for (final d in txs.docs) {
        final data = d.data();
        if (data['voided'] == true) continue;
        if (data['type']   != 'charge') continue;
        final cat = data['category'];
        if (cat == 'source_commission') {
          hasSourceTx = true;
          batch.update(d.reference, {'amount': newCommission});
        } else if (cat == 'app_commission') {
          hasAppTx = true;
          batch.update(d.reference, {'amount': newAppCommission});
        }
      }

      // Κοινά πεδία για τυχόν νέες εγγραφές billing
      final base = {
        'uid':        driverUid,
        'uidName':    job.takenByName ?? '',
        'monthKey':   _monthKey(job.doneAt ?? job.createdAt),
        'type':       'charge',
        'sourceId':   newSourceId   ?? job.sourceId   ?? '',
        'sourceName': newSourceName ?? job.sourceName ?? 'Standard Rate',
        'adminUid':   job.createdBy,
        'adminName':  job.createdByName,
        'collectorUid':  collector['uid'],
        'collectorName': collector['name'],
        'jobId':      jobId,
        'note':       '${job.from} → ${job.to}',
        'voided':     false,
        'createdAt':  job.doneAt ?? job.createdAt,
        'createdBy':  'MASTER_EDIT',
      };

      // Αν δεν υπήρχε εγγραφή γιαουρτιού αλλά τώρα μπαίνει ποσό (θετικό Ή
      // αρνητικό) → δημιούργησέ τη. (Αρνητικό = πίστωση προς τον οδηγό.)
      if (!hasSourceTx && newCommission != 0) {
        batch.set(_fs.collection(_billingTx).doc(), {
          ...base,
          'category':      'source_commission',
          'amount':        newCommission,
          'recipientUid':  job.createdBy,
          'recipientName': job.createdByName,
        });
      }
      // Ομοίως για το App
      if (!hasAppTx && newAppCommission > 0) {
        batch.set(_fs.collection(_billingTx).doc(), {
          ...base,
          'category':      'app_commission',
          'amount':        newAppCommission,
          'recipientUid':  kMasterRecipient,
          'recipientName': 'Master',
        });
      }

      // 3. Διόρθωση τζίρου & χρέους του οδηγού (διαφορές)
      // Αρνητικό γιαούρτι προστίθεται στον τζίρο (ο οδηγός το εισέπραξε).
      // effPrice = price - min(commission, 0).
      double effPrice(double p, double c) => p - (c < 0 ? c : 0);
      final oldEff = effPrice(oldPrice, oldComm);
      final newEff = effPrice(newPrice, newCommission);
      final priceDelta = newEff - oldEff;
      final debtDelta  = (newCommission + newAppCommission) -
          (oldComm + oldAppComm);
      final updates = <String, dynamic>{};
      if (priceDelta != 0) {
        updates['turnover'] = FieldValue.increment(priceDelta);
      }
      if (debtDelta != 0) {
        updates['appDebt'] = FieldValue.increment(debtDelta);
      }
      if (updates.isNotEmpty) {
        batch.update(_fs.collection('presence').doc(driverUid), updates);
      }

      await batch.commit();
    } catch (_) {}
  }

  // ─── Sources ──────────────────────────────────────────────────────────────

  // Επιστρέφει πηγές. Αν δοθεί createdBy → δικές του + global (Standard Rate).
  // Χωρίς createdBy (master) → όλες.
  static Stream<List<JobSource>> sources({String? createdBy}) {
    return _fs
        .collection(_sources)
        .orderBy('name')
        .snapshots()
        .map((snap) {
      var all = snap.docs.map((d) => JobSource.fromDoc(d)).toList();
      if (createdBy != null && createdBy.isNotEmpty) {
        all = all
            .where((s) => s.createdBy == createdBy || s.isGlobal)
            .toList();
      }
      // Global πηγές (Standard Rate) πρώτες
      all.sort((a, b) {
        if (a.isGlobal && !b.isGlobal) return -1;
        if (!a.isGlobal && b.isGlobal) return 1;
        return a.name.compareTo(b.name);
      });
      return all;
    });
  }

  // ─── Clients (Πελάτες) ────────────────────────────────────────────────────
  static const _clients = 'clients';

  /// Stream πελατών.
  ///   • createdBy == null  → όλοι (master)
  ///   • createdBy != null  → μόνο οι δικοί του (admin)
  static Stream<List<Client>> clients({String? createdBy}) {
    return _fs
        .collection(_clients)
        .snapshots()
        .map((snap) {
      var all = snap.docs.map((d) => Client.fromDoc(d)).toList();
      if (createdBy != null && createdBy.isNotEmpty) {
        all = all.where((c) => c.createdBy == createdBy).toList();
      }
      all.sort((a, b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return all;
    });
  }

  /// Όλοι οι πελάτες που μπορεί να δει ο χρήστης — μία φορά (για auto-suggest).
  static Future<List<Client>> clientsOnce({String? createdBy}) async {
    final snap = await _fs.collection(_clients).get();
    var all = snap.docs.map((d) => Client.fromDoc(d)).toList();
    if (createdBy != null && createdBy.isNotEmpty) {
      all = all.where((c) => c.createdBy == createdBy).toList();
    }
    all.sort((a, b) =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return all;
  }

  static Future<String> createClient(Client client) async {
    final ref = await _fs.collection(_clients).add(client.toMap());
    return ref.id;
  }

  static Future<void> updateClient(String id, Client client) async {
    await _fs.collection(_clients).doc(id).update(client.toMap());
  }

  static Future<void> deleteClient(String id) async {
    await _fs.collection(_clients).doc(id).delete();
  }

  /// Πηγές για τα dropdown της φόρμας πελάτη (master: όλες, admin: δικές+global).
  static Future<List<JobSource>> clientsSourcesHelper({
    required bool   isMaster,
    required String adminUid,
  }) async {
    await ensureStandardRate();
    final snap = await _fs.collection(_sources).orderBy('name').get();
    var all = snap.docs.map((d) => JobSource.fromDoc(d)).toList();
    if (!isMaster) {
      all = all
          .where((s) => s.createdBy == adminUid || s.isGlobal)
          .toList();
    }
    all.sort((a, b) {
      if (a.isGlobal && !b.isGlobal) return -1;
      if (!a.isGlobal && b.isGlobal) return 1;
      return a.name.compareTo(b.name);
    });
    return all;
  }

  // ─── App Settings (global) ────────────────────────────────────────────────
  static const _settingsDoc = 'app_settings';

  /// Επιστρέφει τις global ρυθμίσεις {appCommission, subscription, calendarSubscription}.
  static Future<Map<String, double>> getAppSettings() async {
    try {
      final doc = await _fs.collection(_settingsDoc).doc('config').get();
      final d   = doc.data();
      return {
        'appCommission': (d?['appCommission'] as num?)?.toDouble() ?? 1.50,
        'subscription':  (d?['subscription']  as num?)?.toDouble() ?? 5.00,
        'calendarSubscription':
            (d?['calendarSubscription'] as num?)?.toDouble() ?? 0.00,
      };
    } catch (_) {
      return {
        'appCommission': 1.50,
        'subscription': 5.00,
        'calendarSubscription': 0.00,
      };
    }
  }

  static Stream<Map<String, double>> appSettingsStream() {
    return _fs.collection(_settingsDoc).doc('config').snapshots().map((doc) {
      final d = doc.data();
      return {
        'appCommission': (d?['appCommission'] as num?)?.toDouble() ?? 1.50,
        'subscription':  (d?['subscription']  as num?)?.toDouble() ?? 5.00,
        'calendarSubscription':
            (d?['calendarSubscription'] as num?)?.toDouble() ?? 0.00,
      };
    });
  }

  /// Αλλάζει global προμήθεια App → ενημερώνει ΟΛΕΣ τις πηγές.
  static Future<void> setGlobalAppCommission(double value) async {
    await _fs.collection(_settingsDoc).doc('config').set(
      {'appCommission': value},
      SetOptions(merge: true),
    );
    // Ενημέρωσε όλες τις πηγές (batch)
    final all   = await _fs.collection(_sources).get();
    final batch = _fs.batch();
    for (final doc in all.docs) {
      batch.update(doc.reference, {
        'appCommissionValue': value,
        'appCommissionType':  CommissionType.fixed.name,
      });
    }
    await batch.commit();
  }

  static Future<void> setSubscription(double value) async {
    await _fs.collection(_settingsDoc).doc('config').set(
      {'subscription': value},
      SetOptions(merge: true),
    );
  }

  /// Ορίζει την έξτρα μηνιαία συνδρομή ΗΜΕΡΟΛΟΓΙΟΥ. 0 = ανενεργή.
  static Future<void> setCalendarSubscription(double value) async {
    await _fs.collection(_settingsDoc).doc('config').set(
      {'calendarSubscription': value},
      SetOptions(merge: true),
    );
  }

  /// [ΑΝΕΝΕΡΓΟ] Μεταφέρθηκε server-side (Cloud Function `monthlyCharges`).
  /// Διατηρείται μόνο ως αναφορά — επιστρέφει αμέσως χωρίς να χρεώσει.
  static Future<void> applyMonthlySubscription(String uid) async {
    return; // server-side πλέον (monthlyCharges)
    // ignore: dead_code
    if (uid.isEmpty) return;
    final now      = DateTime.now();
    final monthKey = '${now.year}-${now.month.toString().padLeft(2, '0')}';
    final ref      = _fs.collection('presence').doc(uid);
    try {
      final doc       = await ref.get();
      // Ο master δεν χρεώνεται συνδρομή (ανήκει σ' αυτόν).
      if ((doc.data()?['master'] as bool?) ?? false) return;
      final lastMonth = doc.data()?['lastSubscriptionMonth'] as String?;
      if (lastMonth == null) {
        // Πρώτη φορά → μόνο κατέγραψε τον μήνα, ΜΗ χρεώσεις
        await ref.set({'lastSubscriptionMonth': monthKey},
            SetOptions(merge: true));
        return;
      }
      if (lastMonth == monthKey) return; // ήδη χρεώθηκε αυτόν τον μήνα
      final settings = await getAppSettings();
      final sub      = settings['subscription'] ?? 5.0;
      final data     = doc.data();
      final name     =
          '${data?['displayName'] ?? ''} ${data?['lastName'] ?? ''}'.trim();

      // Collector: ο admin της σπιτικής ομάδας· αλλιώς ο master κεντρικά.
      var collectorUid  = kMasterRecipient;
      var collectorName = 'Master';
      final homeGroupId = (data?['homeGroupId'] as String?) ?? '';
      if (homeGroupId.isNotEmpty) {
        try {
          final g = (await _fs.collection('groups').doc(homeGroupId).get())
              .data();
          if (g != null) {
            var aUid = (g['createdBy'] as String?) ?? '';
            if (aUid.isEmpty) {
              final admins = List<String>.from(g['adminUids'] ?? []);
              if (admins.isNotEmpty) aUid = admins.first;
            }
            if (aUid.isNotEmpty) {
              collectorUid  = aUid;
              collectorName = await _nameOf(aUid);
            }
          }
        } catch (_) {}
      }

      await ref.update({
        'appDebt': FieldValue.increment(sub),
        'lastSubscriptionMonth': monthKey,
      });
      // Billing record συνδρομής → ανήκει στον master
      await _fs.collection(_billingTx).add({
        'uid':        uid,
        'uidName':    name,
        'monthKey':   monthKey,
        'type':       'charge',
        'category':   'subscription',
        'amount':     sub,
        'sourceId':   '',
        'sourceName': '',
        'adminUid':   '',
        'adminName':  '',
        'recipientUid':  kMasterRecipient,
        'recipientName': 'Master',
        'collectorUid':  collectorUid,
        'collectorName': collectorName,
        'jobId':      '',
        'note':       'Συνδρομή μηνός $monthKey',
        'voided':     false,
        'createdAt':  FieldValue.serverTimestamp(),
        'createdBy':  'SYSTEM',
      });
    } catch (_) {}
  }

  /// [ΑΝΕΝΕΡΓΟ] Μεταφέρθηκε server-side (Cloud Function `monthlyCharges`).
  /// Διατηρείται μόνο ως αναφορά — επιστρέφει αμέσως χωρίς να χρεώσει.
  static Future<void> applyMonthlyCalendarSubscription(String uid) async {
    return; // server-side πλέον (monthlyCharges)
    // ignore: dead_code
    if (uid.isEmpty) return;
    final now      = DateTime.now();
    final monthKey = '${now.year}-${now.month.toString().padLeft(2, '0')}';
    final ref      = _fs.collection('presence').doc(uid);
    try {
      final doc  = await ref.get();
      final data = doc.data();
      if (data == null) return;

      // Ο master δεν χρεώνεται.
      if ((data['master'] as bool?) ?? false) return;
      // Μόνο όσοι έχουν ενεργό ημερολόγιο.
      if (((data['calendarEnabled'] as bool?) ?? false) != true) return;

      // Ποσό συνδρομής ημερολογίου — αν 0/κενό, καμία χρέωση.
      final settings = await getAppSettings();
      final calSub   = settings['calendarSubscription'] ?? 0.0;
      if (calSub <= 0) return;

      final lastMonth = data['lastCalendarSubMonth'] as String?;
      if (lastMonth == null) {
        // Πρώτη φορά → μόνο κατέγραψε τον μήνα, ΜΗ χρεώσεις.
        await ref.set({'lastCalendarSubMonth': monthKey},
            SetOptions(merge: true));
        return;
      }
      if (lastMonth == monthKey) return; // ήδη χρεώθηκε αυτόν τον μήνα

      final name =
          '${data['displayName'] ?? ''} ${data['lastName'] ?? ''}'.trim();

      // Collector: ίδια λογική με την κανονική συνδρομή (admin σπιτικής ομάδας).
      var collectorUid  = kMasterRecipient;
      var collectorName = 'Master';
      final homeGroupId = (data['homeGroupId'] as String?) ?? '';
      if (homeGroupId.isNotEmpty) {
        try {
          final g = (await _fs.collection('groups').doc(homeGroupId).get())
              .data();
          if (g != null) {
            var aUid = (g['createdBy'] as String?) ?? '';
            if (aUid.isEmpty) {
              final admins = List<String>.from(g['adminUids'] ?? []);
              if (admins.isNotEmpty) aUid = admins.first;
            }
            if (aUid.isNotEmpty) {
              collectorUid  = aUid;
              collectorName = await _nameOf(aUid);
            }
          }
        } catch (_) {}
      }

      await ref.update({
        'appDebt': FieldValue.increment(calSub),
        'lastCalendarSubMonth': monthKey,
      });
      await _fs.collection(_billingTx).add({
        'uid':        uid,
        'uidName':    name,
        'monthKey':   monthKey,
        'type':       'charge',
        'category':   'calendar_subscription',
        'amount':     calSub,
        'sourceId':   '',
        'sourceName': '',
        'adminUid':   '',
        'adminName':  '',
        'recipientUid':  kMasterRecipient,
        'recipientName': 'Master',
        'collectorUid':  collectorUid,
        'collectorName': collectorName,
        'jobId':      '',
        'note':       'Συνδρομή ημερολογίου $monthKey',
        'voided':     false,
        'createdAt':  FieldValue.serverTimestamp(),
        'createdBy':  'SYSTEM',
      });
    } catch (_) {}
  }
  static const _billingTx = 'billing_tx';

  /// ΕΦΑΠΑΞ migration: δημιουργεί billing records + τζίρο για τις παλιές
  /// ολοκληρωμένες δουλειές. Τρέχει μέχρι να ΠΕΤΥΧΕΙ (flag στο τέλος).
  static Future<void> migrateOldJobs() async {
    final cfgRef = _fs.collection('app_settings').doc('config');
    try {
      final cfg = await cfgRef.get();
      if (cfg.data()?['billingMigrated_v3'] == true) {
        debugPrint('migrateOldJobs: ήδη ολοκληρωμένο');
        return;
      }
    } catch (e) {
      debugPrint('migrateOldJobs: σφάλμα ελέγχου flag: $e');
      return;
    }

    try {
      debugPrint('migrateOldJobs: ΕΝΑΡΞΗ...');
      // 1. Όλες οι ολοκληρωμένες δουλειές
      final doneSnap = await _fs
          .collection(_jobs)
          .where('status', isEqualTo: JobStatus.done.name)
          .get();
      final doneJobs = <Job>[];
      for (final d in doneSnap.docs) {
        try {
          doneJobs.add(Job.fromDoc(d));
        } catch (e) {
          debugPrint('migrateOldJobs: παραλείπω δουλειά ${d.id}: $e');
        }
      }
      debugPrint('migrateOldJobs: ${doneJobs.length} ολοκληρωμένες δουλειές');

      // 2. Ποιες δουλειές έχουν ήδη billing record
      final existingTx = await _fs.collection(_billingTx).get();
      final existingJobIds = <String>{};
      for (final d in existingTx.docs) {
        final jid = d.data()['jobId'];
        if (jid is String && jid.isNotEmpty) existingJobIds.add(jid);
      }

      // 3. Δημιουργία billing records για δουλειές χωρίς εγγραφή
      var batch = _fs.batch();
      var ops   = 0;
      for (final job in doneJobs) {
        if (existingJobIds.contains(job.id)) continue;
        if (job.takenBy == null || job.takenBy!.isEmpty) continue;
        final monthKey = _monthKey(job.doneAt ?? job.createdAt);
        final base = {
          'uid':        job.takenBy,
          'uidName':    job.takenByName ?? '',
          'monthKey':   monthKey,
          'type':       'charge',
          'sourceId':   job.sourceId   ?? '',
          'sourceName': job.sourceName ?? 'Standard Rate',
          'adminUid':   job.createdBy,
          'adminName':  job.createdByName,
          'jobId':      job.id,
          'note':       '${job.from} → ${job.to}',
          'voided':     false,
          'createdAt':  job.doneAt ?? job.createdAt,
          'createdBy':  'MIGRATION',
        };
        if (job.commission > 0) {
          batch.set(_fs.collection(_billingTx).doc(),
              {...base, 'category': 'source_commission',
               'amount': job.commission});
          ops++;
        }
        if (job.appCommission > 0) {
          batch.set(_fs.collection(_billingTx).doc(),
              {...base, 'category': 'app_commission',
               'amount': job.appCommission});
          ops++;
        }
        if (ops >= 400) { await batch.commit(); batch = _fs.batch(); ops = 0; }
      }
      if (ops > 0) await batch.commit();

      // 4. Επαναϋπολογισμός τζίρου ανά οδηγό
      final turnoverByUid = <String, double>{};
      for (final job in doneJobs) {
        final u = job.takenBy;
        if (u == null || u.isEmpty) continue;
        // Αρνητικό γιαούρτι → προστίθεται στον τζίρο.
        final eff = job.price - (job.commission < 0 ? job.commission : 0);
        turnoverByUid[u] = (turnoverByUid[u] ?? 0) + eff;
      }
      debugPrint('migrateOldJobs: τζίρος για ${turnoverByUid.length} οδηγούς');

      // 5. Επαναϋπολογισμός χρέους ανά οδηγό (από ΟΛΑ τα billing_tx)
      final allTx   = await _fs.collection(_billingTx).get();
      final debtByUid = <String, double>{};
      for (final d in allTx.docs) {
        final data = d.data();
        if (data['voided'] == true) continue;
        final uid = data['uid'] as String? ?? '';
        if (uid.isEmpty) continue;
        final amount = (data['amount'] as num?)?.toDouble() ?? 0;
        if (data['type'] == 'charge') {
          debtByUid[uid] = (debtByUid[uid] ?? 0) + amount;
        } else if (data['type'] == 'payment') {
          debtByUid[uid] = (debtByUid[uid] ?? 0) - amount;
        }
      }

      // 6. Εγγραφή τζίρου + χρέους στο presence
      final allUids = {...turnoverByUid.keys, ...debtByUid.keys};
      batch = _fs.batch();
      ops   = 0;
      for (final uid in allUids) {
        batch.set(_fs.collection('presence').doc(uid), {
          'turnover': turnoverByUid[uid] ?? 0.0,
          'appDebt':  debtByUid[uid]     ?? 0.0,
        }, SetOptions(merge: true));
        ops++;
        if (ops >= 400) { await batch.commit(); batch = _fs.batch(); ops = 0; }
      }
      if (ops > 0) await batch.commit();

      // 7. ΜΟΝΟ τώρα (μετά την επιτυχία) → flag
      await cfgRef.set({'billingMigrated_v3': true},
          SetOptions(merge: true));
      debugPrint('migrateOldJobs: ΟΛΟΚΛΗΡΩΘΗΚΕ '
          '(${allUids.length} οδηγοί ενημερώθηκαν)');
    } catch (e) {
      // Το flag ΔΕΝ μπαίνει → θα ξαναδοκιμάσει την επόμενη φορά
      debugPrint('migrateOldJobs: ΣΦΑΛΜΑ (θα ξαναδοκιμάσει): $e');
    }
  }

  /// ΕΦΑΠΑΞ migration v4: γεμίζει recipient/collector στις ΠΑΛΙΕΣ εγγραφές
  /// billing_tx με βάση το νέο μοντέλο (γιαούρτι→poster, app/συνδρομή→master,
  /// collector = admin ομάδας δουλειάς / σπιτικής / poster). Idempotent.
  static Future<void> migrateBillingRecipients() async {
    final cfgRef = _fs.collection('app_settings').doc('config');
    try {
      final cfg = await cfgRef.get();
      if (cfg.data()?['billingMigrated_v4'] == true) return;
    } catch (_) {
      return;
    }

    try {
      // 1. Ομάδες: id → {members, adminUid, adminName(later)}
      final groupsSnap = await _fs.collection('groups').get();
      final groupAdmin   = <String, String>{};      // gid → adminUid
      final groupMembers = <String, List<String>>{}; // gid → memberUids
      for (final g in groupsSnap.docs) {
        var aUid = (g.data()['createdBy'] as String?) ?? '';
        if (aUid.isEmpty) {
          final admins = List<String>.from(g.data()['adminUids'] ?? []);
          if (admins.isNotEmpty) aUid = admins.first;
        }
        groupAdmin[g.id]   = aUid;
        groupMembers[g.id] = List<String>.from(g.data()['memberUids'] ?? []);
      }

      // 2. Presence: uid → {homeGroupId, name}
      final presSnap = await _fs.collection('presence').get();
      final homeOf = <String, String>{};
      final nameOf = <String, String>{};
      for (final p in presSnap.docs) {
        homeOf[p.id] = (p.data()['homeGroupId'] as String?) ?? '';
        nameOf[p.id] =
            '${p.data()['displayName'] ?? ''} ${p.data()['lastName'] ?? ''}'
                .trim();
      }

      // Ομάδες ανά οδηγό
      final driverGroups = <String, List<String>>{};
      groupMembers.forEach((gid, members) {
        for (final u in members) {
          driverGroups.putIfAbsent(u, () => []).add(gid);
        }
      });

      // 3. Jobs: jobId → groupId
      final jobsSnap = await _fs.collection(_jobs).get();
      final jobGroupOf = <String, String>{};
      for (final j in jobsSnap.docs) {
        jobGroupOf[j.id] = (j.data()['groupId'] as String?) ?? '';
      }

      // Επιλογή collector group για (driver, jobGroup)
      String collectorAdmin(String driverUid, String jobGroup,
          String posterUid) {
        final gs = driverGroups[driverUid];
        if (gs != null && gs.isNotEmpty) {
          String? pick;
          if (jobGroup.isNotEmpty && gs.contains(jobGroup)) {
            pick = jobGroup;
          } else if (homeOf[driverUid] != null &&
              homeOf[driverUid]!.isNotEmpty &&
              gs.contains(homeOf[driverUid])) {
            pick = homeOf[driverUid];
          } else {
            pick = gs.first;
          }
          final aUid = groupAdmin[pick] ?? '';
          if (aUid.isNotEmpty) return aUid;
        }
        return posterUid; // χωρίς ομάδα → poster
      }

      // 4. Πέρασε όλες τις χρεώσεις χωρίς recipient/collector
      final txSnap = await _fs.collection(_billingTx).get();
      var batch = _fs.batch();
      var ops   = 0;
      for (final d in txSnap.docs) {
        final data = d.data();
        if (data['type'] != 'charge') continue;               // πληρωμές: skip
        final hasRecipient = (data['recipientUid'] as String?)?.isNotEmpty == true;
        final hasCollector = (data['collectorUid'] as String?)?.isNotEmpty == true;
        if (hasRecipient && hasCollector) continue;

        final cat       = data['category'] as String? ?? '';
        final driverUid = data['uid'] as String? ?? '';
        final posterUid = data['adminUid'] as String? ?? '';
        final posterNm  = data['adminName'] as String? ?? '';
        final jobId     = data['jobId'] as String? ?? '';
        final jobGroup  = jobGroupOf[jobId] ?? '';

        // recipient
        String recUid, recNm;
        if (cat == 'source_commission') {
          recUid = posterUid; recNm = posterNm;
        } else {
          recUid = kMasterRecipient; recNm = 'Master';
        }
        // collector
        final colUid = (cat == 'subscription' || cat == 'calendar_subscription')
            ? (homeOf[driverUid] != null && homeOf[driverUid]!.isNotEmpty
                ? (groupAdmin[homeOf[driverUid]] ?? kMasterRecipient)
                : kMasterRecipient)
            : collectorAdmin(driverUid, jobGroup, posterUid);
        final colNm = colUid == kMasterRecipient
            ? 'Master'
            : (nameOf[colUid] ?? '');

        batch.update(d.reference, {
          'recipientUid':  recUid,
          'recipientName': recNm,
          'collectorUid':  colUid,
          'collectorName': colNm,
        });
        ops++;
        if (ops >= 400) { await batch.commit(); batch = _fs.batch(); ops = 0; }
      }
      if (ops > 0) await batch.commit();

      await cfgRef.set({'billingMigrated_v4': true}, SetOptions(merge: true));
      debugPrint('migrateBillingRecipients: ΟΛΟΚΛΗΡΩΘΗΚΕ');
    } catch (e) {
      debugPrint('migrateBillingRecipients: ΣΦΑΛΜΑ (θα ξαναδοκιμάσει): $e');
    }
  }

  /// Στιγμιαίο χρέος ενός οδηγού (live).
  static Stream<double> debtStream(String uid) {
    return _fs.collection('presence').doc(uid).snapshots().map(
        (d) => (d.data()?['appDebt'] as num?)?.toDouble() ?? 0.0);
  }

  /// Τζίρος ενός οδηγού — υπολογίζεται ΑΠΕΥΘΕΙΑΣ από τις ολοκληρωμένες
  /// δουλειές του ιστορικού (live). Δεν εξαρτάται από migration.
  static Stream<double> turnoverFor(String uid) {
    return _fs
        .collection(_jobs)
        .where('takenBy', isEqualTo: uid)
        .snapshots()
        .map((s) {
      double total = 0;
      for (final d in s.docs) {
        final data = d.data();
        if (data['status'] != JobStatus.done.name) continue;
        total += (data['price'] as num?)?.toDouble() ?? 0;
      }
      return total;
    });
  }

  /// Τζίρος + ΠΛΗΘΟΣ ολοκληρωμένων δουλειών ενός οδηγού (live).
  /// Υπολογίζεται από την ίδια πηγή με τον τζίρο (jobs/status==done), οπότε
  /// ακυρώσεις & ολικές διαγραφές το επηρεάζουν αυτόματα — όπως και τον τζίρο.
  static Stream<({double turnover, int jobs})> turnoverStatsFor(String uid) {
    return _fs
        .collection(_jobs)
        .where('takenBy', isEqualTo: uid)
        .snapshots()
        .map((s) {
      double total = 0;
      int    count = 0;
      for (final d in s.docs) {
        final data = d.data();
        if (data['status'] != JobStatus.done.name) continue;
        final price = (data['price'] as num?)?.toDouble() ?? 0;
        final comm  = (data['commission'] as num?)?.toDouble() ?? 0;
        // Αρνητικό γιαούρτι → προστίθεται στον τζίρο (ο οδηγός το εισέπραξε).
        total += price - (comm < 0 ? comm : 0);
        count++;
      }
      return (turnover: total, jobs: count);
    });
  }

  /// Τζίρος όλων των οδηγών — από τις ολοκληρωμένες δουλειές.
  /// uid → συνολικός τζίρος.
  static Future<Map<String, double>> turnoverByDriver() async {
    final map = <String, double>{};
    try {
      final snap = await _fs
          .collection(_jobs)
          .where('status', isEqualTo: JobStatus.done.name)
          .get();
      for (final d in snap.docs) {
        final data = d.data();
        final uid  = data['takenBy'] as String?;
        if (uid == null || uid.isEmpty) continue;
        map[uid] = (map[uid] ?? 0) +
            ((data['price'] as num?)?.toDouble() ?? 0);
      }
    } catch (_) {}
    return map;
  }

  /// LIVE έκδοση του [groupBillingTotals]: ακούει τις συλλογές που αλλάζουν
  /// (billing_tx για χρεώσεις/πληρωμές, jobs(done) για τζίρο) και επανυπολογίζει
  /// αυτόματα. Έτσι, μόλις κάποιος πληρώσει στην ομάδα, τα νούμερα ανανεώνονται
  /// χωρίς να χρειάζεται έξοδος/επανείσοδος στη σελίδα.
  ///
  /// Κόστος ανάγνωσης: ίδιο με το one-shot ανά επανυπολογισμό· οι επανυπολογισμοί
  /// γίνονται μόνο όταν ΟΝΤΩΣ αλλάζει κάτι (νέα πληρωμή/χρέωση ή νέα δουλειά).
  static Stream<Map<String, Map<String, dynamic>>> groupBillingTotalsStream() {
    // Trigger stream: κάθε αλλαγή σε billing_tx ή σε ολοκληρωμένες δουλειές
    // πυροδοτεί επανυπολογισμό. Συγχωνεύουμε τα δύο snapshots σε «παλμούς».
    final txStream = _fs.collection(_billingTx).snapshots();
    final doneStream = _fs
        .collection(_jobs)
        .where('status', isEqualTo: JobStatus.done.name)
        .snapshots();

    // Απλό merge: κάθε snapshot από οποιοδήποτε stream → επανυπολογισμός.
    final controller =
        StreamController<Map<String, Map<String, dynamic>>>();
    StreamSubscription? sub1, sub2;
    var computing = false;
    var pendingAgain = false;

    Future<void> recompute() async {
      if (computing) { pendingAgain = true; return; }
      computing = true;
      try {
        final res = await groupBillingTotals();
        if (!controller.isClosed) controller.add(res);
      } finally {
        computing = false;
        if (pendingAgain) {
          pendingAgain = false;
          // ignore: unawaited_futures
          recompute();
        }
      }
    }

    controller.onListen = () {
      sub1 = txStream.listen((_) => recompute(),
          onError: (e) => debugPrint('groupBilling tx err: $e'));
      sub2 = doneStream.listen((_) => recompute(),
          onError: (e) => debugPrint('groupBilling done err: $e'));
    };
    controller.onCancel = () async {
      await sub1?.cancel();
      await sub2?.cancel();
    };

    return controller.stream;
  }

  /// Ανάλυση χρεώσεων/τζίρου ΑΝΑ ΟΜΑΔΑ με σωστή απόδοση:
  ///  • δουλειά ομάδας Χ → χρεώνεται στην ομάδα Χ
  ///  • δουλειά εκτός ομάδας → χρεώνεται στην 1η ομάδα του οδηγού
  /// Επιστρέφει: groupId → {name, charges, turnover, payments,
  ///                        drivers: {uid → {name,charges,turnover,payments}}}
  static Future<Map<String, Map<String, dynamic>>>
      groupBillingTotals() async {
    final result = <String, Map<String, dynamic>>{};
    try {
      // 1. Ομάδες (με σειρά) + μέλη
      final groupsSnap =
          await _fs.collection('groups').orderBy('name').get();
      final orderedGroupIds = <String>[];
      final driverGroups    = <String, List<String>>{};
      for (final d in groupsSnap.docs) {
        orderedGroupIds.add(d.id);
        result[d.id] = {
          'name':         d.data()['name'] ?? 'Ομάδα',
          'charges':      0.0,
          'turnover':     0.0,
          'turnoverJobs': 0,
          'payments':     0.0,
          // Σύνολα ΤΡΕΧΟΝΤΟΣ μήνα — για το «πληρώθηκαν Χ από Υ του μήνα».
          'monthCharges':  0.0,
          'monthPayments': 0.0,
          'drivers':      <String, Map<String, dynamic>>{},
        };
        for (final uid
            in List<String>.from(d.data()['memberUids'] ?? [])) {
          driverGroups.putIfAbsent(uid, () => []).add(d.id);
        }
      }

      // Σε ποια ομάδα αποδίδεται μια χρέωση/δουλειά
      String? attributed(String uid, String jobGroup) {
        final gs = driverGroups[uid];
        if (gs == null || gs.isEmpty) return null;
        if (jobGroup.isNotEmpty && gs.contains(jobGroup)) return jobGroup;
        return gs.first; // εκτός ομάδας → 1η ομάδα του οδηγού
      }

      Map<String, dynamic> driverOf(
          String gid, String uid, String name) {
        final drivers = result[gid]!['drivers']
            as Map<String, Map<String, dynamic>>;
        return drivers.putIfAbsent(uid, () => {
              'name':         name,
              'charges':      0.0,
              'turnover':     0.0,
              'turnoverJobs': 0,
              'payments':     0.0,
            });
      }

      // 2. Ολοκληρωμένες δουλειές → τζίρος + χάρτης jobId→groupId
      final jobIdToGroup = <String, String>{};
      final doneSnap = await _fs
          .collection(_jobs)
          .where('status', isEqualTo: JobStatus.done.name)
          .get();
      for (final d in doneSnap.docs) {
        final data     = d.data();
        final jobGroup = (data['groupId'] as String?) ?? '';
        jobIdToGroup[d.id] = jobGroup;
        final uid = data['takenBy'] as String?;
        if (uid == null || uid.isEmpty) continue;
        final g = attributed(uid, jobGroup);
        if (g == null) continue;
        final price = (data['price'] as num?)?.toDouble() ?? 0;
        final comm  = (data['commission'] as num?)?.toDouble() ?? 0;
        // Αρνητικό γιαούρτι → προστίθεται στον τζίρο (ο οδηγός το εισέπραξε).
        final effPrice = price - (comm < 0 ? comm : 0);
        result[g]!['turnover'] =
            (result[g]!['turnover'] as double) + effPrice;
        result[g]!['turnoverJobs'] =
            (result[g]!['turnoverJobs'] as int) + 1;
        final de = driverOf(g, uid, data['takenByName'] ?? '');
        de['turnover'] = (de['turnover'] as double) + effPrice;
        de['turnoverJobs'] = (de['turnoverJobs'] as int) + 1;
      }

      // 3. billing_tx → χρεώσεις / πληρωμές
      final txSnap = await _fs.collection(_billingTx).get();
      for (final d in txSnap.docs) {
        final data = d.data();
        if (data['voided'] == true) continue;
        final uid = data['uid'] as String? ?? '';
        if (uid.isEmpty) continue;
        final amount   = (data['amount'] as num?)?.toDouble() ?? 0;
        final jobId    = data['jobId'] as String? ?? '';
        final jobGroup =
            jobId.isNotEmpty ? (jobIdToGroup[jobId] ?? '') : '';
        final g = attributed(uid, jobGroup);
        if (g == null) continue;
        final de = driverOf(g, uid, data['uidName'] ?? '');
        final isThisMonth = (data['monthKey'] as String? ?? '') == _monthKey();
        if (data['type'] == 'charge') {
          result[g]!['charges'] =
              (result[g]!['charges'] as double) + amount;
          de['charges'] = (de['charges'] as double) + amount;
          if (isThisMonth) {
            result[g]!['monthCharges'] =
                (result[g]!['monthCharges'] as double) + amount;
          }
        } else if (data['type'] == 'payment') {
          result[g]!['payments'] =
              (result[g]!['payments'] as double) + amount;
          de['payments'] = (de['payments'] as double) + amount;
          if (isThisMonth) {
            result[g]!['monthPayments'] =
                (result[g]!['monthPayments'] as double) + amount;
          }
        }
      }
    } catch (e) {
      debugPrint('groupBillingTotals error: $e');
    }
    return result;
  }

  /// (παλιό) Στιγμιαίος τζίρος από presence — διατηρείται για συμβατότητα.
  static Stream<double> turnoverStream(String uid) => turnoverFor(uid);

  /// Συναλλαγές χρέωσης/πληρωμής ενός οδηγού (ταξινομημένες, νεότερες πρώτα).
  static Stream<List<BillingTx>> billingTransactionsFor(String uid) {
    return _fs
        .collection(_billingTx)
        .where('uid', isEqualTo: uid)
        .snapshots()
        .map((s) {
      final list = s.docs.map((d) => BillingTx.fromDoc(d)).toList();
      list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return list;
    });
  }

  /// Stream ΟΛΩΝ των εγγραφών billing (για master/εκκαθαρίσεις).
  static Stream<List<BillingTx>> allBillingTx() {
    return _fs.collection(_billingTx).snapshots().map((s) {
      final list = s.docs.map((d) => BillingTx.fromDoc(d)).toList()
        ..removeWhere((t) => t.voided);
      list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return list;
    });
  }

  /// «Σε ποιον οφείλονται πόσα» (recipient view).
  /// recipientUid → {name, total, bySource{src→amt}, byCollector{uid→{name,amt}}}.
  /// total = χρεώσεις − πληρωμές (καθαρό ανεξόφλητο).
  static Map<String, Map<String, dynamic>> recipientOutstanding(
      List<BillingTx> txs) {
    final out = <String, Map<String, dynamic>>{};
    for (final t in txs) {
      if (t.voided) continue;
      final rid = t.recipientUid.isNotEmpty ? t.recipientUid : t.adminUid;
      if (rid.isEmpty) continue;
      final sign = t.isPayment ? -1.0 : 1.0;
      final e = out.putIfAbsent(rid, () => {
            'name':        t.recipientName.isNotEmpty
                ? t.recipientName
                : (rid == kMasterRecipient ? 'Master' : t.adminName),
            'total':       0.0,
            'bySource':    <String, double>{},
            'byCollector': <String, Map<String, dynamic>>{},
          });
      e['total'] = (e['total'] as double) + sign * t.amount;
      final src = t.sourceName.isNotEmpty ? t.sourceName : '—';
      final bs  = e['bySource'] as Map<String, double>;
      bs[src] = (bs[src] ?? 0) + sign * t.amount;
      if (t.collectorUid.isNotEmpty) {
        final bc = e['byCollector'] as Map<String, Map<String, dynamic>>;
        final ce = bc.putIfAbsent(t.collectorUid, () => {
              'name':  t.collectorName.isNotEmpty
                  ? t.collectorName
                  : (t.collectorUid == kMasterRecipient ? 'Master' : ''),
              'total': 0.0,
            });
        ce['total'] = (ce['total'] as double) + sign * t.amount;
      }
    }
    return out;
  }

  /// «Τι μαζεύει & τι προωθεί ο κάθε collector» (collector view).
  /// collectorUid → {name, total, byRecipient{rid→{name,total,bySource}},
  ///                 byDriver{uid→{name,total}}}.
  static Map<String, Map<String, dynamic>> collectorOutstanding(
      List<BillingTx> txs) {
    final out = <String, Map<String, dynamic>>{};
    for (final t in txs) {
      if (t.voided) continue;
      final cid = t.collectorUid;
      if (cid.isEmpty) continue;
      final sign = t.isPayment ? -1.0 : 1.0;
      final e = out.putIfAbsent(cid, () => {
            'name':        t.collectorName.isNotEmpty
                ? t.collectorName
                : (cid == kMasterRecipient ? 'Master' : ''),
            'total':       0.0,
            'byRecipient': <String, Map<String, dynamic>>{},
            'byDriver':    <String, Map<String, dynamic>>{},
          });
      e['total'] = (e['total'] as double) + sign * t.amount;

      final rid = t.recipientUid.isNotEmpty ? t.recipientUid : t.adminUid;
      final br  = e['byRecipient'] as Map<String, Map<String, dynamic>>;
      final re  = br.putIfAbsent(rid.isEmpty ? '—' : rid, () => {
            'name':     t.recipientName.isNotEmpty
                ? t.recipientName
                : (rid == kMasterRecipient ? 'Master' : t.adminName),
            'total':    0.0,
            'isMaster': rid == kMasterRecipient,
            'bySource': <String, double>{},
          });
      re['total'] = (re['total'] as double) + sign * t.amount;
      final src = t.sourceName.isNotEmpty ? t.sourceName : '—';
      final rbs = re['bySource'] as Map<String, double>;
      rbs[src] = (rbs[src] ?? 0) + sign * t.amount;

      final bd = e['byDriver'] as Map<String, Map<String, dynamic>>;
      final de = bd.putIfAbsent(t.uid, () => {
            'name':  t.uidName,
            'total': 0.0,
          });
      de['total'] = (de['total'] as double) + sign * t.amount;
    }
    return out;
  }

  /// Λίστα όλων των εγκεκριμένων οδηγών με χρέος + τζίρο.
  static Stream<List<Map<String, dynamic>>> driversWithDebt() {
    return _fs
        .collection('presence')
        .where('isApproved', isEqualTo: true)
        .snapshots()
        .map((s) {
      final list = s.docs.map((d) {
        final data = d.data();
        return {
          'uid':      d.id,
          'name':     '${data['displayName'] ?? ''} ${data['lastName'] ?? ''}'
              .trim(),
          'debt':     (data['appDebt'] as num?)?.toDouble() ?? 0.0,
          'turnover': (data['turnover'] as num?)?.toDouble() ?? 0.0,
        };
      }).where((m) => (m['name'] as String).isNotEmpty).toList();
      // Μεγαλύτερο χρέος πρώτα
      list.sort((a, b) =>
          (b['debt'] as double).compareTo(a['debt'] as double));
      return list;
    });
  }

  /// Master καταγράφει πληρωμή οδηγού για συγκεκριμένο μήνα.
  // ─── Εκκαθαρίσεις (collector → recipient) ─────────────────────────────────
  static const _settlements = 'settlements';

  /// Καταγράφει ότι ο collector προώθησε `amount` στον παραλήπτη.
  static Future<void> recordSettlement({
    required String collectorUid,
    required String collectorName,
    required String recipientUid,
    required String recipientName,
    required double amount,
    required String byUid,
    String note = '',
  }) async {
    if (amount <= 0) return;
    await _fs.collection(_settlements).add({
      'collectorUid':  collectorUid,
      'collectorName': collectorName,
      'recipientUid':  recipientUid,
      'recipientName': recipientName,
      'amount':        amount,
      'note':          note,
      'createdAt':     FieldValue.serverTimestamp(),
      'createdBy':     byUid,
    });
  }

  static Stream<List<Settlement>> settlements() {
    return _fs.collection(_settlements).snapshots().map((s) =>
        s.docs.map((d) => Settlement.fromDoc(d)).toList());
  }

  /// Ledger προώθησης: τι έχει μαζέψει ο collector για άλλους και τι εκκρεμεί.
  /// collectorUid → {name, byRecipient: {rid → {name, isMaster,
  ///                  collected, forwarded, pending}}}.
  /// collected = πληρωμές που μαζεύτηκαν για λογαριασμό του παραλήπτη.
  /// forwarded = όσα έχει ήδη προωθήσει (settlements). pending = διαφορά.
  static Map<String, Map<String, dynamic>> forwardingLedger(
      List<BillingTx> txs, List<Settlement> sets) {
    final out = <String, Map<String, dynamic>>{};

    Map<String, dynamic> recOf(String cid, String cName, String rid,
        String rName) {
      final e = out.putIfAbsent(cid, () => {
            'name':        cName,
            'byRecipient': <String, Map<String, dynamic>>{},
          });
      final br = e['byRecipient'] as Map<String, Map<String, dynamic>>;
      return br.putIfAbsent(rid, () => {
            'name':      rName.isNotEmpty
                ? rName
                : (rid == kMasterRecipient ? 'Master' : ''),
            'isMaster':  rid == kMasterRecipient,
            'collected': 0.0,
            'forwarded': 0.0,
            'pending':   0.0,
          });
    }

    // Μαζεμένα: από τις πληρωμές (recipient ≠ collector → πρέπει να προωθηθούν)
    for (final t in txs) {
      if (t.voided || !t.isPayment) continue;
      final cid = t.collectorUid;
      final rid = t.recipientUid;
      if (cid.isEmpty || rid.isEmpty || cid == rid) continue;
      final re = recOf(cid, t.collectorName, rid, t.recipientName);
      re['collected'] = (re['collected'] as double) + t.amount;
    }
    // Προωθημένα: από τα settlements
    for (final s in sets) {
      if (s.collectorUid.isEmpty || s.recipientUid.isEmpty) continue;
      final re = recOf(s.collectorUid, s.collectorName, s.recipientUid,
          s.recipientName);
      re['forwarded'] = (re['forwarded'] as double) + s.amount;
    }
    // Εκκρεμότητα
    for (final e in out.values) {
      final br = e['byRecipient'] as Map<String, Map<String, dynamic>>;
      for (final re in br.values) {
        re['pending'] =
            (re['collected'] as double) - (re['forwarded'] as double);
      }
    }
    return out;
  }

  static Future<void> recordPayment({
    required String uid,
    required String uidName,
    required double amount,
    required String masterUid,
    String monthKey = '',
    String note = '',
    // Αν δοθεί, η πληρωμή κατανέμεται ΜΟΝΟ στις χρεώσεις όπου ο παραλήπτης
    // είναι αυτός ο uid (π.χ. admin εξοφλεί μόνο τα δικά του γιαούρτια).
    // null = όλες οι χρεώσεις (συμπεριφορά master).
    String? onlyRecipientUid,
  }) async {
    if (amount <= 0) return;
    final presenceRef = _fs.collection('presence').doc(uid);

    // 1. Φόρτωσε όλες τις (μη-ακυρωμένες) εγγραφές του οδηγού
    var txs = <BillingTx>[];
    try {
      final snap = await _fs
          .collection(_billingTx)
          .where('uid', isEqualTo: uid)
          .get();
      txs = snap.docs.map((d) => BillingTx.fromDoc(d)).toList()
        ..removeWhere((t) => t.voided);
    } catch (_) {}

    // Σειρά εξόφλησης: ΠΡΩΤΑ η προμήθεια App (παλιότερη → νεότερη), μετά όλες
    // οι υπόλοιπες χρεώσεις (παλιότερη → νεότερη). Έτσι μια μερική πληρωμή
    // «τρώει» πρώτα τα 0,60€/δουλειά της App και μετά τα γιαούρτια/συνδρομές.
    int prio(BillingTx t) => t.category == 'app_commission' ? 0 : 1;
    // Φιλτράρισμα ανά παραλήπτη (αν admin) — μόνο ΘΕΤΙΚΕΣ χρεώσεις.
    bool recipientOk(BillingTx t) =>
        onlyRecipientUid == null || t.recipientUid == onlyRecipientUid;
    final charges = txs
        .where((t) => t.isCharge && t.amount > 0 && recipientOk(t))
        .toList()
      ..sort((a, b) {
        final p = prio(a).compareTo(prio(b));
        if (p != 0) return p;
        return a.createdAt.compareTo(b.createdAt);
      });
    // Προηγούμενες πληρωμές — φιλτραρισμένες με το ίδιο κριτήριο παραλήπτη,
    // ώστε το «ήδη πληρωμένο» να μετράει μόνο για τις χρεώσεις αυτού του παραλήπτη.
    final alreadyPaid = txs
        .where((t) => t.isPayment && t.amount > 0 && recipientOk(t))
        .fold<double>(0, (s, t) => s + t.amount);

    // 2. Υπόλοιπο ανά χρέωση (FIFO) μετά τις προηγούμενες πληρωμές
    var pool = alreadyPaid;
    final leftovers = <BillingTx, double>{};
    for (final c in charges) {
      if (pool >= c.amount) {
        pool -= c.amount;
      } else {
        leftovers[c] = c.amount - pool;
        pool = 0;
      }
    }

    // 3. Κατανομή της νέας πληρωμής — παλιές χρεώσεις πρώτα
    final batch = _fs.batch();
    var remaining = amount;
    for (final c in charges) {
      if (remaining <= 0.0001) break;
      final left = leftovers[c] ?? 0;
      if (left <= 0) continue;
      final pay = remaining >= left ? left : remaining;
      remaining -= pay;
      batch.set(_fs.collection(_billingTx).doc(), {
        'uid':           uid,
        'uidName':       uidName,
        'monthKey':      c.monthKey,
        'type':          'payment',
        'category':      'payment',
        'amount':        pay,
        'sourceId':      c.sourceId,
        'sourceName':    c.sourceName,
        'adminUid':      c.recipientUid,
        'adminName':     c.recipientName,
        'recipientUid':  c.recipientUid,
        'recipientName': c.recipientName,
        'collectorUid':  c.collectorUid,
        'collectorName': c.collectorName,
        'jobId':         c.jobId,
        'note':          note.isNotEmpty ? note : 'Εξόφληση: ${c.categoryLabel}',
        'voided':        false,
        'createdAt':     FieldValue.serverTimestamp(),
        'createdBy':     masterUid,
      });
    }
    // 4. Τυχόν υπερπληρωμή → πίστωση χωρίς συγκεκριμένο παραλήπτη
    //    ΜΟΝΟ όταν εξοφλεί ο master (χωρίς φίλτρο). Σε φιλτραρισμένη πληρωμή
    //    (admin) ΔΕΝ δημιουργούμε ανώνυμη πίστωση — δεν αφορά άλλους παραλήπτες.
    if (remaining > 0.001 && onlyRecipientUid == null) {
      batch.set(_fs.collection(_billingTx).doc(), {
        'uid':           uid,
        'uidName':       uidName,
        'monthKey':      monthKey.isNotEmpty ? monthKey : _monthKey(),
        'type':          'payment',
        'category':      'payment',
        'amount':        remaining,
        'sourceId':      '',
        'sourceName':    '',
        'adminUid':      '',
        'adminName':     '',
        'recipientUid':  '',
        'recipientName': '',
        'collectorUid':  '',
        'collectorName': '',
        'jobId':         '',
        'note':          note.isNotEmpty ? note : 'Πληρωμή (πίστωση)',
        'voided':        false,
        'createdAt':     FieldValue.serverTimestamp(),
        'createdBy':     masterUid,
      });
    }
    // 5. Μείωσε το συνολικό χρέος (cache).
    //    Για φιλτραρισμένη (admin) πληρωμή, μειώνουμε μόνο όσο όντως
    //    κατανεμήθηκε (amount - remaining) — αν ο admin έβαλε παραπάνω από όσα
    //    του οφείλονται, το υπόλοιπο δεν χρεώνεται/πιστώνεται πουθενά.
    final applied = onlyRecipientUid == null ? amount : (amount - remaining);
    if (applied > 0.0001) {
      batch.update(presenceRef, {'appDebt': FieldValue.increment(-applied)});
    }
    try {
      await batch.commit();
    } catch (_) {}
  }

  /// Master δηλώνει έναν ΜΗΝΑ ως πλήρως πληρωμένο.
  /// Προσθέτει payment ίσο με το υπόλοιπο του μήνα.
  static Future<void> markMonthPaid({
    required String uid,
    required String uidName,
    required String monthKey,
    required double balance,
    required String masterUid,
  }) async {
    if (balance <= 0) return;
    await recordPayment(
      uid:       uid,
      uidName:   uidName,
      amount:    balance,
      masterUid: masterUid,
      monthKey:  monthKey,
      note:      'Εξόφληση μηνός $monthKey',
    );
  }

  // ── Πληρωμή ΠΡΟΣ τον οδηγό (όταν ο διαχειριστής χρωστάει) ─────────────────
  //
  // Χρησιμοποιείται όταν το γιαούρτι είναι αρνητικό (ο διαχειριστής έβαλε
  // λεφτά από την τσέπη του). Καταγράφει payment με ΑΡΝΗΤΙΚΟ amount, ώστε:
  //   balance = charges - payments  →  -2,50 - (-2,50) = 0
  // και ΑΥΞΑΝΕΙ το appDebt προς το 0 (το αρνητικό appDebt σημαίνει «του χρωστάς»).
  //
  // [amount] = πόσα έδωσες στον οδηγό (θετικός αριθμός). Κατανέμεται FIFO στις
  // ΑΡΝΗΤΙΚΕΣ χρεώσεις (πιστώσεις) του οδηγού.
  static Future<void> recordDriverPayment({
    required String uid,
    required String uidName,
    required double amount,      // θετικό = πόσα έδωσες
    required String masterUid,
    String monthKey = '',
    String note = '',
    String? onlyRecipientUid,    // admin → μόνο οι δικές του πιστώσεις
  }) async {
    if (amount <= 0) return;
    final presenceRef = _fs.collection('presence').doc(uid);

    // 1. Φόρτωσε τις (μη-ακυρωμένες) εγγραφές του οδηγού
    var txs = <BillingTx>[];
    try {
      final snap = await _fs
          .collection(_billingTx)
          .where('uid', isEqualTo: uid)
          .get();
      txs = snap.docs.map((d) => BillingTx.fromDoc(d)).toList()
        ..removeWhere((t) => t.voided);
    } catch (_) {}

    bool recipientOk(BillingTx t) =>
        onlyRecipientUid == null || t.recipientUid == onlyRecipientUid;

    // ΑΡΝΗΤΙΚΕΣ χρεώσεις = πιστώσεις προς τον οδηγό (παλιότερη → νεότερη).
    final credits = txs
        .where((t) => t.isCharge && t.amount < 0 && recipientOk(t))
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    // Ήδη δοσμένα (αρνητικές πληρωμές = πληρωμές προς οδηγό).
    final alreadyPaidToDriver = txs
        .where((t) => t.isPayment && t.amount < 0 && recipientOk(t))
        .fold<double>(0, (s, t) => s + t.amount.abs());

    // Συνολική πίστωση που οφείλεται (απόλυτη τιμή).
    final totalCredit =
        credits.fold<double>(0, (s, t) => s + t.amount.abs());
    final outstanding = totalCredit - alreadyPaidToDriver;
    if (outstanding <= 0.001) return; // δεν χρωστάς κάτι

    // Δεν δίνεις παραπάνω από όσα οφείλονται.
    final pay = amount > outstanding ? outstanding : amount;

    // 2. Υπόλοιπο ανά πίστωση (FIFO) μετά τις προηγούμενες πληρωμές προς οδηγό
    var consumed = alreadyPaidToDriver;
    final leftovers = <BillingTx, double>{};
    for (final c in credits) {
      final mag = c.amount.abs();
      if (consumed >= mag) {
        consumed -= mag;
      } else {
        leftovers[c] = mag - consumed;
        consumed = 0;
      }
    }

    // 3. Κατανομή της νέας πληρωμής (αρνητικά amounts) — παλιές πιστώσεις πρώτα
    final batch = _fs.batch();
    var remaining = pay;
    for (final c in credits) {
      if (remaining <= 0.0001) break;
      final left = leftovers[c] ?? 0;
      if (left <= 0) continue;
      final give = remaining >= left ? left : remaining;
      remaining -= give;
      batch.set(_fs.collection(_billingTx).doc(), {
        'uid':           uid,
        'uidName':       uidName,
        'monthKey':      c.monthKey,
        'type':          'payment',
        'category':      'payment',
        'amount':        -give, // ΑΡΝΗΤΙΚΟ = πληρωμή προς οδηγό
        'sourceId':      c.sourceId,
        'sourceName':    c.sourceName,
        'adminUid':      c.recipientUid,
        'adminName':     c.recipientName,
        'recipientUid':  c.recipientUid,
        'recipientName': c.recipientName,
        'collectorUid':  c.collectorUid,
        'collectorName': c.collectorName,
        'jobId':         c.jobId,
        'note':          note.isNotEmpty ? note : 'Πληρωμή προς οδηγό',
        'voided':        false,
        'createdAt':     FieldValue.serverTimestamp(),
        'createdBy':     masterUid,
      });
    }

    // 4. Αύξησε το appDebt προς το 0 (το αρνητικό μειώνεται κατά pay).
    batch.update(presenceRef, {'appDebt': FieldValue.increment(pay)});
    try {
      await batch.commit();
    } catch (_) {}
  }

  /// Master δηλώνει ότι πλήρωσε ΟΛΟΚΛΗΡΟ το ποσό που χρωστάει σε έναν μήνα.
  static Future<void> markMonthPaidToDriver({
    required String uid,
    required String uidName,
    required String monthKey,
    required double balance, // αρνητικό
    required String masterUid,
    String? onlyRecipientUid,
  }) async {
    if (balance >= 0) return;
    await recordDriverPayment(
      uid:       uid,
      uidName:   uidName,
      amount:    balance.abs(),
      masterUid: masterUid,
      monthKey:  monthKey,
      note:      'Πληρωμή προς οδηγό — μήνας $monthKey',
      onlyRecipientUid: onlyRecipientUid,
    );
  }

  /// Master μηδενίζει εντελώς το τρέχον χρέος ενός οδηγού.
  static Future<void> clearDebt({
    required String uid,
    required String uidName,
    required String masterUid,
  }) async {
    final ref = _fs.collection('presence').doc(uid);
    double debt = 0;
    try {
      final d = (await ref.get()).data()?['appDebt'] as num?;
      debt = d?.toDouble() ?? 0.0;
    } catch (_) {}
    if (debt <= 0) return;
    // Περνά από την FIFO κατανομή ώστε να ξοφλούνται οι σωστοί παραλήπτες.
    await recordPayment(
      uid:       uid,
      uidName:   uidName,
      amount:    debt,
      masterUid: masterUid,
      note:      'Μηδενισμός χρέους',
    );
  }

  /// Μηνιαία ανάλυση χρεώσεων ενός οδηγού (live).
  ///
  /// [excludeOwnRecipient]: για την ΠΡΟΣΩΠΙΚΗ καρτέλα admin/master — αφαιρεί
  /// χρεώσεις που οφείλονται στον ίδιο (έβγαλε & πήρε δική του δουλειά), ώστε
  /// να μη «χρωστάει στον εαυτό του». [isMaster]: επιπλέον αφαιρεί προμήθεια
  /// App + συνδρομή (που ανήκουν στον master). Οι προμήθειες πηγής προς άλλον
  /// admin ή πηγή (π.χ. Χιλτον) παραμένουν.
  static Stream<List<MonthlyBilling>> monthlyBillingFor(
    String uid, {
    bool excludeOwnRecipient = false,
    bool isMaster = false,
  }) {
    return billingTransactionsFor(uid).map((txs) {
      if (!excludeOwnRecipient) {
        return MonthlyBilling.fromTransactions(txs);
      }
      final filtered = txs.where((t) {
        if (t.isPayment) return true; // πληρωμές μειώνουν ό,τι οφείλεται σε άλλους
        if (t.recipientUid == uid) return false;          // αυτο-οφειλή
        if (isMaster && t.isForMaster) return false;       // App + συνδρομή → στον master
        return true;
      }).toList();
      return MonthlyBilling.fromTransactions(filtered);
    });
  }

  /// Εφάπαξ καθαρισμός ιστορικών «αυτο-χρεώσεων» του master: ακυρώνει τις
  /// εγγραφές προμήθειας App / συνδρομής που είχαν καταγραφεί κατά λάθος στον
  /// ίδιο τον master και αναιρεί το αντίστοιχο χρέος (appDebt). Τρέξ' το μία
  /// φορά αν υπάρχουν παλιές τέτοιες εγγραφές. Δεν αγγίζει προμήθειες πηγής
  /// (που όντως οφείλονται σε άλλον admin/πηγή).
  static Future<void> cleanupMasterSelfCharges(String masterUid) async {
    if (masterUid.isEmpty) return;
    try {
      final snap = await _fs
          .collection(_billingTx)
          .where('uid', isEqualTo: masterUid)
          .get();
      final batch = _fs.batch();
      double refund = 0;
      for (final d in snap.docs) {
        final data = d.data();
        if (data['voided'] == true) continue;
        if (data['type'] != 'charge') continue;
        final cat       = data['category'] as String? ?? '';
        final recipient = data['recipientUid'] as String? ?? '';
        final selfOwed  = cat == 'app_commission' ||
            cat == 'subscription' ||
            cat == 'calendar_subscription' ||
            recipient == kMasterRecipient ||
            recipient == masterUid;
        if (!selfOwed) continue;
        refund += (data['amount'] as num?)?.toDouble() ?? 0;
        batch.update(d.reference, {'voided': true});
      }
      if (refund > 0) {
        batch.update(_fs.collection('presence').doc(masterUid),
            {'appDebt': FieldValue.increment(-refund)});
      }
      await batch.commit();
    } catch (e) {
      debugPrint('cleanupMasterSelfCharges error: $e');
    }
  }

  /// Δημιουργεί την πηγή "Standard Rate" αν δεν υπάρχει.
  static Future<void> ensureStandardRate() async {
    final ref = _fs.collection(_sources).doc('standard_rate');
    final doc = await ref.get();
    if (doc.exists) return;
    final settings = await getAppSettings();
    await ref.set({
      'name':               'Standard Rate',
      'commissionType':     CommissionType.fixed.name,
      'commissionValue':    0.0,
      'appCommissionType':  CommissionType.fixed.name,
      'appCommissionValue': settings['appCommission'] ?? 1.50,
      'createdBy':          'SYSTEM',
      'isGlobal':           true,
    });
  }

  static Future<void> createSource(JobSource source) async {
    await _fs.collection(_sources).add(source.toMap());
  }

  static Future<void> updateSource(String id, JobSource source) async {
    await _fs.collection(_sources).doc(id).update(source.toMap());
  }

  static Future<void> deleteSource(String id) async {
    await _fs.collection(_sources).doc(id).delete();
  }

  // ─── Stats ────────────────────────────────────────────────────────────────

  // Δουλειές συγκεκριμένου οδηγού σε χρονικό διάστημα
  static Future<List<Job>> jobsForDriver({
    required String   uid,
    required DateTime from,
    required DateTime to,
  }) async {
    final snap = await _fs
        .collection(_jobs)
        .where('takenBy', isEqualTo: uid)
        .where('status',  isEqualTo: JobStatus.done.name)
        .where('takenAt', isGreaterThanOrEqualTo: Timestamp.fromDate(from))
        .where('takenAt', isLessThanOrEqualTo:    Timestamp.fromDate(to))
        .orderBy('takenAt', descending: true)
        .get();
    return snap.docs.map((d) => Job.fromDoc(d)).toList();
  }

  // ─── Admin history summary ─────────────────────────────────────────────────
  /// Επιστρέφει τα uid των μελών των δοθέντων ομάδων.
  static Future<List<String>> memberUidsOf(List<String> groupIds) async {
    if (groupIds.isEmpty) return [];
    try {
      final snap = await _fs.collection('groups').get();
      final uids = <String>{};
      for (final d in snap.docs) {
        if (!groupIds.contains(d.id)) continue;
        uids.addAll(List<String>.from(d.data()['memberUids'] ?? []));
      }
      return uids.toList();
    } catch (_) {
      return [];
    }
  }

  static Future<Map<String, dynamic>> summaryForPeriod({
    required DateTime from,
    required DateTime to,
    String?           driverUid,   // null = όλοι
    String?           groupId,     // null = όλες (admin, single group)
    List<String>?     groupIds,    // για non-admin (πολλές ομάδες)
    List<String>?     memberUids,  // μέλη ομάδων → δείχνει & εκτός-ομάδας δουλειές τους
  }) async {
    try {
      final snap = await _fs
          .collection(_jobs)
          .where('status', whereIn: [
            JobStatus.done.name,
            JobStatus.cancelled.name,
          ])
          .get();

      final fromMidnight = DateTime(from.year, from.month, from.day);
      final toEndOfDay   = DateTime(to.year, to.month, to.day, 23, 59, 59);

      final jobs = <Job>[];
      for (final d in snap.docs) {
        Job j;
        try { j = Job.fromDoc(d); } catch (_) { continue; }
        // Φίλτρο ημερομηνίας
        final ref = j.doneAt ?? j.takenAt ?? j.createdAt;
        if (ref.isBefore(fromMidnight) || ref.isAfter(toEndOfDay)) continue;
        // Φίλτρο οδηγού
        if (driverUid != null && j.takenBy != driverUid) continue;
        // Ενοποιημένο φίλτρο ομάδων: δουλειά της ομάδας Ή δουλειά μέλους
        final effGroups = <String>{};
        if (groupId != null && groupId.isNotEmpty) effGroups.add(groupId);
        if (groupIds != null) effGroups.addAll(groupIds);
        if (effGroups.isNotEmpty) {
          final inGroup = j.groupId != null &&
              j.groupId!.isNotEmpty &&
              effGroups.contains(j.groupId);
          final byMember = memberUids != null &&
              j.takenBy != null &&
              memberUids.contains(j.takenBy);
          if (!inGroup && !byMember) continue;
        }
        jobs.add(j);
      }

      jobs.sort((a, b) {
        final aDate = a.doneAt ?? a.takenAt ?? a.createdAt;
        final bDate = b.doneAt ?? b.takenAt ?? b.createdAt;
        return bDate.compareTo(aDate);
      });

      // Οι ΑΚΥΡΩΜΕΝΕΣ δουλειές παραμένουν ορατές στη λίστα του ιστορικού,
      // αλλά ΔΕΝ μετράνε στα σύνολα: ούτε στον τζίρο, ούτε στον αριθμό
      // δουλειών, ούτε στις προμήθειες (γιαούρτι / App).
      final activeJobs = jobs
          .where((j) => j.status != JobStatus.cancelled)
          .toList();

      final totalPrice   =
          activeJobs.fold<double>(0, (s, j) => s + j.price);
      final totalComm    =
          activeJobs.fold<double>(0, (s, j) => s + j.commission);
      final totalAppComm =
          activeJobs.fold<double>(0, (s, j) => s + j.appCommission);

      return {
        'count':        activeJobs.length,
        'totalPrice':   totalPrice,
        'totalComm':    totalComm,
        'totalAppComm': totalAppComm,
        'jobs':         jobs,
      };
    } catch (e) {
      debugPrint('summaryForPeriod error: $e');
      return {
        'count': 0, 'totalPrice': 0.0, 'totalComm': 0.0,
        'totalAppComm': 0.0, 'jobs': <Job>[],
      };
    }
  }
}
