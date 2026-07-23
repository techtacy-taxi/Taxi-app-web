// lib/calendar/jobs_calendar_page.dart
//
// Ενιαίο «Ημερολόγιο δουλειών» — ορατό ΣΕ ΟΛΟΥΣ (οδηγοί, admin, master).
// ΝΕΑ διάταξη:
//   • Το ημερολόγιο του μήνα πιάνει σχεδόν ΟΛΗ την οθόνη (shouldFillViewport)
//   • Οι δουλειές της ημέρας ζουν σε ΣΥΡΤΑΡΙ (DraggableScrollableSheet) κάτω:
//     κλειστό δείχνει τίτλο + πρώτες κάρτες, τραβιέται σχεδόν μέχρι πάνω
//     αφήνοντας ορατό μικρό κομμάτι του ημερολογίου
//   • Κουκκίδες: μέχρι 4, μεγαλύτερες (7px) + «+Ν» όταν υπάρχουν περισσότερες
//   • Safe-area κάτω για το Android navigation bar
//
// Χρωματικός κώδικας (ίδιος με πριν):
//   Γαλάζιο = ΡΑΝΤΕΒΟΥ · Κίτρινο = ΑΜΕΣΗ · Πορτοκαλί = ανατεθειμένη
//   (admin/master) · Κόκκινο = Αποθηκευμένη (admin/master)
//   Περίγραμμα οχήματος: πράσινο = Ταξί, μοβ = Βαν.
//
// Data: οδηγός βλέπει μόνο τις ΔΙΚΕΣ ΤΟΥ δουλειές (takenBy == uid).
// admin/master βλέπουν όλες τις δουλειές τους ΚΑΙ τις saved_jobs.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_theme.dart';
import '../jobs/job_details_sheet.dart';
import '../jobs/job_model.dart';
import '../jobs/job_service.dart';
import '../jobs/saved_job_service.dart';
import '../widgets/vehicle_type_icon.dart';
import 'google_calendar_page.dart';
import 'ics_calendar_export.dart';

enum _EntryKind { appointment, immediate, assigned, saved, done, cancelled }

class _CalEntry {
  final Job        job;
  final DateTime   day;
  final _EntryKind kind;
  final String?    vehicleType; // 'taxi' | 'van' | άλλο/κενό
  final SavedJob?  savedJob;    // μόνο για kind == saved

  _CalEntry({
    required this.job,
    required this.day,
    required this.kind,
    required this.vehicleType,
    this.savedJob,
  });
}

class JobsCalendarPage extends StatefulWidget {
  final String uid;
  final bool   isAdmin;
  final bool   isMaster;
  /// Ο χρήστης έχει ενεργό Google Calendar sync (calendarEnabled ή master).
  final bool   googleCalendarEnabled;

  const JobsCalendarPage({
    super.key,
    required this.uid,
    required this.isAdmin,
    required this.isMaster,
    required this.googleCalendarEnabled,
  });

  @override
  State<JobsCalendarPage> createState() => _JobsCalendarPageState();
}

class _JobsCalendarPageState extends State<JobsCalendarPage> {
  DateTime _focusedMonth = DateTime.now();
  DateTime _selectedDay  = DateTime.now();

  bool get _seesAllOrgJobs => widget.isAdmin || widget.isMaster;

  // Μάτι πάνω δεξιά (ΜΟΝΟ master): αναμμένο (true) = βλέπει ΟΛΟΥΣ τους
  // οδηγούς/admins του οργανισμού (προεπιλογή, ίδια συμπεριφορά με πριν)·
  // σβηστό (false) = βλέπει ΜΟΝΟ τις δικές του δουλειές. Η επιλογή
  // αποθηκεύεται τοπικά (SharedPreferences) — μένει όπως την άφησε.
  static const String _kOnlyMinePrefsKey = 'calendar_master_only_mine_v1';
  bool _onlyMine = false;

  @override
  void initState() {
    super.initState();
    _loadOnlyMinePref();
  }

  Future<void> _loadOnlyMinePref() async {
    if (!widget.isMaster) return;
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getBool(_kOnlyMinePrefsKey) ?? false;
    if (mounted && saved != _onlyMine) setState(() => _onlyMine = saved);
  }

