// lib/jobs/job_details_sheet.dart
// Sheet λεπτομερειών δουλειάς — ανοίγει από τις κάρτες δουλειών (ημερολόγιο,
// popup ειδοποιήσεων owner κ.ά.)

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:vibration/vibration.dart';
import 'job_shared_widgets.dart';
import '../app_theme.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'job_model.dart';
import 'job_service.dart';
import 'saved_job_service.dart';
import 'ics_export_service.dart';
import 'ics_access.dart';
import 'job_map_distance.dart';
import '../widgets/vehicle_type_icon.dart';

// ─────────────────────────────────────────────────────────────────────────────
// ΚΟΙΝΗ ΡΟΗ «ΤΕΛΟΣ ΔΙΑΔΡΟΜΗΣ» (+ προαιρετική ΕΠΙΣΤΡΟΦΗ)
// Χρησιμοποιείται από το JobDetailsSheet.
// ─────────────────────────────────────────────────────────────────────────────

/// Διάλογος επιβεβαίωσης τέλους. Επιστρέφει:
///  • 'yes'    → κανονικό τέλος
///  • 'return' → ο πελάτης θέλει επιστροφή
///  • null     → ακύρωση
Future<String?> showFinishRouteDialog(BuildContext ctx) {
  return showDialog<String>(
    context: ctx,
    builder: (dCtx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Row(children: [
        Icon(Icons.flag_rounded, color: Color(0xFF1E8E3E), size: 26),
        SizedBox(width: 10),
        Text('Τέλος Διαδρομής;',
            style: TextStyle(fontWeight: FontWeight.bold)),
      ]),
      content: const Text(
        'Είσαι σίγουρος ότι θέλεις να τερματίσεις τη διαδρομή;',
        style: TextStyle(fontSize: 15),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      actions: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            AppButton(
              label: 'Ναι, Τέλος',
              color: const Color(0xFF1E8E3E),
              onPressed: () => Navigator.pop(dCtx, 'yes'),
            ),
            const SizedBox(height: 8),
            AppButton(
              label: 'Θέλει επιστροφή',
              icon: Icons.u_turn_left_rounded,
              color: const Color(0xFF7B1FA2),
              onPressed: () => Navigator.pop(dCtx, 'return'),
            ),
            const SizedBox(height: 8),
            AppButtonTonal(
              label: 'Ακύρωση',
              onPressed: () => Navigator.pop(dCtx, null),
            ),
          ],
        ),
      ],
    ),
  );
}

/// Ροή επιστροφής: ημερομηνία → ώρα → σχόλια → αποθήκευση.
/// Επιστρέφει true αν αποθηκεύτηκε η επιστροφή, false αν ακυρώθηκε.
Future<bool> runReturnFlow(BuildContext ctx, Job job) async {
  final now = DateTime.now();

  final date = await showDatePicker(
    context: ctx,
    initialDate: now.add(const Duration(hours: 1)),
    firstDate: now.subtract(const Duration(days: 1)),
    lastDate: now.add(const Duration(days: 365)),
    helpText: 'Ημερομηνία επιστροφής',
    cancelText: 'Ακύρωση',
    confirmText: 'Επόμενο',
  );
  if (date == null || !ctx.mounted) return false;

  final time = await showTimePicker(
    context: ctx,
    initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))),
    helpText: 'Ώρα επιστροφής',
    cancelText: 'Ακύρωση',
    confirmText: 'Επόμενο',
  );
  if (time == null || !ctx.mounted) return false;

  final scheduledAt = DateTime(
      date.year, date.month, date.day, time.hour, time.minute);

  final noteCtrl = TextEditingController();
  final action = await showDialog<String>(
    context: ctx,
    builder: (dCtx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Row(children: [
        Icon(Icons.u_turn_left_rounded, color: Color(0xFF7B1FA2), size: 24),
        SizedBox(width: 10),
        Expanded(child: Text('Σχόλια επιστροφής',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17))),
      ]),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: const Color(0xFFF3E5F5),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(children: [
            const Icon(Icons.alarm_rounded,
                size: 18, color: Color(0xFF7B1FA2)),
            const SizedBox(width: 8),
            Expanded(child: Text(
                DateFormat('dd/MM/yyyy  HH:mm').format(scheduledAt),
                style: const TextStyle(
                    fontWeight: FontWeight.bold, color: Color(0xFF7B1FA2)))),
          ]),
        ),
        TextField(
          controller: noteCtrl,
          maxLines: 3,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            hintText: 'Προαιρετικό σχόλιο (μπαίνει με ΚΕΦΑΛΑΙΑ)',
            filled: true,
            fillColor: Colors.grey.shade50,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ]),
      actions: [
        AppButtonTonal(
          label: 'Ακύρωση',
          onPressed: () => Navigator.pop(dCtx, 'cancel'),
        ),
        AppButton(
          label: 'Αποθήκευση & Τέλος',
          icon: Icons.save_rounded,
          color: const Color(0xFF7B1FA2),
          onPressed: () => Navigator.pop(dCtx, 'save'),
        ),
      ],
    ),
  );

  final extraNote = noteCtrl.text;
  noteCtrl.dispose();

  if (action != 'save') return false;

  try {
    await SavedJobService.saveReturn(
      original: job,
      scheduledAt: scheduledAt,
      extraNote: extraNote,
    );
  } catch (_) {/* συνεχίζουμε στο τέλος ακόμη κι αν αποτύχει το draft */}
  return true;
}

