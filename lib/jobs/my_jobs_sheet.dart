// lib/jobs/my_jobs_sheet.dart
// Bottom sheet "Οι δουλειές μου" + MyJobTile

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:vibration/vibration.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:intl/intl.dart';

import 'job_details_sheet.dart';
import 'job_shared_widgets.dart';
import 'job_model.dart';
import 'job_service.dart';

// ─── Εμφάνιση bottom sheet "Οι δουλειές μου" ─────────────────────────────────

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

void showMyJobsSheet(BuildContext context, List<Job> jobs, String uid) {
  FlutterForegroundTask.sendDataToTask({'action': 'stopSound'});

  showModalBottomSheet(
    context:            context,
    isScrollControlled: true,
    backgroundColor:    Colors.transparent,
    builder: (_) => _MyJobsSheetBody(initialJobs: jobs, uid: uid),
  );
}

// Σώμα του sheet — LIVE: ακούει τις δουλειές που έχει αναλάβει ο οδηγός, ώστε
// αν ο admin σβήσει/αλλάξει δουλειά ενώ είναι ανοιχτή η λίστα, να ανανεώνεται
// αμέσως (χωρίς να χρειάζεται κλείσιμο/άνοιγμα).
class _MyJobsSheetBody extends StatelessWidget {
  final List<Job> initialJobs;
  final String    uid;
  const _MyJobsSheetBody({required this.initialJobs, required this.uid});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('jobs')
          .where('takenBy', isEqualTo: uid)
          .where('status',
              whereIn: [JobStatus.taken.name, JobStatus.boarded.name])
          .snapshots(),
      builder: (context, snap) {
        // Πριν έρθει το πρώτο live snapshot, δείξε την αρχική λίστα.
        final jobs = snap.hasData
            ? snap.data!.docs.map((d) => Job.fromDoc(d)).toList()
            : initialJobs;
        final sorted = _sortMyJobs(jobs);

        // Αν αδειάσει η λίστα (π.χ. ο admin έσβησε τις δουλειές), κλείσε το sheet.
        if (snap.hasData && sorted.isEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (Navigator.of(context).canPop()) Navigator.of(context).pop();
          });
        }

        return Container(
          decoration: const BoxDecoration(
            color:        Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          padding: EdgeInsets.fromLTRB(
              20, 12, 20, 20 + MediaQuery.of(context).padding.bottom),
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.85),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            // Drag handle
            const SheetHandle(bottomMargin: 16),
            // Header
            Row(children: [
              const Icon(Icons.work_rounded, color: Color(0xFF1E8E3E)),
              const SizedBox(width: 10),
              const Text('Οι δουλειές μου',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E8E3E),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${sorted.length} δουλειέ${sorted.length == 1 ? "α" : "ς"}',
                  style: const TextStyle(color: Colors.white,
                      fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ),
            ]),
            const SizedBox(height: 12),
            if (sorted.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 30),
                child: Text('Δεν έχεις ενεργές δουλειές',
                    style: TextStyle(color: Colors.grey[600], fontSize: 15)),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap:       true,
                  itemCount:        sorted.length,
                  separatorBuilder: (_, _) => Container(
                    height: 6, color: Colors.grey.shade100,
                    margin: const EdgeInsets.symmetric(vertical: 4),
                  ),
                  itemBuilder: (ctx, i) => FadeSlideIn(
                    index: i,
                    child: MyJobTile(
                      job:   sorted[i],
                      uid:   uid,
                      index: i + 1,
                      total: sorted.length,
                    ),
                  ),
                ),
              ),
          ]),
        );
      },
    );
  }
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
  const MyJobsBottomBar({super.key, required this.uid, this.onHeightChanged});

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
    // γραμμές από/προς, ποσά/κέρδος και 3 κουμπιά δράσης — χρειάζεται αρκετό
    // ύψος ώστε να φαίνεται ΟΛΟΚΛΗΡΗ (μαζί με το «Τέλος Διαδρομής»).
    final est = 18.0 + count * 230.0;
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

class MyJobTile extends StatelessWidget {
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

  @override
  Widget build(BuildContext context) {
    final isImmediate = job.scheduledAt == null;

    return InkWell(
      onTap: () => _showDetails(context),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        // Μοβ φόντο για δουλειές-ΕΠΙΣΤΡΟΦΗ ώστε να ξεχωρίζουν.
        decoration: job.isReturn
            ? BoxDecoration(
                color: const Color(0xFFF3E5F5),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF7B1FA2), width: 1.5),
              )
            : null,
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

