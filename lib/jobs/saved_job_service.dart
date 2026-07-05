// ==========================================
// FILE: ./lib/jobs/saved_job_service.dart
// ==========================================
//
// ΑΠΟΘΗΚΕΥΜΕΝΕΣ ΔΟΥΛΕΙΕΣ (drafts)
//
// Ξεχωριστό collection 'saved_jobs'. Μια αποθηκευμένη δουλειά είναι ένα
// προσχέδιο μιας κανονικής δουλειάς (ίδια πεδία με Job.toMap) μαζί με:
//   • ownerUid / ownerName : ποιος την έφτιαξε (admin/master)
//   • savedAt              : πότε αποθηκεύτηκε (για τον κανόνα 1 μήνα)
//
// Κανόνες αυτόματου σβησίματος (γίνονται client-side κατά το φόρτωμα — ΚΑΝΕΝΑ
// επιπλέον write αν δεν χρειάζεται, σεβόμενοι το 100m όριο):
//   • Αν autoReturned == true (δηλ. η δουλειά ΓΥΡΙΣΕ ΜΟΝΗ ΤΗΣ εδώ επειδή δεν
//     την πήρε κανείς οδηγός — δες JobService.returnExpiredToSaved): 24 ΩΡΕΣ
//     από το savedAt.
//   • Αλλιώς (χειροκίνητο draft του admin): 1 μήνας από το savedAt, Ή
//     1 μέρα μετά το ραντεβού (scheduledAt), όποιο έρθει πρώτο.
//
// Ορατότητα:
//   • admin  → μόνο δικές του (ownerUid == adminUid)
//   • master → όλες, με φίλτρα (ποιος έφτιαξε / μόνο δικές του)

import 'package:cloud_firestore/cloud_firestore.dart';
import 'job_model.dart';

class SavedJob {
  final String   id;
  final Job      job;        // το προσχέδιο ως κανονική δουλειά
  final String   ownerUid;   // ποιος την έφτιαξε
  final String   ownerName;
  final DateTime savedAt;
  final String?  calendarEventId; // αν προήλθε από συμβάν ημερολογίου
  final String?  lastEditedByName; // ποιος την άγγιξε τελευταίος (αν ξένος)
  final String?  origin;           // π.χ. 'public_form' = ήρθε από τη φόρμα site
  final bool     autoReturned;     // true = γύρισε μόνη της (αδιεκδίκητη, όχι χειροκίνητο draft)

  const SavedJob({
    required this.id,
    required this.job,
    required this.ownerUid,
    required this.ownerName,
    required this.savedAt,
    this.calendarEventId,
    this.lastEditedByName,
    this.origin,
    this.autoReturned = false,
  });

  /// True αν η δουλειά δημιουργήθηκε από τη δημόσια φόρμα της ιστοσελίδας.
  bool get isFromPublicForm => origin == 'public_form';

  factory SavedJob.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data()!;
    return SavedJob(
      id:        doc.id,
      job:       Job.fromDoc(doc), // ίδια πεδία με Job
      ownerUid:  d['ownerUid']  ?? d['createdBy'] ?? '',
      ownerName: d['ownerName'] ?? d['createdByName'] ?? '',
      savedAt:   (d['savedAt'] as Timestamp?)?.toDate() ??
                 (d['createdAt'] as Timestamp?)?.toDate() ??
                 DateTime.now(),
      calendarEventId: d['calendarEventId'] as String?,
      lastEditedByName: d['lastEditedByName'] as String?,
      origin:   d['origin'] as String?,
      autoReturned: d['autoReturned'] == true,
    );
  }

  // Πότε λήγει:
  //  • autoReturned == true (αδιεκδίκητη δουλειά που γύρισε μόνη της):
  //    24 ΩΡΕΣ από το savedAt — δεν έχει νόημα να μένει draft για πολύ μια
  //    δουλειά που ήδη «χάθηκε» μία φορά.
  //  • Χειροκίνητο draft: όποιο έρθει πρώτο: 1 μήνας από αποθήκευση, ή 1 μέρα
  //    μετά το ραντεβού.
  DateTime get expiresAt {
    if (autoReturned) {
      return savedAt.add(const Duration(hours: 24));
    }
    final monthCutoff = DateTime(
        savedAt.year, savedAt.month + 1, savedAt.day,
        savedAt.hour, savedAt.minute);
    final sched = job.scheduledAt;
    if (sched != null) {
      final afterAppt = sched.add(const Duration(days: 1));
      return afterAppt.isBefore(monthCutoff) ? afterAppt : monthCutoff;
    }
    return monthCutoff;
  }

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