/// Τρέχει ολόκληρη τη ροή τέλους (με επανεμφάνιση του διαλόγου αν ο χρήστης
/// ακυρώσει μέσα στη ροή επιστροφής).
/// Επιστρέφει:
///  • 'yes'    → να γίνει completeJob (κανονικό τέλος)
///  • 'return' → έγινε completeJob-worthy ΚΑΙ αποθηκεύτηκε επιστροφή
///  • null     → ακυρώθηκε τελείως, καμία ενέργεια
Future<String?> runCompleteRouteFlow(BuildContext ctx, Job job) async {
  while (true) {
    final choice = await showFinishRouteDialog(ctx);
    if (choice == null || !ctx.mounted) return null;
    if (choice == 'yes') return 'yes';
    // 'return'
    final saved = await runReturnFlow(ctx, job);
    if (saved) return 'return';
    if (!ctx.mounted) return null;
    // ακυρώθηκε στη ροή → ξαναδείχνουμε τον διάλογο τέλους
  }
}


class JobDetailsSheet extends StatelessWidget {
  final Job          job;
  final BuildContext parentContext; // για να κλείσει και το "Οι δουλειές μου"
  final bool         hideComplete;  // true → χωρίς κουμπί ολοκλήρωσης (υπενθύμιση)
  final String?      headerLabel;   // προαιρετικός τίτλος (π.χ. υπενθύμιση)
  final bool         historyMode;   // true → καρτέλα ιστορικού (δημιουργός/εκτελεστής)
  final bool         openJobMode;   // true → ανοιχτή δουλειά (κατάσταση ανάθεσης/επιβίβασης)

  const JobDetailsSheet({
    super.key,
    required this.job,
    required this.parentContext,
    this.hideComplete = false,
    this.headerLabel,
    this.historyMode = false,
    this.openJobMode = false,
  });

  Future<void> _confirmComplete(BuildContext ctx) async {
    final result = await runCompleteRouteFlow(ctx, job);
    if (result == null || !ctx.mounted) return; // ακύρωση

    // Κλείνουμε ΜΟΝΟ το details sheet (με τον δικό του navigator).
    final sheetNav = Navigator.of(ctx);
    if (sheetNav.canPop()) sheetNav.pop();

    // Το "Οι δουλειές μου" το κλείνουμε ΜΟΝΟ αν υπάρχει & μπορεί να κλείσει.
    // ΠΟΤΕ τυφλό pop: αλλιώς αδειάζει το stack → μαύρη οθόνη.
    if (parentContext.mounted) {
      final parentNav = Navigator.of(parentContext);
      if (parentNav.canPop()) parentNav.pop();
    }

    await JobService.completeJob(job.id);
    if (parentContext.mounted) {
      ScaffoldMessenger.of(parentContext).showSnackBar(
        SnackBar(
          content: Text(result == 'return'
              ? 'Τέλος διαδρομής — η επιστροφή αποθηκεύτηκε!'
              : 'Δουλειά ολοκληρώθηκε!'),
          backgroundColor: const Color(0xFF1E8E3E),
        ),
      );
    }
  }


  Future<void> _markBoarded(BuildContext ctx) async {
    Vibration.vibrate(duration: 1000);
    Navigator.pop(ctx);  // κλείνει το details sheet· η λίστα ανανεώνεται live
    await JobService.markBoarded(job.id);
    if (parentContext.mounted) {
      showCenterToast(parentContext, 'Το σύστημα ενημερώθηκε');
    }
  }

