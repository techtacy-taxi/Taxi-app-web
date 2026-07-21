// lib/jobs/my_jobs_sheet.dart
// «Οι δουλειές μου»: MyJobsBottomBar (συρτάρι χάρτη) + MyJobTile (compact κάρτα)
// + picker εξαγωγής στο ημερολόγιο. Το παλιό modal sheet (showMyJobsSheet)
// αφαιρέθηκε — το κάλυψε πλήρως το MyJobsBottomBar.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:vibration/vibration.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'job_details_sheet.dart';
import 'job_shared_widgets.dart';
import 'job_model.dart';
import 'job_service.dart';
import 'ics_export_service.dart';
import 'ics_access.dart';

// ─── Κουμπί «Στο ημερολόγιο» (κάτω-κάτω στο συρτάρι) ──────────────────────────
// Μπλε, λευκά γράμματα. Ανοίγει picker για να διαλέξεις ΠΟΙΕΣ δουλειές θα
// μπουν στο ημερολόγιο· μετά παράγει .ics & το ανοίγει (Android) / κατεβάζει (Web).
class _AllToCalendarButton extends StatefulWidget {
  final List<Job> jobs;
  const _AllToCalendarButton({required this.jobs});

  @override
  State<_AllToCalendarButton> createState() => _AllToCalendarButtonState();
}

class _AllToCalendarButtonState extends State<_AllToCalendarButton> {
  bool _allowed = IcsAccess.cached ?? false;

  @override
  void initState() {
    super.initState();
    if (IcsAccess.cached == null) {
      IcsAccess.canExport().then((v) {
        if (mounted) setState(() => _allowed = v);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_allowed) return const SizedBox.shrink();
    final jobs = widget.jobs;
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: jobs.isEmpty
            ? null
            : () => showCalendarPicker(context, jobs),
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF1A73E8),
          disabledBackgroundColor: const Color(0xFF1A73E8),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 13),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14)),
        ),
        icon: const Icon(Icons.calendar_month_rounded, color: Colors.white),
        label: const Text('Στο ημερολόγιο',
            style: TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.bold,
                color: Colors.white)),
      ),
    );
  }
}

// ─── Picker: διάλεξε ποιες δουλειές θα μπουν στο ημερολόγιο ───────────────────
// Όλες ξεκινούν ΞΕΤΣΕΚΑΡΙΣΜΕΝΕΣ — διαλέγεις εσύ.
Future<void> showCalendarPicker(BuildContext context, List<Job> jobs) {
  return showDialog<void>(
    context: context,
    builder: (_) => _CalendarPickerDialog(jobs: jobs),
  );
}

class _CalendarPickerDialog extends StatefulWidget {
  final List<Job> jobs;
  const _CalendarPickerDialog({required this.jobs});
  @override
  State<_CalendarPickerDialog> createState() => _CalendarPickerDialogState();
}

