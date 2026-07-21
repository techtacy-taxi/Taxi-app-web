// lib/calendar/ics_calendar_export.dart
//
// Λεπτό wrapper πάνω στο υπάρχον IcsExportService — μετονομάζει τη ροή σε
// «Αποθήκευση ημερολογίου» (πρώην «Εξαγωγή .ics») για το νέο Ημερολόγιο
// Δουλειών. ΔΕΝ αλλάζει τη λογική εξαγωγής/ανοίγματος .ics.

import 'package:flutter/material.dart';

import '../jobs/ics_export_service.dart';
import '../jobs/job_model.dart';

Future<void> exportDayToIcsAndSave({
  required BuildContext context,
  required List<Job>    jobs,
  required DateTime      day,
}) async {
  if (jobs.isEmpty) return;
  final dm = '${day.day.toString().padLeft(2, "0")}-'
      '${day.month.toString().padLeft(2, "0")}-${day.year}';

  final ok = await IcsExportService.exportJobs(
    jobs,
    fileName: 'athenstaxi_$dm.ics',
  );

  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(ok
        ? 'Το ημερολόγιο αποθηκεύτηκε.'
        : 'Δεν ήταν δυνατή η αποθήκευση — δοκιμάστε ξανά.'),
    backgroundColor: ok ? const Color(0xFF1E8E3E) : Colors.red,
  ));
}
