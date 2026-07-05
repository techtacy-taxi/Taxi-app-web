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
import 'notifications_service.dart';

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

  /// Ξεκινά listeners. Ασφαλές να κληθεί πολλές φορές.
  void start() {
    // Ασφαλιστική δικλείδα: το γεγονός ότι η εφαρμογή μόλις άνοιξε/ήρθε στο
    // προσκήνιο σημαίνει ότι ο master είδε ήδη την ειδοποίηση (ή/και θα δει
    // αμέσως το popup). Σβήνουμε προληπτικά κάθε native ειδοποίηση/ήχο που
    // μπορεί να έχει μείνει «κολλημένη» από background handler, ώστε να μην
    // χρειάζεται ποτέ να σκοτώσει κανείς την εφαρμογή για να σταματήσει.
    cancelPublicBookingNotifications();

    // 1) Firestore listener — ο αξιόπιστος τρόπος για foreground.
    if (_fsSub == null) {
      _primed = false;
      _seenIds.clear();
      final myUid = FirebaseAuth.instance.currentUser?.uid;
      if (myUid == null) return; // δεν είναι συνδεδεμένος — τίποτα να ακούσει
      // ΣΗΜΑΝΤΙΚΟ: φιλτράρουμε με ownerUid == ο ίδιος — το vivaWebhook ήδη
      // αναθέτει κάθε δουλειά από τη δημόσια φόρμα στον master/tenant-owner
      // ΤΟΥ ΣΥΓΚΕΚΡΙΜΕΝΟΥ tenant (βλ. findMasterUid στο index.js). Έτσι:
      //   • Εσύ (master, tenant "default") βλέπεις/ακούς ΜΟΝΟ τις δικές σου.
      //   • Κάθε tenant-owner βλέπει/ακούει ΜΟΝΟ τις δικές του — σαν να τις
      //     είχε φτιάξει μόνος του και τις είχε αποθηκεύσει.
      // Χωρίς αυτό το φίλτρο, ΟΛΟΙ θα έβλεπαν/άκουγαν τις κρατήσεις ΟΛΩΝ
      // των tenants — διαρροή δεδομένων μεταξύ πελατών.
      _fsSub = FirebaseFirestore.instance
          .collection('saved_jobs')
          .where('origin', isEqualTo: 'public_form')
          .where('ownerUid', isEqualTo: myUid)
          .snapshots()
          .listen(_onSnapshot, onError: (_) {});
    }
    // 2) FCM — εφεδρικό.
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
    _fsSub?.cancel(); _fsSub = null;
    _fcmSub?.cancel(); _fcmSub = null;
    _primed = false;
    _seenIds.clear();
  }

  void _onSnapshot(QuerySnapshot<Map<String, dynamic>> snap) {
    // Πρώτο snapshot: «γέμισε» τις υπάρχουσες χωρίς popup.
    if (!_primed) {
      for (final d in snap.docs) {
        _seenIds.add(d.id);
      }
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
        final from = (data['from'] ?? '').toString();
        final to   = (data['to'] ?? '').toString();
        // ΣΗΜΑΝΤΙΚΟ: περιμένουμε να ΞΕΚΙΝΗΣΕΙ πραγματικά ο ήχος πριν ανοίξει
        // το popup. Αλλιώς, αν ο master πατήσει «ΟΚ» πολύ γρήγορα, το stop
        // τρέχει πριν προλάβει να ξεκινήσει το startRingtoneLoop (async —
        // φόρτωμα mp3) και ο ήχος «ξεκινάει μετά το ΟΚ», σαν να μη σταματάει.
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
    if (ctx == null) return;

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
                      SizedBox(
                        height: 48,
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFFFFB300),
                            foregroundColor: const Color(0xFF5A3D00),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                          onPressed: () => Navigator.of(dctx).pop(),
                          child: const Text('OK',
                              style: TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w900)),
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
