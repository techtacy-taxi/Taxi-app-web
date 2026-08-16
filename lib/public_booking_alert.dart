// ==========================================
// FILE: ./lib/public_booking_alert.dart
// ==========================================
//
// ΕΙΔΟΠΟΙΗΣΗ «ΝΕΑ ΚΡΑΤΗΣΗ ΑΠΟ ΦΟΡΜΑ» — foreground popup (στη μέση).
//
// Δουλεύει με ΔΥΟ πηγές (για σιγουριά):
//   1) Firestore listener στο 'saved_jobs' (origin == 'public_form') —
//      ο ΑΞΙΟΠΙΣΤΟΣ τρόπος, ίδια τεχνική με το owner_alerts. Όταν η εφαρμογή
//      είναι ΑΝΟΙΧΤΗ και μπει νέα δουλειά από φόρμα → σκάει το popup.
//   2) FCM onMessage (αν φτάσει) — εφεδρικό, ίδιο popup.
//
// Μετρητής: αν έρθουν κι άλλες πριν πατηθεί «ΟΚ», ο αριθμός αυξάνεται (1→2→3)
// μέσα στο ίδιο dialog — ΔΕΝ ανοίγουν πολλά dialogs.
//
// Όταν η εφαρμογή είναι killed/background → αναλαμβάνει ο background handler
// (fcm_service.dart -> _showPublicBookingBg) με native ειδοποίηση.
//
// Εκκίνηση: PublicBookingAlerts.instance.start();  (μόνο για master)

import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'notifications_service.dart';
import 'jobs/new_saved_badge_store.dart';

class PublicBookingAlerts {
  PublicBookingAlerts._();
  static final PublicBookingAlerts instance = PublicBookingAlerts._();

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _fsSub;
  StreamSubscription<RemoteMessage>? _fcmSub;
  bool _primed = false;                 // αγνόησε τις υπάρχουσες στο 1ο snapshot
  final Set<String> _seenIds = {};      // για να μη μετράμε δύο φορές την ίδια
  bool _dialogOpen = false;
  int _pendingCount = 0;
  void Function(void Function())? _setStateInDialog;
  Timer? _dialogRetryTimer;

  // Τελευταία τιμή του publicBookingTapTick που έχουμε ήδη εξυπηρετήσει.
  // Χρειάζεται γιατί σε cold start ο μετρητής αυξάνεται ΠΡΙΝ τρέξει το
  // start() — άρα δεν αρκεί μόνο ο listener, ελέγχουμε και στην εκκίνηση.
  int _lastTapTick = 0;
  VoidCallback? _tapListener;

