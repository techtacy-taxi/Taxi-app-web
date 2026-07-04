// ==========================================
// FILE: ./lib/jobs/job_model.dart
// ==========================================

import 'package:cloud_firestore/cloud_firestore.dart';

// ─── Status ───────────────────────────────────────────────────────────────────

enum JobStatus { open, taken, boarded, expired, done, cancelled }

// ─── Job ──────────────────────────────────────────────────────────────────────

class Job {
  final String     id;
  final String     from;
  final String     to;
  final double?    fromLat;
  final double?    fromLng;
  final double?    toLat;
  final double?    toLng;
  final double?    routeKm;       // χιλιόμετρα διαδρομής (νέα φόρμα Google)
  final int?       routeMinutes;  // εκτιμώμενη διάρκεια διαδρομής σε λεπτά (με κίνηση)
  final String?    routePolyline; // encoded polyline διαδρομής (νέα φόρμα)
  final double     price;
  final double     commission;   // προμήθεια πηγής (γιαούρτι)
  final double     appCommission; // προμήθεια App
  final String     commissionLabel;
  final int        persons;
  final int        luggage;
  final bool       childSeat;
  final int        childSeatCount;  // πλήθος παιδικών καθισμάτων
  final bool       withReturn;     // δουλειά με επιστροφή
  final bool       withStops;      // δουλειά με στάσεις
  final double     childSeatPrice;  // τιμή ανά παιδικό κάθισμα
  final String     vehicleType;  // "taxi" / "van" / "any"
  final JobStatus  status;
  final String     createdBy;
  final String     createdByName; // Όνομα διαχειριστή που δημιούργησε
  final String?    takenBy;
  final String?    takenByName;
  final String?    note;
  final String?    sourceId;
  final String?    sourceName;
  final DateTime?  scheduledAt;
  final DateTime   createdAt;
  final DateTime?  takenAt;
  final DateTime?  doneAt;
  final DateTime?  cancelledAt;
  final String?      groupId;      // αν απευθύνεται σε συγκεκριμένη ομάδα
  final List<String> targetUids;   // συγκεκριμένοι οδηγοί (1+) — αντί για ομάδα
  final List<String> targetNames;  // ονόματα των συγκεκριμένων οδηγών (παράλληλη λίστα)
  final int        timeoutMins;  // λεπτά κάθε σταδίου κλιμάκωσης
  final String?    clientName;   // όνομα πελάτη
  final String?    clientPhone;  // τηλέφωνο πελάτη
  final String?    clientEmail;  // email πελάτη
  final String?    flightOrShip; // πτήση / πλοίο
  final bool       isReturn;     // δουλειά-επιστροφή (μοβ κάρτα, badge ΕΠΙΣΤΡΟΦΗ)
  final bool       availableOnly; // αν true = υπάρχει στάδιο "πρώτα στους διαθέσιμους"
  final bool       exclusiveTarget; // αν true = ΜΟΝΟ στην ομάδα/οδηγούς, χωρίς κλιμάκωση σε όλους
  final int        escalationStage; // τρέχον στάδιο κλιμάκωσης (0-based, δες escalationPlan)
  final DateTime?  stageStartedAt;   // πότε ξεκίνησε το τρέχον στάδιο (null → createdAt)
  final bool       stopped;          // ο admin πάτησε ΣΤΟΠ — σταματά χτύπημα & κλιμάκωση
  // ── Ομαδική αποστολή σε 1 οδηγό ──
  // Όταν στέλνονται πολλές αποθηκευμένες δουλειές ΜΑΖΙ σε έναν συγκεκριμένο
  // οδηγό (αποκλειστικά), όλες μοιράζονται το ίδιο batchId. Ο οδηγός τις βλέπει
  // ως μία λίστα με «Αποδοχή όλων». Κάθε δουλειά παραμένει ΞΕΧΩΡΙΣΤΗ εγγραφή
  // (σωστό billing/ιστορικό). Κενό = κανονική μεμονωμένη δουλειά.
  final String     batchId;

  // ── Προκαταβολή μέσω Viva (δημόσια φόρμα κράτησης) ──
  // Αν depositPaid, ο πελάτης έχει ήδη πληρώσει depositAmount στον master
  // μέσω Viva· ο οδηγός εισπράττει μόνο το υπόλοιπο (βλ. remainingToCollect).
  final bool       depositPaid;
  final double     depositAmount;
  final String?    vivaOrderCode;
  // Αν true, ο πελάτης πλήρωσε ΟΛΟΚΛΗΡΗ την τιμή online (όχι μόνο 10%) —
  // ο οδηγός δεν χρειάζεται να εισπράξει τίποτα.
  final bool       fullyPaid;