  // ── Ακύρωση (οδηγός): η δουλειά ΞΑΝΑΒΓΑΙΝΕΙ στους οδηγούς ──
  Future<void> _confirmCancel(BuildContext ctx) async {
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (dCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(children: [
          Icon(Icons.undo_rounded, color: Color(0xFFA32D2D), size: 24),
          SizedBox(width: 10),
          Expanded(child: Text('Ακύρωση ανάληψης;',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17))),
        ]),
        content: const Text(
          'Η δουλειά θα επιστρέψει στο σύστημα και θα ξαναβγεί στους '
          'οδηγούς. Σίγουρα;',
          style: TextStyle(fontSize: 15),
        ),
        actions: [
          AppButtonTonal(
            label: 'Πίσω',
            onPressed: () => Navigator.pop(dCtx, false),
          ),
          AppButton(
            label: 'Ναι, ακύρωση',
            color: const Color(0xFFA32D2D),
            onPressed: () => Navigator.pop(dCtx, true),
          ),
        ],
      ),
    );
    if (ok != true || !ctx.mounted) return;

    final sheetNav = Navigator.of(ctx);
    if (sheetNav.canPop()) sheetNav.pop();
    await JobService.reopenJob(job.id);
    if (parentContext.mounted) {
      showCenterToast(parentContext, 'Η δουλειά επέστρεψε στους οδηγούς');
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasClient =
        (job.clientName != null && job.clientName!.isNotEmpty) ||
        (job.clientPhone != null && job.clientPhone!.isNotEmpty) ||
        (job.clientEmail != null && job.clientEmail!.isNotEmpty);

    // Κάτω σειρά κουμπιών: Ακύρωση + (Παρέλαβα → Ολοκλήρωση).
    final showActions = !hideComplete && !historyMode &&
        (job.isTaken || job.isBoarded);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        systemNavigationBarColor: Colors.black,
        systemNavigationBarIconBrightness: Brightness.light,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
      child: SafeArea(
        top: false,
        child: Container(
          decoration: BoxDecoration(
            color:        AppColors.of(context).card,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          // Επιπλέον κάτω περιθώριο ώστε τα κουμπιά να μην κρύβονται ΠΟΤΕ
          // από το Android navigation bar (πίσω/Home) — μαζί με το SafeArea.
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 26),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const SheetHandle(bottomMargin: 14),

              // Header υπενθύμισης (αν δοθεί)
              if (headerLabel != null) ...[
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.deepOrange,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                    const Icon(Icons.alarm_rounded,
                        color: Colors.white, size: 24),
                    const SizedBox(width: 10),
                    Text(headerLabel!,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5)),
                  ]),
                ),
              ],

              // Banner κατάστασης ανάθεσης — μόνο για ανοιχτές δουλειές
              if (openJobMode) ...[
                _openStatusBanner(),
                const SizedBox(height: 12),
              ],

              // ── 1) Μπάρα ώρας/οχήματος — ίδια με το popup «Νέα δουλειά» ──
              _scheduleBar(),
              const SizedBox(height: 10),

              // ── 2) Μπλοκ πληρωμής — ίδια γλώσσα με το popup ──
              _payBlock(),
              const SizedBox(height: 10),

              // ── 3) Κάρτα πελάτη (όνομα → ταμπέλα, πτήση·άφιξη, κλήση/WA) ──
              if (hasClient) ...[
                _clientCard(context),
                const SizedBox(height: 8),
              ],

              // ── 4) Chips λεπτομερειών ──
              _detailChips(context),
              const SizedBox(height: 8),

              // Ομαδική μεταφορά (Shuttle/Λεωφορείο): στάσεις με σειρά
              GroupStopsSection(job: job),

              // ── 5) Χάρτης + κάρτα διαδρομής με ΔΥΟ κουμπιά πλοήγησης ──
              JobMapDistanceCard(job: job),
              const SizedBox(height: 6),
              _routeCard(context),
              const SizedBox(height: 8),

              // ── 6) Σημείωση ──
              if (job.note != null && job.note!.isNotEmpty) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(11),
                  decoration: BoxDecoration(
                    color:        const Color(0xFFFAEEDA),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    const Icon(Icons.sticky_note_2_outlined,
                        size: 17, color: Color(0xFF854F0B)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(job.note!,
                          style: const TextStyle(
                              fontSize: 13, color: Color(0xFF633806))),
                    ),
                  ]),
                ),
                const SizedBox(height: 10),
              ],

              // Στοιχεία ιστορικού: ποιος δημιούργησε & ποιος εκτέλεσε
              if (historyMode) ...[
                Builder(builder: (context) {
                  final c = AppColors.of(context);
                  return Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: c.scaffold,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: c.cardBorder),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (job.createdByName.isNotEmpty)
                          Row(children: [
                            Icon(Icons.person_add_alt_rounded,
                                size: 16, color: c.textFaint),
                            const SizedBox(width: 8),
                            Expanded(child: Text(
                                'Δημιουργήθηκε από: ${job.createdByName}',
                                style: TextStyle(
                                    fontSize: 13, color: c.textMain))),
                          ]),
                        if (job.createdByName.isNotEmpty &&
                            (job.takenByName ?? '').isNotEmpty)
                          const SizedBox(height: 6),
                        if ((job.takenByName ?? '').isNotEmpty)
                          Row(children: [
                            Icon(Icons.local_taxi_rounded,
                                size: 16, color: c.textFaint),
                            const SizedBox(width: 8),
                            Expanded(child: Text(
                                'Εκτελέστηκε από: ${job.takenByName}',
                                style: TextStyle(
                                    fontSize: 13, color: c.textMain))),
                          ]),
                      ],
                    ),
                  );
                }),
                const SizedBox(height: 12),
              ],

              // ── 7) Δευτερεύοντα: Πινακίδα ονόματος · Στο ημερολόγιο ──
              if (!historyMode) ...[
                Row(children: [
                  if (job.clientName != null &&
                      job.clientName!.isNotEmpty) ...[
                    Expanded(
                      child: _pillButton(context,
                        icon:  Icons.badge_rounded,
                        label: 'Πινακίδα ονόματος',
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            fullscreenDialog: true,
                            builder: (_) =>
                                NameSignScreen(name: job.clientName!),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(child: _JobToCalendarButton(job: job)),
                ]),
                const SizedBox(height: 10),
              ],

              // ── 8) Κάτω σειρά: Ακύρωση + (Παρέλαβα → Ολοκλήρωση) ──
              if (showActions)
                Row(children: [
                  Expanded(
                    flex: 9,
                    child: SizedBox(
                      height: 50,
                      child: OutlinedButton(
                        onPressed: () => _confirmCancel(context),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFA32D2D),
                          side: const BorderSide(
                              color: Color(0xFFF09595), width: 1.5),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(25)),
                        ),
                        child: const Text('Ακύρωση',
                            style: TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 13,
                    child: SizedBox(
                      height: 50,
                      child: job.isTaken
                          // Δεν έχει επιβιβαστεί ακόμη → «Παρέλαβα».
                          ? FilledButton.icon(
                              onPressed: () => _markBoarded(context),
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFF378ADD),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(25)),
                              ),
                              icon: const Icon(Icons.directions_car_rounded,
                                  size: 20),
                              label: const Text('Παρέλαβα',
                                  style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.bold)),
                            )
                          // Επιβιβάστηκε → το ίδιο κουμπί γίνεται «Ολοκλήρωση».
                          : FilledButton.icon(
                              onPressed: () => _confirmComplete(context),
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFF639922),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(25)),
                              ),
                              icon: const Icon(Icons.check_rounded, size: 20),
                              label: const Text('Ολοκλήρωση',
                                  style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.bold)),
                            ),
                    ),
                  ),
                ]),
            ]),
          ),
        ),
      ),
    );
  }

  // ─── 1) Μπάρα ώρας/οχήματος (στυλ popup «Νέα δουλειά») ────────────────────
  Widget _scheduleBar() {
    final sched = job.scheduledAt;
    final isNow = sched == null;

    String label;
    if (isNow) {
      label = 'ΤΩΡΑ — Άμεση παραλαβή';
    } else {
      final now      = DateTime.now();
      final today    = DateTime(now.year, now.month, now.day);
      final thatDay  = DateTime(sched.year, sched.month, sched.day);
      final hm       = DateFormat('HH:mm').format(sched);
      const wd = ['Δευ','Τρ','Τετ','Πέμ','Παρ','Σάβ','Κυρ'];
      final d = '${wd[sched.weekday - 1]} ${DateFormat('dd/MM').format(sched)}';
      if (thatDay == today) {
        label = 'Σήμερα, $d · $hm';
      } else if (thatDay == today.add(const Duration(days: 1))) {
        label = 'Αύριο, $d · $hm';
      } else {
        label = '$d · $hm';
      }
    }

    final bg     = isNow ? const Color(0xFFFAEEDA) : const Color(0xFFB5D4F4);
    final fg     = isNow ? const Color(0xFF633806) : const Color(0xFF042C53);
    final fgSoft = isNow ? const Color(0xFFBA7517) : const Color(0xFF185FA5);
    final chipBg = isNow ? const Color(0xFF412402) : const Color(0xFF0C447C);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      decoration: BoxDecoration(
        color:        bg,
        borderRadius: BorderRadius.circular(13),
      ),
      child: Row(children: [
        Icon(isNow ? Icons.bolt_rounded : Icons.event_rounded,
            size: 24, color: fgSoft),
        const SizedBox(width: 9),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
            if (!isNow)
              Text('ΡΑΝΤΕΒΟΥ',
                  style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                      color: fgSoft)),
            Text(label,
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700, color: fg)),
          ]),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color:        chipBg,
            borderRadius: BorderRadius.circular(11),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            VehicleTypeIcon(
                vehicleType: job.vehicleType, size: 15, color: Colors.white),
            const SizedBox(width: 5),
            Text(job.vehicleLabel.toUpperCase(),
                style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: Colors.white)),
          ]),
        ),
      ]),
    );
  }

  // ─── 2) Μπλοκ πληρωμής (στυλ popup) ───────────────────────────────────────
  // Προπληρωμένη → μπλε «ΠΡΟΠΛΗΡΩΜΕΝΗ — ΜΗΝ εισπράξεις» (αναβοσβήνει).
  // Μετρητά → πράσινο «Εισπράττεις X €». Κάτω γραμμή: προμήθειες + Κέρδος.
  Widget _payBlock() {
    final prepaid = job.fullyPaid;

    final border = prepaid ? const Color(0xFF378ADD) : const Color(0xFF97C459);
    final bg     = prepaid ? const Color(0xFFE6F1FB) : const Color(0xFFF7FBF1);
    final fg     = prepaid ? const Color(0xFF042C53) : const Color(0xFF173404);
    final fgSoft = prepaid ? const Color(0xFF378ADD) : const Color(0xFF639922);
    final divCol = prepaid ? const Color(0xFFB5D4F4) : const Color(0xFFC0DD97);

    // Γραμμή προμηθειών: γιαούρτι (πηγή) + app.
    final fees = <String>[
      if (job.commission > 0)
        '−${job.commission.toStringAsFixed(2)} €'
        '${job.sourceName != null && job.sourceName!.isNotEmpty ? " ${job.sourceName}" : ""}',
      if (job.appCommission > 0)
        'App −${job.appCommission.toStringAsFixed(2)} €',
    ];

    final content = Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(13, 11, 13, 10),
      decoration: BoxDecoration(
        color:        bg,
        border:       Border.all(color: border, width: 2),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(prepaid ? Icons.credit_card_rounded : Icons.payments_rounded,
              size: 22, color: fgSoft),
          const SizedBox(width: 9),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Text(prepaid ? 'ΠΡΟΠΛΗΡΩΜΕΝΗ — ΜΗΝ εισπράξεις' : 'Εισπράττεις',
                  style: TextStyle(
                      fontSize: prepaid ? 16 : 13,
                      fontWeight: FontWeight.w700,
                      color: prepaid ? fg : fgSoft)),
              if (prepaid)
                Text('Ο πελάτης έχει πληρώσει',
                    style: TextStyle(fontSize: 12.5, color: fgSoft))
              else ...[
                Text('${job.price.toStringAsFixed(2)} €',
                    style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        color: fg)),
                Text('Πληρωμή από τον πελάτη στο ταξί',
                    style: TextStyle(fontSize: 12, color: fgSoft)),
              ],
              if (job.depositPaid && !prepaid)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                      'Ο πελάτης πλήρωσε ήδη '
                      '${job.depositAmount.toStringAsFixed(2)} € προκαταβολή '
                      'online — είναι ΗΔΗ αφαιρεμένη από το ποσό πάνω.',
                      style: TextStyle(
                          fontSize: 11, color: Colors.blue.shade700)),
                ),
            ]),
          ),
        ]),
        Container(
            height: 0.8,
            color: divCol,
            margin: const EdgeInsets.symmetric(vertical: 8)),
        Row(children: [
          Expanded(
            child: Text(
                prepaid
                    ? 'Ναύλος ${job.depositAmount.toStringAsFixed(2)} €'
                      '${fees.isNotEmpty ? " · ${fees.join(" · ")}" : ""}'
                    : fees.isNotEmpty ? fees.join(' · ') : '—',
                style: TextStyle(fontSize: 12.5, color: fgSoft)),
          ),
          Text('Κέρδος ${job.driverEarning.toStringAsFixed(2)} €',
              style: TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w800, color: fg)),
        ]),
      ]),
    );

    return prepaid ? BlinkingBox(child: content) : content;
  }

  // ─── 3) Κάρτα πελάτη ──────────────────────────────────────────────────────
  Widget _clientCard(BuildContext context) {
    final name  = job.clientName ?? '';
    final phone = job.clientPhone ?? '';
    final email = job.clientEmail ?? '';
    final initials = name.trim().isEmpty
        ? '?'
        : name.trim().split(RegExp(r'\s+'))
            .take(2).map((w) => w[0]).join().toUpperCase();

    Future<void> launch(Uri uri, {bool external = false}) async {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri,
            mode: external
                ? LaunchMode.externalApplication
                : LaunchMode.platformDefault);
      }
    }

    Widget roundBtn(
            {IconData? icon,
            Widget? override,
            required Color bg,
            required Color fg,
            required String tooltip,
            required VoidCallback onTap}) =>
        Tooltip(
          message: tooltip,
          child: InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: Container(
              width: 38, height: 38,
              decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
              alignment: Alignment.center,
              child: override ?? Icon(icon, size: 18, color: fg),
            ),
          ),
        );

    final c = AppColors.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      decoration: BoxDecoration(
        color:        c.scaffold,
        borderRadius: BorderRadius.circular(13),
        border:       Border.all(color: c.cardBorder, width: 0.8),
      ),
      child: Column(children: [
        Row(children: [
          Container(
            width: 42, height: 42,
            decoration: const BoxDecoration(
                color: Color(0xFFFAEEDA), shape: BoxShape.circle),
            alignment: Alignment.center,
            child: Text(initials,
                style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF854F0B))),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              if (name.isNotEmpty)
                Text(name,
                    style: TextStyle(
                        fontSize: 14.5, fontWeight: FontWeight.w700,
                        color: c.textMain)),
              if (job.flightOrShip != null && job.flightOrShip!.isNotEmpty)
                Row(children: [
                  Icon(Icons.flight_land_rounded,
                      size: 14, color: c.textFaint),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(job.flightOrShip!,
                        style: TextStyle(
                            fontSize: 12, color: c.textFaint)),
                  ),
                ])
              else if (phone.isNotEmpty)
                Text(phone,
                    style: TextStyle(
                        fontSize: 12, color: c.textFaint)),
            ]),
          ),
          if (phone.isNotEmpty) ...[
            roundBtn(
              icon: Icons.phone_rounded,
              bg: const Color(0xFFEAF3DE),
              fg: const Color(0xFF3B6D11),
              tooltip: 'Κλήση',
              onTap: () {
                final clean = phone.replaceAll(RegExp(r'\s+'), '');
                launch(Uri(scheme: 'tel', path: clean));
              },
            ),
            const SizedBox(width: 7),
            roundBtn(
              override: const FaIcon(FontAwesomeIcons.whatsapp,
                  size: 18, color: Color(0xFF0F6E56)),
              bg: const Color(0xFFE1F5EE),
              fg: const Color(0xFF0F6E56),
              tooltip: 'WhatsApp',
              onTap: () {
                final clean = phone.replaceAll(RegExp(r'\s+'), '');
                final wa = clean.startsWith('+') ? clean.substring(1) : clean;
                launch(Uri.parse('https://wa.me/$wa'), external: true);
              },
            ),
          ],
          if (email.isNotEmpty) ...[
            const SizedBox(width: 7),
            roundBtn(
              icon: Icons.email_rounded,
              bg: const Color(0xFFFAECE7),
              fg: const Color(0xFF993C1D),
              tooltip: 'Email',
              onTap: () => launch(Uri(scheme: 'mailto', path: email.trim())),
            ),
          ],
        ]),
        // Τηλέφωνο σε δική του γραμμή όταν πάνω δείχνουμε πτήση
        if (phone.isNotEmpty &&
            job.flightOrShip != null && job.flightOrShip!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(children: [
              Icon(Icons.phone_iphone_rounded,
                  size: 14, color: c.textFaint),
              const SizedBox(width: 6),
              Text(phone,
                  style: TextStyle(
                      fontSize: 12.5, color: c.textFaint)),
            ]),
          ),
      ]),
    );
  }

  // ─── 4) Chips λεπτομερειών ────────────────────────────────────────────────
  Widget _detailChips(BuildContext context) {
    final c = AppColors.of(context);
    Widget chip(IconData icon, String label,
            {Color? bg, Color? fg, Color? borderCol}) =>
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color:        bg ?? c.card,
            border:       Border.all(
                color: borderCol ?? c.cardBorder, width: 0.8),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 15, color: fg ?? c.textMain),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: fg ?? c.textMain)),
          ]),
        );

    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(spacing: 6, runSpacing: 6, children: [
        chip(Icons.person_rounded,
            '${job.persons} άτομ${job.persons == 1 ? "ο" : "α"}'),
        chip(Icons.luggage_rounded, '${job.luggage} βαλίτσες'),
        if (job.childSeatCount > 0)
          chip(Icons.child_care_rounded,
              '${job.childSeatCount} κάθισμα'
              '${job.childSeatPrice > 0 ? " (+${(job.childSeatCount * job.childSeatPrice).toStringAsFixed(0)}€)" : ""}',
              bg: const Color(0xFFFBEAF0),
              fg: const Color(0xFF993556),
              borderCol: const Color(0xFFF4C0D1)),
      ]),
    );
  }

  // ─── 5) Κάρτα διαδρομής — ΔΥΟ κουμπιά πλοήγησης (Παραλαβή & Προορισμός) ──
  Widget _routeCard(BuildContext context) {
    Widget navBtn(Color bg, Color fg, double? lat, double? lng) {
      if (lat == null || lng == null) return const SizedBox(width: 40);
      return InkWell(
        onTap: () => _openInMaps(lat, lng),
        customBorder: const CircleBorder(),
        child: Container(
          width: 40, height: 40,
          decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
          alignment: Alignment.center,
          child: Icon(Icons.navigation_rounded, size: 19, color: fg),
        ),
      );
    }

    final routeMin = job.routeMinutes;

    final c = AppColors.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color:        c.card,
        borderRadius: BorderRadius.circular(13),
        border:       Border.all(color: c.cardBorder, width: 0.8),
      ),
      child: Column(children: [
        // Παραλαβή
        Row(children: [
          const Icon(Icons.trip_origin_rounded,
              size: 17, color: Color(0xFF185FA5)),
          const SizedBox(width: 9),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Text('Παραλαβή',
                  style: TextStyle(fontSize: 11, color: c.textFaint)),
              Text(job.from,
                  style: TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600,
                      color: c.textMain)),
            ]),
          ),
          const SizedBox(width: 6),
          navBtn(const Color(0xFFE6F1FB), const Color(0xFF185FA5),
              job.fromLat, job.fromLng),
        ]),
        // Κάθετη γραμμή σύνδεσης
        Row(children: [
          Padding(
            padding: const EdgeInsets.only(left: 7.5),
            child: Container(width: 1.5, height: 14, color: c.divider),
          ),
        ]),
        // Προορισμός
        Row(children: [
          const Icon(Icons.place_rounded,
              size: 17, color: Color(0xFF993C1D)),
          const SizedBox(width: 9),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Text('Προορισμός${routeMin != null ? " · ~$routeMin λεπτά" : ""}',
                  style: TextStyle(fontSize: 11, color: c.textFaint)),
              Text(job.to,
                  style: TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600,
                      color: c.textMain)),
            ]),
          ),
          const SizedBox(width: 6),
          navBtn(const Color(0xFFFAECE7), const Color(0xFF993C1D),
              job.toLat, job.toLng),
        ]),
      ]),
    );
  }

  // ─── Outline pill κουμπί (Πινακίδα ονόματος / Στο ημερολόγιο) ─────────────
  Widget _pillButton(BuildContext context, {
    required IconData icon,
    required String   label,
    required VoidCallback onTap,
  }) {
    final c = AppColors.of(context);
    // Ίδιο ύψος/γεωμετρία με το «Στο ημερολόγιο» δίπλα του (48px,
    // ακτίνα 14) — Row με explicit spacing αντί για .icon() ώστε η
    // στοίχιση εικονιδίου/κειμένου να είναι πανομοιότυπη και στα δύο.
    return SizedBox(
      height: 48,
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          foregroundColor: c.textMain,
          side: BorderSide(color: c.cardBorder, width: 0.8),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: c.textMain),
            const SizedBox(width: 8),
            Flexible(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600,
                      color: c.textMain)),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Πλοήγηση στο Google Maps ────────────────────────────────────────────
  Future<void> _openInMaps(double lat, double lng) async {
    final nativeUri = Uri.parse('google.navigation:q=$lat,$lng&mode=d');
    if (await canLaunchUrl(nativeUri)) {
      await launchUrl(nativeUri, mode: LaunchMode.externalApplication);
      return;
    }
    final webUri = Uri.parse(
      'https://www.google.com/maps/dir/?api=1'
      '&destination=$lat,$lng&travelmode=driving',
    );
    if (await canLaunchUrl(webUri)) {
      await launchUrl(webUri, mode: LaunchMode.externalApplication);
    }
  }

  // ─── Banner κατάστασης ανοιχτής δουλειάς (αμετάβλητο) ───────────────────
  Widget _openStatusBanner() {
    final Color    color;
    final IconData icon;
    final String   title;
    String         subtitle;

    if (job.isBoarded) {
      color    = const Color(0xFF1E8E3E);
      icon     = Icons.directions_car_rounded;
      title    = 'Παρελήφθη από ${job.takenByName ?? 'οδηγό'}';
      subtitle = 'Ο πελάτης έχει επιβιβαστεί';
    } else if (job.isTaken) {
      color    = Colors.orange.shade800;
      icon     = Icons.check_circle_rounded;
      title    = 'Ανελήφθη από ${job.takenByName ?? 'οδηγό'}';
      subtitle = 'Σε αναμονή επιβίβασης';
    } else if (job.stopped) {
      color    = Colors.grey.shade700;
      icon     = Icons.stop_circle_rounded;
      title    = 'Σταματημένη';
      subtitle = 'Δεν χτυπάει πλέον σε οδηγούς';
    } else if (job.isPastDeadline) {
      color    = Colors.grey.shade600;
      icon     = Icons.timer_off_rounded;
      title    = 'Έληξε ο χρόνος';
      subtitle = 'Δεν την ανέλαβε κανείς';
    } else {
      color    = Colors.red.shade600;
      icon     = Icons.hourglass_top_rounded;
      title    = 'Ανοιχτή — σε αναμονή';
      subtitle = 'Δεν την έχει αναλάβει κανείς ακόμα';
    }

    // Ώρα ανάληψης, αν υπάρχει
    final takenLabel = job.takenAt != null
        ? DateFormat('dd/MM  HH:mm').format(job.takenAt!)
        : null;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:        color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
        border:       Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(children: [
        Icon(icon, color: color, size: 26),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(
                fontSize: 15, fontWeight: FontWeight.bold, color: color)),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(subtitle, style: TextStyle(
                  fontSize: 12, color: color.withValues(alpha: 0.85))),
            ),
            if (takenLabel != null && (job.isTaken || job.isBoarded))
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('Ανάληψη: $takenLabel', style: TextStyle(
                    fontSize: 11.5, color: Colors.grey[600])),
              ),
          ]),
        ),
      ]),
    );
  }

}

