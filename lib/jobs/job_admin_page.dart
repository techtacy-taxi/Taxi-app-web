// lib/jobs/job_admin_page.dart
// Refactored: card widgets moved to admin_job_card.dart & history_job_card.dart
// Shared widgets in job_shared_widgets.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'dart:async';

import 'admin_job_card.dart';
import 'clients_admin_tab.dart';
import 'history_job_card.dart';
import 'job_form.dart';
import 'job_model.dart';
import 'job_service.dart';
import 'job_shared_widgets.dart';
import 'saved_jobs_tab.dart';
import '../voice/voice_models.dart';
import '../voice/share_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// JobAdminPage
// ─────────────────────────────────────────────────────────────────────────────

class JobAdminPage extends StatefulWidget {
  final String       adminUid;
  final String       adminName;
  final bool         isAdmin;
  final bool         isMaster;
  final List<String> managedGroupIds;
  final List<String> userGroupIds;

  const JobAdminPage({
    super.key,
    required this.adminUid,
    this.adminName       = '',
    this.isAdmin         = true,
    this.isMaster        = false,
    this.managedGroupIds = const [],
    this.userGroupIds    = const [],
  });

  @override
  State<JobAdminPage> createState() => _JobAdminPageState();
}

class _JobAdminPageState extends State<JobAdminPage>
    with SingleTickerProviderStateMixin {

  late TabController _tabCtrl;

  bool get _isDriverInGroup =>
      !widget.isAdmin && widget.userGroupIds.isNotEmpty;

  bool get _hasOpenTab => widget.isAdmin || _isDriverInGroup;

  int get _tabCount {
    // Master: Ανοιχτές + Αποθηκευμένες + Ιστορικό + Πηγές + Πελάτες
    if (widget.isMaster) return 5;
    // Admin: Ανοιχτές + Αποθηκευμένες + Ιστορικό + Πηγές + Πελάτες (δικά του)
    if (widget.isAdmin) return 5;
    // Driver με ομάδα: Ανοιχτές + Ιστορικό
    if (_isDriverInGroup) return 2;
    // Driver χωρίς ομάδα: μόνο Ιστορικό (δικές του δουλειές)
    return 1;
  }

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: _tabCount, vsync: this);
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F8F8),
      appBar: AppBar(
        title: const Text('Δουλειές',
            style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.amber,
        foregroundColor: Colors.black,
        elevation: 0,
        bottom: _hasOpenTab
            ? TabBar(
                controller:           _tabCtrl,
                isScrollable:         widget.isAdmin || widget.isMaster,
                tabAlignment:         (widget.isAdmin || widget.isMaster)
                    ? TabAlignment.center
                    : TabAlignment.fill,
                indicatorColor:       Colors.black,
                labelColor:           Colors.black,
                unselectedLabelColor: Colors.black54,
                tabs: [
                  const Tab(icon: Icon(Icons.work_rounded),    text: 'Ανοιχτές'),
                  if (widget.isAdmin || widget.isMaster)
                    const Tab(icon: Icon(Icons.bookmark_rounded), text: 'Αποθηκευμένες'),
                  const Tab(icon: Icon(Icons.history_rounded), text: 'Ιστορικό'),
                  if (widget.isAdmin || widget.isMaster)
                    const Tab(icon: Icon(Icons.handshake_rounded), text: 'Πηγές'),
                  if (widget.isAdmin || widget.isMaster)
                    const Tab(icon: Icon(Icons.people_alt_rounded), text: 'Πελάτες'),
                ],
              )
            : TabBar(
                controller:     _tabCtrl,
                indicatorColor: Colors.black,
                labelColor:     Colors.black,
                tabs: const [
                  Tab(icon: Icon(Icons.history_rounded), text: 'Ιστορικό'),
                ],
              ),
      ),
      floatingActionButton: widget.isAdmin
          ? FloatingActionButton.extended(
              onPressed: () async {
                await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => JobFormPage(
                    adminUid:  widget.adminUid,
                    adminName: widget.adminName,
                    isMaster:  widget.isMaster,
                  ),
                ));
              },
              backgroundColor: Colors.amber,
              foregroundColor: Colors.black,
              icon:  const Icon(Icons.add_rounded),
              label: const Text('Νέα Δουλειά',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            )
          : null,
      body: TabBarView(
        controller: _tabCtrl,
        children: _hasOpenTab
            ? [
                _OpenJobsTab(
                  adminUid: widget.adminUid,
                  adminName: widget.adminName,
                  // Master: κανένα φίλτρο (όλα)
                  // Admin: φιλτράρει με managedGroupIds
                  // Driver: φιλτράρει με userGroupIds (μόνο της ομάδας του)
                  managedGroupIds: widget.isMaster
                      ? <String>[]
                      : widget.managedGroupIds,
                  userGroupIds: widget.userGroupIds,
                  isMaster: widget.isMaster,
                  isAdmin:  widget.isAdmin,
                ),
                if (widget.isAdmin || widget.isMaster)
                  SavedJobsTab(
                    adminUid:  widget.adminUid,
                    adminName: widget.adminName,
                    isMaster:  widget.isMaster,
                  ),
                _HistoryTab(
                  adminUid:        widget.adminUid,
                  adminName:       widget.adminName,
                  isAdmin:         widget.isAdmin,
                  isMaster:        widget.isMaster,
                  managedGroupIds: widget.isMaster
                      ? <String>[] : widget.managedGroupIds,
                  userGroupIds:    widget.userGroupIds,
                ),
                if (widget.isAdmin || widget.isMaster)
                  _SourcesTab(
                    adminUid: widget.adminUid,
                    isMaster: widget.isMaster,
                  ),
                if (widget.isAdmin || widget.isMaster)
                  ClientsTab(
                    adminUid:  widget.adminUid,
                    adminName: widget.adminName,
                    isMaster:  widget.isMaster,
                  ),
              ]
            : [
                _HistoryTab(
                  adminUid:     widget.adminUid,
                  isAdmin:      false,
                  userGroupIds: widget.userGroupIds,
                ),
              ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _OpenJobsTab — με φίλτρα (οδηγός / ομάδα / καμία ανάθεση) & δικαιώματα
// ─────────────────────────────────────────────────────────────────────────────

// Ειδικό id φίλτρου: δουλειές χωρίς ανάθεση σε κανέναν
const String _kUnassigned = '__unassigned__';

class _OpenJobsTab extends StatefulWidget {
  final String       adminUid;
  final String       adminName;
  final List<String> managedGroupIds; // ομάδες που διαχειρίζεται ο admin
  final List<String> userGroupIds;    // ομάδες στις οποίες ανήκει ο οδηγός
  final bool         isMaster;
  final bool         isAdmin;

  const _OpenJobsTab({
    required this.adminUid,
    this.adminName       = '',
    this.managedGroupIds = const [],
    this.userGroupIds    = const [],
    this.isMaster        = false,
    this.isAdmin         = false,
  });

  @override
  State<_OpenJobsTab> createState() => _OpenJobsTabState();
}

class _OpenJobsTabState extends State<_OpenJobsTab>
    with SingleTickerProviderStateMixin {
  late TabController _innerTab;

  String? _filterDriverUid;   // null = όλοι, _kUnassigned = αδέσμευτες, αλλιώς uid
  String? _filterDriverName;
  String? _filterGroupId;     // null = όλες
  String? _filterGroupName;

  List<Map<String, dynamic>> _drivers    = [];
  List<Map<String, dynamic>> _groups     = [];
  List<String>               _memberUids = []; // μέλη ομάδων που διαχειρίζεται ο admin
  // groupId → μέλη της ομάδας (για αντιστοίχιση δουλειάς σε ομάδα ακόμη κι όταν
  // δεν έχει groupId — π.χ. broadcast ή στοχευμένοι οδηγοί).
  final Map<String, Set<String>> _groupMembers = {};

  // Auto-return: ids που ήδη επεξεργαστήκαμε, για να μην τρέχει σε κάθε tick.
  final Set<String> _autoReturnHandled = {};
  bool _autoReturnRunning = false;

  // Παρακολούθηση ραντεβού που πέρασαν >2 ώρες (αδιεκδίκητα) → διαγραφή μία φορά.
  final Set<String> _staleDeleteHandled = {};
  bool _staleDeleteRunning = false;

  // Κοινή πρόσβαση: ownerUid -> επίπεδο που έχω εγώ πάνω στις δουλειές του
  Map<String, ShareLevel> _shared = const {};
  StreamSubscription<Map<String, ShareLevel>>? _shareSub;

  /// Επίπεδο πρόσβασης που έχω σε μια συγκεκριμένη ανοιχτή δουλειά.
  ShareLevel _levelFor(Job j) {
    if (widget.isMaster) return ShareLevel.full;
    if (j.createdBy == widget.adminUid) return ShareLevel.full;
    return _shared[j.createdBy] ?? ShareLevel.none;
  }

  bool get _showFullFilters => widget.isAdmin || widget.isMaster;

  @override
  void initState() {
    super.initState();
    _innerTab = TabController(length: 2, vsync: this);
    _loadFilters();
    if (widget.isAdmin && !widget.isMaster) {
      _shareSub = ShareService.sharedOwnersStream(widget.adminUid).listen((m) {
        if (mounted) setState(() => _shared = m);
      });
    }
  }

  @override
  void dispose() {
    _innerTab.dispose();
    _shareSub?.cancel();
    super.dispose();
  }

  Future<void> _loadFilters() async {
    final fs = FirebaseFirestore.instance;
    try {
      final results = await Future.wait([
        fs.collection('presence').orderBy('displayName').get(),
        fs.collection('groups').orderBy('name').get(),
      ]);
      if (!mounted) return;

      // Μέλη των ομάδων που διαχειρίζεται ο admin (για ορατότητα εκτός-ομάδας)
      final memberUids = <String>{};
      if (widget.isAdmin && !widget.isMaster &&
          widget.managedGroupIds.isNotEmpty) {
        for (final d in results[1].docs) {
          if (!widget.managedGroupIds.contains(d.id)) continue;
          memberUids.addAll(List<String>.from(d.data()['memberUids'] ?? []));
        }
      }

      var drivers = results[0].docs.map((d) {
        final data = d.data();
        return {
          'uid':  d.id,
          'name': '${data['displayName'] ?? ''} ${data['lastName'] ?? ''}'.trim(),
        };
      }).where((d) => (d['name'] as String).isNotEmpty).toList();

      // Ο admin βλέπει στο picker μόνο τους οδηγούς των ομάδων του
      if (widget.isAdmin && !widget.isMaster && memberUids.isNotEmpty) {
        drivers = drivers
            .where((d) => memberUids.contains(d['uid']))
            .toList();
      }

      setState(() {
        _memberUids = memberUids.toList();
        _drivers    = drivers;
        _groups     = results[1].docs
            .where((d) => widget.isMaster ||
                widget.managedGroupIds.contains(d.id))
            .map((d) => {'id': d.id, 'name': d.data()['name'] ?? ''})
            .toList();
        // Χάρτης μελών ανά ομάδα (όλες οι ομάδες — για αντιστοίχιση).
        _groupMembers.clear();
        for (final d in results[1].docs) {
          _groupMembers[d.id] =
              Set<String>.from(d.data()['memberUids'] ?? const <String>[]);
        }
      });
    } catch (_) {/* αγνόησε — τα φίλτρα απλώς δεν θα γεμίσουν */}
  }

  // ── Βασικό φίλτρο ορατότητας (δικαιώματα) ─────────────────────────────────
  bool _baseVisible(Job j) {
    if (widget.isMaster) return true;

    if (widget.isAdmin) {
      // Δικές του + ομάδων που διαχειρίζεται + όσες ανέλαβε μέλος του
      if (j.createdBy == widget.adminUid) return true;
      if (j.groupId != null && j.groupId!.isNotEmpty &&
          widget.managedGroupIds.contains(j.groupId)) {
        return true;
      }
      if (j.takenBy != null && _memberUids.contains(j.takenBy)) return true;
      // + δουλειές admins που μου έχουν δώσει κοινή πρόσβαση
      if (_shared.containsKey(j.createdBy)) return true;
      return false;
    }

    // Οδηγός: δικές του + ομάδας του + ανοιχτές προς όλους + όσες τον στοχεύουν
    if (j.takenBy == widget.adminUid) return true;
    if (j.createdBy == widget.adminUid) return true;
    if (j.groupId != null && j.groupId!.isNotEmpty &&
        widget.userGroupIds.contains(j.groupId)) {
      return true;
    }
    if ((j.groupId == null || j.groupId!.isEmpty) && j.isOpen) return true;
    if (j.targetUids.contains(widget.adminUid)) return true;
    return false;
  }

  // ── Εφαρμογή των επιλεγμένων φίλτρων (chip) ───────────────────────────────
  bool _matchesFilters(Job j) {
    // Φίλτρο οδηγού
    if (_filterDriverUid == _kUnassigned) {
      if (j.takenBy != null && j.takenBy!.isNotEmpty) return false;
    } else if (_filterDriverUid != null) {
      if (j.takenBy != _filterDriverUid) return false;
    }
    // Φίλτρο ομάδας
    if (_filterGroupId != null && !_jobBelongsToGroup(j, _filterGroupId!)) {
      return false;
    }
    return true;
  }

  /// Μια δουλειά «ανήκει» σε ομάδα αν ισχύει ΟΠΟΙΟΔΗΠΟΤΕ από τα εξής:
  ///  1) Έχει άμεσα ανατεθεί στην ομάδα (j.groupId).
  ///  2) Στοχεύει συγκεκριμένους οδηγούς που είναι μέλη της ομάδας.
  ///  3) Είναι broadcast/προς όλους και ο ΔΗΜΙΟΥΡΓΟΣ της είναι μέλος της ομάδας.
  ///  4) Την πήρε οδηγός που είναι μέλος της ομάδας.
  bool _jobBelongsToGroup(Job j, String groupId) {
    if (j.groupId == groupId) return true;

    final members = _groupMembers[groupId];
    if (members == null || members.isEmpty) return false;

    // Στοχευμένοι οδηγοί μέλη της ομάδας
    if (j.targetUids.isNotEmpty &&
        j.targetUids.any(members.contains)) {
      return true;
    }
    // Broadcast (χωρίς ομάδα & χωρίς στόχους): δείξ' την στην ομάδα του δημιουργού
    final isBroadcast = (j.groupId == null || j.groupId!.isEmpty) &&
        j.targetUids.isEmpty;
    if (isBroadcast && members.contains(j.createdBy)) return true;

    // Την πήρε μέλος της ομάδας
    if (j.takenBy != null && members.contains(j.takenBy)) return true;

    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      _buildFilterBar(),
      Divider(height: 1, color: Colors.grey.shade200),
      Expanded(
        child: StreamBuilder<List<Job>>(
          stream: JobService.allJobs(limit: 100),
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const JobListSkeleton(count: 4);
            }
            // Βάση: ενεργές + δικαιώματα + επιλεγμένα φίλτρα.
            // Συμπεριλαμβάνει και ραντεβού που μαρκαρίστηκαν ήδη 'expired'
            // (π.χ. τελείωσε η κλιμάκωση πριν φτάσει η ώρα τους) ώστε να ΜΗΝ
            // εξαφανίζονται πριν προλάβει να τρέξει το auto-return/auto-delete.
            final base = (snap.data ?? [])
                .where((j) =>
                    j.isOpen || j.isTaken || j.isBoarded ||
                    (j.status == JobStatus.expired && j.scheduledAt != null))
                .where(_baseVisible)
                .where(_matchesFilters)
                .toList();

            // ── AUTO-RETURN ληγμένων αδιεκδίκητων στις «Αποθηκευμένες» ──
            // Αδιεκδίκητες που πέρασαν όλα τα στάδια & τον χρόνο (ή έχουν ήδη
            // μαρκαριστεί 'expired' — isUnclaimedExpired πιάνει και τις δύο
            // περιπτώσεις), δεν είναι σταματημένες, και είναι δικές μου (ή
            // master). Τις επαναφέρουμε.
            final expired = (snap.data ?? [])
                .where((j) =>
                    j.isUnclaimedExpired &&
                    !(j.status == JobStatus.open && j.stopped) &&
                    (widget.isMaster || j.createdBy == widget.adminUid) &&
                    !_autoReturnHandled.contains(j.id))
                .toList();
            if (expired.isNotEmpty) {
              _runAutoReturn(expired);
            }

            // ── AUTO-DELETE ραντεβού που πέρασαν >2 ώρες & δεν αναλήφθηκαν ──
            // Ανοιχτά (ή ήδη 'expired') ραντεβού των οποίων η ώρα πέρασε πάνω
            // από 2 ώρες χωρίς να τα πάρει οδηγός → διαγράφονται οριστικά
            // (δικά μου ή master).
            final stale = (snap.data ?? [])
                .where((j) =>
                    j.isStaleSchedule &&
                    (widget.isMaster || j.createdBy == widget.adminUid) &&
                    !_staleDeleteHandled.contains(j.id))
                .toList();
            if (stale.isNotEmpty) {
              _runStaleDelete(stale);
            }

            // Άμεσες = χωρίς ραντεβού · Ραντεβού = με scheduledAt
            // Άμεσες: παλιότερη πρώτη (σειρά δημιουργίας).
            final immediate = base
                .where((j) => j.scheduledAt == null)
                .toList()
              ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
            // Ραντεβού: πιο κοντινό πάνω· ισοπαλία → σειρά δημιουργίας.
            final scheduled = base
                .where((j) => j.scheduledAt != null)
                .toList()
              ..sort((a, b) {
                final c = a.scheduledAt!.compareTo(b.scheduledAt!);
                if (c != 0) return c;
                return a.createdAt.compareTo(b.createdAt);
              });

            return Column(children: [
              // ── Υπο-tabs: Άμεσες / Ραντεβού ───────────────────────────
              Container(
                color: Colors.white,
                child: TabBar(
                  controller:           _innerTab,
                  indicatorColor:       Colors.amber,
                  indicatorWeight:      3,
                  labelColor:           Colors.black,
                  unselectedLabelColor: Colors.black45,
                  labelStyle: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 13),
                  tabs: [
                    Tab(child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.flash_on_rounded, size: 16),
                        const SizedBox(width: 6),
                        Text('Άμεσες (${immediate.length})'),
                      ],
                    )),
                    Tab(child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.event_rounded, size: 16),
                        const SizedBox(width: 6),
                        Text('Ραντεβού (${scheduled.length})'),
                      ],
                    )),
                  ],
                ),
              ),
              Divider(height: 1, color: Colors.grey.shade200),
              Expanded(child: TabBarView(
                controller: _innerTab,
                children: [
                  _jobsList(immediate,
                      empty: 'Δεν υπάρχουν άμεσες δουλειές'),
                  _jobsList(scheduled,
                      empty: 'Δεν υπάρχουν ραντεβού'),
                ],
              )),
            ]);
          },
        ),
      ),
    ]);
  }

  // Επαναφορά ληγμένων αδιεκδίκητων στις «Αποθηκευμένες» (μία φορά ανά εμφάνιση).
  Future<void> _runAutoReturn(List<Job> expired) async {
    if (_autoReturnRunning) return;
    _autoReturnRunning = true;
    // Σημείωσέ τες ως «υπό επεξεργασία» ώστε να μην ξανατρέξει σε επόμενο tick.
    for (final j in expired) {
      _autoReturnHandled.add(j.id);
    }
    try {
      final moved = await JobService.returnExpiredToSaved(expired);
      if (moved > 0 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(moved == 1
                ? '↩️ 1 αδιεκδίκητη δουλειά επέστρεψε στις «Αποθηκευμένες»'
                : '↩️ $moved αδιεκδίκητες δουλειές επέστρεψαν στις «Αποθηκευμένες»'),
            backgroundColor: const Color(0xFF1565C0),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (_) {
      // Σε σφάλμα, επίτρεψε επανάληψη αργότερα
      for (final j in expired) {
        _autoReturnHandled.remove(j.id);
      }
    } finally {
      _autoReturnRunning = false;
    }
  }

  // Διαγραφή ραντεβού που πέρασαν >2 ώρες & δεν αναλήφθηκαν (μία φορά ανά εμφάνιση).
  Future<void> _runStaleDelete(List<Job> stale) async {
    if (_staleDeleteRunning) return;
    _staleDeleteRunning = true;
    for (final j in stale) {
      _staleDeleteHandled.add(j.id);
    }
    try {
      final deleted = await JobService.deleteStaleSchedules(stale);
      if (deleted > 0 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(deleted == 1
                ? '🗑️ 1 αδιεκδίκητο ραντεβού διαγράφηκε (πέρασε η ώρα του)'
                : '🗑️ $deleted αδιεκδίκητα ραντεβού διαγράφηκαν (πέρασε η ώρα τους)'),
            backgroundColor: Colors.grey.shade800,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (_) {
      // Σε σφάλμα, επίτρεψε επανάληψη αργότερα
      for (final j in stale) {
        _staleDeleteHandled.remove(j.id);
      }
    } finally {
      _staleDeleteRunning = false;
    }
  }

  Widget _jobsList(List<Job> jobs, {required String empty}) {
    if (jobs.isEmpty) {
      return jobEmpty(_hasActiveFilter
          ? 'Δεν υπάρχουν δουλειές\nμε αυτά τα φίλτρα'
          : empty);
    }
    // Αδιεκδίκητες (open, χωρίς οδηγό) — δικές μου ή master
    final unclaimed = jobs
        .where((j) =>
            j.isOpen &&
            j.takenBy == null &&
            (widget.isMaster || j.createdBy == widget.adminUid))
        .toList();

    return Column(children: [
      // ── Κουμπί «Ξαναστείλε όλες» (όταν υπάρχουν ≥2 αδιεκδίκητες) ──
      if (unclaimed.length >= 2)
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: OutlinedButton.icon(
            onPressed: () => _resendAll(unclaimed),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF1E8E3E),
              side: const BorderSide(color: Color(0xFF1E8E3E)),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            icon: const Icon(Icons.campaign_rounded, size: 18),
            label: Text('Ξαναστείλε όλες (${unclaimed.length})',
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
        ),
      Expanded(
        child: ListView.separated(
          padding:          EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
          itemCount:        jobs.length,
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder:      (_, i) {
            final lvl = _levelFor(jobs[i]);
            final isForeign = !widget.isMaster &&
                jobs[i].createdBy != widget.adminUid &&
                _shared.containsKey(jobs[i].createdBy);
            return AdminJobCard(
              job:        jobs[i],
              adminUid:   widget.adminUid,
              adminName:  widget.adminName,
              isMaster:   widget.isMaster,
              isAdmin:    widget.isAdmin,
              shareLevel: lvl,
              isForeign:  isForeign,
            );
          },
        ),
      ),
    ]);
  }

  // Ξαναστέλνει όλες τις αδιεκδίκητες «από την αρχή» (στάδιο 0, φρέσκος χρόνος).
  Future<void> _resendAll(List<Job> unclaimed) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Ξαναστείλε όλες;'),
        content: Text(
            '${unclaimed.length} αδιεκδίκητες δουλειές θα ξανασταλούν από την '
            'αρχή στους ίδιους παραλήπτες (ομάδα/οδηγό/όλους).'),
        actions: [
          AppButtonTonal(label: 'Άκυρο', onPressed: () => Navigator.pop(ctx, false)),
          AppButton(
            label: 'Ξαναστείλε',
            icon: Icons.campaign_rounded,
            color: const Color(0xFF1E8E3E),
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      // Καθάρισε το auto-return guard ώστε να μην τις θεωρεί ληγμένες
      for (final j in unclaimed) {
        _autoReturnHandled.remove(j.id);
      }
      await JobService.resendJobs(unclaimed.map((j) => j.id).toList());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('🔔 Ξαναστάλθηκαν ${unclaimed.length} δουλειές'),
            backgroundColor: const Color(0xFF1E8E3E),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Σφάλμα: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  bool get _hasActiveFilter =>
      _filterDriverUid != null || _filterGroupId != null;

  // ── Μπάρα φίλτρων ─────────────────────────────────────────────────────────
  Widget _buildFilterBar() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: _showFullFilters ? _adminFilters() : _driverFilters(),
    );
  }

  // Admin / Master: picker οδηγού (+ καμία ανάθεση) & picker ομάδας
  Widget _adminFilters() => Row(children: [
        Expanded(child: _filterChip(
          icon:  _filterDriverUid == _kUnassigned
              ? Icons.person_off_rounded : Icons.person_rounded,
          label: _filterDriverName ?? 'Όλοι οι οδηγοί',
          color: _filterDriverUid != null ? Colors.blue : Colors.grey,
          onTap: _showDriverPicker,
        )),
        const SizedBox(width: 8),
        Expanded(child: _filterChip(
          icon:  Icons.groups_rounded,
          label: _filterGroupName ?? 'Όλες οι ομάδες',
          color: _filterGroupId != null ? Colors.purple : Colors.grey,
          onTap: _showGroupPicker,
        )),
        if (_hasActiveFilter)
          IconButton(
            icon:    const Icon(Icons.clear_rounded, size: 18),
            color:   Colors.red,
            tooltip: 'Καθαρισμός φίλτρων',
            onPressed: () => setState(() {
              _filterDriverUid = null; _filterDriverName = null;
              _filterGroupId   = null; _filterGroupName  = null;
            }),
          ),
      ]);

  // Οδηγός: απλό toggle 3 επιλογών
  Widget _driverFilters() => Row(children: [
        Expanded(child: _segChip('Όλες', null, Icons.list_rounded)),
        const SizedBox(width: 8),
        Expanded(child: _segChip(
            'Δικές μου', widget.adminUid, Icons.person_rounded)),
        const SizedBox(width: 8),
        Expanded(child: _segChip(
            'Αδέσμευτες', _kUnassigned, Icons.person_off_rounded)),
      ]);

  Widget _segChip(String label, String? value, IconData icon) {
    final selected = _filterDriverUid == value;
    return GestureDetector(
      onTap: () => setState(() {
        _filterDriverUid  = value;
        _filterDriverName = value == null ? null : label;
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: selected ? Colors.amber : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: selected ? Colors.amber : Colors.grey.shade300),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, size: 14,
              color: selected ? Colors.black : Colors.grey[600]),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(
              fontSize: 11,
              fontWeight: selected ? FontWeight.bold : FontWeight.w500,
              color: selected ? Colors.black : Colors.grey[700])),
        ]),
      ),
    );
  }

  void _showDriverPicker() => showModalBottomSheet(
        context: context, backgroundColor: Colors.transparent,
        builder: (_) => JobPickerSheet(
          title: 'Επιλογή Οδηγού', icon: Icons.person_rounded,
          items: [
            {'id': null,         'name': 'Όλοι οι οδηγοί'},
            {'id': _kUnassigned, 'name': 'Καμία ανάθεση (αδέσμευτες)'},
            ..._drivers.map((d) => {'id': d['uid'], 'name': d['name']}),
          ],
          selectedId: _filterDriverUid,
          onSelected: (id, name) => setState(() {
            _filterDriverUid  = id;
            _filterDriverName = id == null ? null : name;
            if (id != null) { _filterGroupId = null; _filterGroupName = null; }
          }),
        ),
      );

  void _showGroupPicker() => showModalBottomSheet(
        context: context, backgroundColor: Colors.transparent,
        builder: (_) => JobPickerSheet(
          title: 'Επιλογή Ομάδας', icon: Icons.groups_rounded,
          items: [
            {'id': null, 'name': 'Όλες οι ομάδες'},
            ..._groups.map((g) => {'id': g['id'], 'name': g['name']}),
          ],
          selectedId: _filterGroupId,
          onSelected: (id, name) => setState(() {
            _filterGroupId   = id;
            _filterGroupName = id == null ? null : name;
            if (id != null) { _filterDriverUid = null; _filterDriverName = null; }
          }),
        ),
      );

  Widget _filterChip({required IconData icon, required String label,
      required Color color, required VoidCallback onTap}) =>
      GestureDetector(onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withValues(alpha: 0.3)),
          ),
          child: Row(children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
            Expanded(child: Text(label,
                style: TextStyle(fontSize: 11, color: color,
                    fontWeight: FontWeight.w600),
                maxLines: 1, overflow: TextOverflow.ellipsis)),
            Icon(Icons.arrow_drop_down_rounded, size: 16, color: color),
          ]),
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// _HistoryTab
// ─────────────────────────────────────────────────────────────────────────────