class _CalendarPickerDialogState extends State<_CalendarPickerDialog> {
  late final List<bool> _checked;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Καμία τσεκαρισμένη εξαρχής.
    _checked = List<bool>.filled(widget.jobs.length, false);
  }

  int get _count => _checked.where((c) => c).length;
  bool get _allOn => _count == widget.jobs.length && widget.jobs.isNotEmpty;

  void _toggleAll() {
    final target = !_allOn;
    setState(() {
      for (var i = 0; i < _checked.length; i++) {
        _checked[i] = target;
      }
    });
  }

  Future<void> _confirm() async {
    if (_busy || _count == 0) return;
    final selected = <Job>[];
    for (var i = 0; i < widget.jobs.length; i++) {
      if (_checked[i]) selected.add(widget.jobs[i]);
    }
    setState(() => _busy = true);
    final ok = await IcsExportService.exportJobs(selected);
    if (!mounted) return;
    setState(() => _busy = false);
    Navigator.of(context).pop();
    final msg = ok
        ? 'Άνοιγμα ημερολογίου με ${selected.length} '
            'δουλειέ${selected.length == 1 ? "α" : "ς"}'
        : 'Δεν ήταν δυνατό το άνοιγμα του ημερολογίου';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: ok ? const Color(0xFF1A73E8) : Colors.red.shade700,
      ),
    );
  }

  String _subtitle(Job j) {
    final price = '${j.remainingToCollect.toStringAsFixed(2)}€';
    if (j.scheduledAt != null) {
      return '${DateFormat('dd/MM  HH:mm').format(j.scheduledAt!)} · $price';
    }
    return 'Άμεση · $price';
  }

  @override
  Widget build(BuildContext context) {
    const blue = Color(0xFF1A73E8);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        // Κεφαλή
        Container(
          width: double.infinity,
          color: blue,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: const Row(children: [
            Icon(Icons.calendar_month_rounded, color: Colors.white, size: 22),
            SizedBox(width: 10),
            Expanded(child: Text('Ποιες στο ημερολόγιο;',
                style: TextStyle(color: Colors.white, fontSize: 16,
                    fontWeight: FontWeight.bold))),
          ]),
        ),
        // Επιλογή όλων
        InkWell(
          onTap: _toggleAll,
          child: Container(
            width: double.infinity,
            color: const Color(0xFFF5F8FE),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(children: [
              Icon(_allOn
                  ? Icons.check_box_rounded
                  : Icons.check_box_outline_blank_rounded,
                  color: blue, size: 22),
              const SizedBox(width: 12),
              Text('Επιλογή όλων (${widget.jobs.length})',
                  style: const TextStyle(fontSize: 13,
                      fontWeight: FontWeight.bold, color: blue)),
            ]),
          ),
        ),
        // Λίστα δουλειών
        Flexible(
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: widget.jobs.length,
            itemBuilder: (ctx, i) {
              final j = widget.jobs[i];
              return InkWell(
                onTap: () => setState(() => _checked[i] = !_checked[i]),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                  decoration: BoxDecoration(
                    border: Border(
                        bottom: BorderSide(color: Colors.grey.shade200)),
                  ),
                  child: Row(children: [
                    Icon(_checked[i]
                        ? Icons.check_box_rounded
                        : Icons.check_box_outline_blank_rounded,
                        color: _checked[i] ? blue : Colors.grey.shade400,
                        size: 22),
                    const SizedBox(width: 12),
                    Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${j.from} → ${j.to}',
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 14,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 1),
                        Text(_subtitle(j),
                            style: TextStyle(fontSize: 12.5,
                                color: Colors.grey[600])),
                      ],
                    )),
                  ]),
                ),
              );
            },
          ),
        ),
        // Κουμπιά
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
          child: Row(children: [
            Expanded(child: TextButton(
              onPressed: _busy ? null : () => Navigator.of(context).pop(),
              style: TextButton.styleFrom(
                backgroundColor: const Color(0xFFF1F1F1),
                foregroundColor: Colors.grey[700],
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Ακύρωση',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            )),
            const SizedBox(width: 10),
            Expanded(child: FilledButton.icon(
              onPressed: (_busy || _count == 0) ? null : _confirm,
              style: FilledButton.styleFrom(
                backgroundColor: blue,
                disabledBackgroundColor: blue.withValues(alpha: 0.4),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              icon: _busy
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.calendar_month_rounded, size: 18),
              label: Text(_count == 0 ? 'Προσθήκη' : 'Προσθήκη ($_count)',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            )),
          ]),
        ),
      ]),
    );
  }
}

// Ταξινόμηση: πιο κοντινό ραντεβού πάνω-πάνω, πιο μακρινό κάτω-κάτω.
// Οι άμεσες (χωρίς ραντεβού) = «τώρα» → μπαίνουν πρώτες.
// Ίδια στιγμή ή και οι δύο άμεσες → με τη σειρά που φτιάχτηκαν (createdAt).
List<Job> _sortMyJobs(List<Job> jobs) {
  final sorted = [...jobs]..sort((a, b) {
    final aHas = a.scheduledAt != null;
    final bHas = b.scheduledAt != null;
    if (aHas && bHas) {
      final c = a.scheduledAt!.compareTo(b.scheduledAt!);
      if (c != 0) return c;
      return a.createdAt.compareTo(b.createdAt);
    }
    if (!aHas && bHas) return -1; // άμεση πριν από ραντεβού
    if (aHas && !bHas) return 1;
    return a.createdAt.compareTo(b.createdAt); // και οι δύο άμεσες
  });
  return sorted;
}

// ─── MyJobsBottomBar ─────────────────────────────────────────────────────────
//
// Μπάρα «Οι δουλειές μου» κολλημένη στο κάτω μέρος της οθόνης, πάνω από το
// navigation bar του Android. Εμφανίζεται ΜΟΝΟ όταν ο οδηγός έχει αναλάβει
// δουλειές. Αντικαθιστά το παλιό πράσινο floating button.
//
//   • Tap στην μπάρα            → ανοίγει το sheet «Οι δουλειές μου».
//   • Swipe-up στην μπάρα ή στο
//     γκρι χερούλι              → ανοίγει το sheet.
//
// Για να ΜΗΝ μπερδεύεται το swipe-up με το system gesture (πήγαινε στην αρχική),
// η μπάρα κάθεται ΠΑΝΩ από την περιοχή gesture του συστήματος: προσθέτουμε το
// MediaQuery.padding.bottom ως κάτω περιθώριο, ώστε το χερούλι της μπάρας να
// βρίσκεται ψηλότερα από την μπάρα χειρονομιών του Android. Έτσι, ακόμα κι αν ο
// χρήστης έχει απενεργοποιήσει το navigation bar (gesture mode), η μπάρα μένει
// πάντα ορατή και πιάνεται, χωρίς να ενεργοποιεί το swipe-up του συστήματος.

