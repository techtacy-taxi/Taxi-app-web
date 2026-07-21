// lib/owner_alerts.dart
//
// In-app ειδοποιήσεις για τον OWNER (admin/master που έβγαλε τη δουλειά).
//
// Όταν η εφαρμογή είναι ΑΝΟΙΧΤΗ, ακούμε τις δουλειές μας από το Firestore και
// δείχνουμε modal dialog (με ΟΚ) ΠΑΝΩ ΑΠΟ κάθε οθόνη, μέσω του global
// navigatorKey. Όταν η εφαρμογή είναι εκτός/κλειστή, αναλαμβάνει ο background
// handler (fcm_service.dart -> _showOwnerBg) με native ειδοποίηση — και μόλις
// ανοίξεις την εφαρμογή, οι αδιάβαστες εμφανίζονται εδώ ως ουρά.
//
// ΟΥΡΑ & ΠΡΟΤΕΡΑΙΟΤΗΤΑ:
//   - Owner ειδοποιήσεις = ίδιας αξίας -> FIFO (παλιότερη πρώτη).
//   - Το dialog δείχνει "+N" όταν περιμένουν κι άλλες.
//   - Οι διεκδικήσεις δουλειάς (job_badge) έχουν ΥΨΗΛΟΤΕΡΗ προτεραιότητα: όταν
//     ανοίγει διεκδίκηση, το owner dialog κλείνει & η ειδοποίηση μένει στην
//     ουρά· συνεχίζει μόλις κλείσει η διεκδίκηση.
//
// Πατώντας πάνω στην κάρτα της δουλειάς ανοίγει η ΑΝΑΛΥΤΙΚΗ καρτέλα
// (JobDetailsSheet) για να δεις ακριβώς ποια δουλειά είναι.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'jobs/job_model.dart';
import 'jobs/job_details_sheet.dart';
import 'notifications_service.dart';
import 'alert_gate.dart';

enum OwnerEventKind { taken, boarded, stageAdvance, expired }

class OwnerAlert {
  final Job            job;
  final OwnerEventKind kind;
  final String         title;
  final String         body;
  final DateTime       at;
  OwnerAlert({
    required this.job,
    required this.kind,
    required this.title,
    required this.body,
    required this.at,
  });
}

class OwnerAlerts {
  OwnerAlerts._();
  static final OwnerAlerts instance = OwnerAlerts._();

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sub;
  String? _uid;
  bool _primed = false;
  bool _dialogOpen = false;

  // Αν true, το τρέχον dialog κλείνει λόγω διεκδίκησης (preempt): η ειδοποίηση
  // ξαναμπαίνει στην αρχή της ουράς αντί να καταναλωθεί.
  bool _preempting = false;
  OwnerAlert? _current;

  final Map<String, _JobState> _last = {};
  final List<OwnerAlert> _queue = [];

  void start(String uid) {
    if (uid.isEmpty) return;
    if (_uid == uid && _sub != null) return;
    stop();
    _uid = uid;
    _primed = false;
    _last.clear();
    _queue.clear();

    AlertGate.instance.onClaimPreempt = _preemptForClaim;
    AlertGate.instance.claimActive.addListener(_onClaimActiveChanged);

    _sub = FirebaseFirestore.instance
        .collection('jobs')
        .where('createdBy', isEqualTo: uid)
        .snapshots()
        .listen(_onSnapshot, onError: (_) {});
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    _uid = null;
    _last.clear();
    _queue.clear();
    _primed = false;
    if (AlertGate.instance.onClaimPreempt == _preemptForClaim) {
      AlertGate.instance.onClaimPreempt = null;
    }
    AlertGate.instance.claimActive.removeListener(_onClaimActiveChanged);
  }

  void _onClaimActiveChanged() {
    if (!AlertGate.instance.claimActive.value) _pump();
  }

  void _preemptForClaim() {
    if (!_dialogOpen) return;
    _preempting = true;
    NotificationsService.navigatorKey.currentState?.pop();
  }