  const Job({
    required this.id,
    required this.from,
    required this.to,
    this.fromLat,
    this.fromLng,
    this.toLat,
    this.toLng,
    this.routeKm,
    this.routeMinutes,
    this.routePolyline,
    required this.price,
    this.commission    = 0,
    this.appCommission = 0,
    this.commissionLabel = '',
    this.persons      = 1,
    this.luggage      = 0,
    this.childSeat    = false,
    this.childSeatCount = 0,
    this.withReturn   = false,
    this.withStops    = false,
    this.childSeatPrice = 0,
    this.vehicleType  = 'any',
    this.status       = JobStatus.open,
    required this.createdBy,
    this.createdByName = '',
    this.takenBy,
    this.takenByName,
    this.note,
    this.sourceId,
    this.sourceName,
    this.scheduledAt,
    required this.createdAt,
    this.takenAt,
    this.doneAt,
    this.cancelledAt,
    this.groupId,
    this.targetUids   = const [],
    this.targetNames  = const [],
    this.timeoutMins  = 5,
    this.clientName,
    this.clientPhone,
    this.clientEmail,
    this.flightOrShip,
    this.isReturn      = false,
    this.availableOnly = true,
    this.exclusiveTarget = false,
    this.escalationStage = 0,
    this.stageStartedAt,
    this.stopped         = false,
    this.batchId         = '',
    this.depositPaid     = false,
    this.depositAmount   = 0,
    this.vivaOrderCode,
    this.fullyPaid       = false,
  });

  factory Job.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data()!;

    // ── Συγκεκριμένοι οδηγοί — νέο πεδίο targetUids, με συμβατότητα παλιού targetUid ──
    final rawUids = d['targetUids'];
    final tUids = rawUids is List
        ? rawUids.map((e) => e.toString()).toList()
        : (d['targetUid'] != null &&
                (d['targetUid'] as String).isNotEmpty
            ? <String>[d['targetUid'] as String]
            : <String>[]);
    final rawNames = d['targetNames'];
    final tNames = rawNames is List
        ? rawNames.map((e) => e.toString()).toList()
        : (d['targetName'] != null
            ? <String>[d['targetName'] as String]
            : <String>[]);

    // ── Στάδιο κλιμάκωσης — νέο πεδίο, με μετάφραση παλιών δουλειών ──
    int      eStage;
    DateTime? sStart;
    if (d['escalationStage'] != null) {
      eStage = (d['escalationStage'] as num).toInt();
      sStart = (d['stageStartedAt'] as Timestamp?)?.toDate();
    } else {
      // Παλιά δουλειά: αν είχε repostedAt → ήταν ήδη broadcast σε όλους
      final reposted = (d['repostedAt'] as Timestamp?)?.toDate();
      if (reposted != null) {
        eStage = 99; // clamp → τελευταίο στάδιο (όλοι)
        sStart = reposted;
      } else {
        eStage = 0;
        sStart = (d['createdAt'] as Timestamp?)?.toDate();
      }
    }