  Future<void> _toggleOnlyMine() async {
    setState(() => _onlyMine = !_onlyMine);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kOnlyMinePrefsKey, _onlyMine);
  }

  // Μεγέθη συρταριού (ποσοστά ύψους οθόνης).
  static const double _sheetMin = 0.30;
  static const double _sheetMax = 0.92;

  // ── Firestore streams ──────────────────────────────────────────────────

  Stream<List<_CalEntry>> _monthEntries() {
    final monthStart = DateTime(_focusedMonth.year, _focusedMonth.month, 1);
    final monthEnd    = DateTime(_focusedMonth.year, _focusedMonth.month + 1, 1);

    // Ο οδηγός βλέπει μόνο τις δικές του δουλειές (ό,τι ώρα κι αν είναι).
    // Ο admin βλέπει ΜΟΝΟ ό,τι δημιούργησε ο ίδιος (createdBy == uid) —
    // ανεξαρτήτως ποιος την ανέλαβε/ολοκλήρωσε. Ο master βλέπει τα πάντα, με
    // δυνατότητα (μάτι) να δει μόνο τις δικές του (createdBy == uid).
    Query<Map<String, dynamic>> q = FirebaseFirestore.instance
        .collection('jobs')
        .where('scheduledAt', isGreaterThanOrEqualTo: Timestamp.fromDate(monthStart))
        .where('scheduledAt', isLessThan: Timestamp.fromDate(monthEnd));

    // ΣΗΜΕΙΩΣΗ: οι ΑΜΕΣΕΣ δουλειές (χωρίς scheduledAt) δεν έχουν ημερομηνία
    // ραντεβού — τις παίρνουμε ξεχωριστά μέσω takenAt/createdAt παρακάτω.
    return q.snapshots().asyncMap((snap) async {
      final entries = <_CalEntry>[];

      for (final doc in snap.docs) {
        final job = Job.fromDoc(doc);
        if (!_seesAllOrgJobs && job.takenBy != widget.uid) continue;
        // Admin (ΟΧΙ master): βλέπει ΜΟΝΟ δουλειές που δημιούργησε ο ίδιος —
        // ποτέ δουλειές άλλου admin/tenant, ανεξαρτήτως ποιος τις ανέλαβε ή
        // πού κατέληξαν (αποθηκευμένη/ανάληψη/ολοκληρωμένη/ακυρωμένη).
        if (widget.isAdmin && !widget.isMaster && job.createdBy != widget.uid) {
          continue;
        }
        // Επιτρεπόμενες καταστάσεις: admin/master βλέπει ό,τι είναι ακόμα
        // ανοιχτό ΚΑΙ ό,τι έχει γίνει/ακυρωθεί· ο οδηγός βλέπει μόνο ό,τι
        // ανέλαβε ο ίδιος — ανεξαρτήτως αν έχει ολοκληρωθεί ή ακυρωθεί.
        final allowed = _seesAllOrgJobs
            ? (job.isOpen || job.isTaken || job.isBoarded ||
                job.status == JobStatus.done ||
                job.status == JobStatus.cancelled)
            : (job.isTaken || job.isBoarded ||
                job.status == JobStatus.done ||
                job.status == JobStatus.cancelled);
        if (!allowed) continue;

        final _EntryKind kind;
        if (job.status == JobStatus.done) {
          kind = _EntryKind.done;
        } else if (job.status == JobStatus.cancelled) {
          kind = _EntryKind.cancelled;
        } else if (_seesAllOrgJobs && job.isOpen) {
          kind = _EntryKind.assigned; // ανοιχτή αλλά με ραντεβού
        } else {
          kind = job.scheduledAt != null
              ? _EntryKind.appointment
              : _EntryKind.immediate;
        }

        entries.add(_CalEntry(
          job: job,
          day: job.scheduledAt!,
          kind: kind,
          vehicleType: job.vehicleType,
        ));
      }

      // Άμεσες δουλειές (χωρίς scheduledAt) — μόνο για ΤΟΝ ΤΡΕΧΟΝΤΑ μήνα,
      // ταξινομημένες με βάση την ημέρα ανάληψης (takenAt) ή δημιουργίας.
      final immediateQuery = _seesAllOrgJobs
          ? FirebaseFirestore.instance
              .collection('jobs')
              .where('takenAt',
                  isGreaterThanOrEqualTo: Timestamp.fromDate(monthStart))
              .where('takenAt', isLessThan: Timestamp.fromDate(monthEnd))
          : FirebaseFirestore.instance
              .collection('jobs')
              .where('takenBy', isEqualTo: widget.uid)
              .where('takenAt',
                  isGreaterThanOrEqualTo: Timestamp.fromDate(monthStart))
              .where('takenAt', isLessThan: Timestamp.fromDate(monthEnd));

      final immSnap = await immediateQuery.get();
      for (final doc in immSnap.docs) {
        final job = Job.fromDoc(doc);
        if (job.scheduledAt != null) continue; // ήδη μετρήθηκε πάνω
        if (job.takenAt == null) continue;
        if (!_seesAllOrgJobs && job.takenBy != widget.uid) continue;
        if (widget.isAdmin && !widget.isMaster && job.createdBy != widget.uid) {
          continue;
        }
        final _EntryKind kind = job.status == JobStatus.done
            ? _EntryKind.done
            : job.status == JobStatus.cancelled
                ? _EntryKind.cancelled
                : _EntryKind.immediate;
        entries.add(_CalEntry(
          job: job,
          day: job.takenAt!,
          kind: kind,
          vehicleType: job.vehicleType,
        ));
      }

      // Admin/master: αποθηκευμένες (draft) δουλειές — κόκκινο. Ο admin
      // (όχι master) βλέπει μόνο όσες αποθήκευσε ο ίδιος.
      // ΣΗΜΕΙΩΣΗ: τα πεδία στο saved_jobs doc είναι FLAT (scheduledAt, from,
      // to...) — ΟΧΙ ένθετα κάτω από 'job'. Το query έψαχνε λάθος
      // 'job.scheduledAt' (πεδίο που δεν υπάρχει) και γι' αυτό ΚΑΜΙΑ
      // online-form κράτηση δεν εμφανιζόταν ποτέ σε κανέναν admin/master.
      if (_seesAllOrgJobs) {
        final savedSnap = await FirebaseFirestore.instance
            .collection('saved_jobs')
            .where('scheduledAt',
                isGreaterThanOrEqualTo: Timestamp.fromDate(monthStart))
            .where('scheduledAt', isLessThan: Timestamp.fromDate(monthEnd))
            .get();
        for (final doc in savedSnap.docs) {
          try {
            final sj = SavedJob.fromDoc(doc);
            if (sj.job.scheduledAt == null) continue;
            if (widget.isAdmin && !widget.isMaster &&
                sj.ownerUid != widget.uid) {
              continue;
            }
            entries.add(_CalEntry(
              job:         sj.job,
              day:         sj.job.scheduledAt!,
              kind:        _EntryKind.saved,
              vehicleType: sj.job.vehicleType,
              savedJob:    sj,
            ));
          } catch (_) {/* παλιό/ασύμβατο doc — αγνόησέ το */}
        }
      }

      entries.sort((a, b) => a.day.compareTo(b.day));
      // Μάτι σβηστό (ΜΟΝΟ master): κράτα ΜΟΝΟ τις δουλειές που δημιούργησε
      // ο ίδιος ο master — ΟΧΙ αυτές που έτυχε να οδηγήσει ο ίδιος. Το
      // "δικές μου" σημαίνει «δικές μου επιχείρησης», όχι «οδήγησα εγώ».
      if (widget.isMaster && _onlyMine) {
        return entries.where((e) => e.job.createdBy == widget.uid).toList();
      }
      return entries;
    });
  }

  // ── Χρώματα ──────────────────────────────────────────────────────────────

  /// Βασικό χρώμα κατάστασης (γέμισμα μπάρας/κουκκίδας).
  Color _statusColor(AppColors c, _EntryKind kind) {
    switch (kind) {
      case _EntryKind.appointment:
        return c.blue;
      case _EntryKind.immediate:
        return c.amber;
      case _EntryKind.assigned:
        return const Color(0xFFEF9F27); // πορτοκαλί — ανέλαβε κάποιος
      case _EntryKind.saved:
        return const Color(0xFFD64545); // κόκκινο — αποθηκευμένη
      case _EntryKind.done:
        return c.greenDeep; // πράσινο — ολοκληρωμένη
      case _EntryKind.cancelled:
        return const Color(0xFF8A8A8A); // γκρι — ακυρωμένη
    }
  }

  /// Χρώμα περιγράμματος ανά όχημα: πράσινο = Ταξί, μοβ = Βαν.
  Color? _vehicleBorderColor(String? vehicleType) {
    switch (vehicleType) {
      case 'taxi':
        return const Color(0xFF4CAF50);
      case 'van':
        return const Color(0xFF9C27B0);
      default:
        return null; // bus/άλλο/άγνωστο — χωρίς ειδικό περίγραμμα
    }
  }

  // ── UI ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Scaffold(
      backgroundColor: c.scaffold,
      appBar: AppBar(
        title: const Text('Ημερολόγιο'),
        backgroundColor: c.scaffold,
        foregroundColor: c.textMain,
        elevation: 0,
        actions: widget.isMaster
            ? [
                IconButton(
                  tooltip: _onlyMine
                      ? 'Βλέπεις μόνο τις δικές σου δουλειές'
                      : 'Βλέπεις όλες τις δουλειές του οργανισμού',
                  icon: Icon(
                    _onlyMine
                        ? Icons.visibility_off_rounded
                        : Icons.visibility_rounded,
                    color: _onlyMine ? c.textFaint : c.amberDeep,
                  ),
                  onPressed: _toggleOnlyMine,
                ),
              ]
            : null,
      ),
      body: StreamBuilder<List<_CalEntry>>(
        stream: _monthEntries(),
        builder: (context, snap) {
          final all = snap.data ?? const <_CalEntry>[];
          final byDay = <DateTime, List<_CalEntry>>{};
          for (final e in all) {
            final key = DateTime(e.day.year, e.day.month, e.day.day);
            (byDay[key] ??= []).add(e);
          }
          final selKey = DateTime(
              _selectedDay.year, _selectedDay.month, _selectedDay.day);
          final dayEntries = byDay[selKey] ?? const <_CalEntry>[];
          final dayTotal =
              dayEntries.fold<double>(0, (sum, e) => sum + e.job.price);

          return LayoutBuilder(builder: (context, constraints) {
            final h = constraints.maxHeight;
            return Stack(children: [
              // Ημερολόγιο: γεμίζει τον χώρο ΠΑΝΩ από το κλειστό συρτάρι.
              Positioned(
                left: 0, right: 0, top: 0,
                height: h * (1 - _sheetMin) + 8,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                  child: _monthCalendar(c, byDay),
                ),
              ),

              // Συρτάρι δουλειών — τραβιέται μέχρι σχεδόν την κορυφή.
              DraggableScrollableSheet(
                minChildSize:     _sheetMin,
                initialChildSize: _sheetMin,
                maxChildSize:     _sheetMax,
                snap: true,
                snapSizes: const [_sheetMin, _sheetMax],
                builder: (context, scrollCtrl) {
                  final safeBottom = MediaQuery.of(context).padding.bottom;
                  return Container(
                    decoration: BoxDecoration(
                      color: c.card,
                      borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(22)),
                      border: Border.all(color: c.cardBorder, width: 0.8),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.10),
                          blurRadius: 14,
                          offset: const Offset(0, -3),
                        ),
                      ],
                    ),
                    child: ListView(
                      controller: scrollCtrl,
                      padding: EdgeInsets.fromLTRB(
                          14, 8, 14, 16 + (safeBottom > 0 ? safeBottom : 10)),
                      children: [
                        // Χερούλι
                        Center(
                          child: Container(
                            width: 42, height: 5,
                            margin: const EdgeInsets.only(bottom: 10),
                            decoration: BoxDecoration(
                              color: c.textFaint.withValues(alpha: 0.45),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                        Row(children: [
                          Expanded(
                            child: Text(
                              '${_weekdayDate(_selectedDay)} · ${dayEntries.length} '
                              '${dayEntries.length == 1 ? "δουλειά" : "δουλειές"}',
                              style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: c.textMain),
                            ),
                          ),
                          if (dayTotal > 0)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 5),
                              decoration: BoxDecoration(
                                color: c.blueSoft,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text('${dayTotal.toStringAsFixed(0)} €',
                                  style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: c.blueDeep)),
                            ),
                        ]),
                        const SizedBox(height: 10),

                        if (dayEntries.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 24),
                            child: Center(
                              child: Text('Καμία δουλειά αυτή την ημέρα',
                                  style: TextStyle(
                                      fontSize: 13, color: c.textFaint)),
                            ),
                          )
                        else
                          ...dayEntries.map((e) => _entryCard(c, e)),

                        const SizedBox(height: 16),
                        _bottomButtons(c, dayEntries),
                      ],
                    ),
                  );
                },
              ),
            ]);
          });
        },
      ),
    );
  }

  String _weekdayDate(DateTime d) {
    const days = ['Δευτέρα','Τρίτη','Τετάρτη','Πέμπτη','Παρασκευή','Σάββατο','Κυριακή'];
    return '${days[d.weekday - 1]} '
        '${d.day.toString().padLeft(2, "0")}/${d.month.toString().padLeft(2, "0")}';
  }

  Widget _monthCalendar(AppColors c, Map<DateTime, List<_CalEntry>> byDay) {
    return Container(
      decoration: BoxDecoration(
        color:        c.card,
        borderRadius: BorderRadius.circular(16),
        border:       Border.all(color: c.cardBorder, width: 0.8),
      ),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: TableCalendar<_CalEntry>(
        firstDay:       DateTime.utc(2023, 1, 1),
        lastDay:        DateTime.utc(2035, 12, 31),
        focusedDay:     _focusedMonth,
        currentDay:     DateTime.now(),
        shouldFillViewport: true, // γεμίζει όλο το διαθέσιμο ύψος
        selectedDayPredicate: (d) => isSameDay(d, _selectedDay),
        eventLoader: (day) {
          final key = DateTime(day.year, day.month, day.day);
          return byDay[key] ?? const [];
        },
        onDaySelected: (selected, focused) => setState(() {
          _selectedDay  = selected;
          _focusedMonth = focused;
        }),
        onPageChanged: (focused) => setState(() => _focusedMonth = focused),
        headerStyle: HeaderStyle(
          formatButtonVisible: false,
          titleCentered:       true,
          titleTextStyle: TextStyle(
              fontSize: 15, fontWeight: FontWeight.w600, color: c.textMain),
          leftChevronIcon:  Icon(Icons.chevron_left_rounded,  color: c.textFaint),
          rightChevronIcon: Icon(Icons.chevron_right_rounded, color: c.textFaint),
        ),
        daysOfWeekStyle: DaysOfWeekStyle(
          weekdayStyle: TextStyle(fontSize: 11, color: c.textFaint),
          weekendStyle: TextStyle(fontSize: 11, color: c.textFaint),
        ),
        calendarStyle: CalendarStyle(
          outsideDaysVisible: false,
          defaultTextStyle:   TextStyle(fontSize: 14, color: c.textMain),
          weekendTextStyle:   const TextStyle(fontSize: 14, color: Color(0xFF993C1D)),
          todayDecoration: BoxDecoration(
            color:  c.amberSoft,
            shape:  BoxShape.circle,
          ),
          todayTextStyle: TextStyle(
              color: c.isDark ? c.amberDeep : const Color(0xFF633806),
              fontWeight: FontWeight.w600),
          selectedDecoration: BoxDecoration(
            color: c.textMain,
            shape: BoxShape.circle,
          ),
          selectedTextStyle: TextStyle(
              color: c.scaffold, fontWeight: FontWeight.w600),
        ),
        calendarBuilders: CalendarBuilders<_CalEntry>(
          // Έως 8 κουκκίδες σε ΔΥΟ σειρές (4+4), μεγαλύτερες (8px)·
          // «+Ν» αν υπάρχουν κι άλλες. Περίγραμμα οχήματος διατηρείται.
          markerBuilder: (context, day, dayEntries) {
            if (dayEntries.isEmpty) return null;
            final shown = dayEntries.take(8).toList();
            final extra = dayEntries.length - shown.length;
            return Positioned(
              bottom: 3,
              child: SizedBox(
                width: 46,
                child: Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 2.5, runSpacing: 2.5,
                  children: [
                    ...shown.map((e) {
                      final border = _vehicleBorderColor(e.vehicleType);
                      return Container(
                        width: 8, height: 8,
                        decoration: BoxDecoration(
                          color: _statusColor(c, e.kind),
                          shape: BoxShape.circle,
                          border: border != null
                              ? Border.all(color: border, width: 1)
                              : null,
                        ),
                      );
                    }),
                    if (extra > 0)
                      Text('+$extra',
                          style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              color: c.textFaint)),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _entryCard(AppColors c, _CalEntry e) {
    final job    = e.job;
    final status = _statusColor(c, e.kind);
    final border = _vehicleBorderColor(e.vehicleType);
    final barBg  = status.withValues(alpha: 0.16);

    String timeLabel() {
      final t = e.day;
      return '${t.hour.toString().padLeft(2, "0")}:${t.minute.toString().padLeft(2, "0")}';
    }

    String paymentLabel() =>
        job.fullyPaid ? 'Προπληρωμένη' : 'Μετρητά';
    Color paymentColor() => job.fullyPaid ? c.blueDeep : c.greenDeep;
    Color paymentBg()    => job.fullyPaid ? c.bluePale : c.greenPale;

    final phone = (job.clientPhone ?? '').trim();

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          if (e.kind == _EntryKind.saved && e.savedJob != null) {
            // TODO: hook to saved-job editor όταν φτάσουμε σε εκείνη την οθόνη
            return;
          }
          showModalBottomSheet(
            context: context,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            builder: (ctx) => JobDetailsSheet(job: job, parentContext: context),
          );
        },
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: c.scaffold,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: c.cardBorder, width: 0.8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Πάνω ΓΕΜΑΤΗ μπάρα: ώρα · Μετρητά (πράσινο) · τιμή ──────────
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 11),
                decoration: BoxDecoration(
                  color: barBg,
                  border: border != null
                      ? Border(bottom: BorderSide(color: border, width: 2))
                      : null,
                ),
                child: Row(children: [
                  Icon(Icons.access_time_filled_rounded,
                      size: 19, color: status),
                  const SizedBox(width: 6),
                  Text(timeLabel(),
                      style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: status)),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color:        paymentBg(),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(paymentLabel(),
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: paymentColor())),
                  ),
                  const SizedBox(width: 10),
                  Text('${job.price.toStringAsFixed(0)} €',
                      style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: status)),
                ]),
              ),

              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Διαδρομή με pickup/dropoff ─────────────────────────
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Column(children: [
                          Container(
                            width: 9, height: 9,
                            decoration: BoxDecoration(
                                color: c.greenDivider.withValues(alpha: 1),
                                shape: BoxShape.circle,
                                border: Border.all(color: c.green, width: 2)),
                          ),
                          Container(width: 2, height: 22, color: c.cardBorder),
                          Icon(Icons.location_on_rounded,
                              size: 14, color: const Color(0xFFE24B4A)),
                        ]),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(job.from,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 14.5, color: c.textMain)),
                            const SizedBox(height: 14),
                            Text(job.to,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 14.5, color: c.textMain)),
                          ],
                        ),
                      ),
                    ]),
                    const SizedBox(height: 12),
                    // ── Εικονίδια: όχημα · άτομα · βαλίτσες · παιδικό ──────
                    Row(children: [
                      VehicleTypeIcon(
                          vehicleType: job.vehicleType,
                          size: 22, color: c.textFaint),
                      const SizedBox(width: 16),
                      _iconNum(c, Icons.person_rounded, job.persons),
                      if (job.luggage > 0) ...[
                        const SizedBox(width: 16),
                        _iconNum(c, Icons.work_outline_rounded, job.luggage),
                      ],
                      if (job.childSeatCount > 0) ...[
                        const SizedBox(width: 16),
                        _iconNum(c, Icons.child_care_rounded,
                            job.childSeatCount,
                            color: const Color(0xFFD4537E)),
                      ],
                    ]),
                    // ── Κάτω γραμμή: τηλέφωνο+WhatsApp · υπενθυμίσεις+edit ──
                    if (phone.isNotEmpty || job.scheduledAt != null) ...[
                      const SizedBox(height: 12),
                      Divider(height: 1, color: c.cardBorder),
                      const SizedBox(height: 10),
                      Row(children: [
                        if (phone.isNotEmpty) ...[
                          Icon(Icons.phone_rounded,
                              size: 19, color: c.textFaint),
                          const SizedBox(width: 6),
                          GestureDetector(
                            onTap: () =>
                                launchUrl(Uri(scheme: 'tel', path: phone)),
                            child: Text(phone,
                                style: TextStyle(
                                    fontSize: 14, color: c.textFaint)),
                          ),
                          const SizedBox(width: 10),
                          GestureDetector(
                            onTap: () => launchUrl(
                              Uri.parse('https://wa.me/'
                                  '${phone.replaceAll(RegExp(r'[^0-9]'), '')}'),
                              mode: LaunchMode.externalApplication,
                            ),
                            child: const FaIcon(FontAwesomeIcons.whatsapp,
                                size: 19, color: Color(0xFF1D9E75)),
                          ),
                        ],
                        const Spacer(),
                        if (job.scheduledAt != null) ...[
                          Icon(Icons.notifications_active_rounded,
                              size: 18, color: c.amberDeep),
                          const SizedBox(width: 5),
                          Text(
                            job.reminderOffsets.map((m) => '$m′').join(' · '),
                            style: TextStyle(
                                fontSize: 13.5, color: c.amberDeep,
                                fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(width: 8),
                          GestureDetector(
                            onTap: () => _editReminders(context, job),
                            child: Icon(Icons.edit_rounded,
                                size: 18, color: c.textFaint),
                          ),
                        ],
                      ]),
                    ],
                    if (e.kind == _EntryKind.saved) ...[
                      const SizedBox(height: 6),
                      Text('Αποθηκευμένη — δεν έχει δοθεί ακόμη',
                          style: TextStyle(
                              fontSize: 12,
                              color: const Color(0xFFD64545),
                              fontWeight: FontWeight.w600)),
                    ],
                    if (e.kind == _EntryKind.done) ...[
                      const SizedBox(height: 6),
                      Text(
                          job.takenByName != null
                              ? 'Ολοκληρώθηκε — ${job.takenByName}'
                              : 'Ολοκληρώθηκε',
                          style: TextStyle(
                              fontSize: 12,
                              color: c.greenDeep,
                              fontWeight: FontWeight.w600)),
                    ],
                    if (e.kind == _EntryKind.cancelled) ...[
                      const SizedBox(height: 6),
                      const Text('Ακυρώθηκε',
                          style: TextStyle(
                              fontSize: 12,
                              color: Color(0xFF8A8A8A),
                              fontWeight: FontWeight.w600)),
                    ],
                    // ── Διακριτικά: ποιος τη δημιούργησε / ποιος την
                    //    ανέλαβε — μόνο σε admin/master (ο οδηγός ήδη ξέρει
                    //    ότι είναι δική του). Χρήσιμο ειδικά για τον master
                    //    που βλέπει δουλειές από πολλούς admins μαζί.
                    //    ΣΗΜΕΙΩΣΗ: οι αποθηκευμένες (saved) δουλειές κρατούν
                    //    τον δημιουργό στο ownerName του SavedJob (όχι στο
                    //    job.createdByName — διαφορετικό πεδίο στο doc).
                    if (_seesAllOrgJobs) ...[
                      const SizedBox(height: 6),
                      Builder(builder: (_) {
                        final creatorName = (e.kind == _EntryKind.saved
                                ? e.savedJob?.ownerName
                                : job.createdByName) ??
                            '';
                        return Text(
                          [
                            creatorName.isNotEmpty
                                ? 'Από: $creatorName'
                                : 'Από: Online φόρμα',
                            if (job.takenByName != null &&
                                job.takenByName!.isNotEmpty)
                              'Οδηγός: ${job.takenByName}',
                          ].join('   ·   '),
                          style: TextStyle(fontSize: 11, color: c.textFaint),
                        );
                      }),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _iconNum(AppColors c, IconData icon, int n, {Color? color}) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 20, color: color ?? c.textFaint),
      const SizedBox(width: 4),
      Text('$n', style: TextStyle(fontSize: 14.5, color: color ?? c.textFaint)),
    ]);
  }

  // ── Μενού επεξεργασίας υπενθυμίσεων (10΄/30΄ κλειδωμένα + custom) ──────────
  // Ίδια λογική με τη φόρμα νέας δουλειάς: 10 & 30 πάντα μέσα, ο χρήστης
  // μπορεί να προσθέσει επιπλέον (π.χ. 90΄). Αποθηκεύει απευθείας στη
  // δουλειά — το syncAppointmentReminders θα τα πάρει στο επόμενο snapshot.
  static const List<int> _lockedReminderOffsets = [30, 10];

  Future<void> _editReminders(BuildContext context, Job job) async {
    final c = AppColors.of(context);
    var offsets = List<int>.from(job.reminderOffsets)
      ..sort((a, b) => b.compareTo(a));

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      // ΡΗΤΟ σκούρο φόντο — δεν βασιζόμαστε στο ambient Theme (που μπορεί να
      // δίνει λευκό/διάφανο canvas και να «χάνεται» το λευκό κείμενο).
      backgroundColor: c.scaffold,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheetState) {
          Future<void> addOffset() async {
            final ctrl = TextEditingController();
            final mins = await showDialog<int>(
              context: sheetCtx,
              builder: (dctx) => AlertDialog(
                backgroundColor: c.scaffold,
                title: Text('Νέα υπενθύμιση',
                    style: TextStyle(color: c.textMain)),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 6, runSpacing: 6,
                      children: [15, 45, 60, 90, 120, 180].map((m) =>
                          ActionChip(
                            label: Text(m % 60 == 0 ? '${m ~/ 60}ω' : '$m′',
                                style: TextStyle(color: c.textMain)),
                            backgroundColor: c.cardBorder.withValues(alpha: 0.25),
                            onPressed: () => Navigator.pop(dctx, m),
                          )).toList(),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: ctrl,
                      keyboardType: TextInputType.number,
                      style: TextStyle(color: c.textMain),
                      decoration: InputDecoration(
                        labelText: 'Ή λεπτά',
                        labelStyle: TextStyle(color: c.textFaint),
                        border: const OutlineInputBorder(),
                        enabledBorder: OutlineInputBorder(
                            borderSide: BorderSide(color: c.cardBorder)),
                        isDense: true,
                      ),
                    ),
                  ],
                ),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(dctx),
                      child: Text('Άκυρο', style: TextStyle(color: c.textFaint))),
                  FilledButton(
                    onPressed: () =>
                        Navigator.pop(dctx, int.tryParse(ctrl.text.trim())),
                    child: const Text('Προσθήκη'),
                  ),
                ],
              ),
            );
            if (mins == null || mins <= 0 || mins > 1440) return;
            if (offsets.contains(mins)) return;
            setSheetState(() {
              offsets = ({...offsets, mins}.toList()
                ..sort((a, b) => b.compareTo(a)));
            });
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Υπενθυμίσεις πριν το ραντεβού',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700,
                          color: c.textMain)),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8, runSpacing: 8,
                    children: [
                      for (final m in offsets)
                        _lockedReminderOffsets.contains(m)
                            ? Chip(
                                avatar: Icon(Icons.lock_rounded,
                                    size: 14, color: c.textFaint),
                                label: Text('$m′',
                                    style: TextStyle(color: c.textFaint)),
                                backgroundColor:
                                    c.cardBorder.withValues(alpha: 0.25),
                              )
                            : Chip(
                                label: Text('$m′',
                                    style: TextStyle(color: c.textMain)),
                                backgroundColor: c.amberSoft,
                                deleteIconColor: c.amberDeep,
                                onDeleted: () => setSheetState(() =>
                                    offsets = offsets
                                        .where((x) => x != m)
                                        .toList()),
                              ),
                      ActionChip(
                        avatar: Icon(Icons.add_rounded,
                            size: 16, color: c.textMain),
                        label: Text('Προσθήκη',
                            style: TextStyle(color: c.textMain)),
                        backgroundColor: c.cardBorder.withValues(alpha: 0.25),
                        onPressed: addOffset,
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () async {
                        await JobService.updateJob(job.id, {
                          'reminderOffsets':
                              ({...offsets, 30, 10}.toList()
                                ..sort((a, b) => b.compareTo(a))),
                        });
                        if (sheetCtx.mounted) Navigator.pop(sheetCtx);
                      },
                      child: const Text('Αποθήκευση'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _bottomButtons(AppColors c, List<_CalEntry> dayEntries) {
    Widget squareButton({
      required IconData icon,
      required String label,
      required VoidCallback? onPressed,
    }) {
      return Expanded(
        child: SizedBox(
          height: 64,
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: onPressed,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 22),
                const SizedBox(height: 4),
                Text(label,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w600, height: 1.15)),
              ],
            ),
          ),
        ),
      );
    }

    return Row(children: [
      squareButton(
        icon: Icons.event_available_rounded,
        label: 'Αποθήκευση ημερολογίου',
        onPressed: dayEntries.isEmpty
            ? null
            : () => exportDayToIcsAndSave(
                context: context,
                jobs:    dayEntries.map((e) => e.job).toList(),
                day:     _selectedDay,
              ),
      ),
      if (widget.googleCalendarEnabled) ...[
        const SizedBox(width: 10),
        squareButton(
          icon: Icons.calendar_month_rounded,
          label: 'Google Calendar',
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => GoogleCalendarPage(
              adminUid:  widget.uid,
              isMaster:  widget.isMaster,
            ),
          )),
        ),
      ],
    ]);
  }
}
