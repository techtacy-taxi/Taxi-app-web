// lib/jobs/job_details_sheet.dart
// Sheet λεπτομερειών δουλειάς — ανοίγει από "Λεπτομέρειες" στο MyJobTile

import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:vibration/vibration.dart';
import 'job_shared_widgets.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'job_model.dart';
import 'job_service.dart';
import 'saved_job_service.dart';
import 'ics_export_service.dart';
import 'ics_access.dart';
import 'job_map_distance.dart';

// ─────────────────────────────────────────────────────────────────────────────
// ΚΟΙΝΗ ΡΟΗ «ΤΕΛΟΣ ΔΙΑΔΡΟΜΗΣ» (+ προαιρετική ΕΠΙΣΤΡΟΦΗ)
// Χρησιμοποιείται και από το JobDetailsSheet και από το MyJobTile.
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

  @override
  Widget build(BuildContext context) {
    final schedLabel = job.scheduledAt != null
        ? DateFormat('dd/MM/yyyy  HH:mm').format(job.scheduledAt!)
        : null;

    return Container(
      decoration: const BoxDecoration(
        color:        Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: EdgeInsets.fromLTRB(
          20, 12, 20, 20 + MediaQuery.of(context).padding.bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [

          // Drag handle
          const SheetHandle(bottomMargin: 16),

          // Ομαδική μεταφορά: στάσεις/κρατήσεις με σειρά, πλοήγηση,
          // επικοινωνία, τιμές και τσεκ παραλαβής.
          GroupStopsSection(job: job),

          // Header υπενθύμισης (αν δοθεί)
          if (headerLabel != null) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(
                color: Colors.deepOrange,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                const Icon(Icons.alarm_rounded, color: Colors.white, size: 24),
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

          // Banner ραντεβού
          if (schedLabel != null) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(
                color: Colors.blue.shade700,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(children: [
                const Icon(Icons.alarm_rounded, color: Colors.white, size: 24),
                const SizedBox(width: 10),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('ΡΑΝΤΕΒΟΥ', style: TextStyle(
                      color: Colors.white, fontSize: 11,
                      fontWeight: FontWeight.w900, letterSpacing: 1.4)),
                  Text(schedLabel, style: const TextStyle(
                      color: Colors.white, fontSize: 17,
                      fontWeight: FontWeight.bold)),
                ]),
              ]),
            ),
          ],

          // Banner κατάστασης ανάθεσης — μόνο για ανοιχτές δουλειές
          if (openJobMode) ...[
            _openStatusBanner(),
            const SizedBox(height: 14),
          ],

          // ── Μπάρα «ΠΡΟΠΛΗΡΩΜΕΝΗ» — μόνο για πλήρη πληρωμή (online ή
          // χειροκίνητη). Ίδιο στυλ με τη μπλε μπάρα «Ραντεβού» παρακάτω.
          if (job.fullyPaid) ...[
            BlinkingBox(
              child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFD97757),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.warning_amber_rounded, color: Colors.white, size: 18),
                SizedBox(width: 8),
                Text('ΠΡΟΠΛΗΡΩΜΕΝΗ — ΔΕΝ ΕΙΣΠΡΑΤΤΕΙΣ ΤΙΠΟΤΑ', style: TextStyle(
                    color: Colors.white, fontSize: 12.5,
                    fontWeight: FontWeight.w900, letterSpacing: .5)),
              ]),
              ),
            ),
          ],

          // ── Τιμή / είσπραξη — ΠΡΩΤΑ, πλήρους πλάτους, ξεκάθαρη διατύπωση ──
          // (Το job.price είναι ΗΔΗ η καθαρή τιμή μετά την προκαταβολή — ΔΕΝ
          // αφαιρείται τίποτα άλλο. Το γράφουμε ρητά ώστε να μην μπερδεύεται
          // με «υπόλοιπο ΜΕΙΟΝ προκαταβολή».)
          job.depositPaid
              ? BlinkingBox(child: _buildMoneyBox(job))
              : _buildMoneyBox(job),
          const SizedBox(height: 12),

          // ── Διαδρομή — ΜΕΤΑ την τιμή, πλήρους πλάτους (όχι στριμωγμένη) ──
          _navBox(
            context: context,
            pinIcon: Icons.trip_origin_rounded,
            pinColor: Colors.amber.shade700,
            label: job.from,
            lat:   job.fromLat,
            lng:   job.fromLng,
          ),
          const SizedBox(height: 8),
          _navBox(
            context: context,
            pinIcon: Icons.place_rounded,
            pinColor: Colors.red,
            label: job.to,
            lat:   job.toLat,
            lng:   job.toLng,
          ),
          const SizedBox(height: 16),
          Divider(color: Colors.grey[200]),
          const SizedBox(height: 8),

          // ── Χάρτης + απόσταση από σένα (ίδιο με το popup «Νέα Δουλειά»),
          // ξαναϋπολογίζεται φρέσκια κάθε φορά που ανοίγει αυτή η κάρτα.
          JobMapDistanceCard(job: job),
          const SizedBox(height: 14),

          // Info cells
          Wrap(spacing: 8, runSpacing: 8, children: [
            _dCell(Icons.person_rounded,    'Άτομα',    '${job.persons}'),
            _dCell(Icons.luggage_rounded,   'Βαλίτσες', '${job.luggage}'),
            _dCell(job.vehicleType == 'van'
                ? Icons.airport_shuttle_rounded : Icons.local_taxi_rounded,
                'Όχημα', job.vehicleLabel),
            if (job.childSeatCount > 0)
              _dCell(Icons.child_care_rounded, 'Παιδικά καθίσματα',
                  '${job.childSeatCount}'
                  '${job.childSeatPrice > 0
                      ? ' (${(job.childSeatCount * job.childSeatPrice)
                          .toStringAsFixed(2)}€)'
                      : ''}'),
            if (job.flightOrShip != null && job.flightOrShip!.isNotEmpty)
              _dCell(Icons.flight_rounded, 'Πτήση/Πλοίο', job.flightOrShip!),
          ]),

          // Στοιχεία πελάτη
          if ((job.clientName != null && job.clientName!.isNotEmpty) ||
              (job.clientPhone != null && job.clientPhone!.isNotEmpty) ||
              (job.clientEmail != null && job.clientEmail!.isNotEmpty)) ...[
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color:        Colors.amber.shade50,
                borderRadius: BorderRadius.circular(14),
                border:       Border.all(color: Colors.amber.shade200),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (job.clientName != null && job.clientName!.isNotEmpty) ...[
                    Row(children: [
                      Icon(Icons.badge_rounded,
                          size: 18, color: Colors.amber.shade800),
                      const SizedBox(width: 8),
                      Text(job.clientName!, style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.bold)),
                    ]),
                  ],
                  if (job.clientPhone != null && job.clientPhone!.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Row(children: [
                      Icon(Icons.phone_iphone_rounded,
                          size: 18, color: Colors.amber.shade800),
                      const SizedBox(width: 8),
                      Expanded(child: Text(job.clientPhone!,
                          style: const TextStyle(fontSize: 15))),
                      phoneBtn(
                        context: context,
                        icon: Icons.phone_rounded,
                        color: Colors.blue,
                        tooltip: 'Κλήση',
                        onTap: () async {
                          final clean = job.clientPhone!
                              .replaceAll(RegExp(r'\s+'), '');
                          final uri = Uri(scheme: 'tel', path: clean);
                          if (await canLaunchUrl(uri)) await launchUrl(uri);
                        },
                      ),
                      const SizedBox(width: 8),
                      phoneBtn(
                        context: context,
                        iconOverride: const FaIcon(FontAwesomeIcons.whatsapp,
                            size: 20, color: Color(0xFF25D366)),
                        color: const Color(0xFF25D366),
                        tooltip: 'WhatsApp',
                        onTap: () async {
                          final clean = job.clientPhone!
                              .replaceAll(RegExp(r'\s+'), '');
                          final waNumber = clean.startsWith('+')
                              ? clean.substring(1) : clean;
                          final uri = Uri.parse('https://wa.me/$waNumber');
                          if (await canLaunchUrl(uri)) {
                            await launchUrl(uri,
                                mode: LaunchMode.externalApplication);
                          }
                        },
                      ),
                    ]),
                  ],
                  if (job.clientEmail != null && job.clientEmail!.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Row(children: [
                      Icon(Icons.email_rounded,
                          size: 18, color: Colors.amber.shade800),
                      const SizedBox(width: 8),
                      Expanded(child: Text(job.clientEmail!,
                          style: const TextStyle(fontSize: 15))),
                      phoneBtn(
                        context: context,
                        icon: Icons.send_rounded,
                        color: Colors.deepOrange,
                        tooltip: 'Email',
                        onTap: () async {
                          final addr = job.clientEmail!.trim();
                          final uri = Uri(scheme: 'mailto', path: addr);
                          if (await canLaunchUrl(uri)) {
                            await launchUrl(uri,
                                mode: LaunchMode.externalApplication);
                          }
                        },
                      ),
                    ]),
                  ],
                ],
              ),
            ),
          ],

          // Σημειώσεις
          if (job.note != null && job.note!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                  color: Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.grey.shade200)),
              child: Row(children: [
                Icon(Icons.notes_rounded, size: 14, color: Colors.grey[600]),
                const SizedBox(width: 8),
                Expanded(child: Text(job.note!, style: TextStyle(
                    fontSize: 13, color: Colors.grey[700]))),
              ]),
            ),
          ],

          const SizedBox(height: 20),

          // Στοιχεία ιστορικού: ποιος δημιούργησε & ποιος εκτέλεσε
          if (historyMode) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (job.createdByName.isNotEmpty)
                    Row(children: [
                      Icon(Icons.person_add_alt_rounded,
                          size: 16, color: Colors.grey[600]),
                      const SizedBox(width: 8),
                      Expanded(child: Text(
                          'Δημιουργήθηκε από: ${job.createdByName}',
                          style: TextStyle(fontSize: 13, color: Colors.grey[800]))),
                    ]),
                  if (job.createdByName.isNotEmpty &&
                      (job.takenByName ?? '').isNotEmpty)
                    const SizedBox(height: 6),
                  if ((job.takenByName ?? '').isNotEmpty)
                    Row(children: [
                      Icon(Icons.local_taxi_rounded,
                          size: 16, color: Colors.grey[600]),
                      const SizedBox(width: 8),
                      Expanded(child: Text(
                          'Εκτελέστηκε από: ${job.takenByName}',
                          style: TextStyle(fontSize: 13, color: Colors.grey[800]))),
                    ]),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          // Κουμπί «Παρέλαβα» — όσο είναι taken (όχι ακόμα boarded)
          if (!hideComplete && job.isTaken) ...[
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => _markBoarded(context),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.orange.shade800,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                icon:  const Icon(Icons.directions_car_rounded),
                label: const Text('Παρέλαβα',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 10),
          ],

          // Κουμπί «Προσθήκη στο ημερολόγιο» — για αυτή τη δουλειά
          if (!historyMode) ...[
            _JobToCalendarButton(job: job),
            const SizedBox(height: 10),
          ],

          // Κουμπί ολοκλήρωσης — κρύβεται στην υπενθύμιση ραντεβού
          if (!hideComplete)
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => _confirmComplete(context),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF1E8E3E),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                icon:  const Icon(Icons.check_rounded),
                label: const Text('Ολοκλήρωση Δουλειάς',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              ),
            ),
        ]),
      ),
    );
  }

  // ─── Πλοήγηση στο Google Maps ────────────────────────────────────────────

  /// Ανοίγει το Google Maps σε mode πλοήγησης προς [lat,lng].
  /// Δοκιμάζει πρώτα το native intent (google.navigation:) και αν δεν
  /// υπάρχει εφαρμογή, ανοίγει το web URL.
  Future<void> _openInMaps(double lat, double lng) async {
    // Native Google Maps — ανοίγει απευθείας σε πλοήγηση
    final nativeUri = Uri.parse('google.navigation:q=$lat,$lng&mode=d');
    if (await canLaunchUrl(nativeUri)) {
      await launchUrl(nativeUri, mode: LaunchMode.externalApplication);
      return;
    }
    // Fallback: web URL (λειτουργεί και χωρίς Google Maps app)
    final webUri = Uri.parse(
      'https://www.google.com/maps/dir/?api=1'
      '&destination=$lat,$lng&travelmode=driving',
    );
    if (await canLaunchUrl(webUri)) {
      await launchUrl(webUri, mode: LaunchMode.externalApplication);
    }
  }

  /// Πλαίσιο-κουμπί διεύθυνσης: pin στην αρχή, μαύρο κείμενο, εικονίδιο
  /// πλοήγησης. Το πλαίσιο μεγαλώνει με το κείμενο. Πατώντας το, ανοίγει
  /// εξωτερική εφαρμογή πλοήγησης (Google Maps / Waze).
  Widget _navBox({
    required BuildContext context,
    required IconData pinIcon,
    required Color    pinColor,
    required String   label,
    required double?  lat,
    required double?  lng,
  }) {
    final hasCoords = lat != null && lng != null;

    final content = Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: pinColor.withValues(alpha: 0.55), width: 1.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(pinIcon, color: pinColor, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontSize:   16,
                fontWeight: FontWeight.w600,
                color:      Colors.black87,
              ),
            ),
          ),
          if (hasCoords) ...[
            const SizedBox(width: 8),
            Icon(Icons.navigation_rounded, size: 22, color: pinColor),
          ],
        ],
      ),
    );

    if (!hasCoords) return content;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap:        () => _openInMaps(lat, lng),
        borderRadius: BorderRadius.circular(12),
        child:        content,
      ),
    );
  }

  /// Κείμενο διεύθυνσης — αν η δουλειά έχει συντεταγμένες (νέα φόρμα)
  /// γίνεται tappable και ανοίγει Google Maps για πλοήγηση.
  // ignore: unused_element
  Widget _navText({
    required BuildContext context,
    required String  label,
    required double? lat,
    required double? lng,
  }) {
    final hasCoords = lat != null && lng != null;

    if (!hasCoords) {
      return Text(label,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600));
    }

    return InkWell(
      onTap:        () => _openInMaps(lat, lng),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize:       16,
                  fontWeight:     FontWeight.w600,
                  decoration:     TextDecoration.underline,
                  decorationStyle: TextDecorationStyle.dotted,
                  color:          Color(0xFF1565C0),
                ),
              ),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.navigation_rounded,
                size: 16, color: Color(0xFF1565C0)),
          ],
        ),
      ),
    );
  }

  // ─── Κουτί τιμής/είσπραξης/κέρδους — εξαγμένο ώστε να μπορεί να τυλιχτεί
  // σε BlinkingBox όταν υπάρχει προπληρωμή (depositPaid), για να μην μπερδέψει
  // ποτέ ο οδηγός πόσα να πάρει από τον πελάτη.
  Widget _buildMoneyBox(Job job) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(job.fullyPaid ? 'Πληρώθηκε online — μηδέν είσπραξη' : 'Να εισπράξεις',
                style: TextStyle(fontSize: 12, color: Colors.grey[600], fontWeight: FontWeight.w600)),
            Text('${job.price.toStringAsFixed(2)}€', style: const TextStyle(
                fontSize: 24, fontWeight: FontWeight.bold, color: Color(0xFF1E8E3E))),
            if (job.depositPaid)
              Text(job.fullyPaid
                   ? 'Ο πελάτης πλήρωσε ήδη ΟΛΟΚΛΗΡΗ την τιμή (${job.depositAmount.toStringAsFixed(2)}€) online στον master.'
                   : 'Ο πελάτης πλήρωσε ήδη ${job.depositAmount.toStringAsFixed(2)}€ προκαταβολή online στον master — δεν αφαιρείται από το ποσό πάνω, είναι ήδη υπολογισμένη.',
                  style: TextStyle(fontSize: 11, color: Colors.blue.shade700)),
          ]),
        ),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          if (job.commission > 0)
            Text('-${job.commission.toStringAsFixed(2)}€ γιαούρτι',
                style: TextStyle(fontSize: 12,
                    color: Colors.red.shade700, fontWeight: FontWeight.w600)),
          if (job.appCommission > 0)
            Text('-${job.appCommission.toStringAsFixed(2)}€ app',
                style: TextStyle(fontSize: 12,
                    color: Colors.indigo.shade700, fontWeight: FontWeight.w600)),
          Text('Κέρδος: ${job.driverEarning.toStringAsFixed(2)}€',
              style: const TextStyle(fontSize: 14,
                  fontWeight: FontWeight.bold, color: Colors.purple)),
        ]),
      ]),
    );
  }

  // ─── Banner κατάστασης ανοιχτής δουλειάς ────────────────────────────────────
  // Δείχνει ποιος ανέλαβε τη δουλειά, αν επιβιβάστηκε ο πελάτης, ή ότι είναι
  // ακόμη σε αναμονή / σταματημένη.
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

  Widget _dCell(IconData icon, String label, String value) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color:        Colors.grey.shade50,
      borderRadius: BorderRadius.circular(10),
      border:       Border.all(color: Colors.grey.shade200),
    ),
    child: Column(children: [
      Icon(icon, size: 16, color: Colors.grey[600]),
      const SizedBox(height: 4),
      Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
      Text(label, style: TextStyle(fontSize: 10, color: Colors.grey[500])),
    ]),
  );
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
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: _busy ? null : _run,
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF1A73E8),
          disabledBackgroundColor: const Color(0xFF1A73E8),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14)),
        ),
        icon: _busy
            ? const SizedBox(width: 18, height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white))
            : const Icon(Icons.calendar_month_rounded),
        label: const Text('Προσθήκη στο ημερολόγιο',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
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
          return Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              border: Border(
                  bottom: BorderSide(color: Colors.grey.shade200)),
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
        }),
      ],
    ]);
  }
}