    return Job(
      id:               doc.id,
      from:             d['from']             ?? '',
      to:               d['to']               ?? '',
      fromLat:          (d['fromLat']  as num?)?.toDouble(),
      fromLng:          (d['fromLng']  as num?)?.toDouble(),
      toLat:            (d['toLat']    as num?)?.toDouble(),
      toLng:            (d['toLng']    as num?)?.toDouble(),
      routeKm:          (d['routeKm']  as num?)?.toDouble(),
      routeMinutes:     (d['routeMinutes'] as num?)?.toInt(),
      routePolyline:    d['routePolyline'] as String?,
      price:            (d['price']    as num?)?.toDouble() ?? 0,
      commission:       (d['commission']    as num?)?.toDouble() ?? 0,
      appCommission:    (d['appCommission'] as num?)?.toDouble() ?? 0,
      commissionLabel:  d['commissionLabel'] ?? '',
      persons:          (d['persons']  as num?)?.toInt() ?? 1,
      luggage:          (d['luggage']  as num?)?.toInt() ?? 0,
      childSeat:        (d['childSeat'] as bool?) ?? false,
      childSeatCount:   (d['childSeatCount'] as num?)?.toInt() ?? 0,
      withReturn:       (d['withReturn'] as bool?) ?? false,
      withStops:        (d['withStops']  as bool?) ?? false,
      childSeatPrice:   (d['childSeatPrice'] as num?)?.toDouble() ?? 0,
      vehicleType:      d['vehicleType']  ?? 'any',
      status:           JobStatus.values.firstWhere(
              (e) => e.name == (d['status'] ?? 'open'),
          orElse: () => JobStatus.open),
      createdBy:        d['createdBy']      ?? '',
      createdByName:    d['createdByName']  ?? '',
      takenBy:          d['takenBy'],
      takenByName:      d['takenByName'],
      note:             d['note'],
      sourceId:         d['sourceId'],
      sourceName:       d['sourceName'],
      scheduledAt:      (d['scheduledAt'] as Timestamp?)?.toDate(),
      createdAt:        (d['createdAt']   as Timestamp?)?.toDate() ?? DateTime.now(),
      takenAt:          (d['takenAt']       as Timestamp?)?.toDate(),
      doneAt:           (d['doneAt']        as Timestamp?)?.toDate(),
      cancelledAt:      (d['cancelledAt']   as Timestamp?)?.toDate(),
      groupId:          d['groupId'],
      targetUids:       tUids,
      targetNames:      tNames,
      timeoutMins:      (d['timeoutMins'] as num?)?.toInt() ?? 5,
      clientName:       d['clientName'],
      clientPhone:      d['clientPhone'],
      clientEmail:      d['clientEmail'],
      flightOrShip:     d['flightOrShip'],
      isReturn:         (d['isReturn'] as bool?) ?? false,
      availableOnly:    (d['availableOnly'] as bool?) ?? true,
      exclusiveTarget:  (d['exclusiveTarget'] as bool?) ?? false,
      escalationStage:  eStage,
      stageStartedAt:   sStart,
      stopped:          (d['stopped'] as bool?) ?? false,
      batchId:          d['batchId'] ?? '',
      depositPaid:      (d['depositPaid'] as bool?) ?? false,
      depositAmount:    (d['depositAmount'] as num?)?.toDouble() ?? 0,
      vivaOrderCode:    d['vivaOrderCode'] as String?,
      fullyPaid:        (d['fullyPaid'] as bool?) ?? false,
    );
  }

  Map<String, dynamic> toMap() => {
    'from':             from,
    'to':               to,
    if (fromLat != null) 'fromLat': fromLat,
    if (fromLng != null) 'fromLng': fromLng,
    if (toLat   != null) 'toLat':   toLat,
    if (toLng   != null) 'toLng':   toLng,
    if (routeKm != null) 'routeKm': routeKm,
    if (routeMinutes != null) 'routeMinutes': routeMinutes,
    if (routePolyline != null) 'routePolyline': routePolyline,
    'price':            price,
    'commission':       commission,
    'appCommission':    appCommission,
    'commissionLabel':  commissionLabel,
    'persons':          persons,
    'luggage':          luggage,
    'childSeat':        childSeat,
    'childSeatCount':   childSeatCount,
    'withReturn':       withReturn,
    'withStops':        withStops,
    'childSeatPrice':   childSeatPrice,
    'vehicleType':      vehicleType,
    'status':           status.name,
    'createdBy':        createdBy,
    'createdByName':    createdByName,
    if (takenBy     != null) 'takenBy':     takenBy,
    if (takenByName != null) 'takenByName': takenByName,
    if (note        != null) 'note':        note,
    if (sourceId    != null) 'sourceId':    sourceId,
    if (sourceName  != null) 'sourceName':  sourceName,
    if (scheduledAt != null) 'scheduledAt': Timestamp.fromDate(scheduledAt!),
    'createdAt':        FieldValue.serverTimestamp(),
    if (groupId     != null) 'groupId':     groupId,
    'targetUids':       targetUids,
    'targetNames':      targetNames,
    'timeoutMins':      timeoutMins,
    if (clientName   != null) 'clientName':   clientName,
    if (clientPhone  != null) 'clientPhone':  clientPhone,
    if (clientEmail  != null) 'clientEmail':  clientEmail,
    if (flightOrShip != null) 'flightOrShip': flightOrShip,
    if (isReturn) 'isReturn': true,
    'availableOnly':    availableOnly,
    'exclusiveTarget':  exclusiveTarget,
    'escalationStage':  escalationStage,
    'stageStartedAt':   stageStartedAt != null
        ? Timestamp.fromDate(stageStartedAt!)
        : FieldValue.serverTimestamp(),
    'stopped':          stopped,
    if (batchId.isNotEmpty) 'batchId': batchId,
    if (depositPaid) 'depositPaid': true,
    if (depositPaid) 'depositAmount': depositAmount,
    if (vivaOrderCode != null) 'vivaOrderCode': vivaOrderCode,
    if (fullyPaid) 'fullyPaid': true,
  };

  // ── Ποσό που πρέπει να εισπράξει ο ΟΔΗΓΟΣ από τον πελάτη ──
  // Αν έχει ήδη πληρωθεί προκαταβολή μέσω Viva (δημόσια φόρμα), ο οδηγός
  // εισπράττει μόνο το υπόλοιπο. Η προμήθεια/κέρδος (driverEarning) ΔΕΝ
  // αλλάζει — υπολογίζεται πάντα στην πλήρη τιμή, όπως πριν.
  double get remainingToCollect =>
      depositPaid ? (price - depositAmount).clamp(0, price) : price;

  // Helpers
  bool get isOpen      => status == JobStatus.open;
  bool get isTaken     => status == JobStatus.taken;
  bool get isBoarded   => status == JobStatus.boarded;
  bool get isExpired   => status == JobStatus.expired;
  bool get isCancelled => status == JobStatus.cancelled;

  double get driverEarning => price - commission - appCommission;

  // Έχει πλήρεις συντεταγμένες Από & Προς (δουλειά νέας φόρμας Google)
  bool get hasRouteCoords =>
      fromLat != null && fromLng != null &&
      toLat   != null && toLng   != null;

  String get vehicleLabel {
    switch (vehicleType) {
      case 'taxi': return 'Taxi';
      case 'van':  return 'Van';
      default:     return 'Taxi / Van';
    }
  }

  // ─── Κλιμάκωση δουλειάς (escalation) ──────────────────────────────────────
  //
  // Στάδια ανάλογα με την επιλογή αποστολής + το "Πρώτα σε διαθέσιμους":
  //
  //  ΟΜΑΔΑ ή ΣΥΓΚΕΚΡΙΜΕΝΟΙ ΟΔΗΓΟΙ
  //   • με «πρώτα διαθέσιμοι»:  διαθέσιμοι βάσης → όλη η βάση → όλοι οι οδηγοί
  //   • χωρίς:                 όλη η βάση → όλοι οι οδηγοί
  //  ΟΛΟΙ ΟΙ ΟΔΗΓΟΙ
  //   • με «πρώτα διαθέσιμοι»:  όλοι οι διαθέσιμοι → όλοι (δεν χρειάζεται 3ο)
  //   • χωρίς:                 όλοι (ένα στάδιο)
  //
  // "βάση" = η ομάδα ή οι συγκεκριμένοι οδηγοί που επιλέχθηκαν.

  bool get hasSpecificDrivers => targetUids.isNotEmpty;
  bool get hasGroup => groupId != null && groupId!.isNotEmpty;
  bool get _hasBaseAudience => hasSpecificDrivers || hasGroup;

  List<JobStage> get escalationPlan {
    if (_hasBaseAudience) {
      // Αποκλειστική αποστολή: ΜΟΝΟ στη βάση (ομάδα/οδηγούς), χωρίς
      // κλιμάκωση σε «όλους». Αν δεν το πάρει κανείς, απλώς λήγει.
      if (exclusiveTarget) {
        // Συγκεκριμένοι οδηγοί (όχι ομάδα): το «πρώτα διαθέσιμοι» δεν έχει
        // νόημα — οι επιλεγμένοι πρέπει να τη δουν ούτως ή άλλως. Ένα στάδιο,
        // ώστε να ΜΗΝ ξαναχτυπάει η ίδια δουλειά (αλλιώς βγαίνει 2 φορές).
        if (hasSpecificDrivers) {
          return const [
            JobStage(restrictToBase: true,  availableOnly: false),
          ];
        }
        if (availableOnly) {
          return const [
            JobStage(restrictToBase: true,  availableOnly: true),
            JobStage(restrictToBase: true,  availableOnly: false),
          ];
        }
        return const [
          JobStage(restrictToBase: true,  availableOnly: false),
        ];
      }
      if (availableOnly) {
        return const [
          JobStage(restrictToBase: true,  availableOnly: true),
          JobStage(restrictToBase: true,  availableOnly: false),
          JobStage(restrictToBase: false, availableOnly: false),
        ];
      }
      return const [
        JobStage(restrictToBase: true,  availableOnly: false),
        JobStage(restrictToBase: false, availableOnly: false),
      ];
    }
    // Όλοι οι οδηγοί
    if (availableOnly) {
      return const [
        JobStage(restrictToBase: false, availableOnly: true),
        JobStage(restrictToBase: false, availableOnly: false),
      ];
    }
    return const [JobStage(restrictToBase: false, availableOnly: false)];
  }

  int get _stageIndex {
    final p = escalationPlan;
    if (escalationStage < 0) return 0;
    if (escalationStage >= p.length) return p.length - 1;
    return escalationStage;
  }

  JobStage get currentStage          => escalationPlan[_stageIndex];
  bool get isLastStage               => _stageIndex >= escalationPlan.length - 1;
  bool get currentStageRequiresAvailable => currentStage.availableOnly;
  bool get currentStageRestrictsToBase   => currentStage.restrictToBase;
  int  get stageNumber               => _stageIndex + 1;        // 1-based για εμφάνιση
  int  get totalStages               => escalationPlan.length;

  // Έχει προχωρήσει πέρα από το 1ο στάδιο (για badge "ξανάστάλθηκε")
  bool get isReposted => _stageIndex > 0;

  // Πότε ξεκίνησε το τρέχον στάδιο
  DateTime get _stageStart => stageStartedAt ?? createdAt;
  DateTime get _deadline   => _stageStart.add(Duration(minutes: timeoutMins));

  // Τέλος του τρέχοντος σταδίου → πρέπει να προχωρήσει στο επόμενο.
  bool get needsStageAdvance =>
      isOpen &&
      !stopped &&
      !isLastStage &&
      DateTime.now().isAfter(_deadline);

  // Έχει περάσει οριστικά η προθεσμία (τελευταίο στάδιο & έληξε ο χρόνος).
  //
  // ΑΣΦΑΛΙΣΤΙΚΗ ΔΙΚΛΕΙΔΑ: μια ΑΜΕΣΗ δουλειά (χωρίς ραντεβού) ΔΕΝ μένει ανοιχτή
  // πάνω από 1 ΩΡΑ από τη δημιουργία της, ό,τι κι αν ορίζει η κλιμάκωση/
  // timeoutMins (π.χ. αν ο admin έχει βάλει μεγάλο timeout ανά στάδιο). Έτσι
  // ο owner ξέρει σίγουρα ότι μέσα σε 1 ώρα η δουλειά είτε θα αναληφθεί είτε
  // θα επιστρέψει στις «Αποθηκευμένες».
  bool get isPastDeadline {
    if (!isOpen) return false;
    if (stopped) return false;        // σταματημένη → μένει στις ανοιχτές του admin
    if (scheduledAt == null &&
        DateTime.now().isAfter(createdAt.add(const Duration(hours: 1)))) {
      return true;
    }
    if (needsStageAdvance) return false;
    return DateTime.now().isAfter(_deadline);
  }

  // Συμβατότητα με παλιό κώδικα
  bool get isTimedOut => isPastDeadline;

  // Αδιεκδίκητη δουλειά που είτε (α) πέρασε οριστικά την προθεσμία της ενώ
  // είναι ακόμη 'open' (isPastDeadline), είτε (β) έχει ήδη μαρκαριστεί ως
  // 'expired' (π.χ. από το ticker της κάρτας, που ενδέχεται να προλάβει να
  // γράψει το status ΠΡΙΝ προλάβει να τρέξει το auto-return). Το auto-return
  // πρέπει να πιάνει ΚΑΙ τις δύο περιπτώσεις, αλλιώς η δουλειά μένει
  // «κολλημένη» ως 'expired' και εξαφανίζεται χωρίς ποτέ να επιστρέψει στις
  // «Αποθηκευμένες».
  bool get isUnclaimedExpired => status == JobStatus.expired || isPastDeadline;

  // ΑΝΟΙΧΤΟ (ή ήδη μαρκαρισμένο 'expired') ραντεβού του οποίου η ΩΡΑ
  // (scheduledAt) πέρασε πάνω από 2 ΩΡΕΣ και δεν το ανέλαβε κανείς οδηγός →
  // προς οριστική διαγραφή. (Διαφέρει από το isPastDeadline, που αφορά τη
  // λήξη του χρόνου διεκδίκησης/escalation.)
  bool get isStaleSchedule {
    // αναληφθείσα/ολοκληρωμένη → όχι
    if (status != JobStatus.open && status != JobStatus.expired) return false;
    final sched = scheduledAt;
    if (sched == null) return false;         // άμεση (χωρίς ραντεβού) → όχι
    return DateTime.now().isAfter(sched.add(const Duration(hours: 2)));
  }

  // Πόσα δευτερόλεπτα απομένουν στο τρέχον στάδιο
  int get secondsRemaining {
    final remaining = _deadline.difference(DateTime.now()).inSeconds;
    return remaining < 0 ? 0 : remaining;
  }

  // Φτάνει η δουλειά (στο ΤΡΕΧΟΝ στάδιο) στον συγκεκριμένο οδηγό;
  // Ο έλεγχος διαθεσιμότητας γίνεται χωριστά από τον listener.
  bool reachesDriver({
    required String uid,
    required List<String> groupIds,
  }) {
    if (stopped || !isOpen) return false;
    if (currentStage.restrictToBase) {
      if (hasSpecificDrivers) {
        if (!targetUids.contains(uid)) return false;
      } else if (hasGroup) {
        if (!groupIds.contains(groupId)) return false;
      }
    }
    return true;
  }
}