class MyJobsBottomBar extends StatefulWidget {
  final String uid;
  // Ειδοποιεί τη γονική σελίδα όταν αλλάζει το ύψος της μπάρας, ώστε να
  // ανεβάζει τα πλαϊνά FAB και να μην τα καλύπτει. Στέλνει το ύψος της μπάρας
  // (0 όταν είναι κρυμμένη) σε pixels.
  final ValueChanged<double>? onHeightChanged;
  // Επιτρέπει σε ΕΞΩΤΕΡΙΚΟ widget (π.χ. το chip «Δουλειές» στην κύρια οθόνη)
  // να ζητήσει το άνοιγμα του συρταριού προγραμματιστικά, χωρίς να χρειάζεται
  // να αγγίξει ο χρήστης την πράσινη κεφαλή. Το bar καλεί αυτό το callback
  // με μια function που, όταν κληθεί, ανοίγει το συρτάρι.
  final void Function(VoidCallback openFn)? onOpenControllerReady;

  const MyJobsBottomBar({
    super.key,
    required this.uid,
    this.onHeightChanged,
    this.onOpenControllerReady,
  });

  @override
  State<MyJobsBottomBar> createState() => _MyJobsBottomBarState();
}

class _MyJobsBottomBarState extends State<MyJobsBottomBar> {
  // Ρολόι που «χτυπάει» κάθε δευτερόλεπτο ώστε το countdown να μετράει ομαλά
  // (δείχνει και δευτερόλεπτα όταν μένει <1 ώρα). Μηδενικό κόστος — μόνο
  // τοπικό rebuild του widget, καμία εγγραφή/ανάγνωση στο Firestore.
  Timer? _ticker;

  // Ανοιχτό/κλειστό συρτάρι. Κλειστό → φαίνεται μόνο η πράσινη κεφαλή.
  // Ανοιχτό → κάτω από την ΙΔΙΑ κεφαλή ξεδιπλώνεται το λευκό σώμα με τη λίστα.
  bool _expanded = false;

  // Συσσωρευμένο τράβηγμα προς τα κάτω στην κορυφή της λίστας. Το συρτάρι
  // κλείνει ΜΟΝΟ όταν ξεπεράσει ένα κατώφλι (δύσκολο κλείσιμο — δεν κλείνει
  // με το παραμικρό άγγιγμα). Μηδενίζει όταν σταματήσει το τράβηγμα.
  double _pullDown = 0;
  static const double _closeThreshold = 110;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    // Δίνει στον γονέα ένα «τηλεχειριστήριο» για να ανοίξει το συρτάρι
    // προγραμματιστικά (π.χ. tap στο εξωτερικό chip «Δουλειές»).
    widget.onOpenControllerReady?.call(() {
      if (!mounted) return;
      if (!_expanded) _toggle();
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  // Ύψος του λευκού σώματος όταν είναι ανοιχτό: ανάλογο με το πλήθος δουλειών,
  // με ταβάνι ώστε η κορυφή του συρταριού να φτάνει το πολύ ΛΙΓΟ ΚΑΤΩ από το
  // κουμπί «Διαθέσιμος» (πάνω μπάρα χάρτη). Μετά η λίστα κάνει εσωτερικό scroll.
  double _bodyHeight(BuildContext context, int count, double headerBase) {
    final mq = MediaQuery.of(context);
    final topSafe    = mq.padding.top;
    final safeBottom = mq.padding.bottom;
    final bottomGap  = (safeBottom > 0 ? safeBottom : 8.0) + 6;
    // ~150px για λογότυπο + κουμπί Διαθέσιμος + λίγο κενό από πάνω.
    final cap = mq.size.height - topSafe - 150 - headerBase - bottomGap;
    // Εκτίμηση ύψους ανά κάρτα δουλειάς: η κάρτα έχει badge ΡΑΝΤΕΒΟΥ/ΑΜΕΣΗ,
    // πιθανή μπάρα «ΠΡΟΠΛΗΡΩΜΕΝΗ», γραμμές από/προς, ποσά/κέρδος, chip
    // WhatsApp/όνομα πελάτη και 3 κουμπιά δράσης — χρειάζεται αρκετό ύψος
    // ώστε να φαίνεται ΟΛΟΚΛΗΡΗ (μαζί με το «Τέλος Διαδρομής»).
    // Compact κάρτες (~88px κλειστές) + περιθώριο για 1-2 ανοιγμένες.
    final est = 18.0 + count * 96.0 + 160.0 + 66.0; // +66 για το κουμπί «Όλες στο ημερολόγιο»
    final h = est < cap ? est : cap;
    return h < 0 ? 0 : h;
  }

  // Το πιο κοντινό ΜΕΛΛΟΝΤΙΚΟ ραντεβού (ή το πιο πρόσφατο που μόλις πέρασε, για
  // να δείχνει «καθυστέρηση»). Αγνοεί: (α) τις άμεσες δουλειές (scheduledAt ==
  // null) και (β) όσες ο οδηγός πάτησε «Παρέλαβα» (boarded) — εκεί ο πελάτης
  // είναι ήδη μέσα, οπότε το countdown περνάει στο ΕΠΟΜΕΝΟ ραντεβού.
  Job? _nextScheduled(List<Job> jobs) {
    final scheduled = jobs
        .where((j) => j.scheduledAt != null && j.isTaken)
        .toList()
      ..sort((a, b) => a.scheduledAt!.compareTo(b.scheduledAt!));
    if (scheduled.isEmpty) return null;
    final now = DateTime.now();
    // Πρώτο ραντεβού που δεν έχει περάσει πάνω από 1 ώρα (ώστε ένα παλιό
    // ξεχασμένο να μη μπλοκάρει το countdown του επόμενου).
    for (final j in scheduled) {
      if (j.scheduledAt!.isAfter(now.subtract(const Duration(hours: 1)))) {
        return j;
      }
    }
    return scheduled.last;
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('jobs')
          .where('takenBy', isEqualTo: widget.uid)
          .where('status',
              whereIn: [JobStatus.taken.name, JobStatus.boarded.name])
          .snapshots(),
      builder: (context, snap) {
        final jobs = snap.data?.docs.map((d) => Job.fromDoc(d)).toList() ?? [];
        final count = jobs.length;
        final next  = _nextScheduled(jobs);
        final hasCountdown = next != null;

        // Αν αδειάσει η λίστα, το συρτάρι κρύβεται — μηδένισε και το expanded.
        if (count == 0 && _expanded) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _expanded = false);
          });
        }