class _HistoryTab extends StatefulWidget {
  final String       adminUid;
  final String       adminName;
  final bool         isAdmin;
  final bool         isMaster;
  final List<String> managedGroupIds;
  final List<String> userGroupIds;

  const _HistoryTab({
    required this.adminUid,
    this.adminName       = '',
    this.isAdmin         = true,
    this.isMaster        = false,
    this.managedGroupIds = const [],
    this.userGroupIds    = const [],
  });

  @override
  State<_HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<_HistoryTab> {
  DateTime _from = DateTime.now().subtract(const Duration(days: 30));
  DateTime _to   = DateTime.now();
  Map<String, dynamic>? _summary;
  bool   _loading = false;
  String _error   = '';

  String? _filterDriverUid;
  String? _filterDriverName;
  String? _filterGroupId;
  String? _filterGroupName;

  List<Map<String, dynamic>> _drivers = [];
  List<Map<String, dynamic>> _groups  = [];

  // ── Live ανανέωση ιστορικού ──────────────────────────────────────────────
  // Ακούμε τις δουλειές· όταν αλλάξει κάτι (π.χ. ολοκλήρωση + billing από τον
  // trigger), ξαναφορτώνουμε το summary αυτόματα — χωρίς έξοδο/είσοδο.
  // Debounce ώστε οι διαδοχικές αλλαγές (done → billedAt → billing_tx) να
  // προκαλούν ΜΙΑ ανανέωση αφού «ηρεμήσουν».
  StreamSubscription<List<Job>>? _liveSub;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    if (!widget.isAdmin && widget.userGroupIds.isNotEmpty) {
      _filterGroupId   = widget.userGroupIds.first;
      _filterGroupName = 'Η ομάδα μου';
    } else if (!widget.isAdmin && widget.userGroupIds.isEmpty) {
      // Driver ΧΩΡΙΣ ομάδα → βλέπει ΜΟΝΟ δικές του δουλειές
      _filterDriverUid  = widget.adminUid;
      _filterDriverName = 'Οι δουλειές μου';
    }
    if (widget.isAdmin && !widget.isMaster &&
        widget.managedGroupIds.isNotEmpty) {
      _filterGroupId   = widget.managedGroupIds.first;
      _filterGroupName = 'Ομάδα διαχείρισής μου';
    }
    _loadDriversAndGroups();
    _loadSummary();
    _startLiveListener();
  }