// Ένα στάδιο κλιμάκωσης μιας δουλειάς.
class JobStage {
  final bool restrictToBase; // true → μόνο ομάδα/επιλεγμένοι • false → όλοι οι οδηγοί
  final bool availableOnly;  // true → μόνο διαθέσιμοι οδηγοί
  const JobStage({required this.restrictToBase, required this.availableOnly});
}

// ─── Source (πηγή / γιαούρτι) ─────────────────────────────────────────────────

enum CommissionType { fixed, percent }

/// Βραδινό γιαούρτι: ισχύει όταν η ώρα είναι ≥ 23:30 Ή < 05:30.
/// (Το διάστημα «τυλίγει» τα μεσάνυχτα.)
bool isNightYogurt(DateTime t) {
  final mins = t.hour * 60 + t.minute;
  const start = 23 * 60 + 30; // 23:30 → 1410
  const end   = 5 * 60 + 30;  // 05:30 → 330
  return mins >= start || mins < end;
}

class JobSource {
  final String         id;
  final String         name;
  // ── Προμήθεια Πηγής (γιαούρτι) — ημερήσιο ──
  final CommissionType commissionType;
  final double         commissionValue;     // μπορεί να είναι ΑΡΝΗΤΙΚΟ
  // ── Προμήθεια Πηγής (γιαούρτι) — βραδινό (23:30 – 05:30) ──
  // hasNight = true σημαίνει «υπάρχει χωριστή βραδινή τιμή».
  // Αν false → το βράδυ χρησιμοποιείται η ημερήσια τιμή.
  final bool           hasNight;
  final CommissionType nightCommissionType;
  final double         nightCommissionValue; // μπορεί να είναι ΑΡΝΗΤΙΚΟ
  // ── Προμήθεια App (2η) ──
  final CommissionType appCommissionType;
  final double         appCommissionValue; // 0 = δεν έχει
  final String         createdBy;
  final bool           isGlobal; // true = διαθέσιμη σε όλους (π.χ. Standard Rate)