class SavedJobService {
  static final _fs    = FirebaseFirestore.instance;
  static const _coll  = 'saved_jobs';

  /// Αποθηκεύει νέα δουλειά-προσχέδιο. Παίρνει το Job.toMap() (ώστε η μετατροπή
  /// σε κανονική δουλειά να είναι άμεση) + ownerUid/ownerName + savedAt.
  static Future<String> save(Job draft, {
    required String ownerUid,
    required String ownerName,
    String? calendarEventId,
    bool autoReturned = false,
  }) async {
    final map = draft.toMap();
    // Το toMap βάζει createdAt = serverTimestamp· κρατάμε ξεχωριστό savedAt.
    map['ownerUid']  = ownerUid;
    map['ownerName'] = ownerName;
    map['savedAt']   = FieldValue.serverTimestamp();
    map['autoReturned'] = autoReturned;
    if (calendarEventId != null && calendarEventId.isNotEmpty) {
      map['calendarEventId'] = calendarEventId;
    }
    final ref = await _fs.collection(_coll).add(map);
    return ref.id;
  }

  /// Ενημέρωση υπάρχουσας αποθηκευμένης δουλειάς (edit).
  static Future<void> update(String id, Job draft) async {
    final map = draft.toMap();
    // Μην πειράξεις savedAt/owner κατά το edit· αφαίρεσε το createdAt sentinel
    // ώστε να μην αλλάζει η ημ/νία δημιουργίας του draft.
    map.remove('createdAt');
    map.remove('stageStartedAt');
    await _fs.collection(_coll).doc(id).update(map);
  }

  /// Edit από ΑΛΛΟΝ admin (μέσω κοινής πρόσβασης). Η ιδιοκτησία ΔΕΝ αλλάζει:
  /// δεν αγγίζουμε ownerUid/ownerName. Γράφουμε μόνο lastEditedBy* metadata.
  static Future<void> updateAsEditor(
    String id,
    Job draft, {
    required String editorUid,
    required String editorName,
  }) async {
    final map = draft.toMap();
    map.remove('createdAt');
    map.remove('stageStartedAt');
    map.remove('ownerUid');   // ασφάλεια: ποτέ δεν αλλάζει
    map.remove('ownerName');
    map['lastEditedBy']     = editorUid;
    map['lastEditedByName'] = editorName;
    map['lastEditedAt']     = FieldValue.serverTimestamp();
    await _fs.collection(_coll).doc(id).update(map);
  }

  static Future<void> delete(String id) async {
    await _fs.collection(_coll).doc(id).delete();
  }

  /// Stream αποθηκευμένων για συγκεκριμένη λίστα owner uids (δικές μου + κοινές).
  /// [tenantId]: ΑΠΑΡΑΙΤΗΤΟ για μη-master χρήστες (multi-tenant) — φιλτράρει
  /// το ίδιο το Firestore query, ώστε να μην αποτύχει όταν υπάρχουν docs
  /// άλλου tenant στο ίδιο collection (Firestore απορρίπτει ολόκληρο το
  /// query αν έστω ένα doc αποτυγχάνει τους κανόνες ασφαλείας). Ο master
  /// (tenantId == null) συνεχίζει να παίρνει τα πάντα, όπως πριν.
  static Stream<List<SavedJob>> streamForOwners(Set<String> ownerUids, {String? tenantId}) {
    Query<Map<String, dynamic>> q = _fs.collection(_coll);
    if (tenantId != null) {
      q = q.where('tenantId', isEqualTo: tenantId);
    }
    return q.snapshots().map((snap) {
      final all = snap.docs
          .map((d) => SavedJob.fromDoc(d))
          .where((s) => ownerUids.contains(s.ownerUid))
          .toList();
      final live    = <SavedJob>[];
      final expired = <SavedJob>[];
      for (final s in all) {
        (s.isExpired ? expired : live).add(s);
      }
      if (expired.isNotEmpty) {
        // ignore: unawaited_futures
        _purge(expired.map((e) => e.id).toList());
      }
      live.sort((a, b) => b.savedAt.compareTo(a.savedAt));
      return live;
    });
  }

