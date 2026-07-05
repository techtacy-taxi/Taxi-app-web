// lib/jobs/job_badge.dart
//
// FABs χάρτη (admin + driver) + JobListener.
// JobListener: ακούει νέες δουλειές. Εμφανίζει popup όταν app=foreground,
// notification όταν app=background. Όταν λήγει ο χρόνος ενός σταδίου μιας
// δουλειάς, προχωράει στο επόμενο στάδιο κλιμάκωσης (autoAdvanceStageIfNeeded).

import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models.dart';
import '../masters/masters_admin_page.dart';
import '../notifications_service.dart';
import '../alert_gate.dart';
import 'job_admin_page.dart';
import 'job_details_sheet.dart';
import 'job_model.dart';
import 'job_popup.dart';
import 'job_service.dart';
import 'job_shared_widgets.dart';
import 'my_jobs_sheet.dart';
import 'batch_accept_sheet.dart';

// Prefs key: ποιους εκκρεμείς προς έγκριση έχει ήδη ειδοποιηθεί ο master.
const String kPrefsNotifiedPending = 'notified_pending_approvals_v1';
// Prefs key: ποιες επιβιβάσεις έχει ήδη ειδοποιηθεί ο admin που τις έβγαλε.
const String kPrefsNotifiedBoarded = 'notified_boarded_jobs_v1';

// ─── Admin FAB ────────────────────────────────────────────────────────────────

class JobAdminFab extends StatelessWidget {
  final String       adminUid;
  final String       adminName;
  final bool         isMaster;
  final List<String> managedGroupIds;