        // Ύψος που αναφέρεται στη σελίδα για τα FAB: ΠΑΝΤΑ το ύψος της
        // ΚΛΕΙΣΤΗΣ κεφαλής. Όταν το συρτάρι ανοίγει προς τα πάνω, τα FAB
        // ΔΕΝ ανεβαίνουν άλλο — απλώς καλύπτονται προσωρινά από τη λίστα.
        final safeBottom = MediaQuery.of(context).padding.bottom;
        final headerBase = hasCountdown ? 122.0 : 84.0;
        final bodyH = _expanded
            ? _bodyHeight(context, count, headerBase)
            : 0.0;
        final fabHeight = count == 0
            ? 0.0
            : headerBase + (safeBottom > 0 ? safeBottom : 8.0);
        if (widget.onHeightChanged != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            widget.onHeightChanged!(fabHeight);
          });
        }

        return AnimatedSlide(
          offset: count > 0 ? Offset.zero : const Offset(0, 1.4),
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
          child: AnimatedOpacity(
            opacity: count > 0 ? 1 : 0,
            duration: const Duration(milliseconds: 240),
            child: count == 0
                ? const SizedBox(height: 0, width: double.infinity)
                : _bar(context, jobs, count, next),
          ),
        );
      },
    );
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    if (_expanded) {
      // Σταμάτα τυχόν ήχο ειδοποίησης μόλις ο οδηγός δει τις δουλειές.
      FlutterForegroundTask.sendDataToTask({'action': 'stopSound'});
    }
  }

  Widget _bar(BuildContext context, List<Job> jobs, int count, Job? next) {
    final safeBottom = MediaQuery.of(context).padding.bottom;
    final bottomGap = (safeBottom > 0 ? safeBottom : 8.0) + 6;

    // ── Υπολογισμός φάσης countdown ──────────────────────────────────────
    Color barColor = const Color(0xFF1E8E3E); // πράσινο (>30')
    Widget? countdownRow;
    if (next != null) {
      final remaining = next.scheduledAt!.difference(DateTime.now());
      final mins = remaining.inMinutes;
      final overdue = remaining.isNegative;

      IconData cdIcon;
      String   cdLabel;
      if (overdue) {
        barColor = const Color(0xFFC0392B);            // κόκκινο
        cdIcon   = Icons.alarm_rounded;
        cdLabel  = 'Καθυστέρηση';
      } else if (mins < 10) {
        barColor = const Color(0xFFC0392B);            // κόκκινο
        cdIcon   = Icons.alarm_rounded;
        cdLabel  = 'Ραντεβού σε';
      } else if (mins < 30) {
        barColor = const Color(0xFFD9822B);            // πορτοκαλί
        cdIcon   = Icons.access_time_rounded;
        cdLabel  = 'Ραντεβού σε';
      } else {
        barColor = const Color(0xFF1E8E3E);            // πράσινο
        cdIcon   = Icons.alarm_rounded;
        cdLabel  = 'Επόμενο ραντεβού σε';
      }

      countdownRow = Container(
        margin: const EdgeInsets.fromLTRB(14, 0, 14, 10),
        padding: const EdgeInsets.only(top: 8),
        decoration: BoxDecoration(
          border: Border(
              top: BorderSide(color: Colors.white.withValues(alpha: 0.22))),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(cdIcon, color: Colors.white, size: 16),
          const SizedBox(width: 7),
          Text(cdLabel,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85),
                  fontSize: 13)),
          const SizedBox(width: 6),
          Text(_fmtRemaining(remaining),
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.bold)),
        ]),
      );
    }

    final isUrgent = next != null &&
        (next.scheduledAt!.difference(DateTime.now()).isNegative ||
            next.scheduledAt!.difference(DateTime.now()).inMinutes < 10);

    final sorted = _sortMyJobs(jobs);
    final bodyH  = _bodyHeight(context, count, next != null ? 122.0 : 84.0);

    // ── Πράσινη κεφαλή (πάντα ορατή — είναι «η μπάρα») ────────────────────
    final header = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggle,
      onVerticalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (v < -120 && !_expanded) _toggle();   // σύρσιμο πάνω → άνοιγμα
        if (v > 320 && _expanded)  _toggle();    // δυνατό σύρσιμο κάτω → κλείσιμο
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        decoration: BoxDecoration(color: barColor),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Γκρι χερούλι (swipe handle).
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 2),
            child: Container(
              width: 42, height: 5,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
                18, 8, 14, countdownRow == null ? 14 : 8),
            child: Row(children: [
              const Icon(Icons.work_rounded,
                  color: Colors.white, size: 22),
              const SizedBox(width: 12),
              const Text('Οι δουλειές μου',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.bold)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  '$count δουλειέ${count == 1 ? "α" : "ς"}',
                  style: TextStyle(
                      color: barColor,
                      fontSize: 13,
                      fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 8),
              AnimatedRotation(
                duration: const Duration(milliseconds: 250),
                turns: _expanded ? 0.5 : 0,
                child: const Icon(Icons.keyboard_arrow_up_rounded,
                    color: Colors.white, size: 24),
              ),
            ]),
          ),
          ?countdownRow,
        ]),
      ),
    );

    // ── Λευκό σώμα — ξεδιπλώνεται ΚΑΤΩ από την ίδια κεφαλή ────────────────
    final body = AnimatedSize(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeInOutCubic,
      alignment: Alignment.topCenter,
      child: SizedBox(
        height: _expanded ? bodyH : 0,
        width: double.infinity,
        child: _expanded
            ? Container(
                color: Colors.white,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Expanded(
                      child: NotificationListener<ScrollNotification>(
                  // ΔΥΣΚΟΛΟ κλείσιμο: στην κορυφή της λίστας, το συρτάρι κλείνει
                  // μόνο αφού τραβήξεις προς τα κάτω συσσωρευτικά πάνω από το
                  // κατώφλι (_closeThreshold), Ή με δυνατό «πέταγμα» κάτω. Έτσι
                  // δεν κλείνει κατά λάθος όταν απλώς φτάνεις στην 1η δουλειά.
                  onNotification: (n) {
                    // Στην κορυφή & τράβηγμα κάτω → μάζεψε overscroll.
                    if (n is OverscrollNotification &&
                        n.metrics.pixels <= 0 &&
                        n.overscroll < 0) {
                      _pullDown += -n.overscroll;
                      if (_pullDown >= _closeThreshold && _expanded) {
                        _pullDown = 0;
                        _toggle();
                      }
                      return false;
                    }
                    // Δυνατό fling προς τα κάτω στην κορυφή → κλείσε αμέσως.
                    if (n is ScrollEndNotification) {
                      final v = n.dragDetails?.primaryVelocity ?? 0;
                      if (v > 1200 && n.metrics.pixels <= 0 && _expanded) {
                        _toggle();
                      }
                      _pullDown = 0;
                      return false;
                    }
                    // Μόλις αρχίσει κανονικό scroll προς τα πάνω, μηδένισε.
                    if (n is ScrollUpdateNotification &&
                        n.metrics.pixels > 0) {
                      _pullDown = 0;
                    }
                    return false;
                  },
                  child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 18),
                  itemCount: sorted.length,
                  separatorBuilder: (_, _) => Container(
                    height: 6, color: Colors.grey.shade100,
                    margin: const EdgeInsets.symmetric(vertical: 4),
                  ),
                  itemBuilder: (ctx, i) => FadeSlideIn(
                    index: i,
                    child: MyJobTile(
                      job:   sorted[i],
                      uid:   widget.uid,
                      index: i + 1,
                      total: sorted.length,
                    ),
                  ),
                  ),
                ),
                    ),
                    // Κουμπί «Όλες στο ημερολόγιο» — σταθερό κάτω-κάτω
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                      child: _AllToCalendarButton(jobs: sorted),
                    ),
                  ],
                ),
              )
            : null,
      ),
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(12, 0, 12, bottomGap),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: barColor.withValues(alpha: 0.38),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            // Ο παλμός τυλίγει ΜΟΝΟ την κόκκινη κεφαλή — ίδιος ακριβώς είτε η
            // λίστα κλειστή είτε ανοιχτή. Το λευκό σώμα από κάτω δεν αναβοσβήνει.
            _Pulse(active: isUrgent, child: header),
            body,
          ]),
        ),
      ),
    );
  }

  // Μορφοποίηση υπολειπόμενου χρόνου: «2ώρ 45λ», «24:00» (λεπτά:δευτ. όταν <1ώρα),
  // ή «5λ» όταν έχει καθυστερήσει.
  String _fmtRemaining(Duration d) {
    final neg = d.isNegative;
    final s = d.abs();
    final h = s.inHours;
    final m = s.inMinutes % 60;
    if (neg) {
      return h > 0 ? '$hώρ $mλ' : '${s.inMinutes}λ';
    }
    if (h > 0) return '$hώρ $mλ';
    // <1 ώρα → λεπτά:δευτερόλεπτα για ζωντανή αίσθηση
    final mm = s.inMinutes;
    final ss = s.inSeconds % 60;
    return '$mm:${ss.toString().padLeft(2, '0')}';
  }
}

