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

// ─── Μία «στάση» μέσα σε μια ενωμένη δουλειά Shuttle ────────────────────────
// Κάθε στάση αντιστοιχεί σε ΜΙΑ αρχική αποθηκευμένη δουλειά (savedJobId) που
// απορροφήθηκε στο container. isPickupHere=true σημαίνει ότι ο επιβάτης
// ΜΠΑΙΝΕΙ σε αυτό το σημείο (πολλαπλές παραλαβές → 1 κοινό προορισμό)·
// false σημαίνει ότι ΚΑΤΕΒΑΙΝΕΙ εδώ (1 κοινή αφετηρία → πολλαπλοί προορισμοί).
class ShuttleStop {
  final String  savedJobId;
  final String  name;
  final String? phone;
  final String? email;
  final String? flightOrShip;
  final String? note;
  final String  address;
  final double? lat;
  final double? lng;
  final bool    isPickupHere;
  final double  price; // πόσο πληρώνει ΑΥΤΟΣ ο επιβάτης — ο admin μπορεί να το αλλάξει
  final int     persons;
  final int     luggage;
  final int     childSeatCount;

  const ShuttleStop({
    required this.savedJobId,
    required this.name,
    this.phone,
    this.email,
    this.flightOrShip,
    this.note,
    required this.address,
    this.lat,
    this.lng,
    required this.isPickupHere,
    this.price = 0,
    this.persons = 1,
    this.luggage = 0,
    this.childSeatCount = 0,
  });