  const JobSource({
    required this.id,
    required this.name,
    required this.commissionType,
    required this.commissionValue,
    this.hasNight             = false,
    this.nightCommissionType  = CommissionType.fixed,
    this.nightCommissionValue = 0,
    this.appCommissionType  = CommissionType.fixed,
    this.appCommissionValue = 0,
    required this.createdBy,
    this.isGlobal = false,
  });

  factory JobSource.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data()!;
    return JobSource(
      id:              doc.id,
      name:            d['name']           ?? '',
      commissionType:  CommissionType.values.firstWhere(
              (e) => e.name == (d['commissionType'] ?? 'fixed'),
          orElse: () => CommissionType.fixed),
      commissionValue: (d['commissionValue'] as num?)?.toDouble() ?? 0,
      hasNight:        (d['hasNight'] as bool?) ?? false,
      nightCommissionType: CommissionType.values.firstWhere(
              (e) => e.name == (d['nightCommissionType'] ?? 'fixed'),
          orElse: () => CommissionType.fixed),
      nightCommissionValue:
          (d['nightCommissionValue'] as num?)?.toDouble() ?? 0,
      appCommissionType: CommissionType.values.firstWhere(
              (e) => e.name == (d['appCommissionType'] ?? 'fixed'),
          orElse: () => CommissionType.fixed),
      appCommissionValue: (d['appCommissionValue'] as num?)?.toDouble() ?? 0,
      createdBy:       d['createdBy']       ?? '',
      isGlobal:        (d['isGlobal'] as bool?) ?? false,
    );
  }

  Map<String, dynamic> toMap() => {
    'name':               name,
    'commissionType':     commissionType.name,
    'commissionValue':    commissionValue,
    'hasNight':             hasNight,
    'nightCommissionType':  nightCommissionType.name,
    'nightCommissionValue': nightCommissionValue,
    'appCommissionType':  appCommissionType.name,
    'appCommissionValue': appCommissionValue,
    'createdBy':          createdBy,
    'isGlobal':           isGlobal,
  };

  // Υπολογισμός προμήθειας πηγής (ΗΜΕΡΗΣΙΑ) — χωρίς στρογγυλοποίηση.
  // Μπορεί να επιστρέψει ΑΡΝΗΤΙΚΟ (διαχειριστής χρωστάει στον οδηγό).
  double calculate(double price) {
    if (commissionType == CommissionType.fixed) return commissionValue;
    // Ποσοστό: π.χ. 10% × 55€ = 5.50€ (ΟΧΙ round)
    return price * commissionValue / 100;
  }

  // Υπολογισμός προμήθειας πηγής (ΒΡΑΔΙΝΗ). Αν δεν έχει βραδινή → ημερήσια.
  double calculateNight(double price) {
    if (!hasNight) return calculate(price);
    if (nightCommissionType == CommissionType.fixed) return nightCommissionValue;
    return price * nightCommissionValue / 100;
  }

  // Διαλέγει ημερήσια/βραδινή ανάλογα με το isNight.
  double calculateFor(double price, bool isNight) =>
      isNight ? calculateNight(price) : calculate(price);

  // Υπολογισμός προμήθειας App
  double calculateApp(double price) {
    if (appCommissionValue == 0) return 0;
    if (appCommissionType == CommissionType.fixed) return appCommissionValue;
    return price * appCommissionValue / 100;
  }

  // Συνολική προμήθεια (πηγή + app)
  double calculateTotal(double price) => calculate(price) + calculateApp(price);

  String label(double price) {
    final amount = calculate(price);
    // Αρνητικό = ο διαχειριστής δίνει στον οδηγό (το δείχνουμε με +).
    if (commissionType == CommissionType.fixed) {
      final v = commissionValue;
      final sign = v < 0 ? '+' : '-';
      return '$name ($sign${v.abs().toStringAsFixed(2)}€)';
    }
    final sign = amount < 0 ? '+' : '-';
    return '$name ($sign${commissionValue.abs().toStringAsFixed(1)}% '
        '= $sign${amount.abs().toStringAsFixed(2)}€)';
  }
}
// ─── Billing — Συναλλαγή χρέωσης/πληρωμής ────────────────────────────────────
class BillingTx {
  final String   id;
  final String   uid;        // οδηγός
  final String   uidName;    // όνομα οδηγού
  final String   monthKey;   // 'YYYY-MM' — σε ποιον μήνα ανήκει
  final String   type;       // 'charge' | 'payment'
  final String   category;   // 'source_commission' | 'app_commission' | 'subscription' | 'payment'
  final double   amount;     // πάντα θετικό
  final String   sourceId;
  final String   sourceName;
  final String   adminUid;   // (παλιό) ο admin που έβγαλε τη δουλειά
  final String   adminName;
  // ── ΝΕΟ: σε ποιον ΑΝΗΚΟΥΝ τα λεφτά (recipient) ──
  // Γιαούρτι → ο poster της δουλειάς. App + συνδρομή → 'MASTER'.
  final String   recipientUid;
  final String   recipientName;
  // ── ΝΕΟ: ποιος τα ΜΑΖΕΥΕΙ φυσικά από τον οδηγό (collector) ──
  // = admin της ομάδας της δουλειάς, αλλιώς της σπιτικής ομάδας, αλλιώς ο poster.
  final String   collectorUid;
  final String   collectorName;
  final String   jobId;
  final String   note;
  final bool     voided;     // true → ακυρώθηκε (π.χ. ακύρωση δουλειάς)
  final DateTime createdAt;