          // ── Banner ΕΠΙΣΤΡΟΦΗ (πάνω-πάνω) ───────────────────────────────
          if (job.isReturn)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              margin: const EdgeInsets.only(bottom: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF7B1FA2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Row(mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                Icon(Icons.u_turn_left_rounded, color: Colors.white, size: 18),
                SizedBox(width: 8),
                Text('ΕΠΙΣΤΡΟΦΗ', style: TextStyle(
                    color: Colors.white, fontSize: 14,
                    fontWeight: FontWeight.w900, letterSpacing: 2)),
              ]),
            ),

          // ── Header banner (ΑΜΕΣΗ ή ΡΑΝΤΕΒΟΥ) ───────────────────────────
          if (isImmediate)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              margin: const EdgeInsets.only(bottom: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF1E8E3E),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(children: [
                _indexCircle(index),
                const SizedBox(width: 10),
                const Icon(Icons.flash_on_rounded, color: Colors.white, size: 18),
                const SizedBox(width: 6),
                const Text('ΑΜΕΣΗ', style: TextStyle(
                    color: Colors.white, fontSize: 13,
                    fontWeight: FontWeight.w900, letterSpacing: 1.2)),
              ]),
            )
          else
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              margin: const EdgeInsets.only(bottom: 4),
              decoration: BoxDecoration(
                color: Colors.blue.shade700,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(children: [
                _indexCircle(index),
                const SizedBox(width: 10),
                const Icon(Icons.alarm_rounded, color: Colors.white, size: 18),
                const SizedBox(width: 6),
                const Text('ΡΑΝΤΕΒΟΥ', style: TextStyle(
                    color: Colors.white, fontSize: 13,
                    fontWeight: FontWeight.w900, letterSpacing: 1.2)),
                const SizedBox(width: 10),
                Text(DateFormat('dd/MM  HH:mm').format(job.scheduledAt!),
                    style: const TextStyle(color: Colors.white,
                        fontSize: 15, fontWeight: FontWeight.bold)),
              ]),
            ),
          const SizedBox(height: 8),

          // ── Διαδρομή + chips + κουμπιά ──────────────────────────────────
          Row(children: [
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _routeRow(Icons.trip_origin_rounded, Colors.amber, job.from),
                const SizedBox(height: 4),
                _routeRow(Icons.place_rounded, Colors.red, job.to),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 4, children: [
                  _chip(Icons.euro_rounded,
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
                  _chip(Icons.person_rounded, '${job.persons}', Colors.blue),
                  if (job.luggage > 0)
                    _chip(Icons.luggage_rounded, '${job.luggage}', Colors.grey),
                  if (job.childSeat)
                    _chip(Icons.child_care_rounded, 'Παιδικό', Colors.purple),
                  if (job.clientName != null && job.clientName!.isNotEmpty)
                    _chip(Icons.badge_rounded, job.clientName!, Colors.teal),
                  if (job.flightOrShip != null && job.flightOrShip!.isNotEmpty)
                    _chip(Icons.flight_rounded, job.flightOrShip!, Colors.indigo),
                ]),
              ],
            )),
            const SizedBox(width: 12),

            // Κουμπιά: ΟΛΑ ίδιου πλάτους (116) & ύψους (36) — συμμετρικά
            SizedBox(
              width: 116,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(
                  width: double.infinity, height: 36,
                  child: OutlinedButton.icon(
                    onPressed: () => _showDetails(context),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.blue.shade700,
                      side: BorderSide(color: Colors.blue.shade300),
                      padding:
                          const EdgeInsets.symmetric(horizontal: 6),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    icon: Icon(Icons.info_rounded,
                        size: 14, color: Colors.blue.shade700),
                    label: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text('Λεπτομέρειες',
                          maxLines: 1,
                          style: TextStyle(fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: Colors.blue.shade700)),
                    ),
                  ),
                ),
                if (job.isTaken) _BoardButton(jobId: job.id),
                const SizedBox(height: 6),
                SizedBox(
                  width: double.infinity, height: 36,
                  child: FilledButton(
                    onPressed: () => _confirmComplete(context),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF1E8E3E),
                      padding:
                          const EdgeInsets.symmetric(horizontal: 6),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text('Τέλος Διαδρομής',
                          maxLines: 1,
                          style: TextStyle(fontSize: 11,
                              fontWeight: FontWeight.bold)),
                    ),
                  ),
                ),
              ]),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _indexCircle(int n) => Container(
    width: 22, height: 22,
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.25),
      shape: BoxShape.circle,
    ),
    alignment: Alignment.center,
    child: Text('$n', style: const TextStyle(
        color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
  );

  Widget _routeRow(IconData icon, Color color, String text) => Row(children: [
    Icon(icon, size: 12, color: color),
    const SizedBox(width: 6),
    Expanded(child: Text(text,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        maxLines: 1, overflow: TextOverflow.ellipsis)),
  ]);

  Widget _chip(IconData icon, String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color:        color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 10, color: color),
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
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: SizedBox(
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
      ),
    );
  }
}