  void _onSnapshot(QuerySnapshot<Map<String, dynamic>> snap) {
    if (!_primed) {
      for (final d in snap.docs) {
        final j = Job.fromDoc(d);
        _last[j.id] = _JobState(j.status, j.escalationStage);
      }
      _primed = true;
      return;
    }

    for (final change in snap.docChanges) {
      if (change.type == DocumentChangeType.removed) {
        _last.remove(change.doc.id);
        continue;
      }
      final j = Job.fromDoc(change.doc);
      final prev = _last[j.id];
      _last[j.id] = _JobState(j.status, j.escalationStage);
      if (prev == null) continue;

      // (1) Ανατέθηκε
      if (prev.status == JobStatus.open && j.status == JobStatus.taken) {
        final driver = (j.takenByName ?? '').trim();
        _enqueue(OwnerAlert(
          job:   j,
          kind:  OwnerEventKind.taken,
          title: 'Η δουλειά ανατέθηκε',
          body:  driver.isNotEmpty
              ? 'Ο/Η $driver πήρε τη δουλειά.'
              : 'Ένας οδηγός πήρε τη δουλειά.',
          at:    DateTime.now(),
        ));
        continue;
      }

      // (1β) Επιβίβαση — ο οδηγός πάτησε «Επιβίβαση», ο πελάτης μπήκε στο όχημα
      if (prev.status == JobStatus.taken && j.status == JobStatus.boarded) {
        final driver = (j.takenByName ?? '').trim();
        _enqueue(OwnerAlert(
          job:   j,
          kind:  OwnerEventKind.boarded,
          title: 'Επιβίβαση πελάτη',
          body:  driver.isNotEmpty
              ? 'Ο/Η $driver επιβίβασε τον πελάτη.'
              : 'Ο οδηγός επιβίβασε τον πελάτη.',
          at:    DateTime.now(),
        ));
        continue;
      }

      // (2) Καμία εξυπηρέτηση
      if (prev.status == JobStatus.open && j.status == JobStatus.expired) {
        _enqueue(OwnerAlert(
          job:   j,
          kind:  OwnerEventKind.expired,
          title: 'Καμία εξυπηρέτηση',
          body:  'Έληξαν όλα τα στάδια και κανείς δεν πήρε τη δουλειά.',
          at:    DateTime.now(),
        ));
        continue;
      }

      // (3) Έληξε ο χρόνος σταδίου
      if (j.status == JobStatus.open &&
          j.escalationStage > prev.stage &&
          !j.stopped) {
        _enqueue(OwnerAlert(
          job:   j,
          kind:  OwnerEventKind.stageAdvance,
          title: 'Έληξε ο χρόνος',
          body:  'Η δουλειά βγαίνει τώρα σε ${_audienceLabel(j)} '
              '(στάδιο ${j.stageNumber}/${j.totalStages}).',
          at:    DateTime.now(),
        ));
        continue;
      }
    }
  }

  String _audienceLabel(Job job) {
    if (job.currentStageRestrictsToBase) {
      return job.currentStageRequiresAvailable
          ? 'διαθέσιμους της βάσης'
          : 'όλη τη βάση';
    }
    return job.currentStageRequiresAvailable
        ? 'διαθέσιμους οδηγούς'
        : 'όλους τους οδηγούς';
  }

  void _enqueue(OwnerAlert a) {
    final dup =
        _queue.any((q) => q.job.id == a.job.id && q.kind == a.kind);
    if (!dup) _queue.add(a); // FIFO
    _pump();
  }

  Future<void> _pump() async {
    if (_dialogOpen) return;
    if (_queue.isEmpty) return;
    if (AlertGate.instance.claimActive.value) return; // διεκδίκηση -> περίμενε

    final alert = _queue.removeAt(0);
    _current = alert;
    await _show(alert);
  }

  // ── Εμφάνιση (στυλ ανά τύπο γεγονότος) ────────────────────────────────────
  ({IconData icon, Color color}) _styleOf(OwnerEventKind k) {
    switch (k) {
      case OwnerEventKind.taken:
        return (icon: Icons.check_circle_rounded,  color: Colors.green);
      case OwnerEventKind.boarded:
        return (icon: Icons.directions_car_rounded, color: Colors.blue);
      case OwnerEventKind.stageAdvance:
        return (icon: Icons.timer_rounded,         color: Colors.orange);
      case OwnerEventKind.expired:
        return (icon: Icons.error_rounded,         color: Colors.red);
    }
  }