// Παλμός (αναβόσβησμα) για την επείγουσα φάση (<10' ή καθυστέρηση).
class _Pulse extends StatefulWidget {
  final bool   active;
  final Widget child;
  const _Pulse({required this.active, required this.child});
  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );
  late final Animation<double> _a =
      Tween(begin: 1.0, end: 0.55).animate(
          CurvedAnimation(parent: _c, curve: Curves.easeInOut));

  // Συγχρονίζει την κατάσταση του controller με το active. Καλείται σε κάθε
  // build, ώστε ανεξάρτητα από το πότε αλλάζει το active (π.χ. όταν ανοίγει
  // το συρτάρι ενώ αναβοσβήνει) ο παλμός να σταματά/ξεκινά αξιόπιστα.
  void _sync() {
    if (widget.active) {
      if (!_c.isAnimating) _c.repeat(reverse: true);
    } else {
      if (_c.isAnimating) _c.stop();
      _c.value = 1.0; // πλήρως ορατό όταν δεν αναβοσβήνει
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _sync();
    if (!widget.active) return widget.child;
    return FadeTransition(opacity: _a, child: widget.child);
  }
}

// ─── MyJobTile ────────────────────────────────────────────────────────────────
//
// ΝΕΑ compact σχεδίαση (εγκεκριμένο mockup «Οι δουλειές μου»):
//   • Κάρτα με αριστερή χρωματιστή μπάρα:
//       πορτοκαλί = ΤΩΡΑ (άμεση) · μπλε = ραντεβού · μοβ = επιστροφή
//   • Γραμμή 1: chip ώρας (ΤΩΡΑ / HH:mm / Αύριο HH:mm / dd/MM HH:mm),
//     διαδρομή, τιμή δεξιά
//   • Γραμμή 2: όχημα, άτομα, βαλίτσες, παιδικό κάθισμα · δεξιά τρόπος
//     πληρωμής (Μετρητά πράσινο / Προπληρωμένη μπλε — παλλόμενη)
//   • Tap → η κάρτα ΑΝΟΙΓΕΙ επί τόπου και δείχνει chips (είσπραξη, κέρδος,
//     πελάτης, WhatsApp, πτήση) + κουμπιά Λεπτομέρειες / Παρέλαβα / Τέλος.