  void _startLiveListener() {
    _liveSub = JobService.allJobs(limit: 100).listen((_) {
      // Debounce: περίμενε να ηρεμήσουν οι αλλαγές πριν ξαναφορτώσεις.
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 800), () {
        if (mounted) _loadSummary(silent: true);
      });
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _liveSub?.cancel();
    super.dispose();
  }

  Future<void> _loadDriversAndGroups() async {
    final fs      = FirebaseFirestore.instance;
    final results = await Future.wait([
      fs.collection('presence').orderBy('displayName').get(),
      fs.collection('groups').orderBy('name').get(),
    ]);
    if (!mounted) return;
    setState(() {
      _drivers = results[0].docs.map((d) {
        final data = d.data();
        return {
          'uid':  d.id,
          'name': '${data['displayName'] ?? ''} ${data['lastName'] ?? ''}'.trim(),
        };
      }).where((d) => (d['name'] as String).isNotEmpty).toList();

      _groups = results[1].docs.map((d) => {
        'id':   d.id,
        'name': d.data()['name'] ?? '',
      }).toList();
    });
  }

  Future<void> _loadSummary({bool silent = false}) async {
    setState(() { if (!silent) _loading = true; _error = ''; });
    try {
      // Σύνολο ομάδων προς φιλτράρισμα
      List<String>? groupSet;
      if (_filterDriverUid != null) {
        // Φίλτρο συγκεκριμένου οδηγού → χωρίς περιορισμό ομάδας
        groupSet = null;
      } else if (_filterGroupId != null) {
        // Επιλεγμένη συγκεκριμένη ομάδα
        groupSet = [_filterGroupId!];
      } else if (!widget.isAdmin && widget.userGroupIds.isNotEmpty) {
        groupSet = widget.userGroupIds;
      } else if (widget.isAdmin && !widget.isMaster &&
          widget.managedGroupIds.isNotEmpty) {
        groupSet = widget.managedGroupIds;
      }
      // Μέλη των ομάδων → ώστε να φαίνονται & οι εκτός-ομάδας δουλειές τους
      List<String>? memberUids;
      if (groupSet != null && groupSet.isNotEmpty) {
        memberUids = await JobService.memberUidsOf(groupSet);
      }
      final s = await JobService.summaryForPeriod(
        from:       _from,
        to:         _to,
        driverUid:  _filterDriverUid,
        groupIds:   groupSet,
        memberUids: memberUids,
      );
      if (mounted) setState(() { _summary = s; _loading = false; });
    } catch (e) {
      if (mounted) {
        setState(() {
        _error   = e.toString();
        _loading = false;
        _summary = {
          'count': 0, 'totalPrice': 0.0,
          'totalComm': 0.0, 'totalAppComm': 0.0, 'jobs': <Job>[]
        };
      });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('dd/MM/yy');
    return Column(children: [
      Container(
        color: Colors.white,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(children: [
          Row(children: [
            _dateBtn(fmt.format(_from), () async {
              final d = await showDatePicker(context: context,
                  initialDate: _from, firstDate: DateTime(2024), lastDate: _to);
              if (d != null) { setState(() => _from = d); _loadSummary(); }
            }),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6),
              child: Text('→', style: TextStyle(color: Colors.grey)),
            ),
            _dateBtn(fmt.format(_to), () async {
              final d = await showDatePicker(context: context,
                  initialDate: _to, firstDate: _from, lastDate: DateTime.now());
              if (d != null) { setState(() => _to = d); _loadSummary(); }
            }),
            const Spacer(),
            AppButtonTonal(
              label: 'Τελευταίο μήνα',
              onPressed: () {
                setState(() {
                  _from = DateTime.now().subtract(const Duration(days: 30));
                  _to   = DateTime.now();
                });
                _loadSummary();
              },
            ),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            if (widget.isAdmin) ...[
              Expanded(child: _filterChip(
                icon:  Icons.person_rounded,
                label: _filterDriverName ?? 'Όλοι οι οδηγοί',
                color: _filterDriverUid != null ? Colors.blue : Colors.grey,
                onTap: _showDriverPicker,
              )),
              const SizedBox(width: 8),
            ] else if (widget.userGroupIds.isNotEmpty) ...[
              // Οδηγός με ομάδα: εναλλαγή «Η ομάδα μου» ↔ «Οι δουλειές μου»
              Expanded(child: _filterChip(
                icon:  _filterDriverUid != null
                    ? Icons.person_rounded : Icons.groups_rounded,
                label: _filterDriverUid != null
                    ? 'Οι δουλειές μου' : 'Η ομάδα μου',
                color: _filterDriverUid != null
                    ? Colors.blue : Colors.purple,
                onTap: () {
                  setState(() {
                    if (_filterDriverUid != null) {
                      _filterDriverUid  = null;
                      _filterDriverName = null;
                    } else {
                      _filterDriverUid  = widget.adminUid;
                      _filterDriverName = 'Οι δουλειές μου';
                    }
                  });
                  _loadSummary();
                },
              )),
              const SizedBox(width: 8),
            ],
            Expanded(child: _filterChip(
              icon:  Icons.groups_rounded,
              label: _filterGroupName ?? 'Όλες οι ομάδες',
              color: _filterGroupId != null ? Colors.purple : Colors.grey,
              onTap: widget.isAdmin ? _showGroupPicker : () {},
            )),
            if (widget.isAdmin &&
                (_filterDriverUid != null || _filterGroupId != null))
              IconButton(
                icon:    const Icon(Icons.clear_rounded, size: 18),
                color:   Colors.red,
                tooltip: 'Καθαρισμός φίλτρων',
                onPressed: () {
                  setState(() {
                    _filterDriverUid  = null; _filterDriverName = null;
                    _filterGroupId    = null; _filterGroupName  = null;
                  });
                  _loadSummary();
                },
              ),
          ]),
        ]),
      ),
      Divider(height: 1, color: Colors.grey.shade200),

      if (_loading)
        const Expanded(child: Center(
            child: CircularProgressIndicator(color: Colors.amber)))
      else if (_summary == null)
        jobEmpty('Δεν υπάρχουν δεδομένα')
      else
        Expanded(child: ListView(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
          children: [
            if (_error.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.red.shade200)),
                child: Row(children: [
                  Icon(Icons.error_outline_rounded,
                      color: Colors.red.shade700, size: 16),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_error,
                      style: TextStyle(fontSize: 11, color: Colors.red.shade700))),
                ]),
              ),
            if (_filterDriverName != null || _filterGroupName != null)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(color: Colors.amber.shade50,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.amber.shade300)),
                child: Row(children: [
                  const Icon(Icons.filter_alt_rounded, color: Colors.amber, size: 16),
                  const SizedBox(width: 8),
                  Expanded(child: Text(
                    [
                      if (_filterDriverName != null) 'Οδηγός: $_filterDriverName',
                      if (_filterGroupName  != null) 'Ομάδα: $_filterGroupName',
                    ].join('  •  '),
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  )),
                ]),
              ),
            Row(children: [
              _summaryCard('Δουλειές', '${_summary!['count']}',
                  Icons.work_rounded, Colors.blue),
              const SizedBox(width: 8),
              _summaryCard('Τζίρος',
                  '${(_summary!['totalPrice'] as double).toStringAsFixed(2)}€',
                  Icons.euro_rounded, const Color(0xFF1E8E3E)),
              const SizedBox(width: 8),
              _summaryCard('Γιαούρτι',
                  '${(_summary!['totalComm'] as double).toStringAsFixed(2)}€',
                  Icons.handshake_rounded, Colors.orange),
              const SizedBox(width: 8),
              _summaryCard('App',
                  '${(_summary!['totalAppComm'] as double).toStringAsFixed(2)}€',
                  Icons.phone_iphone_rounded, Colors.blue.shade700),
            ]),
            const SizedBox(height: 16),
            if ((_summary!['jobs'] as List<Job>).isEmpty)
              jobEmpty('Δεν βρέθηκαν δουλειές\nστο επιλεγμένο διάστημα')
            else
              ...(_summary!['jobs'] as List<Job>).map((j) =>
                  HistoryJobCard(
                    job:            j,
                    isAdmin:        widget.isAdmin || widget.isMaster,
                    isMaster:       widget.isMaster,
                    adminUid:       widget.adminUid,
                    adminName:      widget.adminName,
                    viewerGroupIds: widget.isAdmin
                        ? widget.managedGroupIds
                        : widget.userGroupIds,
                    onChanged:      _loadSummary,
                  )),
          ],
        )),
    ]);
  }

  void _showDriverPicker() => showModalBottomSheet(
    context: context, backgroundColor: Colors.transparent,
    builder: (_) => JobPickerSheet(
      title: 'Επιλογή Οδηγού', icon: Icons.person_rounded,
      items: [
        {'id': null, 'name': 'Όλοι οι οδηγοί'},
        ..._drivers.map((d) => {'id': d['uid'], 'name': d['name']}),
      ],
      selectedId: _filterDriverUid,
      onSelected: (id, name) {
        setState(() {
          _filterDriverUid  = id;
          _filterDriverName = id == null ? null : name;
          if (id != null) { _filterGroupId = null; _filterGroupName = null; }
        });
        _loadSummary();
      },
    ),
  );

  void _showGroupPicker() => showModalBottomSheet(
    context: context, backgroundColor: Colors.transparent,
    builder: (_) => JobPickerSheet(
      title: 'Επιλογή Ομάδας', icon: Icons.groups_rounded,
      items: [
        {'id': null, 'name': 'Όλες οι ομάδες'},
        ..._groups.map((g) => {'id': g['id'], 'name': g['name']}),
      ],
      selectedId: _filterGroupId,
      onSelected: (id, name) {
        setState(() {
          _filterGroupId   = id;
          _filterGroupName = id == null ? null : name;
          if (id != null) { _filterDriverUid = null; _filterDriverName = null; }
        });
        _loadSummary();
      },
    ),
  );

  Widget _filterChip({required IconData icon, required String label,
      required Color color, required VoidCallback onTap}) =>
      GestureDetector(onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withValues(alpha: 0.3)),
          ),
          child: Row(children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
            Expanded(child: Text(label,
                style: TextStyle(fontSize: 11, color: color,
                    fontWeight: FontWeight.w600),
                maxLines: 1, overflow: TextOverflow.ellipsis)),
            Icon(Icons.arrow_drop_down_rounded, size: 16, color: color),
          ]),
        ),
      );

  Widget _dateBtn(String label, VoidCallback onTap) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
    ),
  );

  Widget _summaryCard(String label, String value, IconData icon, Color color) =>
      Expanded(child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Column(children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(height: 4),
          Text(value, style: TextStyle(
              fontSize: 15, fontWeight: FontWeight.bold, color: color)),
          Text(label, style: TextStyle(fontSize: 10, color: Colors.grey[600])),
        ]),
      ));
}

