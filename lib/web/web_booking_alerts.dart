// ============================================================================
// FILE: ./lib/web/web_booking_alerts.dart
// ============================================================================
//
// ΕΙΔΟΠΟΙΗΣΗ «ΝΕΑ ΚΡΑΤΗΣΗ ΑΠΟ ΦΟΡΜΑ» — ΓΙΑ ΤΟ WEB ADMIN PANEL.
//
// Μέχρι τώρα το web panel ΔΕΝ είχε καμία ειδοποίηση κράτησης: ούτε FCM
// (δεν υπάρχει service worker) ούτε in-app popup. Όποιος διαχειριστής
// δούλευε από browser δεν καταλάβαινε ΠΟΤΕ ότι μπήκε νέα κράτηση από τη
// φόρμα του — η δουλειά απλώς εμφανιζόταν σιωπηλά στα «Αποθηκευμένα».
//
// Εδώ στήνουμε ΤΟΝ ΙΔΙΟ Firestore listener με το κινητό
// (public_booking_alert.dart):
//     saved_jobs  where origin == 'public_form'
//                 and   ownerUid == myUid        ← ΜΟΝΟ οι δικές μου
//                 and   tenantId == myTenantId   ← απαραίτητο για τα rules
//
// Δηλαδή: ο κάθε ιδιοκτήτης φόρμας ακούει ΜΟΝΟ τις κρατήσεις της δικής του
// online φόρμας (master → booking.html, Σερέτης → #seretis_form, κ.ο.κ.).
//
// Όσο το tab είναι ανοιχτό: ήχος σε επανάληψη + popup στη μέση με μετρητή.
// Ο ήχος σταματά με «ΟΚ». (Push όταν το tab είναι κλειστό ΔΕΝ γίνεται —
// θα χρειαζόταν service worker· εδώ καλύπτουμε το «ανοιχτό panel».)

import 'dart:async';
import '../jobs/new_saved_badge_store.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../app_theme.dart';

class WebBookingAlerts {
  WebBookingAlerts._();
  static final WebBookingAlerts instance = WebBookingAlerts._();

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sub;
  AudioPlayer? _player;

  bool _primed = false;
  final Set<String> _seenIds = {};
  bool _dialogOpen = false;
  int _pendingCount = 0;
  final List<String> _lines = [];
  void Function(void Function())? _setStateInDialog;

  /// Το context του shell — για να ανοίγει το dialog από οπουδήποτε.
  BuildContext? _ctx;

  /// Ξεκινά τον listener. Ασφαλές να κληθεί πολλές φορές.
  Future<void> start(BuildContext context) async {
    _ctx = context;
    if (_sub != null) return;

    final myUid = FirebaseAuth.instance.currentUser?.uid;
    if (myUid == null) return;

    // ⚠️ ΚΡΙΣΙΜΟ: τα Firestore rules για saved_jobs απαιτούν ΚΑΙ
    // sameTenantAsResource(). Query μόνο με ownerUid απορρίπτεται ΟΛΟΚΛΗΡΟ
    // (permission-denied) για κάθε μη-master χρήστη — γι' αυτό μπαίνει και
    // το tenantId στο ίδιο το query.
    String? tenantId;
    try {
      final p = await FirebaseFirestore.instance
          .collection('presence').doc(myUid).get();
      tenantId = p.data()?['tenantId'] as String?;
    } catch (_) {}

    Query<Map<String, dynamic>> q = FirebaseFirestore.instance
        .collection('saved_jobs')
        .where('origin', isEqualTo: 'public_form')
        .where('ownerUid', isEqualTo: myUid);
    if (tenantId != null && tenantId.isNotEmpty) {
      q = q.where('tenantId', isEqualTo: tenantId);
    }

    _primed = false;
    _seenIds.clear();
    _sub = q.snapshots().listen(_onSnapshot, onError: (e) {
      debugPrint('WebBookingAlerts listener error: $e');
    });
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
    _primed = false;
    _seenIds.clear();
    _stopSound();
  }

