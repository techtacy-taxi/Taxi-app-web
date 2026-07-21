// lib/calendar/jobs_calendar_page.dart
//
// ΝΕΟ ενιαίο «Ημερολόγιο δουλειών» — ορατό ΣΕ ΟΛΟΥΣ (οδηγούς, admin, master),
// σύμφωνα με το εγκεκριμένο mockup:
//   • Μήνας με κουκκίδες ανά ημέρα (μέχρι 3, μετά «+Ν»)
//   • Λίστα δουλειών της επιλεγμένης ημέρας, σύνολο € πάνω δεξιά
//   • Χρωματικός κώδικας (αριστερή μπάρα + κουκκίδα μήνα):
//       - Γαλάζιο  = ΡΑΝΤΕΒΟΥ (scheduledAt != null, δεν έχει ξεκινήσει)
//       - Κίτρινο  = ΑΜΕΣΗ (χωρίς ραντεβού)
//       - Πορτοκαλί = έχει αναλάβει κάποιος να την εκτελέσει (taken/boarded)
//         — ΜΟΝΟ ορατό σε admin/master (σύνολο "όλων" των δουλειών τους)
//       - Κόκκινο  = Αποθηκευμένη (draft, ΔΕΝ έχει δοθεί ακόμη σε οδηγό)
//         — ΜΟΝΟ admin/master
//   • Περίγραμμα κύκλου/μπάρας ανά όχημα: πράσινο = Ταξί, μοβ = Βαν
//     (εφαρμόζεται πάνω στο βασικό χρώμα κατάστασης — «χρώμα κατάστασης
//     γέμισμα» + «χρώμα οχήματος περίγραμμα»)
//   • Κάτω κουμπιά: «Αποθήκευση ημερολογίου» (πρώην «Εξαγωγή .ics») πάντα
//     ορατό· «Google Calendar» ΜΟΝΟ σε όσους έχουν ενεργό sync
//     (calendarEnabled == true ή master == true)
//
// Data: οδηγός βλέπει μόνο τις ΔΙΚΕΣ ΤΟΥ δουλειές (takenBy == uid).
// admin/master βλέπουν όλες τις δουλειές τους (taken/boarded — πορτοκαλί)
// ΚΑΙ τις saved_jobs (αποθηκευμένες/αδιάθετες — κόκκινο).

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:table_calendar/table_calendar.dart';

import '../app_theme.dart';
import '../jobs/job_details_sheet.dart';
import '../jobs/job_model.dart';
import '../jobs/saved_job_service.dart';
import 'google_calendar_page.dart';
import 'ics_calendar_export.dart';