// ─── Phone button helper ──────────────────────────────────────────────────────

Widget phoneBtn({
  required BuildContext context,
  IconData?             icon,
  Widget?               iconOverride,
  required Color        color,
  required String       tooltip,
  required VoidCallback onTap,
}) =>
    Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color:        color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: iconOverride ?? Icon(icon, size: 20, color: color),
        ),
      ),
    );

// ─── Κουμπί «Προσθήκη στο ημερολόγιο» για ΜΙΑ δουλειά ─────────────────────────
class _JobToCalendarButton extends StatefulWidget {
  final Job job;
  const _JobToCalendarButton({required this.job});
  @override
  State<_JobToCalendarButton> createState() => _JobToCalendarButtonState();
}

class _JobToCalendarButtonState extends State<_JobToCalendarButton> {
  bool _busy = false;
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

  Future<void> _run() async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await IcsExportService.exportJob(widget.job);
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok
            ? 'Άνοιγμα ημερολογίου'
            : 'Δεν ήταν δυνατό το άνοιγμα του ημερολογίου'),
        backgroundColor:
            ok ? const Color(0xFF1A73E8) : Colors.red.shade700,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_allowed) return const SizedBox.shrink();
    // Ίδιο ύψος/γεωμετρία με το «Πινακίδα ονόματος» δίπλα του (48px,
    // ακτίνα 14) — Row κεντραρισμένη με explicit spacing, ίδια στοίχιση
    // εικονιδίου/κειμένου και στα δύο κουμπιά.
    return SizedBox(
      height: 48,
      width: double.infinity,
      child: FilledButton(
        onPressed: _busy ? null : _run,
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF1A73E8),
          disabledBackgroundColor: const Color(0xFF1A73E8),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            _busy
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.calendar_month_rounded, size: 18),
            const SizedBox(width: 8),
            const Flexible(
              child: Text('Προσθήκη στο ημερολόγιο',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  Στάσεις ομαδικής μεταφοράς (Shuttle/Λεωφορείο) στο Job Details.
//  Σειρά: κατά ζώνη/θέση καταλύματος — ΑΥΞΟΥΣΑ όταν το κοινό σημείο είναι
//  ο ΠΡΟΟΡΙΣΜΟΣ (μαζεύουμε), ΦΘΙΝΟΥΣΑ όταν είναι η ΑΦΕΤΗΡΙΑ (αφήνουμε —
//  το μικρότερο νούμερο περνάει ΤΕΛΕΥΤΑΙΟ). Χωρίς θέση → στο τέλος.
//  Κάθε στάση: βελάκι πλοήγησης στη διεύθυνσή της. Κάθε κράτηση: κλήση,
//  WhatsApp, email, τιμή στο τέλος, και τσεκ «παρελήφθη» (γράφεται στο doc
//  της δουλειάς: stopDone.<index>).
// ═══════════════════════════════════════════════════════════════════════
class GroupStopsSection extends StatefulWidget {
  final Job job;
  const GroupStopsSection({super.key, required this.job});

  @override
  State<GroupStopsSection> createState() => _GroupStopsSectionState();
}

class _GroupStopsSectionState extends State<GroupStopsSection> {
  late Map<String, bool> _done; // key: original index ως string

  @override
  void initState() {
    super.initState();
    _done = {};
  }

  Future<void> _toggleDone(int originalIndex, bool v) async {
    setState(() => _done['$originalIndex'] = v);
    try {
      await FirebaseFirestore.instance
          .collection('jobs')
          .doc(widget.job.id)
          .set({'stopDone': {'$originalIndex': v}}, SetOptions(merge: true));
    } catch (_) {}
  }

  Future<void> _launch(Uri uri, {bool external = false}) async {
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri,
            mode: external
                ? LaunchMode.externalApplication
                : LaunchMode.platformDefault);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    if (!job.isShuttleContainer || job.shuttleStops.isEmpty) {
      return const SizedBox.shrink();
    }
    final ascending = !job.shuttleSharedIsPickup; // κοινό=προορισμός → αύξουσα
    // (index, map) για να κρατάμε το original index (τσεκ ανά στάση)
    final entries = List.generate(
        job.shuttleStops.length, (i) => (i, job.shuttleStops[i]));
    int orderOf(Map<String, dynamic> m) =>
        (m['orderInZone'] as num?)?.toInt() ?? 1 << 20; // χωρίς θέση → τέλος
    entries.sort((a, b) {
      final za = (a.$2['zoneName'] as String?) ?? '\uFFFF';
      final zb = (b.$2['zoneName'] as String?) ?? '\uFFFF';
      final zc = za.compareTo(zb);
      if (zc != 0) return zc;
      final oc = orderOf(a.$2).compareTo(orderOf(b.$2));
      return ascending ? oc : -oc;
    });

    Widget iconBtn(IconData ic, Color c, VoidCallback onTap,
            {Widget? override}) =>
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.all(5),
            child: override ?? Icon(ic, size: 19, color: c),
          ),
        );

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 14),
      Row(children: [
        Icon(Icons.directions_bus_rounded,
            size: 18, color: Colors.amber.shade800),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
              '${job.vehicleType == 'bus' ? 'Λεωφορείο' : 'Shuttle'} · '
              '${job.shuttleStops.length} κρατήσεις — '
              '${ascending ? 'παίρνεις με σειρά' : 'αφήνεις με σειρά'}:',
              style: const TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 14)),
        ),
      ]),
      if (job.childSeatCount > 0)
        Padding(
          padding: const EdgeInsets.only(top: 2, left: 24),
          child: Text(
              '🍼 Σύνολο παιδικά καθίσματα: ${job.childSeatCount}',
              style: TextStyle(
                  fontSize: 12.5, color: Colors.orange.shade800,
                  fontWeight: FontWeight.w600)),
        ),
      const SizedBox(height: 6),
      for (int k = 0; k < entries.length; k++) ...[
        Builder(builder: (_) {
          final origIdx = entries[k].$1;
          final m = entries[k].$2;
          final name = (m['name'] as String?) ?? '';
          final addr = (m['address'] as String?) ?? '';
          final zone = m['zoneName'] as String?;
          final ord = (m['orderInZone'] as num?)?.toInt();
          final phone = (m['phone'] as String?)?.trim();
          final email = (m['email'] as String?)?.trim();
          final price = (m['price'] as num?)?.toDouble() ?? 0;
          final persons = (m['persons'] as num?)?.toInt() ?? 1;
          final childSeats = (m['childSeatCount'] as num?)?.toInt() ?? 0;
          final note = (m['note'] as String?)?.trim();
          final lat = (m['lat'] as num?)?.toDouble();
          final lng = (m['lng'] as num?)?.toDouble();
          final done = _done['$origIdx'] == true;
          return Builder(builder: (context) {
            final c = AppColors.of(context);
            return Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.divider)),
            ),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Γραμμή καταλύματος: αρίθμηση σειράς + διεύθυνση + πλοήγηση
                  Row(children: [
                    Container(
                      width: 24, height: 24, alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: Colors.amber.shade100,
                        shape: BoxShape.circle,
                      ),
                      child: Text('${k + 1}',
                          style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.bold,
                              color: Colors.amber.shade900)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                          addr +
                              (zone != null
                                  ? '  ·  $zone${ord != null ? ' #$ord' : ''}'
                                  : ''),
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600)),
                    ),
                    iconBtn(Icons.navigation_rounded, const Color(0xFF185FA5),
                        () {
                      final dest = (lat != null && lng != null)
                          ? '$lat,$lng'
                          : Uri.encodeComponent(addr);
                      _launch(
                          Uri.parse(
                              'https://www.google.com/maps/dir/?api=1&destination=$dest'),
                          external: true);
                    }),
                  ]),
                  // Γραμμή κράτησης: όνομα/άτομα + επικοινωνία + κενό + τιμή
                  Padding(
                    padding: const EdgeInsets.only(left: 32, top: 2),
                    child: Row(children: [
                      Checkbox(
                        value: done,
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                        onChanged: (v) => _toggleDone(origIdx, v == true),
                      ),
                      Expanded(
                        child: Text(
                            '${name.isNotEmpty ? name : '(χωρίς όνομα)'} · $persons άτομ${persons == 1 ? 'ο' : 'α'}'
                            '${childSeats > 0 ? ' · 🍼×$childSeats' : ''}'
                            '${note != null && note.isNotEmpty ? '\n$note' : ''}',
                            style: TextStyle(
                                fontSize: 13,
                                decoration: done
                                    ? TextDecoration.lineThrough
                                    : null,
                                color: done ? Colors.grey : null)),
                      ),
                      if (phone != null && phone.isNotEmpty) ...[
                        iconBtn(Icons.phone_rounded, Colors.blue, () {
                          final clean =
                              phone.replaceAll(RegExp(r'\s+'), '');
                          _launch(Uri(scheme: 'tel', path: clean));
                        }),
                        iconBtn(Icons.circle, const Color(0xFF25D366), () {
                          final clean =
                              phone.replaceAll(RegExp(r'\s+'), '');
                          final wa = clean.startsWith('+')
                              ? clean.substring(1) : clean;
                          _launch(Uri.parse('https://wa.me/$wa'),
                              external: true);
                        },
                            override: const FaIcon(
                                FontAwesomeIcons.whatsapp,
                                size: 19, color: Color(0xFF25D366))),
                      ],
                      if (email != null && email.isNotEmpty)
                        iconBtn(Icons.email_rounded, Colors.orange, () {
                          _launch(Uri(scheme: 'mailto', path: email));
                        }),
                      const SizedBox(width: 12),
                      Text('${price.toStringAsFixed(0)} €',
                          style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF0F6E56))),
                    ]),
                  ),
                ]),
          );
            });
        }),
      ],
    ]);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// FULL-SCREEN «ΤΑΜΠΕΛΑ ΑΕΡΟΔΡΟΜΙΟΥ» — μαύρο φόντο, τεράστια άσπρα γράμματα.