  void _onSnapshot(QuerySnapshot<Map<String, dynamic>> snap) {
    // Πρώτο snapshot = «γέμισμα» χωρίς popup. Το priming γίνεται ΜΟΝΟ σε
    // snapshot από τον server: το πρώτο έρχεται συχνά άδειο από την cache
    // και το επόμενο θα έβλεπε ΟΛΑ τα docs σαν 'added'.
    if (!_primed) {
      for (final d in snap.docs) {
        _seenIds.add(d.id);
      }
      if (snap.metadata.isFromCache) return;
      _primed = true;
      return;
    }

    for (final change in snap.docChanges) {
      if (change.type != DocumentChangeType.added) continue;
      final id = change.doc.id;
      if (_seenIds.contains(id)) continue;
      _seenIds.add(id);

      final data = change.doc.data() ?? {};
      // Ασφαλιστική δικλείδα: αγνόησε παλιές κρατήσεις (>2 λεπτά) σε
      // περίπτωση που το priming έτρεξε με μη έτοιμο αποτέλεσμα.
      final savedAt = (data['savedAt'] as Timestamp?)?.toDate();
      if (savedAt != null &&
          DateTime.now().difference(savedAt) > const Duration(minutes: 2)) {
        continue;
      }

      // Σήμα «ΝΕΑ» στη λίστα Αποθηκευμένων — σβήνει μόνο όταν ανοιχτεί
      // η καρτέλα λεπτομερειών της κράτησης.
      NewSavedBadgeStore.markNew(id);

      final from = (data['from'] ?? '').toString();
      final to = (data['to'] ?? '').toString();
      final name = (data['clientName'] ?? '').toString();
      final no = (data['bookingNumber'] ?? '').toString();
      _lines.add(
        '${no.isNotEmpty ? '#$no · ' : ''}$from → $to${name.isNotEmpty ? ' · $name' : ''}',
      );
      _startSound();
      _bump();
    }
  }

  // ── Ήχος ───────────────────────────────────────────────────────────────
  Future<void> _startSound() async {
    try {
      _player ??= AudioPlayer();
      await _player!.setAsset('assets/Notifaction Bell.mp3');
      await _player!.setLoopMode(LoopMode.one);
      await _player!.play();
    } catch (e) {
      debugPrint('WebBookingAlerts sound error: $e');
    }
  }

  Future<void> _stopSound() async {
    try {
      await _player?.stop();
    } catch (_) {}
  }

  // ── Popup ──────────────────────────────────────────────────────────────
  void _bump() {
    _pendingCount++;
    if (_dialogOpen) {
      _setStateInDialog?.call(() {});
      return;
    }
    _showDialog();
  }

  Future<void> _showDialog() async {
    final ctx = _ctx;
    if (ctx == null || !ctx.mounted) {
      await _stopSound();
      return;
    }
    _dialogOpen = true;

    await showDialog<void>(
      context: ctx,
      barrierDismissible: false,
      builder: (dctx) {
        final ac = AppColors.of(dctx);
        return StatefulBuilder(
          builder: (sctx, setSt) {
            _setStateInDialog = setSt;
            return Dialog(
              backgroundColor: ac.card,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: ac.amberSoft,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Icon(Icons.event_available_rounded,
                              color: ac.amberDeep, size: 26),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            _pendingCount > 1
                                ? '$_pendingCount νέες κρατήσεις από φόρμα'
                                : 'Νέα κράτηση από φόρμα',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: ac.textMain,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 260),
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final l in _lines.reversed)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 10),
                                  decoration: BoxDecoration(
                                    color: ac.scaffold,
                                    border: Border.all(color: ac.cardBorder),
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: Text(
                                    l,
                                    style: TextStyle(
                                        fontSize: 14, color: ac.textMain),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Θα τη βρεις στις «Αποθηκευμένες δουλειές».',
                      style: TextStyle(fontSize: 13, color: ac.textFaint),
                    ),
                    const SizedBox(height: 16),
                    // ── «Δες την τώρα» → ανοίγει τις Αποθηκευμένες ──
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: ac.amber,
                          foregroundColor: ac.onAmber,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        onPressed: () {
                          Navigator.of(dctx).pop();
                          openSavedJobsRequest.value++;
                        },
                        icon: const Icon(Icons.folder_open_rounded, size: 20),
                        label: const Text('Δες τες τώρα',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w700)),
                      ),
                    ),
                    const SizedBox(height: 9),
                    // ── «Αργότερα» → κλείνει, ΑΛΛΑ το σήμα «ΝΕΑ» μένει ──
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: ac.textFaint,
                          side: BorderSide(color: ac.cardBorder, width: 1.5),
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        onPressed: () => Navigator.of(dctx).pop(),
                        child: const Text('Αργότερα',
                            style: TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    _dialogOpen = false;
    _setStateInDialog = null;
    _pendingCount = 0;
    _lines.clear();
    await _stopSound();
  }
}