  const BillingTx({
    required this.id,
    required this.uid,
    required this.uidName,
    this.monthKey   = '',
    required this.type,
    required this.category,
    required this.amount,
    this.sourceId   = '',
    this.sourceName = '',
    this.adminUid   = '',
    this.adminName  = '',
    this.recipientUid  = '',
    this.recipientName = '',
    this.collectorUid  = '',
    this.collectorName = '',
    this.jobId      = '',
    this.note       = '',
    this.voided     = false,
    required this.createdAt,
  });

  factory BillingTx.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data()!;
    return BillingTx(
      id:         doc.id,
      uid:        d['uid']        ?? '',
      uidName:    d['uidName']    ?? '',
      monthKey:   d['monthKey']   ?? '',
      type:       d['type']       ?? 'charge',
      category:   d['category']   ?? 'app_commission',
      amount:     (d['amount'] as num?)?.toDouble() ?? 0,
      sourceId:   d['sourceId']   ?? '',
      sourceName: d['sourceName'] ?? '',
      adminUid:   d['adminUid']   ?? '',
      adminName:  d['adminName']  ?? '',
      // Fallback σε adminUid/adminName για παλιές εγγραφές χωρίς recipient.
      recipientUid:  d['recipientUid']  ?? d['adminUid']  ?? '',
      recipientName: d['recipientName'] ?? d['adminName'] ?? '',
      collectorUid:  d['collectorUid']  ?? '',
      collectorName: d['collectorName'] ?? '',
      jobId:      d['jobId']      ?? '',
      note:       d['note']       ?? '',
      voided:     (d['voided'] as bool?) ?? false,
      createdAt:  (d['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  bool get isCharge  => type == 'charge';
  bool get isPayment => type == 'payment';
  // Ταυτότητα παραλήπτη για ομαδοποίηση (master ή συγκεκριμένος admin).
  bool get isForMaster => recipientUid == 'MASTER' ||
      category == 'app_commission' || category == 'subscription' ||
      category == 'calendar_subscription';

  String get categoryLabel {
    switch (category) {
      case 'source_commission': return 'Προμήθεια πηγής';
      case 'app_commission':    return 'Προμήθεια App';
      case 'commission':        return 'Προμήθεια δουλειάς';
      case 'subscription':      return 'Μηνιαία συνδρομή';
      case 'calendar_subscription': return 'Συνδρομή ημερολογίου';
      case 'payment':           return 'Πληρωμή';
      default:                  return category;
    }
  }
}

// ─── Μηνιαία ανάλυση χρέωσης ─────────────────────────────────────────────────

/// Μία χρέωση (μιας δουλειάς ή συνδρομής) με το πόσο της έχει ήδη πληρωθεί.
/// Οι πληρωμές «δένονται» με τη χρέωση μέσω (jobId, recipientUid, monthKey) —
/// έτσι βγαίνει η κατάσταση κάθε δουλειάς: πληρωμένη / μερική / οφείλεται.
class ChargeDetail {
  final String   jobId;
  final String   note;         // «Από → Προς» της δουλειάς
  final String   category;     // source_commission / app_commission / ...
  final String   sourceName;
  final String   recipientUid;
  final double   amount;       // ποσό χρέωσης
  final double   paid;         // πόσο έχει εξοφληθεί (0..amount)
  final DateTime createdAt;

  const ChargeDetail({
    required this.jobId,
    required this.note,
    required this.category,
    required this.sourceName,
    required this.recipientUid,
    required this.amount,
    required this.paid,
    required this.createdAt,
  });

  // Για ΘΕΤΙΚΗ χρέωση: υπόλοιπο = amount - paid (≥ 0).
  // Για ΑΡΝΗΤΙΚΗ χρέωση (πίστωση προς τον οδηγό): δεν «εξοφλείται» από τον
  // οδηγό — το υπόλοιπο είναι το ίδιο το αρνητικό ποσό.
  double get left =>
      amount < 0 ? amount : (amount - paid).clamp(0, double.infinity);
  // «Πληρωμένη» ΜΟΝΟ για θετικές χρεώσεις που έχουν εξοφληθεί.
  // Οι αρνητικές (πιστώσεις) ΔΕΝ θεωρούνται πληρωμένες.
  bool get isPaid    => amount >= 0 && (amount - paid) <= 0.01;
  bool get isPartial => paid > 0.01 && !isPaid && amount > 0;
  // true = ο διαχειριστής χρωστάει στον οδηγό (αρνητική χρέωση).
  bool get isCredit  => amount < -0.01;
}

class MonthlyBilling {
  final String monthKey;
  final double subscription;
  final double calendarSubscription;
  final double appCommission;
  // Προμήθεια πηγής ανά πηγή: sourceName → ποσό
  final Map<String, double> bySource;
  // Χρωστούμενα ανά admin: adminName → ποσό
  final Map<String, double> byAdmin;
  final double charges;   // σύνολο χρεώσεων
  final double payments;  // σύνολο πληρωμών
  // Αναλυτικές χρεώσεις (με paid ανά χρέωση) — για το expand ανά πηγή/δουλειά.
  final List<ChargeDetail> details;

  const MonthlyBilling({
    required this.monthKey,
    this.subscription  = 0,
    this.calendarSubscription = 0,
    this.appCommission = 0,
    this.bySource      = const {},
    this.byAdmin       = const {},
    this.charges       = 0,
    this.payments      = 0,
    this.details       = const [],
  });

  double get balance => charges - payments;

  // Υπόλοιπο ΜΟΝΟ για χρεώσεις όπου παραλήπτης είναι ο [recipientUid]
  // (π.χ. admin → τα δικά του γιαούρτια). Αθροίζει το left κάθε σχετικής
  // χρέωσης (θετικό = χρωστάει ο οδηγός, αρνητικό = του χρωστάς).
  double balanceForRecipient(String recipientUid) =>
      details
          .where((d) => d.recipientUid == recipientUid)
          .fold<double>(0, (s, d) => s + d.left);
  // Πληρωμένος μήνας:
  //  • Θετικές χρεώσεις → εξοφλήθηκαν (balance ~ 0)
  //  • Αρνητικές χρεώσεις (ο διαχειριστής χρωστάει) → δόθηκαν στον οδηγό (balance ~ 0)
  bool get paid =>
      charges.abs() > 0.001 && balance.abs() <= 0.01;
  // true = ο διαχειριστής χρωστάει στον οδηγό σε αυτόν τον μήνα.
  bool get isCreditMonth => balance < -0.01;

  String get monthLabel {
    const months = [
      '', 'Ιανουάριος', 'Φεβρουάριος', 'Μάρτιος', 'Απρίλιος',
      'Μάιος', 'Ιούνιος', 'Ιούλιος', 'Αύγουστος', 'Σεπτέμβριος',
      'Οκτώβριος', 'Νοέμβριος', 'Δεκέμβριος',
    ];
    final parts = monthKey.split('-');
    if (parts.length != 2) return monthKey;
    final m = int.tryParse(parts[1]) ?? 0;
    if (m < 1 || m > 12) return monthKey;
    return '${months[m]} ${parts[0]}';
  }

  /// Υπολογίζει τη μηνιαία ανάλυση από λίστα συναλλαγών (ενός οδηγού).
  static List<MonthlyBilling> fromTransactions(List<BillingTx> txs) {
    final byMonth = <String, List<BillingTx>>{};
    for (final t in txs) {
      if (t.voided) continue;
      final mk = t.monthKey.isNotEmpty ? t.monthKey : 'άγνωστος';
      byMonth.putIfAbsent(mk, () => []).add(t);
    }
    final result = <MonthlyBilling>[];
    byMonth.forEach((mk, list) {
      double sub = 0, calSub = 0, app = 0, charges = 0, payments = 0;
      final bySource = <String, double>{};
      final byAdmin  = <String, double>{};

      // ── Ταίριασμα πληρωμών ↔ χρεώσεων ──────────────────────────────────
      // Κάθε payment tx γράφτηκε με το jobId & recipientUid της χρέωσης που
      // εξοφλεί (FIFO στο recordPayment). Κλειδί: jobId|recipientUid.
      final paidByKey = <String, double>{};
      for (final t in list) {
        if (t.isPayment && (t.jobId.isNotEmpty || t.recipientUid.isNotEmpty)) {
          final k = '${t.jobId}|${t.recipientUid}';
          paidByKey[k] = (paidByKey[k] ?? 0) + t.amount;
        }
      }
      // Κατανομή του paid στις χρεώσεις του ίδιου κλειδιού, παλιότερες πρώτα.
      final chargesSorted = list.where((t) => t.isCharge).toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      final details = <ChargeDetail>[];
      for (final c in chargesSorted) {
        final k = '${c.jobId}|${c.recipientUid}';
        final pool = paidByKey[k] ?? 0;
        final paid = pool >= c.amount ? c.amount : pool;
        paidByKey[k] = pool - paid;
        details.add(ChargeDetail(
          jobId:        c.jobId,
          note:         c.note,
          category:     c.category,
          sourceName:   c.sourceName,
          recipientUid: c.recipientUid,
          amount:       c.amount,
          paid:         paid,
          createdAt:    c.createdAt,
        ));
      }

      for (final t in list) {
        if (t.isPayment) {
          payments += t.amount;
          continue;
        }
        charges += t.amount;
        switch (t.category) {
          case 'subscription':
            sub += t.amount;
            byAdmin['Σύστημα (App)'] =
                (byAdmin['Σύστημα (App)'] ?? 0) + t.amount;
            break;
          case 'calendar_subscription':
            calSub += t.amount;
            byAdmin['Ημερολόγιο'] =
                (byAdmin['Ημερολόγιο'] ?? 0) + t.amount;
            break;
          case 'app_commission':
            app += t.amount;
            final a = t.adminName.isNotEmpty ? t.adminName : 'App';
            byAdmin[a] = (byAdmin[a] ?? 0) + t.amount;
            break;
          case 'source_commission':
            final s = t.sourceName.isNotEmpty ? t.sourceName : 'Πηγή';
            bySource[s] = (bySource[s] ?? 0) + t.amount;
            final a = t.adminName.isNotEmpty ? t.adminName : 'Admin';
            byAdmin[a] = (byAdmin[a] ?? 0) + t.amount;
            break;
          default:
            break;
        }
      }
      result.add(MonthlyBilling(
        monthKey:      mk,
        subscription:  sub,
        calendarSubscription: calSub,
        appCommission: app,
        bySource:      bySource,
        byAdmin:       byAdmin,
        charges:       charges,
        payments:      payments,
        details:       details,
      ));
    });
    // Νεότερος μήνας πρώτα
    result.sort((a, b) => b.monthKey.compareTo(a.monthKey));
    return result;
  }
}

// ─── Εκκαθάριση μεταξύ collector → recipient ─────────────────────────────────
// Καταγράφει ότι ο collector προώθησε ποσό στον παραλήπτη (admin ή master).
class Settlement {
  final String   id;
  final String   collectorUid;
  final String   collectorName;
  final String   recipientUid;
  final String   recipientName;
  final double   amount;
  final String   note;
  final DateTime createdAt;

  const Settlement({
    required this.id,
    required this.collectorUid,
    required this.collectorName,
    required this.recipientUid,
    required this.recipientName,
    required this.amount,
    this.note = '',
    required this.createdAt,
  });

  factory Settlement.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data()!;
    return Settlement(
      id:            doc.id,
      collectorUid:  d['collectorUid']  ?? '',
      collectorName: d['collectorName'] ?? '',
      recipientUid:  d['recipientUid']  ?? '',
      recipientName: d['recipientName'] ?? '',
      amount:        (d['amount'] as num?)?.toDouble() ?? 0,
      note:          d['note'] ?? '',
      createdAt:     (d['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }
}