// • Immersive: κρύβει status bar (ώρα/μπαταρία) ΚΑΙ navigation bar (πίσω/Home).
// • Κάθε λέξη του ονόματος σε δική της γραμμή → μέγιστο δυνατό μέγεθος
//   γραμματοσειράς, αυτόματα ανάλογα με το μήκος ονόματος/επωνύμου.
// • Άγγιγμα οθόνης → εμφανίζεται X πάνω-δεξιά για 3 δευτερόλεπτα· μετά
//   ξανακρύβεται μέχρι το επόμενο άγγιγμα. Το X κλείνει την οθόνη.
// ─────────────────────────────────────────────────────────────────────────────

class NameSignScreen extends StatefulWidget {
  final String name;
  const NameSignScreen({super.key, required this.name});

  @override
  State<NameSignScreen> createState() => _NameSignScreenState();
}

class _NameSignScreenState extends State<NameSignScreen> {
  bool _showClose = false;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    // Πλήρες immersive: ούτε ώρα/μπαταρία πάνω, ούτε πίσω/Home κάτω.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    // Πάντα landscape — χωράει πιο εύκολα μεγάλα ονοματεπώνυμα.
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    // Επαναφορά system bars: manual (ούτε επιβάλλουμε edgeToEdge, ώστε να
    // μην αφήνει ενδεχομένως λευκή γραμμή nav-bar σε ορισμένες συσκευές
    // Android) ΚΑΙ ελεύθερου orientation, όταν κλείσει η ταμπέλα.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  void _onScreenTap() {
    setState(() => _showClose = true);
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showClose = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Κάθε λέξη (όνομα/επώνυμο) σε ΔΙΚΗ ΤΗΣ γραμμή. Κάθε γραμμή μπαίνει σε
    // FittedBox με scale-down-only και ΕΝΑ Text χωρίς αναδίπλωση (softWrap:
    // false) — έτσι δεν κόβεται ΠΟΤΕ κανένα γράμμα: το FittedBox σμικρύνει
    // όσο χρειάζεται ώστε ολόκληρη η λέξη να χωράει στο πλάτος της οθόνης.
    final words = widget.name.trim().split(RegExp(r'\s+'));
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _onScreenTap,
        child: Stack(children: [
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final w in words)
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          w,
                          softWrap: false,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                            fontSize: 240, // βάση — το FittedBox τη σμικρύνει
                            height: 1.0,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (_showClose)
            Positioned(
              top: 18,
              right: 18,
              child: GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: const BoxDecoration(
                    color: Colors.white24,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close_rounded,
                      color: Colors.white, size: 34),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}