// ─────────────────────────────────────────────────────────────────────────────
// _SourcesTab + _SourceCard + _showSourceDialog
// ─────────────────────────────────────────────────────────────────────────────

class _SourcesTab extends StatelessWidget {
  final String adminUid;
  final bool   isMaster;
  const _SourcesTab({required this.adminUid, this.isMaster = false});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<JobSource>>(
      // Master βλέπει όλες τις πηγές, admin μόνο τις δικές του
      stream: JobService.sources(createdBy: isMaster ? null : adminUid),
      builder: (context, snap) {
        final sources = snap.data ?? [];
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
          children: [
            ...sources.map((s) => _SourceCard(
                source: s, adminUid: adminUid, isMaster: isMaster)),
            if (sources.isEmpty)
              const Center(child: Padding(padding: EdgeInsets.all(40),
                  child: Text('Δεν υπάρχουν πηγές',
                      style: TextStyle(color: Colors.grey)))),
            const SizedBox(height: 80),
            FilledButton.icon(
              onPressed: () => _showSourceDialog(context,
                  adminUid: adminUid, isMaster: isMaster),
              style: FilledButton.styleFrom(
                  backgroundColor: Colors.amber, foregroundColor: Colors.black),
              icon:  const Icon(Icons.add_rounded),
              label: const Text('Νέα Πηγή / Γιαούρτι',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }
}

class _SourceCard extends StatelessWidget {
  final JobSource source;
  final String    adminUid;
  final bool      isMaster;
  const _SourceCard({
    required this.source, required this.adminUid, this.isMaster = false});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0, color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: Colors.grey.shade200)),
      child: ListTile(
        leading: Container(
          width: 40, height: 40,
          decoration: BoxDecoration(color: Colors.orange.shade50,
              borderRadius: BorderRadius.circular(10)),
          child: const Icon(Icons.handshake_rounded,
              color: Colors.orange, size: 22),
        ),
        title: Text(source.name,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              source.commissionType == CommissionType.fixed
                  ? 'Πηγή: ${source.commissionValue.toStringAsFixed(2)}€ σταθερό'
                  : 'Πηγή: ${source.commissionValue.toStringAsFixed(1)}% επί της τιμής',
              style: TextStyle(color: Colors.orange[700], fontSize: 12),
            ),
            if (source.hasNight)
              Text(
                source.nightCommissionType == CommissionType.fixed
                    ? 'Βραδινό: ${source.nightCommissionValue.toStringAsFixed(2)}€ σταθερό'
                    : 'Βραδινό: ${source.nightCommissionValue.toStringAsFixed(1)}% επί της τιμής',
                style: TextStyle(color: Colors.indigo[400], fontSize: 12),
              ),
            if (source.appCommissionValue > 0)
              Text(
                source.appCommissionType == CommissionType.fixed
                    ? 'App: ${source.appCommissionValue.toStringAsFixed(2)}€ σταθερό'
                    : 'App: ${source.appCommissionValue.toStringAsFixed(1)}% επί της τιμής',
                style: TextStyle(color: Colors.blue[700], fontSize: 12),
              ),
          ],
        ),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(
            icon: const Icon(Icons.edit_rounded, size: 18, color: Colors.grey),
            onPressed: () => _showSourceDialog(context,
                adminUid: adminUid, source: source, isMaster: isMaster),
          ),
          IconButton(
            icon: const Icon(Icons.delete_rounded, size: 18, color: Colors.red),
            onPressed: () => _confirmDelete(context),
          ),
        ]),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final ok = await showDialog<bool>(context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Διαγραφή πηγής'),
        content: Text('Να διαγραφεί "${source.name}";'),
        actions: [
          AppButtonTonal(label: 'Άκυρο', onPressed: () => Navigator.pop(ctx, false)),
          AppButton(label: 'Διαγραφή', color: Colors.red, onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
    );
    if (ok == true) await JobService.deleteSource(source.id);
  }
}