  /// Διαβάζει τα savedJobId που ειδοποιήθηκαν ήδη από το background isolate
  /// και τα βάζει στα _seenIds, ώστε ο foreground listener να μην ξαναχτυπήσει
  /// για την ίδια κράτηση μόλις ανοίξει η εφαρμογή από την ειδοποίηση.
  Future<void> _absorbBackgroundNotified() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();   // γράφτηκαν σε ΑΛΛΟ isolate — χωρίς reload δεν φαίνονται
      final list = prefs.getStringList(kBgNotifiedBookings) ?? const <String>[];
      _seenIds.addAll(list);
      await prefs.setStringList(kBgNotifiedBookings, const <String>[]);
    } catch (_) {}
  }

  /// Σταματά ΤΩΡΑ κάθε ήχο/δόνηση/ειδοποίηση κράτησης, χωρίς να κλείσει τυχόν
  /// ανοιχτό dialog. Καλείται όταν η εφαρμογή έρχεται στο προσκήνιο.
  Future<void> silenceNow() async {
    try { await stopRingtoneLoop(); } catch (_) {}
    try { await cancelPublicBookingNotifications(); } catch (_) {}
  }

  /// Καλείται από το map_page στο AppLifecycleState.resumed.
  Future<void> onAppResumed() async {
    await silenceNow();
    await _absorbBackgroundNotified();
  }

  /// Ξεκινά listeners. Ασφαλές να κληθεί πολλές φορές.
  Future<void> start() async {
    // Ασφαλιστική δικλείδα: το γεγονός ότι η εφαρμογή μόλις άνοιξε/ήρθε στο
    // προσκήνιο σημαίνει ότι ο master είδε ήδη την ειδοποίηση (ή/και θα δει
    // αμέσως το popup). Σβήνουμε προληπτικά κάθε native ειδοποίηση/ήχο που
    // μπορεί να έχει μείνει «κολλημένη» από background handler, ώστε να μην
    // χρειάζεται ποτέ να σκοτώσει κανείς την εφαρμογή για να σταματήσει.
    cancelPublicBookingNotifications();
    stopRingtoneLoop();
    // ⚠️ ΚΡΙΣΙΜΟ: πρέπει να γίνει ΠΡΙΝ στηθεί ο listener, αλλιώς το πρώτο
    // snapshot προλαβαίνει και ξαναχτυπάει για κράτηση που μόλις ειδοποιήθηκε.
    await _absorbBackgroundNotified();

    // 1) Firestore listener — ο αξιόπιστος τρόπος για foreground.
    if (_fsSub == null) {
      _primed = false;
      _seenIds.clear();
      final myUid = FirebaseAuth.instance.currentUser?.uid;
      if (myUid == null) return; // δεν είναι συνδεδεμένος — τίποτα να ακούσει

      // ⚠️ ΚΡΙΣΙΜΟ: τα Firestore rules για saved_jobs απαιτούν ΚΑΙ
      // sameTenantAsResource() (tenantId ίδιο με του χρήστη) πέρα από
      // isAdmin(). Ένα query που φιλτράρει ΜΟΝΟ σε ownerUid (χωρίς tenantId)
      // ΔΕΝ μπορεί να επαληθευτεί από τη Firestore βάσει του ΟΡΙΣΜΟΥ του
      // query — απορρίπτεται ΟΛΟΚΛΗΡΟ με permission-denied για ΚΑΘΕ μη-master
      // χρήστη (ο master περνάει γιατί παρακάμπτει το tenantId check). Αυτό
      // εξηγούσε γιατί η ειδοποίηση ΠΟΤΕ δεν ενεργοποιούνταν για tenant
      // owners (π.χ. Seretis) — το σφάλμα καταπινόταν σιωπηλά στο onError.
      // Λύση: προσθέτουμε ΚΑΙ tenantId στο ίδιο το query.
      String? tenantId;
      try {
        final pDoc = await FirebaseFirestore.instance
            .collection('presence').doc(myUid).get();
        tenantId = pDoc.data()?['tenantId'] as String?;
      } catch (_) {}

      Query<Map<String, dynamic>> q = FirebaseFirestore.instance
          .collection('saved_jobs')
          .where('origin', isEqualTo: 'public_form')
          .where('ownerUid', isEqualTo: myUid);
      if (tenantId != null && tenantId.isNotEmpty) {
        q = q.where('tenantId', isEqualTo: tenantId);
      }
      _fsSub = q.snapshots().listen(_onSnapshot, onError: (e) {
        debugPrint('PublicBookingAlerts listener error: $e');
      });
    }
    // 2β) Πάτημα της native ειδοποίησης «Νέα κράτηση από φόρμα».
    //
    // ⚠️ Χωρίς αυτό, το tap απλώς σταματούσε τον ήχο και ΔΕΝ εμφάνιζε τίποτα:
    // το payload έχει μόνο savedJobId (όχι jobId), οπότε οι tap handlers δεν
    // έκαναν καμία ενέργεια, ενώ το _absorbBackgroundNotified() είχε ήδη
    // σημειώσει την κράτηση ως «ειδωμένη» για τον Firestore listener.
    if (_tapListener == null) {
      _tapListener = () {
        final t = NotificationsService.publicBookingTapTick.value;
        if (t <= _lastTapTick) return;
        _lastTapTick = t;
        _bump();
      };
      NotificationsService.publicBookingTapTick.addListener(_tapListener!);
    }
    // Cold start: ο μετρητής μπορεί να αυξήθηκε πριν στηθεί ο listener.
    final tapNow = NotificationsService.publicBookingTapTick.value;
    if (tapNow > _lastTapTick) {
      _lastTapTick = tapNow;
      _bump();
    }

    // 3) FCM — εφεδρικό.
    _fcmSub ??= FirebaseMessaging.onMessage.listen((msg) {
      final type = (msg.data['type'] ?? '').toString();
      if (type == 'public_booking') {
        final id = (msg.data['savedJobId'] ?? '').toString();
        if (id.isNotEmpty && _seenIds.contains(id)) return; // ήδη το είδαμε
        if (id.isNotEmpty) _seenIds.add(id);
        _bump();
      }
    });
  }

  void dispose() {
    _dialogRetryTimer?.cancel(); _dialogRetryTimer = null;
    if (_tapListener != null) {
      NotificationsService.publicBookingTapTick.removeListener(_tapListener!);
      _tapListener = null;
    }
    _fsSub?.cancel(); _fsSub = null;
    _fcmSub?.cancel(); _fcmSub = null;
    _primed = false;
    _seenIds.clear();
  }

  void _onSnapshot(QuerySnapshot<Map<String, dynamic>> snap) {
    // Πρώτο snapshot: «γέμισε» τις υπάρχουσες χωρίς popup.
    //
    // ⚠️ ΚΡΙΣΙΜΟ: το ΠΡΩΤΟ snapshot έρχεται συχνά από την τοπική cache και
    // είναι ΑΔΕΙΟ (cold start). Αν κάναμε priming πάνω σε αυτό, το επόμενο
    // —πραγματικό— snapshot από τον server έβλεπε ΟΛΑ τα docs σαν 'added' και
    // ξαναχτυπούσε. Κάνουμε priming ΜΟΝΟ σε snapshot από τον server.
    if (!_primed) {
      for (final d in snap.docs) {
        _seenIds.add(d.id);
      }
      if (snap.metadata.isFromCache) return;   // περίμενε το server snapshot
      _primed = true;
      return;
    }
    // Επόμενα: πιάσε ΜΟΝΟ νέες προσθήκες.
    for (final change in snap.docChanges) {
      if (change.type == DocumentChangeType.added) {
        final id = change.doc.id;
        if (_seenIds.contains(id)) continue;
        _seenIds.add(id);
        final data = change.doc.data() ?? {};
        // ⚠️ ΑΣΦΑΛΙΣΤΙΚΗ ΔΙΚΛΕΙΔΑ: αν το priming (πάνω) έτρεξε με άδειο/μη
        // έτοιμο αποτέλεσμα (π.χ. auth όχι ακόμα έτοιμο στο cold start), το
        // ΠΡΑΓΜΑΤΙΚΟ snapshot που έρχεται αμέσως μετά βλέπει ΟΛΑ τα docs σαν
        // «νέα» (docChanges πάντα 'added' σε σχέση με άδεια cache) — και ο
        // master ξαναχτυπούσε για μια κράτηση που είχε ήδη ειδοποιηθεί/
        // κλείσει. Αγνόησε αθόρυβα κρατήσεις με savedAt παλιότερο από 2 λεπτά.
        final savedAt = (data['savedAt'] as Timestamp?)?.toDate();
        if (savedAt != null &&
            DateTime.now().difference(savedAt) > const Duration(minutes: 2)) {
          continue;
        }
        final from = (data['from'] ?? '').toString();
        final to   = (data['to'] ?? '').toString();
        // ΣΗΜΑΝΤΙΚΟ: περιμένουμε να ΞΕΚΙΝΗΣΕΙ πραγματικά ο ήχος πριν ανοίξει
        // το popup. Αλλιώς, αν ο master πατήσει «ΟΚ» πολύ γρήγορα, το stop
        // τρέχει πριν προλάβει να ξεκινήσει το startRingtoneLoop (async —
        // φόρτωμα mp3) και ο ήχος «ξεκινάει μετά το ΟΚ», σαν να μη σταματάει.
        // Σήμα «ΝΕΑ» στη λίστα Αποθηκευμένων — σβήνει μόνο όταν ο χρήστης
        // ανοίξει την καρτέλα λεπτομερειών αυτής της κράτησης.
        NewSavedBadgeStore.markNew(id);
        showPublicBookingNotification(savedJobId: id, from: from, to: to).then((_) {
          _bump();
        });
      }
    }
  }

  void _bump() {
    _pendingCount++;
    if (_dialogOpen) {
      _setStateInDialog?.call(() {});   // ανανέωσε τον μετρητή
      return;
    }
    _showDialog();
  }

  Future<void> _showDialog() async {
    final nav = NotificationsService.navigatorKey.currentState;
    final ctx = nav?.overlay?.context;

    // ⚠️ ΚΡΙΣΙΜΟ BUGFIX: πριν εδώ υπήρχε σκέτο `if (ctx == null) return;`.
    // Σε cold start (άνοιγμα από την ειδοποίηση) ο navigator δεν είναι ακόμα
    // έτοιμος, οπότε ο ήχος είχε ΗΔΗ ξεκινήσει, dialog δεν άνοιγε ποτέ, και
    // δεν υπήρχε κανένα «ΟΚ» να πατηθεί → έπρεπε να κλείσεις την εφαρμογή.
    if (ctx == null) {
      await silenceNow();
      _dialogRetryTimer?.cancel();
      _dialogRetryTimer = Timer(const Duration(milliseconds: 700), () {
        if (!_dialogOpen && _pendingCount > 0) _showDialog();
      });
      return;
    }
    _dialogRetryTimer?.cancel();
    _dialogRetryTimer = null;

    _dialogOpen = true;
    await showDialog<void>(
      context: ctx,
      barrierDismissible: false,
      builder: (dctx) => PopScope(
        canPop: false,
        child: StatefulBuilder(
        builder: (c, setLocal) {
          _setStateInDialog = setLocal;
          final n = _pendingCount;
          final word = n == 1 ? 'καινούργια δουλειά' : 'καινούργιες δουλειές';
          return Dialog(
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(22)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── ΚΙΤΡΙΝΟ HEADER (υδρόγειος + τίτλος), όπως οι άλλες ειδοποιήσεις
                Container(
                  width: double.infinity,
                  color: const Color(0xFFFFB300),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 18, vertical: 14),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.public_rounded,
                          color: Color(0xFF5A3D00), size: 26),
                      const SizedBox(width: 10),
                      const Text('Νέα κράτηση από φόρμα',
                          style: TextStyle(
                              color: Color(0xFF5A3D00),
                              fontSize: 17,
                              fontWeight: FontWeight.w900)),
                    ],
                  ),
                ),
                // ── ΠΕΡΙΕΧΟΜΕΝΟ
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 6),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFF3CD),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text('$n',
                              style: const TextStyle(
                                  color: Color(0xFF5A3D00),
                                  fontSize: 22,
                                  fontWeight: FontWeight.w900)),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Center(
                        child: Text(
                          '$n $word από τη φόρμα',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Center(
                        child: Text(
                          'Βρες τες στις «Αποθηκευμένες».',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 13.5, color: Colors.black54),
                        ),
                      ),
                      const SizedBox(height: 20),
                      // ── «Δες την τώρα» → ανοίγει τις Αποθηκευμένες ──
                      SizedBox(
                        height: 48,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFFFFB300),
                            foregroundColor: const Color(0xFF5A3D00),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                          onPressed: () {
                            Navigator.of(dctx).pop();
                            // Το map_page (Android) / admin_shell (web) το
                            // ακούει και ανοίγει την καρτέλα Αποθηκευμένες.
                            openSavedJobsRequest.value++;
                          },
                          icon: const Icon(Icons.folder_open_rounded, size: 20),
                          label: Text(
                              n == 1 ? 'Δες την τώρα' : 'Δες τες τώρα',
                              style: const TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w900)),
                        ),
                      ),
                      const SizedBox(height: 9),
                      // ── «Αργότερα» → κλείνει, ΑΛΛΑ το σήμα «ΝΕΑ» μένει ──
                      SizedBox(
                        height: 46,
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.black54,
                            side: BorderSide(color: Colors.grey.shade400,
                                width: 1.5),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                          onPressed: () => Navigator.of(dctx).pop(),
                          child: const Text('Αργότερα',
                              style: TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w700)),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
      ),
    );

    _dialogOpen = false;
    _pendingCount = 0;
    _setStateInDialog = null;
    // Σταμάτα τον συνεχόμενο ήχο + σβήσε τις σχετικές ειδοποιήσεις.
    try { await stopRingtoneLoop(); } catch (_) {}
    try { await cancelPublicBookingNotifications(); } catch (_) {}
  }
}