  const JobAdminFab({
    super.key,
    required this.adminUid,
    this.adminName       = '',
    this.isMaster        = false,
    this.managedGroupIds = const [],
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Job>>(
      stream: JobService.allJobs(limit: 100),
      builder: (context, snap) {
        // Φιλτράρισμα ανοιχτών δουλειών:
        //   • Master (managedGroupIds == []) → όλες
        //   • Admin με συγκεκριμένες ομάδες → μόνο αυτές
        final allOpen = snap.data?.where((j) => j.isOpen) ?? <Job>[];
        final openCount = (isMaster || managedGroupIds.isEmpty)
            ? allOpen.length
            : allOpen.where((j) =>
                j.groupId != null &&
                managedGroupIds.contains(j.groupId)).length;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            FloatingActionButton(
              heroTag:         'jobs_admin',
              backgroundColor: Colors.black87,
              foregroundColor: Colors.white,
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => JobAdminPage(
                  adminUid:        adminUid,
                  adminName:       adminName,
                  isAdmin:         true,
                  isMaster:        isMaster,
                  managedGroupIds: managedGroupIds,
                ),
              )),
              child: const Icon(Icons.work_rounded),
            ),
            // Badge μετρητή — εμφανίζεται/κρύβεται με «αναπήδηση» και ο
            // αριθμός αλλάζει με scale animation (one-shot, μηδενικό κόστος).
            Positioned(
              top: -4, right: -4,
              child: AnimatedScale(
                scale:    openCount > 0 ? 1 : 0,
                duration: const Duration(milliseconds: 250),
                curve:    Curves.easeOutBack,
                child: Container(
                  padding: const EdgeInsets.all(5),
                  decoration: const BoxDecoration(
                      color: Colors.red, shape: BoxShape.circle),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    transitionBuilder: (child, anim) =>
                        ScaleTransition(scale: anim, child: child),
                    child: Text(
                      openCount > 9 ? '9+' : '$openCount',
                      key: ValueKey<int>(openCount),
                      style: const TextStyle(color: Colors.white,
                          fontSize: 10, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ─── Driver Jobs FAB ──────────────────────────────────────────────────────────

class DriverJobsFab extends StatelessWidget {
  final String uid;
  const DriverJobsFab({super.key, required this.uid});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('jobs')
          .where('takenBy', isEqualTo: uid)
          .where('status',  whereIn: [JobStatus.taken.name, JobStatus.boarded.name])
          .snapshots(),
      builder: (context, snap) {
        final takenJobs = snap.data?.docs
            .map((d) => Job.fromDoc(d)).toList() ?? [];

        if (takenJobs.isEmpty) return const SizedBox.shrink();

        return Stack(
          clipBehavior: Clip.none,
          children: [
            FloatingActionButton(
              heroTag:         'driver_jobs',
              backgroundColor: const Color(0xFF1E8E3E),
              foregroundColor: Colors.white,
              onPressed: () => showMyJobsSheet(context, takenJobs, uid),
              child: const Icon(Icons.work_rounded),
            ),
            Positioned(
              top: -4, right: -4,
              child: Container(
                padding: const EdgeInsets.all(5),
                decoration: const BoxDecoration(
                    color: Colors.amber, shape: BoxShape.circle),
                child: Text(
                  '${takenJobs.length}',
                  style: const TextStyle(color: Colors.black,
                      fontSize: 10, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ─── Job Listener ─────────────────────────────────────────────────────────────

class JobListener extends StatefulWidget {
  final String       uid;
  final String       displayName;
  final String       lastName;
  final String       vehicleType;
  final List<String> groupIds;
  final bool         isAvailable;
  final bool         isMaster;
  final bool         isAdmin;
  final Widget       child;

  const JobListener({
    super.key,
    required this.uid,
    required this.displayName,
    required this.lastName,
    required this.vehicleType,
    required this.groupIds,
    required this.isAvailable,
    this.isMaster = false,
    this.isAdmin  = false,
    required this.child,
  });

  @override
  State<JobListener> createState() => _JobListenerState();
}

class _JobListenerState extends State<JobListener> with WidgetsBindingObserver {
  StreamSubscription<List<Job>>? _jobsSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _broadcastSub;

  final Set<String>      _shownJobIds    = {};
  final Set<String>      _notifiedJobIds = {};
  Map<String, int>       _rejectedMap    = <String, int>{};
  bool                   _popupShowing   = false;
  bool                   _isFirstSnapshot = true;
  List<Job>              _lastOpenJobs   = const [];

  // ── Ουρά διεκδικήσεων: εμφανίζονται μία-μία ─────────────────────────────
  // Όταν φτάνουν πολλές δουλειές ταυτόχρονα, μπαίνουν σε σειρά. Δείχνουμε
  // την πρώτη ως popup και πάνω της ένα banner με πόσες περιμένουν πίσω.
  final List<Job>          _pendingQueue  = [];
  final Set<String>        _queuedJobIds  = {};
  final ValueNotifier<int> _pendingCount  = ValueNotifier<int>(0);
  // batchIds που έχουν ήδη εμφανιστεί ως λίστα «Αποδοχή όλων» (μην ξαναβγούν)
  final Set<String>        _shownBatchIds = {};

  int  _lastSeenBroadcastMs = 0;
  bool _upgradeDialogShowing = false;

  // ── Μήνυμα "ποιος πήρε τη δουλειά" ─────────────────────────────────────
  final Set<String> _announcedTaken = <String>{};

  // ── Υπενθυμίσεις ραντεβού (exact alarms) ───────────────────────────────
  // Δεν κάνουμε πια polling με Timer. Ακούμε τις προγραμματισμένες δουλειές
  // και αναθέτουμε στο NotificationsService να προγραμματίσει exact alarms.
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _scheduledSub;
  List<Job>   _myScheduledJobs    = const [];
  bool        _reminderDialogShowing = false;

  // ── Αιτήματα έγκρισης (μόνο master) ────────────────────────────────────
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _approvalSub;
  Set<String> _notifiedPending      = <String>{};
  bool        _approvalFirstSnapshot = true;
  bool        _approvalDialogShowing = false;

  // ── Επιβιβάσεις σε δικές μου δουλειές (admin/master) ───────────────────
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _boardedSub;
  Set<String> _notifiedBoarded      = <String>{};
  bool        _boardedFirstSnapshot = true;
  // Ουρά παραλαβών: εμφανίζονται μία-μία με μετρητή «εκκρεμούν N».
  final List<Job>          _boardedQueue     = [];
  final Set<String>        _boardedQueuedIds = {};
  final ValueNotifier<int> _boardedPending   = ValueNotifier<int>(0);
  bool                     _boardedPopupShowing = false;

  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadRejected();
    NotificationsService.pendingViewJobId.addListener(_onPendingView);
    NotificationsService.pendingViewBatchId.addListener(_onPendingViewBatch);
    NotificationsService.reminderTapTick.addListener(_checkPendingReminderCard);
    NotificationsService.approvalTapTick.addListener(_openApprovalsPage);

    _jobsSub = JobService.openJobsFor(
      uid:         widget.uid,
      vehicleType: widget.vehicleType,
      groupIds:    widget.groupIds,
    ).listen(_onJobsUpdate);

    _initBroadcastListener();
    _initScheduledReminders();
    _initApprovalListener();
    _initBoardedListener();
    // Αν άνοιξε η εφαρμογή με εκκρεμή υπενθύμιση ραντεβού
    _checkPendingReminderCard();
    // Αν άνοιξε η εφαρμογή με εκκρεμή ειδοποίηση αναβάθμισης
    _checkPendingUpgradeDialog();

    WidgetsBinding.instance.addPostFrameCallback((_) => _onPendingView());
    WidgetsBinding.instance.addPostFrameCallback((_) => _onPendingViewBatch());
  }

  // ─── Listener για broadcast αναβάθμισης από master ──────────────────────
  Future<void> _initBroadcastListener() async {
    final prefs  = await SharedPreferences.getInstance();
    final stored = prefs.getInt(kPrefsLastBroadcast);
    if (stored == null) {
      // Πρώτη εκτέλεση → θεώρησε ό,τι υπάρχει ήδη ως "ιδωμένο"
      _lastSeenBroadcastMs = DateTime.now().millisecondsSinceEpoch;
      await prefs.setInt(kPrefsLastBroadcast, _lastSeenBroadcastMs);
    } else {
      _lastSeenBroadcastMs = stored;
    }

    _broadcastSub = FirebaseFirestore.instance
        .collection('app_broadcasts')
        .doc('current')
        .snapshots()
        .listen(_onBroadcast);
  }

  Future<void> _onBroadcast(
      DocumentSnapshot<Map<String, dynamic>> doc) async {
    if (!doc.exists) return;
    final data   = doc.data();
    final sentAt = (data?['sentAt'] as Timestamp?)?.toDate();
    if (sentAt == null) return;

    final sentMs = sentAt.millisecondsSinceEpoch;
    if (sentMs <= _lastSeenBroadcastMs) return; // ήδη το είδαμε

    _lastSeenBroadcastMs = sentMs;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kPrefsLastBroadcast, sentMs);

    // Ο master που το έστειλε δεν χρειάζεται popup
    if (data?['sentBy'] == widget.uid) return;

    if (_isAppForeground) {
      if (!mounted) return;
      await _showUpgradeDialog();
    } else {
      // Background → ΜΟΝΟ αποθήκευση flag ώστε να εμφανιστεί το popup μόλις
      // ανοίξει η εφαρμογή. Την ίδια την ειδοποίηση τη στέλνει πλέον το
      // Cloud Function (onBroadcastCreated/Updated) ως high-priority FCM,
      // που χτυπά ακόμη και με κλειστή εφαρμογή. Έτσι ΔΕΝ εμφανίζεται διπλή.
      await prefs.setBool('pending_upgrade_dialog_v1', true);
    }
  }

  Future<void> _checkPendingUpgradeDialog() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('pending_upgrade_dialog_v1') != true) return;
      await prefs.remove('pending_upgrade_dialog_v1');
      if (!mounted) return;
      await _showUpgradeDialog();
    } catch (_) {}
  }

  Future<void> _showUpgradeDialog() async {
    if (_upgradeDialogShowing || !mounted) return;
    final ctx0 = _rootCtx;
    if (ctx0 == null) return;
    _upgradeDialogShowing = true;
    await showDialog<void>(
      context: ctx0,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
        title: Row(children: const [
          Icon(Icons.system_update_rounded, color: Colors.amber, size: 28),
          SizedBox(width: 10),
          Expanded(child: Text('Καινούργια Έκδοση',
              style: TextStyle(fontWeight: FontWeight.bold))),
        ]),
        content: const Text(
          'Παρακαλώ αναβαθμιστείτε στην καινούργια έκδοση της '
          'εφαρμογής που θα βρείτε εδώ.',
          style: TextStyle(fontSize: 15),
        ),
        actions: [
          AppButtonTonal(label: 'Αργότερα', onPressed: () => Navigator.pop(ctx)),
          AppButton(
            label: 'Έλεγχος αναβαθμίσεων',
            icon: Icons.download_rounded,
            color: Colors.amber,
            onPressed: () async {
              Navigator.pop(ctx);
              final uri = Uri.parse(kUpdateUrl);
              if (await canLaunchUrl(uri)) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
          ),
        ],
        ),
      ),
    );
    _upgradeDialogShowing = false;
  }

  // ─── Υπενθυμίσεις ραντεβού (30′ & 10′ πριν) μέσω EXACT ALARMS ───────────
  // Ακούμε τις δουλειές που έχει αναλάβει ο οδηγός. Σε κάθε αλλαγή,
  // ξανασυγχρονίζουμε τα προγραμματισμένα alarms: το NotificationsService
  // προγραμματίζει όσα ραντεβού έχουν μελλοντικά checkpoints και ακυρώνει
  // όσα δεν ισχύουν πλέον (ολοκληρώθηκαν / ακυρώθηκαν / άλλαξε η ώρα).
  Future<void> _initScheduledReminders() async {
    _scheduledSub = FirebaseFirestore.instance
        .collection('jobs')
        .where('takenBy', isEqualTo: widget.uid)
        .where('status',  whereIn: ['taken', 'boarded'])
        .snapshots()
        .listen((snap) {
      _myScheduledJobs = snap.docs
          .map((d) => Job.fromDoc(d))
          .where((j) => j.scheduledAt != null)
          .toList();
      // ignore: unawaited_futures
      _syncReminders();
    });
  }

  Future<void> _syncReminders() async {
    final specs = _myScheduledJobs
        .where((j) => j.scheduledAt != null)
        .map((j) => ReminderSpec(
              jobId:       j.id,
              from:        j.from,
              to:          j.to,
              scheduledAt: j.scheduledAt!,
            ))
        .toList();
    await NotificationsService.syncAppointmentReminders(specs);
  }

  // ─── Αιτήματα έγκρισης (μόνο master) ────────────────────────────────────
  // Ακούει τους χρήστες με isApproved == false. Όταν εμφανιστεί νέος:
  //   • foreground → dialog με κουμπί «Άνοιγμα Διαχειριστών»
  //   • background → notification (ξυπνάει & χτυπάει)
  // Κρατάμε σε prefs ποιους έχουμε ήδη ειδοποιήσει, ώστε να μην ξαναχτυπά
  // για τον ίδιο σε κάθε snapshot/άνοιγμα.
  Future<void> _initApprovalListener() async {
    if (!widget.isMaster) return;

    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getString(kPrefsNotifiedPending);
    if (raw != null) {
      try {
        _notifiedPending = Set<String>.from(jsonDecode(raw) as List);
      } catch (_) {}
    }

    _approvalSub = FirebaseFirestore.instance
        .collection('presence')
        .where('isApproved', isEqualTo: false)
        .snapshots()
        .listen(_onApprovalSnapshot);
  }

  Future<void> _onApprovalSnapshot(
      QuerySnapshot<Map<String, dynamic>> snap) async {
    // Εκκρεμείς χρήστες (όχι ο ίδιος ο master)
    final pending = snap.docs.where((d) => d.id != widget.uid).toList();
    final pendingIds = pending.map((d) => d.id).toSet();

    // Καθάρισε από το set όσους δεν είναι πλέον εκκρεμείς (εγκρίθηκαν/διαγράφηκαν)
    _notifiedPending.removeWhere((id) => !pendingIds.contains(id));

    // Νέοι εκκρεμείς που δεν έχουμε ξαναειδοποιήσει
    final fresh = pendingIds.difference(_notifiedPending);

    // Πρώτο snapshot: μάρκαρε τους υπάρχοντες ως «ιδωμένους» ΧΩΡΙΣ χτύπημα,
    // αλλά αν είμαστε foreground κι υπάρχουν εκκρεμείς, δείξε ένα ενημερωτικό
    // dialog μία φορά (ο master μόλις άνοιξε — καλό να ξέρει το backlog).
    if (_approvalFirstSnapshot) {
      _approvalFirstSnapshot = false;
      _notifiedPending = pendingIds;
      await _persistNotifiedPending();
      if (pending.isNotEmpty && _isAppForeground && mounted) {
        await _showApprovalDialog(pending);
      }
      return;
    }

    if (fresh.isEmpty) {
      await _persistNotifiedPending();
      return;
    }

    _notifiedPending.addAll(fresh);
    await _persistNotifiedPending();

    if (_isAppForeground && mounted) {
      // Δείξε τους ΝΕΟΥΣ εκκρεμείς αναλυτικά.
      final freshDocs = pending.where((d) => fresh.contains(d.id)).toList();
      await _showApprovalDialog(freshDocs);
    }
    // ΕΚΤΟΣ εφαρμογής: το FCM background handler εμφανίζει την ειδοποίηση.
    // (Το backend στέλνει push στους masters όταν δημιουργείται pending.)
  }

  Widget _approvalCard(Map<String, dynamic> m) {
    final name   = '${m['displayName'] ?? ''} ${m['lastName'] ?? ''}'.trim();
    final phone  = (m['phone'] ?? '').toString();
    final vModel = (m['vehicleModel'] ?? '').toString();
    final plate  = (m['plateNumber'] ?? '').toString();
    final vType  = (m['vehicleType'] ?? '').toString();
    final vLabel = vType == 'van' ? 'Van' : (vType == 'taxi' ? 'Taxi' : '');
    final ref    = (m['referredBy'] ?? '').toString();
    final email  = (m['email'] ?? '').toString();

    Widget row(IconData ic, String v) => Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(ic, size: 16, color: Colors.grey.shade600),
        const SizedBox(width: 8),
        Expanded(child: Text(v, style: const TextStyle(fontSize: 14))),
      ]),
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.deepPurple.shade50,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name.isNotEmpty ? name : 'Νέος οδηγός',
              style: const TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 16)),
          if (phone.isNotEmpty) row(Icons.phone_rounded, phone),
          if (vModel.isNotEmpty || plate.isNotEmpty || vLabel.isNotEmpty)
            row(Icons.directions_car_rounded,
                [vLabel, vModel, plate].where((s) => s.isNotEmpty).join(' • ')),
          if (ref.isNotEmpty) row(Icons.handshake_rounded, 'Πρόταση: $ref'),
          if (email.isNotEmpty) row(Icons.email_rounded, email),
        ],
      ),
    );
  }
  Future<void> _persistNotifiedPending() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var list = _notifiedPending.toList();
      if (list.length > 200) list = list.sublist(list.length - 200);
      await prefs.setString(kPrefsNotifiedPending, jsonEncode(list));
    } catch (_) {}
  }

  Future<void> _showApprovalDialog(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) async {
    if (_approvalDialogShowing || !mounted || docs.isEmpty) return;
    _approvalDialogShowing = true;
    // ignore: unawaited_futures
    cancelApprovalNotification();

    final single = docs.length == 1;
    final ctx0 = _rootCtx;
    if (ctx0 == null) { _approvalDialogShowing = false; return; }

    await showDialog<void>(
      context: ctx0,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(children: [
          const Icon(Icons.person_add_alt_1_rounded,
              color: Colors.deepPurple, size: 28),
          const SizedBox(width: 10),
          Expanded(child: Text(
            single ? 'Νέο αίτημα έγκρισης'
                   : '${docs.length} νέα αιτήματα έγκρισης',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
          )),
        ]),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final d in docs) _approvalCard(d.data()),
              const SizedBox(height: 4),
              Text(
                single
                    ? 'Ο οδηγός περιμένει την έγκρισή σου.'
                    : 'Περιμένουν την έγκρισή σου.',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
              ),
            ],
          ),
        ),
        actions: [
          AppButtonTonal(label: 'Αργότερα', onPressed: () => Navigator.pop(ctx)),
          AppButton(
            label: 'Έγκριση / Διαχείριση',
            icon: Icons.admin_panel_settings_rounded,
            color: Colors.deepPurple,
            onPressed: () {
              Navigator.pop(ctx);
              _openApprovalsPage();
            },
          ),
        ],
        ),
      ),
    );
    _approvalDialogShowing = false;
  }

  void _openApprovalsPage() {
    if (!widget.isMaster) return;
    // ignore: unawaited_futures
    cancelApprovalNotification();
    final nav = NotificationsService.navigatorKey.currentState;
    if (nav == null) return;
    nav.push(MaterialPageRoute(
      builder: (_) => MastersAdminPage(masterUid: widget.uid),
    ));
  }

  // ─── Επιβιβάσεις σε δικές μου δουλειές (admin/master) ───────────────────
  // Ακούει τις δουλειές που έβγαλα εγώ (createdBy == uid) με status boarded.
  // Όταν εμφανιστεί νέα επιβίβαση:
  //   • foreground → banner στην οθόνη
  //   • background → notification (ξυπνάει & χτυπάει)
  Future<void> _initBoardedListener() async {
    if (!(widget.isAdmin || widget.isMaster)) return;

    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getString(kPrefsNotifiedBoarded);
    if (raw != null) {
      try {
        _notifiedBoarded = Set<String>.from(jsonDecode(raw) as List);
      } catch (_) {}
    }

    _boardedSub = FirebaseFirestore.instance
        .collection('jobs')
        .where('createdBy', isEqualTo: widget.uid)
        .where('status',    isEqualTo: 'boarded')
        .snapshots()
        .listen(_onBoardedSnapshot);
  }

  Future<void> _onBoardedSnapshot(
      QuerySnapshot<Map<String, dynamic>> snap) async {
    final jobs       = snap.docs.map((d) => Job.fromDoc(d)).toList();
    final boardedIds = jobs.map((j) => j.id).toSet();

    // Καθάρισε όσες δεν είναι πλέον boarded (π.χ. ολοκληρώθηκαν).
    _notifiedBoarded.removeWhere((id) => !boardedIds.contains(id));

    final fresh = boardedIds.difference(_notifiedBoarded);

    // Πρώτο snapshot: μάρκαρε τις υπάρχουσες ΧΩΡΙΣ χτύπημα.
    if (_boardedFirstSnapshot) {
      _boardedFirstSnapshot = false;
      _notifiedBoarded = boardedIds;
      await _persistNotifiedBoarded();
      return;
    }

    if (fresh.isEmpty) {
      await _persistNotifiedBoarded();
      return;
    }

    _notifiedBoarded.addAll(fresh);
    await _persistNotifiedBoarded();

    for (final id in fresh) {
      final job = jobs.firstWhere((j) => j.id == id);
      if (_isAppForeground && mounted) {
        _enqueueBoarded(job);
      }
      // ΕΚΤΟΣ εφαρμογής: το FCM background handler (type:boarded) εμφανίζει
      // την ειδοποίηση — δουλεύει ακόμη και με κλειστή εφαρμογή.
    }
    // ignore: unawaited_futures
    _pumpBoardedQueue();
  }

  Future<void> _persistNotifiedBoarded() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var list = _notifiedBoarded.toList();
      if (list.length > 200) list = list.sublist(list.length - 200);
      await prefs.setString(kPrefsNotifiedBoarded, jsonEncode(list));
    } catch (_) {}
  }

  // ── Ουρά παραλαβών (εμφανίζονται μία-μία με μετρητή εκκρεμών) ───────────
  void _enqueueBoarded(Job job) {
    if (_boardedQueuedIds.contains(job.id)) return;
    _boardedQueuedIds.add(job.id);
    _boardedQueue.add(job);
    _boardedPending.value = _boardedQueue.length;
  }

  Future<void> _pumpBoardedQueue() async {
    if (_boardedPopupShowing || !mounted) return;
    if (_boardedQueue.isEmpty) return;

    final job = _boardedQueue.removeAt(0);
    _boardedQueuedIds.remove(job.id);
    // Ο μετρητής δείχνει πόσες ΑΛΛΕΣ παραλαβές περιμένουν πίσω από αυτή.
    _boardedPending.value = _boardedQueue.length;

    _boardedPopupShowing = true;
    await _showBoardedDialog(job);
    _boardedPopupShowing = false;

    if (mounted) {
      // ignore: unawaited_futures
      _pumpBoardedQueue();
    }
  }

  Future<void> _showBoardedDialog(Job job) async {
    final ctx0 = _rootCtx;
    if (ctx0 == null) return;
    final driver = (job.takenByName ?? '').trim();
    final isScheduled = job.scheduledAt != null;

    await showDialog<void>(
      context: ctx0,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: const [
              BoxShadow(color: Colors.black45, blurRadius: 24,
                  offset: Offset(0, 8)),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── ΚΙΤΡΙΝΟ HEADER (μέχρι τη γκρι γραμμή) ──────────────────
              Container(
                width: double.infinity,
                color: Colors.amber,
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ValueListenableBuilder<int>(
                      valueListenable: _boardedPending,
                      builder: (_, count, _) {
                        if (count <= 0) return const SizedBox.shrink();
                        return Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.orange.shade700,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            count == 1
                                ? '⏳ Εκκρεμεί 1 ακόμη παραλαβή'
                                : '⏳ Εκκρεμούν $count ακόμη παραλαβές',
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 13),
                          ),
                        );
                      },
                    ),
                    const Icon(Icons.directions_car_filled_rounded,
                        color: Colors.black87, size: 46),
                    const SizedBox(height: 8),
                    Text(
                      driver.isNotEmpty ? '$driver παρέλαβε' : 'Παραλαβή πελάτη',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 19,
                          color: Colors.black87),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        isScheduled
                            ? '📅 Ραντεβού • ${_fmtDateTime(job.scheduledAt!)}'
                            : '⚡ Άμεση',
                        style: TextStyle(
                          color: isScheduled
                              ? Colors.deepPurple
                              : Colors.green.shade800,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // ── BODY (λευκό) ──────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
              // ── Διαδρομή ──
              _boardedRow(Icons.my_location_rounded, 'Από', job.from,
                  Colors.green),
              const SizedBox(height: 8),
              _boardedRow(Icons.location_on_rounded, 'Προς', job.to,
                  Colors.red),
              const SizedBox(height: 12),
              // ── Τιμή (ή υπόλοιπο προς είσπραξη αν πληρώθηκε προκαταβολή) ──
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.euro_rounded,
                      color: Colors.black87, size: 22),
                  const SizedBox(width: 4),
                  Text('${job.remainingToCollect.toStringAsFixed(2)}€',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 24)),
                ],
              ),
              if (job.depositPaid)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    job.fullyPaid
                        ? 'Πληρώθηκε ΟΛΟΚΛΗΡΗ online — μηδέν είσπραξη'
                        : 'Προπληρώθηκε ${job.depositAmount.toStringAsFixed(2)}€ online',
                    style: TextStyle(fontSize: 11.5, color: Colors.blue.shade700,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              const SizedBox(height: 10),
              // ── Λοιπές πληροφορίες (chips) ──
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 6,
                children: [
                  _boardedChip('👤 ${job.persons} άτ.'),
                  if (job.luggage > 0) _boardedChip('🧳 ${job.luggage}'),
                  if (job.childSeatCount > 0)
                    _boardedChip('🪑 ${job.childSeatCount} παιδ.'),
                  if (job.withReturn) _boardedChip('🔄 Με επιστροφή'),
                  if (job.withStops) _boardedChip('🛑 Με στάσεις'),
                  if ((job.sourceName ?? '').isNotEmpty)
                    _boardedChip('🏷️ ${job.sourceName}'),
                  if ((job.flightOrShip ?? '').isNotEmpty)
                    _boardedChip('✈️ ${job.flightOrShip}'),
                ],
              ),
              if ((job.clientName ?? '').isNotEmpty ||
                  (job.clientPhone ?? '').isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  [
                    if ((job.clientName ?? '').isNotEmpty) job.clientName,
                    if ((job.clientPhone ?? '').isNotEmpty) job.clientPhone,
                  ].join('  •  '),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.grey.shade700, fontSize: 13),
                ),
              ],
              if ((job.note ?? '').isNotEmpty) ...[
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.amber.shade50,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text('📝 ${job.note}',
                      style: const TextStyle(fontSize: 13)),
                ),
              ],
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.blue.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  icon: const Icon(Icons.check_circle_rounded),
                  label: const Text('ΟΚ, ενημερώθηκα',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 16)),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ),
                  ],
                ),
              ),
            ],
          ),
          ),
        ),
      ),
      ),
    );
  }

  Widget _boardedRow(
      IconData icon, String label, String value, Color color) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: TextStyle(
                      color: Colors.grey.shade500,
                      fontSize: 11,
                      fontWeight: FontWeight.w600)),
              Text(value,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w500)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _boardedChip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(text, style: const TextStyle(fontSize: 13)),
    );
  }

  /// Καλείται όταν ανοίξει/επανέλθει η εφαρμογή ή πατηθεί reminder.
  /// Αν υπάρχει εκκρεμής κάρτα ραντεβού (γράφτηκε από το tap του
  /// notification), την εμφανίζει.
  Future<void> _checkPendingReminderCard() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final raw = prefs.getString(kPendingReminderCard);
      if (raw == null) return;
      await prefs.remove(kPendingReminderCard);
      // Σταμάτα τυχόν ήχο που μπορεί να παίζει
      await NotificationsService.silenceRingtone();
      final data  = jsonDecode(raw) as Map<String, dynamic>;
      final jobId = data['jobId'] as String;
      final mins  = (data['minsBefore'] as num?)?.toInt() ?? 0;
      final doc   = await FirebaseFirestore.instance
          .collection('jobs').doc(jobId).get();
      if (!doc.exists || !mounted) return;
      final job = Job.fromDoc(doc);
      await _showReminderDialog(job, mins);
    } catch (_) {}
  }

  String _fmtDateTime(DateTime dt) {
    final d = '${dt.day.toString().padLeft(2, '0')}/'
        '${dt.month.toString().padLeft(2, '0')}';
    final t = '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
    return '$d $t';
  }

  Future<void> _showReminderDialog(Job job, int minsBefore) async {
    if (_reminderDialogShowing) return;
    final ctx0 = _rootCtx;
    if (ctx0 == null) return;
    _reminderDialogShowing = true;
    // Σταμάτα τον ήχο μόλις ανοίξει η κάρτα
    await NotificationsService.silenceRingtone();

    // Άνοιγμα της αναλυτικής κάρτας (με τηλέφωνο / WhatsApp),
    // χωρίς το κουμπί ολοκλήρωσης — είναι υπενθύμιση
    await showModalBottomSheet<void>(
      context: ctx0,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => JobDetailsSheet(
        job:           job,
        parentContext: ctx0,
        hideComplete:  true,
        headerLabel:   'ΥΠΕΝΘΥΜΙΣΗ ΡΑΝΤΕΒΟΥ • σε $minsBefore′',
      ),
    );
    _reminderDialogShowing = false;
  }

  // ─── "Ποιος πήρε τη δουλειά" — μήνυμα 5 δευτ. σε όλους ──────────────────
  Future<void> _checkIfTaken(String jobId) async {
    if (_announcedTaken.contains(jobId)) return;
    _announcedTaken.add(jobId);
    if (_announcedTaken.length > 200) {
      _announcedTaken.remove(_announcedTaken.first);
    }
    try {
      final doc = await FirebaseFirestore.instance
          .collection('jobs').doc(jobId).get();
      if (!doc.exists) return;
      final job = Job.fromDoc(doc);
      // Μόνο αν ανελήφθη πραγματικά
      if (!job.isTaken && !job.isBoarded) return;
      final who = job.takenByName ?? '';
      if (who.isEmpty) return;

      // Σταμάτα κάθε ειδοποίηση/ήχο γι' αυτή τη δουλειά (την πήρε άλλος)
      _shownJobIds.add(job.id);
      _notifiedJobIds.add(job.id);
      // ignore: unawaited_futures
      NotificationsService.cancelJobNotification(job.id);

      // Ο οδηγός που την πήρε δεν χρειάζεται το μήνυμα
      if (job.takenBy == widget.uid) return;
      if (!_isAppForeground || !mounted) return;
      _showTakenBanner(job);
    } catch (_) {}
  }

  void _showTakenBanner(Job job) {
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    final isScheduled = job.scheduledAt != null;
    final typeLabel   = isScheduled
        ? 'Προγραμματισμένη${job.scheduledAt != null
            ? ' • ${_fmtDateTime(job.scheduledAt!)}' : ''}'
        : 'Άμεση';
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => Positioned.fill(
        child: IgnorePointer(
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 32),
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.green.shade700,
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: const [
                    BoxShadow(color: Colors.black54, blurRadius: 20,
                        offset: Offset(0, 6)),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.check_circle_rounded,
                        color: Colors.white, size: 44),
                    const SizedBox(height: 10),
                    Text('${job.takenByName} πήρε τη δουλειά',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 17)),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(typeLabel,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12,
                              fontWeight: FontWeight.w600)),
                    ),
                    const SizedBox(height: 10),
                    Text('${job.from}  →  ${job.to}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 14)),
                    const SizedBox(height: 6),
                    Text('${job.remainingToCollect.toStringAsFixed(2)}€',
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 20)),
                    if (job.depositPaid)
                      Text(job.fullyPaid
                          ? '(πληρώθηκε ΟΛΟΚΛΗΡΗ online)'
                          : '(προπληρώθηκε ${job.depositAmount.toStringAsFixed(2)}€)',
                          style: const TextStyle(color: Colors.white70, fontSize: 11)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    // Μένει 5 δευτερόλεπτα και φεύγει
    Timer(const Duration(seconds: 5), () {
      try { entry.remove(); } catch (_) {}
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    NotificationsService.pendingViewJobId.removeListener(_onPendingView);
    NotificationsService.pendingViewBatchId.removeListener(_onPendingViewBatch);
    NotificationsService.reminderTapTick.removeListener(_checkPendingReminderCard);
    NotificationsService.approvalTapTick.removeListener(_openApprovalsPage);
    _jobsSub?.cancel();
    _broadcastSub?.cancel();
    _scheduledSub?.cancel();
    _approvalSub?.cancel();
    _boardedSub?.cancel();
    _pendingCount.dispose();
    _boardedPending.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasBackground = _lifecycleState != AppLifecycleState.resumed;
    _lifecycleState = state;
    // Όταν η εφαρμογή ξαναέρχεται μπροστά → δες αν υπάρχει εκκρεμής
    // υπενθύμιση ραντεβού ή ειδοποίηση αναβάθμισης να εμφανιστεί
    if (wasBackground && state == AppLifecycleState.resumed) {
      _checkPendingReminderCard();
      _checkPendingUpgradeDialog();
      // ignore: unawaited_futures
      _pumpBoardedQueue();
    }
  }

  bool get _isAppForeground =>
      _lifecycleState == AppLifecycleState.resumed;

  Future<void> _loadRejected() async {
    final map = await NotificationsService.getRejectedJobMap();
    if (!mounted) return;
    setState(() => _rejectedMap = map);
  }

  // ─── Επεξεργασία snapshots ──────────────────────────────────────────────
  Future<void> _onJobsUpdate(List<Job> jobs) async {
    final previousJobs = _lastOpenJobs;
    _lastOpenJobs = jobs;
    final openIds = jobs.map((j) => j.id).toSet();

    // Πρώτο snapshot: μην ειδοποιήσεις για ήδη υπάρχουσες δουλειές
    if (_isFirstSnapshot) {
      _isFirstSnapshot = false;
      for (final j in jobs) {
        _shownJobIds.add(j.id);
        _notifiedJobIds.add(j.id);
      }
      return;
    }

    // ── Ανίχνευση δουλειών που "εξαφανίστηκαν" → μήπως ανελήφθησαν; ────────
    final previousIds = previousJobs.map((j) => j.id).toSet();
    for (final goneId in previousIds.difference(openIds)) {
      // ignore: unawaited_futures
      _checkIfTaken(goneId);
    }

    // Καθάρισμα
    _notifiedJobIds.removeWhere((id) => !openIds.contains(id));
    _shownJobIds.removeWhere((id) => !openIds.contains(id));
    // Δουλειές που έφυγαν από την ουρά (ανελήφθησαν/ακυρώθηκαν) → εκτός σειράς
    _pendingQueue.removeWhere((j) => !openIds.contains(j.id));
    _queuedJobIds.removeWhere((id) => !openIds.contains(id));
    _syncPendingCount();
    // ignore: unawaited_futures
    NotificationsService.cleanupRejected(openIds);

    // Δουλειές που άλλαξαν στάδιο κλιμάκωσης → ξαναχτυπούν σαν νέες.
    // ΠΡΟΣΟΧΗ: το stageStartedAt είναι serverTimestamp — στην πρώτη εγγραφή
    // φτάνει αρχικά null (pending) και αμέσως μετά "λύνεται" σε πραγματική ώρα.
    // Αυτή η αλλαγή null→ώρα ΔΕΝ είναι νέο στάδιο· αν τη μετρούσαμε, η ίδια
    // δουλειά ξαναέμπαινε στην ουρά κι εμφανιζόταν 2 φορές. Γι' αυτό θεωρούμε
    // «νέο στάδιο» ΜΟΝΟ όταν αυξάνεται πραγματικά το escalationStage.
    final prevById = {for (final j in previousJobs) j.id: j};
    for (final job in jobs) {
      final prev = prevById[job.id];
      if (prev == null) continue;
      final stageIncreased = job.escalationStage > prev.escalationStage;
      if (stageIncreased) {
        // Νέο στάδιο → ξαναχτυπάει (& σε όσους την είχαν δει)
        _notifiedJobIds.remove(job.id);
        _shownJobIds.remove(job.id);
        // Αν περίμενε στην ουρά με παλιά δεδομένα → βγάλ' την για να ξαναμπεί φρέσκια
        _pendingQueue.removeWhere((j) => j.id == job.id);
        _queuedJobIds.remove(job.id);
      }
    }

    for (final job in jobs) {
      if (!job.isOpen) continue;

      // ── Τέλος σταδίου → προχώρα στο επόμενο, μην δείξεις 0άρι popup ──
      if (job.needsStageAdvance) {
        // ignore: unawaited_futures
        JobService.autoAdvanceStageIfNeeded(job);
        continue; // θα εμφανιστεί φρέσκια στον επόμενο κύκλο
      }

      // ── Rejection check ──────────────────────────────────────────────────
      // Αν η δουλειά προχώρησε σε νέο στάδιο μετά την απόρριψη →
      // αγνοούμε την παλιά απόρριψη και την δείχνουμε ξανά.
      final rejectedAtMs = _rejectedMap[job.id];
      if (rejectedAtMs != null) {
        final stageMs = job.stageStartedAt?.millisecondsSinceEpoch ?? 0;
        if (stageMs <= rejectedAtMs) {
          continue; // ακόμα απορριμμένη σε αυτό το στάδιο
        }
        // Αλλιώς προχώρησε σε νέο στάδιο, καθαρίζουμε τοπικά την απόρριψη
        _rejectedMap.remove(job.id);
      }

      // ── Έλεγχος διαθεσιμότητας για το ΤΡΕΧΟΝ στάδιο ─────────────────────
      // Αν το στάδιο απευθύνεται μόνο σε διαθέσιμους & ο οδηγός δεν είναι
      // διαθέσιμος → δεν του χτυπάει (θα του χτυπήσει σε επόμενο στάδιο).
      if (job.currentStageRequiresAvailable && !widget.isAvailable) continue;

      if (_isAppForeground) {
        if (_shownJobIds.contains(job.id)) continue;
        _enqueueJob(job);
      }
      // ΕΚΤΟΣ εφαρμογής: ΔΕΝ εμφανίζουμε εδώ — το αναλαμβάνει το FCM
      // background handler (fcm_service.dart), που δουλεύει ακόμη και με
      // τελείως κλειστή εφαρμογή. Έτσι αποφεύγεται διπλό χτύπημα.
    }

    // Ξεκίνα/συνέχισε την εμφάνιση της ουράς (μία-μία)
    // ignore: unawaited_futures
    _pumpQueue();
  }

  // ── Ουρά διεκδικήσεων ──────────────────────────────────────────────────
  // Context του root navigator → τα popups εμφανίζονται ΠΑΝΩ από κάθε οθόνη
  // (Ιστορικό, Χρεώσεις κ.λπ.), όχι μόνο όταν είσαι στον χάρτη.
  BuildContext? get _rootCtx =>
      NotificationsService.navigatorKey.currentContext ??
      (mounted ? context : null);

  void _enqueueJob(Job job) {
    if (_shownJobIds.contains(job.id)) return;
    if (_queuedJobIds.contains(job.id)) return;
    _queuedJobIds.add(job.id);
    _pendingQueue.add(job);
    _syncPendingCount();
  }

  // Ο μετρητής δείχνει πόσες διεκδικήσεις περιμένουν ΠΙΣΩ από αυτή που
  // εμφανίζεται τώρα (η τρέχουσα έχει ήδη βγει από την ουρά).
  void _syncPendingCount() {
    _pendingCount.value = _pendingQueue.length;
  }

  // Εμφανίζει τις διεκδικήσεις μία-μία. Όταν κλείσει η μπροστινή (είτε την
  // πάρεις είτε όχι), ανοίγει αυτόματα η επόμενη και ο μετρητής μειώνεται.
  Future<void> _pumpQueue() async {
    if (_popupShowing || !mounted) return;
    if (_pendingQueue.isEmpty) return;

    // ── Έλεγχος ομαδικής ανάθεσης (batch αποκλειστικά σε αυτόν τον οδηγό) ──
    // Αν η επόμενη δουλειά ανήκει σε batch, μάζεψε ΟΛΕΣ τις δουλειές αυτού του
    // batch (από την ουρά) και δείξ' τες ως μία λίστα με «Αποδοχή όλων».
    final next = _pendingQueue.first;
    if (next.batchId.isNotEmpty && _isBatchForMe(next)) {
      if (_shownBatchIds.contains(next.batchId)) {
        // Ήδη εμφανίστηκε — βγάλ' τες από την ουρά για να μην κολλήσει
        _pendingQueue.removeWhere((j) => j.batchId == next.batchId);
        _queuedJobIds.removeWhere((id) =>
            !_pendingQueue.any((j) => j.id == id));
        _syncPendingCount();
        return _pumpQueue();
      }
      await _showBatch(next.batchId);
      return;
    }

    final job = _pendingQueue.removeAt(0);
    _queuedJobIds.remove(job.id);
    _syncPendingCount(); // πόσες έμειναν πίσω από την τρέχουσα

    _popupShowing = true;
    _shownJobIds.add(job.id);
    _notifiedJobIds.add(job.id);
    // Καθάρισε την ειδοποίηση από το tray (εμφανίζεται πλέον ως popup)
    // ignore: unawaited_futures
    NotificationsService.cancelJobNotification(job.id);

    final driverName = '${widget.displayName} ${widget.lastName}'.trim();
    final ctx = _rootCtx;
    if (ctx == null) { _popupShowing = false; return; }
    AlertGate.instance.claimOpened();
    await showJobPopup(
      context:      ctx,
      job:          job,
      uid:          widget.uid,
      driverName:   driverName,
      pendingCount: _pendingCount,
    );
    AlertGate.instance.claimClosed();
    _popupShowing = false;

    // Άνοιξε την επόμενη διεκδίκηση, αν υπάρχει
    if (mounted) {
      // ignore: unawaited_futures
      _pumpQueue();
    }
  }

  // Είναι το batch αποκλειστικά για ΑΥΤΟΝ τον οδηγό; (targetUids == [εγώ])
  bool _isBatchForMe(Job job) {
    return job.exclusiveTarget &&
        job.targetUids.length == 1 &&
        job.targetUids.first == widget.uid;
  }

  // Εμφανίζει τη λίστα ομαδικής ανάθεσης + «Αποδοχή όλων».
  Future<void> _showBatch(String batchId) async {
    // Μάζεψε όλες τις δουλειές του batch από όσες ξέρουμε (ουρά + ανοιχτές)
    final byId = <String, Job>{};
    for (final j in _pendingQueue) {
      if (j.batchId == batchId && j.isOpen) byId[j.id] = j;
    }
    for (final j in _lastOpenJobs) {
      if (j.batchId == batchId && j.isOpen && _isBatchForMe(j)) {
        byId[j.id] = j;
      }
    }
    final batchJobs = byId.values.toList();
    if (batchJobs.isEmpty) {
      // Τίποτα έγκυρο — καθάρισε & συνέχισε
      _pendingQueue.removeWhere((j) => j.batchId == batchId);
      _syncPendingCount();
      return;
    }

    _popupShowing = true;
    _shownBatchIds.add(batchId);
    // Βγάλ' τες από την ουρά & σημείωσέ τες ως ιδωμένες
    for (final j in batchJobs) {
      _shownJobIds.add(j.id);
      _notifiedJobIds.add(j.id);
      // ignore: unawaited_futures
      NotificationsService.cancelJobNotification(j.id);
    }
    _pendingQueue.removeWhere((j) => j.batchId == batchId);
    _queuedJobIds.removeWhere((id) => !_pendingQueue.any((j) => j.id == id));
    _syncPendingCount();

    final driverName = '${widget.displayName} ${widget.lastName}'.trim();
    final ctx = _rootCtx;
    if (ctx == null) { _popupShowing = false; return; }

    AlertGate.instance.claimOpened();
    await showBatchAcceptSheet(
      context:    ctx,
      jobs:       batchJobs,
      uid:        widget.uid,
      driverName: driverName,
    );
    AlertGate.instance.claimClosed();
    _popupShowing = false;

    if (mounted) {
      // ignore: unawaited_futures
      _pumpQueue();
    }
  }

  // Διατηρείται για άνοιγμα από tap σε notification → μπαίνει στην ουρά.
  Future<void> _showPopupFor(Job job) async {
    _enqueueJob(job);
    await _pumpQueue();
  }

  // ─── Tap σε ειδοποίηση ομαδικής ανάθεσης → άνοιξε λίστα «Αποδοχή όλων» ───
  Future<void> _onPendingViewBatch() async {
    final batchId = NotificationsService.pendingViewBatchId.value;
    if (batchId == null) return;
    NotificationsService.pendingViewBatchId.value = null;
    if (!mounted) return;

    // Βρες τις δουλειές του batch — πρώτα από τις γνωστές ανοιχτές
    var batchJobs = _lastOpenJobs
        .where((j) => j.batchId == batchId && j.isOpen && _isBatchForMe(j))
        .toList();

    // Αλλιώς φέρ' τες από Firestore
    if (batchJobs.isEmpty) {
      try {
        final snap = await FirebaseFirestore.instance
            .collection('jobs')
            .where('batchId', isEqualTo: batchId)
            .get();
        batchJobs = snap.docs
            .map((d) => Job.fromDoc(d))
            .where((j) => j.isOpen && _isBatchForMe(j))
            .toList();
      } catch (_) {
        return;
      }
    }
    if (!mounted || batchJobs.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Οι δουλειές δεν είναι πια διαθέσιμες.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    // Μην επαναεμφανίσεις αν ήδη φαίνεται/φάνηκε
    if (_popupShowing || _shownBatchIds.contains(batchId)) return;

    _popupShowing = true;
    _shownBatchIds.add(batchId);
    for (final j in batchJobs) {
      _shownJobIds.add(j.id);
      _notifiedJobIds.add(j.id);
      // ignore: unawaited_futures
      NotificationsService.cancelJobNotification(j.id);
    }
    _pendingQueue.removeWhere((j) => j.batchId == batchId);
    _queuedJobIds.removeWhere((id) => !_pendingQueue.any((j) => j.id == id));
    _syncPendingCount();

    final driverName = '${widget.displayName} ${widget.lastName}'.trim();
    final ctx = _rootCtx;
    if (ctx == null) { _popupShowing = false; return; }
    await showBatchAcceptSheet(
      context:    ctx,
      jobs:       batchJobs,
      uid:        widget.uid,
      driverName: driverName,
    );
    _popupShowing = false;
    if (mounted) {
      // ignore: unawaited_futures
      _pumpQueue();
    }
  }

  // ─── Tap σε notification → άνοιξε popup ────────────────────────────────
  Future<void> _onPendingView() async {
    final jobId = NotificationsService.pendingViewJobId.value;
    if (jobId == null) return;
    NotificationsService.pendingViewJobId.value = null;
    if (!mounted) return;

    Job? job;
    try {
      job = _lastOpenJobs.firstWhere((j) => j.id == jobId);
    } catch (_) {
      job = null;
    }
    if (job == null) {
      try {
        final doc = await FirebaseFirestore.instance
            .collection('jobs').doc(jobId).get();
        if (!doc.exists) return;
        job = Job.fromDoc(doc);
      } catch (_) {
        return;
      }
    }
    if (!mounted) return;

    if (!job.isOpen) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Η δουλειά δεν είναι πια διαθέσιμη.'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    _shownJobIds.remove(jobId);
    _rejectedMap.remove(jobId);
    await _showPopupFor(job);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