Future<void> _showSourceDialog(BuildContext context,
    {required String adminUid, JobSource? source, bool isMaster = false}) async {
  // Default προμήθεια App (ορίζεται από τον master στη σελίδα διαχείρισης).
  // Νέα πηγή admin → παίρνει αυτή την τιμή. Master → μπορεί να την αλλάξει.
  double defaultAppComm = 1.50;
  try {
    final s = await JobService.getAppSettings();
    defaultAppComm = s['appCommission'] ?? 1.50;
  } catch (_) {}

  // Helper: 2 δεκαδικά για σταθερό ποσό (€), 1 δεκαδικό για ποσοστό (%).
  String fmtVal(double v, CommissionType t) =>
      t == CommissionType.percent ? v.toStringAsFixed(1) : v.toStringAsFixed(2);

  final nameCtrl     = TextEditingController(text: source?.name ?? '');
  final valueCtrl    = TextEditingController(
      text: source != null && source.commissionValue != 0
          ? fmtVal(source.commissionValue, source.commissionType) : '');
  // Βραδινή τιμή
  bool hasNight = source?.hasNight ?? false;
  final nightValueCtrl = TextEditingController(
      text: source != null && source.hasNight && source.nightCommissionValue != 0
          ? fmtVal(source.nightCommissionValue, source.nightCommissionType)
          : '');
  CommissionType selNightType =
      source?.nightCommissionType ?? CommissionType.fixed;
  // App commission: υπάρχουσα πηγή → η τιμή της· νέα πηγή → default master.
  final appValueCtrl = TextEditingController(
      text: source != null
          ? (source.appCommissionValue != 0
              ? fmtVal(source.appCommissionValue, source.appCommissionType)
              : '')
          : defaultAppComm.toStringAsFixed(2));

  CommissionType selType    = source?.commissionType    ?? CommissionType.fixed;
  CommissionType selAppType = source?.appCommissionType ?? CommissionType.fixed;

  await showDialog<void>(context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(source == null ? 'Νέα Πηγή' : 'Επεξεργασία Πηγής',
            style: const TextStyle(fontWeight: FontWeight.bold)),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: nameCtrl,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Όνομα (π.χ. Hilton)',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.business_rounded)),
            ),
            const SizedBox(height: 16),
            _commissionBox(label: 'Προμήθεια Πηγής (Γιαούρτι)',
                color: Colors.orange, prefixIcon: Icons.handshake_rounded,
                ctrl: valueCtrl, selType: selType,
                onChanged: (v) => setS(() => selType = v!), setS: setS,
                hint: 'Αρνητικό (π.χ. -5) = χρωστάς εσύ στον οδηγό'),
            const SizedBox(height: 12),
            // ── Βραδινό γιαούρτι (23:30–05:30) ──
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(children: [
                Checkbox(
                  value: hasNight,
                  activeColor: Colors.indigo,
                  onChanged: (v) => setS(() => hasNight = v ?? false),
                ),
                const Expanded(
                  child: Text('Διαφορετική βραδινή τιμή (23:30–05:30)',
                      style: TextStyle(fontWeight: FontWeight.w600,
                          fontSize: 13)),
                ),
              ]),
            ),
            if (hasNight) ...[
              const SizedBox(height: 4),
              _commissionBox(label: 'Βραδινό Γιαούρτι',
                  color: Colors.indigo, prefixIcon: Icons.nightlight_round,
                  ctrl: nightValueCtrl, selType: selNightType,
                  onChanged: (v) => setS(() => selNightType = v!), setS: setS,
                  hint: 'Κενό = 0. Αρνητικό = χρωστάς στον οδηγό'),
            ],
            const SizedBox(height: 12),
            // App commission — κλειδωμένο σε 1€ για admin
            _commissionBox(label: isMaster
                    ? 'Προμήθεια App (2η)'
                    : 'Προμήθεια App (κλειδωμένη)',
                color: Colors.blue, prefixIcon: Icons.phone_iphone_rounded,
                ctrl: appValueCtrl, selType: selAppType,
                onChanged: isMaster
                    ? (v) => setS(() => selAppType = v!)
                    : null,
                setS: setS,
                hint: isMaster ? '0 ή κενό = καμία' : 'Μόνο master μπορεί να αλλάξει',
                readOnly: !isMaster),
          ]),
        ),
        actions: [
          AppButtonTonal(label: 'Άκυρο', onPressed: () => Navigator.pop(ctx)),
          AppButton(
            label: source == null ? 'Δημιουργία' : 'Αποθήκευση',
            color: Colors.amber,
            onPressed: () async {
              final name     = nameCtrl.text.trim();
              final value    = double.tryParse(
                  valueCtrl.text.trim().replaceAll(',', '.')) ?? 0;
              final nightVal = hasNight
                  ? (double.tryParse(
                      nightValueCtrl.text.trim().replaceAll(',', '.')) ?? 0)
                  : 0.0;
              // App: μόνο ο master την αλλάζει. Admin → πάντα το default που
              // έχει ορίσει ο master (fixed). Υπάρχουσα πηγή admin → κρατά την
              // αποθηκευμένη τιμή της.
              final appValue = isMaster
                  ? (double.tryParse(
                      appValueCtrl.text.trim().replaceAll(',', '.')) ?? 0)
                  : (source?.appCommissionValue ?? defaultAppComm);
              final appTypeFinal = isMaster
                  ? selAppType
                  : (source?.appCommissionType ?? CommissionType.fixed);
              if (name.isEmpty) return;
              Navigator.pop(ctx);
              final s = JobSource(id: source?.id ?? '', name: name,
                  commissionType: selType, commissionValue: value,
                  hasNight: hasNight,
                  nightCommissionType: selNightType,
                  nightCommissionValue: nightVal,
                  appCommissionType: appTypeFinal, appCommissionValue: appValue,
                  createdBy: source?.createdBy.isNotEmpty == true
                      ? source!.createdBy
                      : adminUid);
              source == null
                  ? await JobService.createSource(s)
                  : await JobService.updateSource(source.id, s);
            },
          ),
        ],
      ),
    ),
  );
}