  Future<void> _show(OwnerAlert a) async {
    final nav = NotificationsService.navigatorKey.currentState;
    final ctx = nav?.overlay?.context;
    if (ctx == null) {
      _queue.insert(0, a);
      _current = null;
      return;
    }

    _dialogOpen = true;
    _preempting = false;
    final remaining = _queue.length;
    final st = _styleOf(a.kind);
    final j  = a.job;
    final route = (j.from.isNotEmpty || j.to.isNotEmpty)
        ? '${j.from} → ${j.to}'
        : '';

    try {
      await showDialog<void>(
        context: ctx,
        barrierDismissible: false,
        barrierColor: Colors.black.withValues(alpha: 0.35),
        builder: (dctx) {
          final c = AppColors.of(dctx);
          return PopScope(
            canPop: false,
            child: Dialog(
              backgroundColor: c.card,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(22),
                  side: BorderSide(color: c.cardBorder, width: 0.8)),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 20, 18, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // ── Κεφαλίδα: στρογγυλεμένο τετράγωνο εικονίδιο (νέο στυλ)
                    Row(
                      children: [
                        Container(
                          width: 44, height: 44,
                          decoration: BoxDecoration(
                            color: st.color.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(13),
                          ),
                          child: Icon(st.icon, color: st.color, size: 25),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(a.title,
                              style: TextStyle(
                                  fontSize: 17.5,
                                  fontWeight: FontWeight.w700,
                                  color: c.textMain)),
                        ),
                        if (remaining > 0)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 9, vertical: 4),
                            decoration: BoxDecoration(
                              color:        c.amberSoft,
                              borderRadius: BorderRadius.circular(11),
                            ),
                            child: Text('+$remaining',
                                style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: c.amberDeep)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(a.body,
                        style: TextStyle(fontSize: 14.5, color: c.textMain)),
                    const SizedBox(height: 12),

                    // ── Κάρτα δουλειάς (νέο compact στυλ: αριστερή μπάρα
                    //    στο χρώμα του γεγονότος, tap -> αναλυτική καρτέλα)
                    InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () => _openDetails(dctx, j),
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(10, 10, 12, 10),
                        decoration: BoxDecoration(
                          color: c.scaffold,
                          borderRadius: BorderRadius.circular(14),
                          border: Border(
                            top:    BorderSide(color: c.cardBorder, width: 0.8),
                            right:  BorderSide(color: c.cardBorder, width: 0.8),
                            bottom: BorderSide(color: c.cardBorder, width: 0.8),
                            left:   BorderSide(color: st.color, width: 4),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.local_taxi_rounded,
                                color: c.amberDeep, size: 21),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (route.isNotEmpty)
                                    Text(route,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 13.5,
                                            color: c.textMain)),
                                  const SizedBox(height: 3),
                                  Row(children: [
                                    if (j.price > 0)
                                      Text('€${j.price.toStringAsFixed(2)}',
                                          style: TextStyle(
                                              color: c.greenDeep,
                                              fontWeight: FontWeight.w700,
                                              fontSize: 13.5)),
                                    const Spacer(),
                                    Text('Προβολή δουλειάς',
                                        style: TextStyle(
                                            fontSize: 12.5,
                                            color: c.blueDeep,
                                            fontWeight: FontWeight.w600)),
                                  ]),
                                ],
                              ),
                            ),
                            Icon(Icons.chevron_right_rounded,
                                color: c.textFaint),
                          ],
                        ),
                      ),
                    ),

                    if (remaining > 0) ...[
                      const SizedBox(height: 10),
                      Text(
                        'Σε περιμένουν άλλες $remaining '
                        '${remaining == 1 ? "ειδοποίηση" : "ειδοποιήσεις"}.',
                        style: TextStyle(fontSize: 12.5, color: c.textFaint),
                      ),
                    ],

                    const SizedBox(height: 14),
                    // ── Κύριο κουμπί (νέο στυλ: amber, στρογγυλεμένο) ──────
                    SizedBox(
                      height: 48,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: c.amber,
                          foregroundColor: c.onAmber,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                          textStyle: const TextStyle(
                              fontSize: 15.5, fontWeight: FontWeight.w700),
                        ),
                        onPressed: () => Navigator.of(dctx).pop(),
                        child: Text(remaining > 0 ? 'ΟΚ — Επόμενη' : 'ΟΚ'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    } catch (_) {
    } finally {
      _dialogOpen = false;
      if (_preempting) {
        if (_current != null) _queue.insert(0, _current!);
        _preempting = false;
        _current = null;
        // Θα ξανατρέξει όταν κλείσει η διεκδίκηση (_onClaimActiveChanged).
      } else {
        _current = null;
        _pump();
      }
    }
  }

  // Ανοίγει την αναλυτική καρτέλα δουλειάς ΠΑΝΩ από το dialog.
  void _openDetails(BuildContext dctx, Job job) {
    showModalBottomSheet(
      context: dctx,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => JobDetailsSheet(
        job: job,
        parentContext: dctx,
        hideComplete: true,   // μόνο προβολή
        historyMode: true,    // δείχνει δημιουργό & εκτελεστή
        openJobMode: true,    // banner κατάστασης ανάθεσης/επιβίβασης
      ),
    );
  }
}

class _JobState {
  final JobStatus status;
  final int stage;
  const _JobState(this.status, this.stage);
}