  factory ShuttleStop.fromMap(Map<String, dynamic> m) => ShuttleStop(
        savedJobId:   m['savedJobId'] as String? ?? '',
        name:         m['name'] as String? ?? '',
        phone:        m['phone'] as String?,
        email:        m['email'] as String?,
        flightOrShip: m['flightOrShip'] as String?,
        note:         m['note'] as String?,
        address:      m['address'] as String? ?? '',
        lat:          (m['lat'] as num?)?.toDouble(),
        lng:          (m['lng'] as num?)?.toDouble(),
        isPickupHere: m['isPickupHere'] == true,
        price:        (m['price'] as num?)?.toDouble() ?? 0,
        persons:        (m['persons'] as num?)?.toInt() ?? 1,
        luggage:        (m['luggage'] as num?)?.toInt() ?? 0,
        childSeatCount: (m['childSeatCount'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toMap() => {
        'savedJobId':   savedJobId,
        'name':         name,
        if (phone != null) 'phone': phone,
        if (email != null) 'email': email,
        if (flightOrShip != null) 'flightOrShip': flightOrShip,
        if (note != null) 'note': note,
        'address':      address,
        if (lat != null) 'lat': lat,
        if (lng != null) 'lng': lng,
        'isPickupHere': isPickupHere,
        'price':        price,
        'persons':        persons,
        'luggage':        luggage,
        'childSeatCount': childSeatCount,
      };

  ShuttleStop copyWith({double? price}) => ShuttleStop(
        savedJobId: savedJobId, name: name, phone: phone, email: email,
        flightOrShip: flightOrShip, note: note, address: address, lat: lat, lng: lng,
        isPickupHere: isPickupHere, price: price ?? this.price,
        persons: persons, luggage: luggage, childSeatCount: childSeatCount,
      );
}

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
  final int?     bookingNumber;    // μοναδικός αύξων αριθμός κράτησης (ανά tenant), αν από φόρμα

  // ── Ένωση Shuttle ──────────────────────────────────────────────────────
  // Αν mergedIntoId != null, αυτή η αποθηκευμένη δουλειά έχει «απορροφηθεί»
  // σε ένα container (κρύβεται από τη λίστα, αλλά ΔΕΝ διαγράφεται — ώστε να
  // μπορεί να γίνει split αργότερα).
  final String?  mergedIntoId;
  // Αν isShuttleContainer, ΑΥΤΗ η δουλειά ΕΙΝΑΙ το ενωμένο Shuttle — δείχνει
  // το κοινό σημείο + όλες τις στάσεις.
  final bool     isShuttleContainer;
  final List<ShuttleStop> shuttleStops;
  final String?  shuttleSharedPointName;
  final double?  shuttleSharedPointLat;
  final double?  shuttleSharedPointLng;
  final bool     shuttleSharedIsPickup; // true = το κοινό σημείο είναι η ΠΑΡΑΛΑΒΗ (πολλαπλές αφήσεις)
  final List<String> mergedChildIds;    // ids των αρχικών savedJobs που απορροφήθηκαν εδώ
  final String?  tenantId;              // multi-tenant — απαραίτητο για rules στο container doc

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
    this.bookingNumber,
    this.mergedIntoId,
    this.isShuttleContainer = false,
    this.shuttleStops = const [],
    this.shuttleSharedPointName,
    this.shuttleSharedPointLat,
    this.shuttleSharedPointLng,
    this.shuttleSharedIsPickup = false,
    this.mergedChildIds = const [],
    this.tenantId,
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
      bookingNumber: (d['bookingNumber'] as num?)?.toInt(),
      mergedIntoId: d['mergedIntoId'] as String?,
      isShuttleContainer: d['isShuttleContainer'] == true,
      shuttleStops: (d['shuttleStops'] as List<dynamic>?)
              ?.map((e) => ShuttleStop.fromMap(Map<String, dynamic>.from(e as Map)))
              .toList() ??
          const [],
      shuttleSharedPointName: d['shuttleSharedPointName'] as String?,
      shuttleSharedPointLat: (d['shuttleSharedPointLat'] as num?)?.toDouble(),
      shuttleSharedPointLng: (d['shuttleSharedPointLng'] as num?)?.toDouble(),
      shuttleSharedIsPickup: d['shuttleSharedIsPickup'] == true,
      mergedChildIds: (d['mergedChildIds'] as List<dynamic>?)?.map((e) => e as String).toList() ?? const [],
      tenantId: d['tenantId'] as String?,
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

  /// True αν αυτή η δουλειά έχει απορροφηθεί σε ένα ενωμένο Shuttle — πρέπει
  /// να κρύβεται από την κανονική λίστα (φαίνεται μόνο μέσα στο container).
  bool get isMergedAway => mergedIntoId != null;
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

  // ── Ένωση Shuttle ──────────────────────────────────────────────────────
  // Ενώνει πολλές αποθηκευμένες δουλειές σε ΜΙΑ. Δημιουργεί νέο container
  // doc με όλες τις στάσεις· τα αρχικά docs ΔΕΝ διαγράφονται — μαρκάρονται
  // με mergedIntoId ώστε να κρύβονται από τη λίστα αλλά να μπορεί να γίνει
  // split αργότερα χωρίς απώλεια δεδομένων.
  static Future<String> mergeIntoShuttle({
    required List<SavedJob> items,
    required String sharedPointName,
    double? sharedPointLat,
    double? sharedPointLng,
    required bool sharedIsPickup, // true = κοινή ΠΑΡΑΛΑΒΗ (πολλές αφήσεις) · false = κοινή ΑΦΕΣΗ (πολλές παραλαβές)
    required DateTime unifiedScheduledAt,
    required String ownerUid,
    required String ownerName,
    Map<String, double>? priceOverrides, // savedJobId -> τιμή αυτού του επιβάτη (αλλιώς η αρχική του τιμή)
  }) async {
    if (items.length < 2) throw ArgumentError('χρειάζονται τουλάχιστον 2 δουλειές');

    double priceFor(SavedJob i) => priceOverrides?[i.id] ?? i.job.price;

    final totalPersons = items.fold<int>(0, (s, i) => s + i.job.persons);
    final totalLuggage = items.fold<int>(0, (s, i) => s + i.job.luggage);
    final totalChildSeats = items.fold<int>(0, (s, i) => s + i.job.childSeatCount);
    final totalPrice   = items.fold<double>(0, (s, i) => s + priceFor(i));

    final stops = items.map((i) => ShuttleStop(
          savedJobId:   i.id,
          name:         i.job.clientName ?? '',
          phone:        i.job.clientPhone,
          email:        i.job.clientEmail,
          flightOrShip: i.job.flightOrShip,
          note:         i.job.note,
          address:      sharedIsPickup ? i.job.to : i.job.from,
          lat:          sharedIsPickup ? i.job.toLat : i.job.fromLat,
          lng:          sharedIsPickup ? i.job.toLng : i.job.fromLng,
          isPickupHere: !sharedIsPickup,
          price:        priceFor(i),
          persons:        i.job.persons,
          luggage:        i.job.luggage,
          childSeatCount: i.job.childSeatCount,
        )).toList();

    final combinedFrom = sharedIsPickup ? sharedPointName : 'Πολλαπλές παραλαβές (${items.length})';
    final combinedTo   = sharedIsPickup ? 'Πολλαπλές αφήσεις (${items.length})' : sharedPointName;
    final first = items.first.job;

    final containerJob = Job(
      id: '',
      from: combinedFrom,
      to: combinedTo,
      fromLat: sharedIsPickup ? sharedPointLat : null,
      fromLng: sharedIsPickup ? sharedPointLng : null,
      toLat:   sharedIsPickup ? null : sharedPointLat,
      toLng:   sharedIsPickup ? null : sharedPointLng,
      price: totalPrice,
      persons: totalPersons,
      luggage: totalLuggage,
      childSeatCount: totalChildSeats,
      vehicleType: first.vehicleType,
      createdBy: ownerUid,
      createdByName: ownerName,
      scheduledAt: unifiedScheduledAt,
      createdAt: DateTime.now(),
      note: 'Ενωμένη δουλειά Shuttle — ${items.length} επιβάτες/κρατήσεις.',
    );

    final map = containerJob.toMap();
    map['ownerUid']  = ownerUid;
    map['ownerName'] = ownerName;
    map['savedAt']   = FieldValue.serverTimestamp();
    map['isShuttleContainer'] = true;
    map['shuttleSharedPointName'] = sharedPointName;
    if (sharedPointLat != null) map['shuttleSharedPointLat'] = sharedPointLat;
    if (sharedPointLng != null) map['shuttleSharedPointLng'] = sharedPointLng;
    map['shuttleSharedIsPickup'] = sharedIsPickup;
    map['shuttleStops'] = stops.map((s) => s.toMap()).toList();
    map['mergedChildIds'] = items.map((i) => i.id).toList();
    final tid = items.first.tenantId;
    if (tid != null) map['tenantId'] = tid;

    final batch = _fs.batch();
    final containerRef = _fs.collection(_coll).doc();
    batch.set(containerRef, map);
    for (final i in items) {
      batch.update(_fs.collection(_coll).doc(i.id), {'mergedIntoId': containerRef.id});
    }
    await batch.commit();
    return containerRef.id;
  }

  /// Ξεχωρίζει ξανά μια ενωμένη Shuttle δουλειά στα αρχικά της κομμάτια —
  /// διαγράφει το container, ξαναφέρνει ορατά τα αρχικά (mergedIntoId: null).
  static Future<void> splitShuttle(SavedJob container) async {
    if (!container.isShuttleContainer) return;
    final batch = _fs.batch();
    for (final childId in container.mergedChildIds) {
      batch.update(_fs.collection(_coll).doc(childId), {'mergedIntoId': FieldValue.delete()});
    }
    batch.delete(_fs.collection(_coll).doc(container.id));
    await batch.commit();
  }

  /// Αλλάζει την τιμή ΕΝΟΣ επιβάτη μέσα σε ήδη ενωμένο Shuttle — ο admin
  /// μπορεί να παρέμβει οποιαδήποτε στιγμή, όχι μόνο στη στιγμή της ένωσης.
  /// Ξαναϋπολογίζει αυτόματα το συνολικό price του container.
  static Future<void> updateShuttleStopPrice(
    SavedJob container, String savedJobId, double newPrice,
  ) async {
    if (!container.isShuttleContainer) return;
    final updatedStops = container.shuttleStops.map((s) {
      return s.savedJobId == savedJobId ? s.copyWith(price: newPrice) : s;
    }).toList();
    final newTotal = updatedStops.fold<double>(0, (sum, s) => sum + s.price);
    await _fs.collection(_coll).doc(container.id).update({
      'shuttleStops': updatedStops.map((s) => s.toMap()).toList(),
      'price': newTotal,
    });
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