Widget _commissionBox({
  required String label, required Color color,
  required IconData prefixIcon, required TextEditingController ctrl,
  required CommissionType selType,
  required ValueChanged<CommissionType?>? onChanged,
  required StateSetter setS, String hint = '0 = καμία',
  bool readOnly = false,
}) =>
    Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: readOnly
            ? Colors.grey.withValues(alpha: 0.1)
            : color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: readOnly
            ? Colors.grey.withValues(alpha: 0.4)
            : color.withValues(alpha: 0.3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          if (readOnly)
            Icon(Icons.lock_outline_rounded, size: 14, color: Colors.grey[600]),
          if (readOnly) const SizedBox(width: 4),
          Expanded(child: Text(label,
              style: TextStyle(fontWeight: FontWeight.bold,
                  fontSize: 13,
                  color: readOnly ? Colors.grey[700] : color))),
        ]),
        const SizedBox(height: 8),
        RadioGroup<CommissionType>(
          groupValue: selType,
          onChanged: (v) => onChanged?.call(v),
          child: Row(children: [
            Expanded(child: RadioListTile<CommissionType>(dense: true,
              title: const Text('Σταθερό (\u20ac)', style: TextStyle(fontSize: 12)),
              value: CommissionType.fixed,
              enabled: !readOnly && onChanged != null,
              activeColor: color)),
            Expanded(child: RadioListTile<CommissionType>(dense: true,
              title: const Text('Ποσοστό (%)', style: TextStyle(fontSize: 12)),
              value: CommissionType.percent,
              enabled: !readOnly && onChanged != null,
              activeColor: color)),
          ]),
        ),
        TextField(
          controller: ctrl,
          readOnly: readOnly,
          keyboardType: const TextInputType.numberWithOptions(
              decimal: true, signed: true),
          decoration: InputDecoration(
            labelText: selType == CommissionType.fixed ? 'Ποσό (\u20ac)' : 'Ποσοστό (%)',
            hintText: hint, border: const OutlineInputBorder(),
            prefixIcon: Icon(prefixIcon,
                color: readOnly ? Colors.grey : color), isDense: true),
        ),
      ]),
    );