class MyJobTile extends StatefulWidget {
  final Job    job;
  final String uid;
  final int    index;
  final int    total;

  const MyJobTile({
    super.key,
    required this.job,
    required this.uid,
    this.index = 1,
    this.total = 1,
  });

  @override
  State<MyJobTile> createState() => _MyJobTileState();
}

class _MyJobTileState extends State<MyJobTile> {
  bool _open = false;

  Job get job => widget.job;

  Future<void> _confirmComplete(BuildContext context) async {
    final result = await runCompleteRouteFlow(context, job);
    if (result == null || !context.mounted) return; // ακύρωση

    final nav = Navigator.of(context);
    if (nav.canPop()) nav.pop(); // κλείνει το "Οι δουλειές μου" αν είναι ανοιχτό
    await JobService.completeJob(job.id);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result == 'return'
              ? 'Τέλος διαδρομής — η επιστροφή αποθηκεύτηκε!'
              : 'Δουλειά ολοκληρώθηκε!'),
          backgroundColor: const Color(0xFF1E8E3E),
        ),
      );
    }
  }

  void _showDetails(BuildContext context) {
    showModalBottomSheet(
      context:            context,
      isScrollControlled: true,
      backgroundColor:    Colors.transparent,
      builder: (ctx) => JobDetailsSheet(job: job, parentContext: context),
    );
  }

  // Ετικέτα ώρας: ΤΩΡΑ / HH:mm (σήμερα) / Αύριο HH:mm / dd/MM HH:mm.
  String _timeLabel() {
    final s = job.scheduledAt;
    if (s == null) return 'ΤΩΡΑ';
    final now      = DateTime.now();
    final today    = DateTime(now.year, now.month, now.day);
    final thatDay  = DateTime(s.year, s.month, s.day);
    final hm       = DateFormat('HH:mm').format(s);
    if (thatDay == today) return hm;
    if (thatDay == today.add(const Duration(days: 1))) return 'Αύριο $hm';
    return '${DateFormat('dd/MM').format(s)} $hm';
  }

  // Χρώμα κατάστασης: μοβ επιστροφή, πορτοκαλί άμεση, μπλε ραντεβού.
  Color _statusColor() {
    if (job.isReturn) return const Color(0xFF7B1FA2);
    if (job.scheduledAt == null) return const Color(0xFFE8930C);
    return const Color(0xFF1A73E8);
  }

  IconData _vehicleIcon() => job.vehicleType == 'van'
      ? Icons.airport_shuttle_rounded
      : job.vehicleType == 'bus'
          ? Icons.directions_bus_rounded
          : Icons.local_taxi_rounded;

  @override
  Widget build(BuildContext context) {
    final status = _statusColor();
    final prepaid = job.fullyPaid;
    final payColor = prepaid ? const Color(0xFF1A73E8) : const Color(0xFF1E8E3E);

    final payLabel = Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(prepaid ? Icons.credit_card_rounded : Icons.payments_rounded,
          size: 14, color: payColor),
      const SizedBox(width: 4),
      Text(prepaid ? 'Προπληρωμένη' : 'Μετρητά',
          style: TextStyle(fontSize: 12,
              fontWeight: FontWeight.w700, color: payColor)),
    ]);

    return InkWell(
      onTap: () => setState(() => _open = !_open),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        decoration: BoxDecoration(
          color: job.isReturn ? const Color(0xFFF7EFFA) : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border(
            top:    BorderSide(color: Colors.grey.shade200, width: 0.8),
            right:  BorderSide(color: Colors.grey.shade200, width: 0.8),
            bottom: BorderSide(color: Colors.grey.shade200, width: 0.8),
            left:   BorderSide(color: status, width: 4),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(10, 10, 12, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // ── Γραμμή 1: ώρα · διαδρομή · τιμή ──────────────────────────────
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color:        status.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Text(_timeLabel(),
                  style: TextStyle(fontSize: 12.5,
                      fontWeight: FontWeight.w800, color: status)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text('${job.from} → ${job.to}',
                  maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5,
                      fontWeight: FontWeight.w600, color: Colors.black87)),
            ),
            const SizedBox(width: 6),
            Text('${job.price.toStringAsFixed(0)} €',
                style: const TextStyle(fontSize: 15,
                    fontWeight: FontWeight.w800, color: Colors.black87)),
          ]),
          const SizedBox(height: 7),

          // ── Γραμμή 2: όχημα · άτομα · βαλίτσες · παιδικό · πληρωμή ──────
          Row(children: [
            Icon(_vehicleIcon(), size: 15, color: Colors.grey.shade600),
            const SizedBox(width: 3),
            Text(job.vehicleLabel,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            const SizedBox(width: 10),
            Icon(Icons.group_rounded, size: 15, color: Colors.grey.shade600),
            const SizedBox(width: 3),
            Text('${job.persons}',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            if (job.luggage > 0) ...[
              const SizedBox(width: 10),
              Icon(Icons.luggage_rounded, size: 15, color: Colors.grey.shade600),
              const SizedBox(width: 3),
              Text('${job.luggage}',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            ],
            if (job.childSeatCount > 0) ...[
              const SizedBox(width: 10),
              const Icon(Icons.child_care_rounded,
                  size: 15, color: Color(0xFFD4537E)),
            ],
            if (job.isReturn) ...[
              const SizedBox(width: 10),
              const Icon(Icons.u_turn_left_rounded,
                  size: 15, color: Color(0xFF7B1FA2)),
            ],
            const Spacer(),
            prepaid ? _Pulse(active: true, child: payLabel) : payLabel,
          ]),

          // ── Ανοιγμένο τμήμα: chips + κουμπιά δράσης ─────────────────────
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            child: !_open
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (prepaid)
                          _Pulse(
                            active: true,
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 7),
                              margin: const EdgeInsets.only(bottom: 8),
                              decoration: BoxDecoration(
                                color: const Color(0xFFD97757),
                                borderRadius: BorderRadius.circular(9),
                              ),
                              child: const Text(
                                  'ΠΡΟΠΛΗΡΩΜΕΝΗ — ΔΕΝ ΕΙΣΠΡΑΤΤΕΙΣ ΤΙΠΟΤΑ',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: Colors.white,
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: .4)),
                            ),
                          ),
                        Wrap(spacing: 6, runSpacing: 4, children: [
                          job.depositPaid
                              ? _chip(Icons.euro_rounded,
                                  prepaid
                                      ? 'Πληρώθηκε online — 0,00€'
                                      : 'Είσπραξη ${job.remainingToCollect.toStringAsFixed(2)}€',
                                  const Color(0xFF1E8E3E))
                              : _chip(Icons.euro_rounded,
                                  '${job.price.toStringAsFixed(2)}€',
                                  const Color(0xFF1E8E3E)),
                          if (job.commission > 0)
                            _chip(Icons.handshake_rounded,
                                '-${job.commission.toStringAsFixed(2)}€'
                                '${job.sourceName != null && job.sourceName!.isNotEmpty ? " ${job.sourceName}" : ""}',
                                Colors.red.shade700),
                          if (job.appCommission > 0)
                            _chip(Icons.phone_iphone_rounded,
                                'App -${job.appCommission.toStringAsFixed(2)}€',
                                Colors.indigo.shade700),
                          _chip(Icons.account_balance_wallet_rounded,
                              'Κέρδος ${job.driverEarning.toStringAsFixed(2)}€',
                              Colors.green.shade800),
                          if (job.clientName != null &&
                              job.clientName!.isNotEmpty)
                            _chip(Icons.badge_rounded, job.clientName!,
                                Colors.teal),
                          if (job.clientPhone != null &&
                              job.clientPhone!.isNotEmpty)
                            GestureDetector(
                              onTap: () {
                                final digits = job.clientPhone!
                                    .replaceAll(RegExp(r'[^0-9]'), '');
                                launchUrl(Uri.parse('https://wa.me/$digits'),
                                    mode: LaunchMode.externalApplication);
                              },
                              child: _chip(Icons.chat_rounded, 'WhatsApp',
                                  const Color(0xFF25D366),
                                  iconOverride: const FaIcon(
                                      FontAwesomeIcons.whatsapp,
                                      size: 10, color: Color(0xFF25D366))),
                            ),
                          if (job.flightOrShip != null &&
                              job.flightOrShip!.isNotEmpty)
                            _chip(Icons.flight_rounded, job.flightOrShip!,
                                Colors.indigo),
                        ]),
                        const SizedBox(height: 10),
                        Row(children: [
                          Expanded(
                            child: SizedBox(
                              height: 36,
                              child: OutlinedButton(
                                onPressed: () => _showDetails(context),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.blue.shade700,
                                  side: BorderSide(
                                      color: Colors.blue.shade300),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6),
                                  shape: RoundedRectangleBorder(
                                      borderRadius:
                                          BorderRadius.circular(10)),
                                  minimumSize: Size.zero,
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                                child: const FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text('Λεπτομέρειες',
                                      maxLines: 1,
                                      style: TextStyle(fontSize: 11.5,
                                          fontWeight: FontWeight.bold)),
                                ),
                              ),
                            ),
                          ),
                          if (job.isTaken) ...[
                            const SizedBox(width: 8),
                            Expanded(child: _BoardButton(jobId: job.id)),
                          ],
                          const SizedBox(width: 8),
                          Expanded(
                            child: SizedBox(
                              height: 36,
                              child: FilledButton(
                                onPressed: () => _confirmComplete(context),
                                style: FilledButton.styleFrom(
                                  backgroundColor: const Color(0xFF1E8E3E),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6),
                                  shape: RoundedRectangleBorder(
                                      borderRadius:
                                          BorderRadius.circular(10)),
                                  minimumSize: Size.zero,
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                                child: const FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text('Τέλος Διαδρομής',
                                      maxLines: 1,
                                      style: TextStyle(fontSize: 11.5,
                                          fontWeight: FontWeight.bold)),
                                ),
                              ),
                            ),
                          ),
                        ]),
                      ],
                    ),
                  ),
          ),
        ]),
      ),
    );
  }

  Widget _chip(IconData icon, String label, Color color,
          {Widget? iconOverride}) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color:        color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          iconOverride ?? Icon(icon, size: 10, color: color),
          const SizedBox(width: 3),
          Flexible(child: Text(label,
              style: TextStyle(fontSize: 10, color: color,
                  fontWeight: FontWeight.w600))),
        ]),
      );
}


// ─── Κουμπί «Παρέλαβα» που κρύβεται αμέσως μόλις πατηθεί ───────────────────────
class _BoardButton extends StatefulWidget {
  final String jobId;
  const _BoardButton({required this.jobId});
  @override
  State<_BoardButton> createState() => _BoardButtonState();
}

class _BoardButtonState extends State<_BoardButton> {
  bool _done = false;
  @override
  Widget build(BuildContext context) {
    if (_done) return const SizedBox.shrink();
    return SizedBox(
        width: double.infinity, height: 36,
        child: FilledButton(
          onPressed: () {
            Vibration.vibrate(duration: 1000);
            setState(() => _done = true);
            JobService.markBoarded(widget.jobId);
            showCenterToast(context, 'Το σύστημα ενημερώθηκε');
          },
          style: FilledButton.styleFrom(
            backgroundColor: Colors.orange.shade800,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const FittedBox(
            fit: BoxFit.scaleDown,
            child: Text('Παρέλαβα',
                maxLines: 1,
                style: TextStyle(
                    fontSize: 11, fontWeight: FontWeight.bold)),
          ),
        ),
    );
  }
}