enum _EntryKind { appointment, immediate, assigned, saved }

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

  // ── Firestore streams ──────────────────────────────────────────────────

  Stream<List<_CalEntry>> _monthEntries() {
    final monthStart = DateTime(_focusedMonth.year, _focusedMonth.month, 1);
    final monthEnd    = DateTime(_focusedMonth.year, _focusedMonth.month + 1, 1);

    // Ο οδηγός βλέπει μόνο τις δικές του δουλειές (ό,τι ώρα κι αν είναι).
    // Ο admin/master βλέπει ΟΛΕΣ τις taken/boarded του οργανισμού.
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
        if (_seesAllOrgJobs && !(job.isTaken || job.isBoarded || job.isOpen)) {
          continue;
        }
        if (!_seesAllOrgJobs && !(job.isTaken || job.isBoarded)) continue;

        entries.add(_CalEntry(
          job: job,
          day: job.scheduledAt!,
          kind: _seesAllOrgJobs && job.isOpen
              ? _EntryKind.assigned // ανοιχτή αλλά με ραντεβού· εμφανίζεται σαν προγραμματισμένη
              : (job.scheduledAt != null
                  ? _EntryKind.appointment
                  : _EntryKind.immediate),
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
        entries.add(_CalEntry(
          job: job,
          day: job.takenAt!,
          kind: _EntryKind.immediate,
          vehicleType: job.vehicleType,
        ));
      }

      // Admin/master: αποθηκευμένες (draft) δουλειές — κόκκινο.
      if (_seesAllOrgJobs) {
        final savedSnap = await FirebaseFirestore.instance
            .collection('saved_jobs')
            .where('job.scheduledAt',
                isGreaterThanOrEqualTo: Timestamp.fromDate(monthStart))
            .where('job.scheduledAt', isLessThan: Timestamp.fromDate(monthEnd))
            .get();
        for (final doc in savedSnap.docs) {
          try {
            final sj = SavedJob.fromDoc(doc);
            if (sj.job.scheduledAt == null) continue;
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

          return SingleChildScrollView(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _monthCalendar(c, byDay),
                const SizedBox(height: 14),
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
                          style:
                              TextStyle(fontSize: 13, color: c.textFaint)),
                    ),
                  )
                else
                  ...dayEntries.map((e) => _entryCard(c, e)),

                const SizedBox(height: 16),
                _bottomButtons(c, dayEntries),
                const SizedBox(height: 8),
              ],
            ),
          );
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
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TableCalendar<_CalEntry>(
        firstDay:       DateTime.utc(2023, 1, 1),
        lastDay:        DateTime.utc(2035, 12, 31),
        focusedDay:     _focusedMonth,
        currentDay:     DateTime.now(),
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
          defaultTextStyle:   TextStyle(fontSize: 13, color: c.textMain),
          weekendTextStyle:   const TextStyle(fontSize: 13, color: Color(0xFF993C1D)),
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
          markersMaxCount: 3,
          markerSize: 5,
          markersAnchor: 0.9,
        ),
        calendarBuilders: CalendarBuilders<_CalEntry>(
          markerBuilder: (context, day, dayEntries) {
            if (dayEntries.isEmpty) return null;
            final shown = dayEntries.take(3).toList();
            return Positioned(
              bottom: 3,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: shown
                    .map((e) => Container(
                          width:  5, height: 5,
                          margin: const EdgeInsets.symmetric(horizontal: 1),
                          decoration: BoxDecoration(
                            color: _statusColor(c, e.kind),
                            shape: BoxShape.circle,
                          ),
                        ))
                    .toList(),
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

    String timeLabel() {
      final t = e.day;
      return '${t.hour.toString().padLeft(2, "0")}:${t.minute.toString().padLeft(2, "0")}';
    }

    String paymentLabel() {
      if (job.fullyPaid) return 'Προπληρωμένη';
      return 'Μετρητά';
    }

    Color paymentColor() =>
        job.fullyPaid ? c.blueDeep : c.greenDeep;
    IconData paymentIcon() =>
        job.fullyPaid ? Icons.credit_card_rounded : Icons.payments_rounded;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
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
          decoration: BoxDecoration(
            color: c.card,
            borderRadius: BorderRadius.circular(14),
            border: Border(
              top:    BorderSide(color: c.cardBorder, width: 0.8),
              right:  BorderSide(color: c.cardBorder, width: 0.8),
              bottom: BorderSide(color: c.cardBorder, width: 0.8),
              left:   BorderSide(color: status, width: 4),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(10, 9, 12, 9),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 9, vertical: 3),
                  decoration: BoxDecoration(
                    color:        status.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(9),
                    border: border != null
                        ? Border.all(color: border, width: 1.5)
                        : null,
                  ),
                  child: Text(timeLabel(),
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: status)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('${job.from} → ${job.to}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13, color: c.textMain)),
                ),
                Text('${job.price.toStringAsFixed(0)} €',
                    style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: c.textMain)),
              ]),
              const SizedBox(height: 6),
              Row(children: [
                _miniIcon(
                  c,
                  icon: job.vehicleType == 'van'
                      ? Icons.airport_shuttle_rounded
                      : job.vehicleType == 'bus'
                          ? Icons.directions_bus_rounded
                          : Icons.local_taxi_rounded,
                  label: job.vehicleLabel,
                ),
                const SizedBox(width: 10),
                _miniIcon(c,
                    icon: Icons.person_rounded, label: '${job.persons}'),
                if (job.childSeat) ...[
                  const SizedBox(width: 10),
                  Icon(Icons.child_care_rounded,
                      size: 13, color: const Color(0xFFD4537E)),
                ],
                const Spacer(),
                Icon(paymentIcon(), size: 13, color: paymentColor()),
                const SizedBox(width: 3),
                Text(paymentLabel(),
                    style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: paymentColor())),
              ]),
              if (e.kind == _EntryKind.assigned && job.takenByName != null) ...[
                const SizedBox(height: 4),
                Text('Ανέλαβε: ${job.takenByName}',
                    style: TextStyle(fontSize: 10.5, color: c.textFaint)),
              ],
              if (e.kind == _EntryKind.saved) ...[
                const SizedBox(height: 4),
                Text('Αποθηκευμένη — δεν έχει δοθεί ακόμη',
                    style: TextStyle(
                        fontSize: 10.5,
                        color: const Color(0xFFD64545),
                        fontWeight: FontWeight.w600)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _miniIcon(AppColors c, {required IconData icon, required String label}) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 13, color: c.textFaint),
      const SizedBox(width: 3),
      Text(label, style: TextStyle(fontSize: 11.5, color: c.textFaint)),
    ]);
  }

  Widget _bottomButtons(AppColors c, List<_CalEntry> dayEntries) {
    return Row(children: [
      Expanded(
        child: OutlinedButton.icon(
          onPressed: dayEntries.isEmpty
              ? null
              : () => exportDayToIcsAndSave(
                  context: context,
                  jobs:    dayEntries.map((e) => e.job).toList(),
                  day:     _selectedDay,
                ),
          icon: const Icon(Icons.event_available_rounded, size: 18),
          label: const Text('Αποθήκευση ημερολογίου'),
        ),
      ),
      if (widget.googleCalendarEnabled) ...[
        const SizedBox(width: 10),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => GoogleCalendarPage(
                adminUid:  widget.uid,
                isMaster:  widget.isMaster,
              ),
            )),
            icon: const Icon(Icons.calendar_month_rounded, size: 18),
            label: const Text('Google Calendar'),
          ),
        ),
      ],
    ]);
  }
}