  /// Stream όλων των αποθηκευμένων δουλειών.
  ///  • [ownerUid] != null → φιλτράρει μόνο τις δικές του (για admin).
  ///  • null → όλες (για master).
  /// Οι ληγμένες ΦΙΛΤΡΑΡΟΝΤΑΙ τοπικά και διαγράφονται best-effort (ένα μόνο
  /// batch ανά φόρτωμα — αμελητέο write cost).
  static Stream<List<SavedJob>> stream({String? ownerUid}) {
    Query<Map<String, dynamic>> q = _fs.collection(_coll);
    if (ownerUid != null) {
      q = q.where('ownerUid', isEqualTo: ownerUid);
    }
    return q.snapshots().map((snap) {
      final all = snap.docs.map((d) => SavedJob.fromDoc(d)).toList();
      final live    = <SavedJob>[];
      final expired = <SavedJob>[];
      for (final s in all) {
        (s.isExpired ? expired : live).add(s);
      }
      // Καθάρισμα ληγμένων (best-effort, δεν μπλοκάρει το stream)
      if (expired.isNotEmpty) {
        // ignore: unawaited_futures
        _purge(expired.map((e) => e.id).toList());
      }
      // Νεότερες πρώτα
      live.sort((a, b) => b.savedAt.compareTo(a.savedAt));
      return live;
    });
  }

  /// Αποθηκεύει δουλειά-ΕΠΙΣΤΡΟΦΗ από μια ολοκληρωμένη διαδρομή.
  /// Κρατά ΟΛΑ τα στοιχεία (όνομα/τηλέφωνο/email/τιμή/άτομα/πηγή κ.λπ.),
  /// αντιστρέφει Από↔Προς, βάζει τη νέα ημ/νία ραντεβού, και προσθέτει
  /// το νέο σχόλιο ΜΕ ΚΕΦΑΛΑΙΑ κάτω από τα παλιά σχόλια.
  /// Owner = ο δημιουργός της αρχικής δουλειάς (εμφανίζεται στις δικές του).
  static Future<String> saveReturn({
    required Job original,
    required DateTime scheduledAt,
    String? extraNote,
  }) async {
    // Σχόλια: παλιά + (νέα κεφαλαία)
    final parts = <String>[];
    if (original.note != null && original.note!.trim().isNotEmpty) {
      parts.add(original.note!.trim());
    }
    if (extraNote != null && extraNote.trim().isNotEmpty) {
      parts.add(extraNote.trim().toUpperCase());
    }
    final note = parts.isEmpty ? null : parts.join('\n');

    final ret = Job(
      id:               '',
      // ΑΝΤΙΣΤΡΟΦΗ Από↔Προς
      from:             original.to,
      to:               original.from,
      fromLat:          original.toLat,
      fromLng:          original.toLng,
      toLat:            original.fromLat,
      toLng:            original.fromLng,
      // η διαδρομή/polyline δεν ισχύει πια αντίστροφα → καθαρά
      routeKm:          original.routeKm,
      price:            original.price,
      commission:       original.commission,
      appCommission:    original.appCommission,
      commissionLabel:  original.commissionLabel,
      persons:          original.persons,
      luggage:          original.luggage,
      childSeat:        original.childSeat,
      childSeatCount:   original.childSeatCount,
      withReturn:       original.withReturn,
      withStops:        original.withStops,
      childSeatPrice:   original.childSeatPrice,
      vehicleType:      original.vehicleType,
      status:           JobStatus.open,
      createdBy:        original.createdBy,
      createdByName:    original.createdByName,
      note:             note,
      sourceId:         original.sourceId,
      sourceName:       original.sourceName,
      scheduledAt:      scheduledAt,
      createdAt:        DateTime.now(),
      clientName:       original.clientName,
      clientPhone:      original.clientPhone,
      clientEmail:      original.clientEmail,
      flightOrShip:     original.flightOrShip,
      isReturn:         true,
      timeoutMins:      original.timeoutMins,
    );

    return save(ret,
        ownerUid:  original.createdBy,
        ownerName: original.createdByName);
  }

  static Future<void> _purge(List<String> ids) async {
    try {
      final batch = _fs.batch();
      for (final id in ids) {
        batch.delete(_fs.collection(_coll).doc(id));
      }
      await batch.commit();
    } catch (_) {/* αγνόησε — θα ξαναπροσπαθήσει στο επόμενο φόρτωμα */}
  }
}
