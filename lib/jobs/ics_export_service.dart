// lib/jobs/ics_export_service.dart
//
// ΕΞΑΓΩΓΗ δουλειών σε αρχείο .ics (αντίστροφο από το ics_intent.dart που κάνει
// ΕΙΣΑΓΩΓΗ). Παράγει ένα RFC 5545 VCALENDAR με ένα VEVENT ανά δουλειά και το
// ανοίγει/κατεβάζει ανάλογα με την πλατφόρμα:
//   • Android → γράφει προσωρινό .ics & το ανοίγει με system intent
//                (ACTION_VIEW, text/calendar) → ανοίγει το Ημερολόγιο.
//   • Web     → κατεβάζει το .ics (blob download) → ανοίγει η default εφαρμογή.
//
// Χρησιμοποιείται από το my_jobs_sheet.dart (κουμπί «Όλες στο ημερολόγιο»).

import 'package:intl/intl.dart';

import 'job_model.dart';
import 'ics_export_platform.dart';

class IcsExportService {
  /// Δημιουργεί & ανοίγει/κατεβάζει .ics για ΟΛΕΣ τις δουλειές της λίστας.
  /// Επιστρέφει false αν η λίστα είναι κενή ή απέτυχε η εξαγωγή.
  static Future<bool> exportJobs(
    List<Job> jobs, {
    String fileName = 'athenstaxi_jobs.ics',
  }) async {
    if (jobs.isEmpty) return false;
    final content = buildCalendar(jobs);
    return saveAndOpenIcs(content, fileName);
  }

  /// Δημιουργεί & ανοίγει/κατεβάζει .ics για ΜΙΑ δουλειά.
  static Future<bool> exportJob(Job job) =>
      exportJobs([job], fileName: 'athenstaxi_job_${job.id}.ics');

  // ─── Παραγωγή VCALENDAR ─────────────────────────────────────────────────────

  static String buildCalendar(List<Job> jobs) {
    final sb = StringBuffer();
    sb.write('BEGIN:VCALENDAR\r\n');
    sb.write('VERSION:2.0\r\n');
    sb.write('PRODID:-//AthensTaxi//Jobs Export//EL\r\n');
    sb.write('CALSCALE:GREGORIAN\r\n');
    sb.write('METHOD:PUBLISH\r\n');
    for (final j in jobs) {
      _writeEvent(sb, j);
    }
    sb.write('END:VCALENDAR\r\n');
    return sb.toString();
  }

  static void _writeEvent(StringBuffer sb, Job job) {
    // Ώρα έναρξης: το ραντεβού· αλλιώς (άμεση) η ώρα δημιουργίας.
    final start = job.scheduledAt ?? job.createdAt;
    // Διάρκεια: η εκτιμώμενη διαδρομή (αν υπάρχει), αλλιώς 1 ώρα.
    final mins = (job.routeMinutes != null && job.routeMinutes! > 0)
        ? job.routeMinutes!
        : 60;
    final end = start.add(Duration(minutes: mins));

    final summary = '${job.from} → ${job.to}';

    sb.write('BEGIN:VEVENT\r\n');
    sb.write('UID:athenstaxi-${job.id}@athenstaxi\r\n');
    sb.write('DTSTAMP:${_fmtUtc(DateTime.now())}\r\n');
    sb.write('DTSTART:${_fmtLocal(start)}\r\n');
    sb.write('DTEND:${_fmtLocal(end)}\r\n');
    _writeFolded(sb, 'SUMMARY', _esc(summary));
    if (job.to.trim().isNotEmpty) {
      _writeFolded(sb, 'LOCATION', _esc(job.to));
    }
    final desc = _buildDescription(job);
    if (desc.isNotEmpty) {
      _writeFolded(sb, 'DESCRIPTION', _esc(desc));
    }
    // Υπενθύμιση 30' πριν το ραντεβού.
    if (job.scheduledAt != null) {
      sb.write('BEGIN:VALARM\r\n');
      sb.write('ACTION:DISPLAY\r\n');
      sb.write('DESCRIPTION:${_esc(summary)}\r\n');
      sb.write('TRIGGER:-PT30M\r\n');
      sb.write('END:VALARM\r\n');
    }
    sb.write('END:VEVENT\r\n');
  }

  /// Συγκεντρώνει τα στοιχεία της δουλειάς για το πεδίο DESCRIPTION.
  static String _buildDescription(Job job) {
    final lines = <String>[];
    lines.add('Από: ${job.from}');
    lines.add('Προς: ${job.to}');
    if (job.clientName != null && job.clientName!.trim().isNotEmpty) {
      lines.add('Πελάτης: ${job.clientName!.trim()}');
    }
    if (job.clientPhone != null && job.clientPhone!.trim().isNotEmpty) {
      lines.add('Τηλέφωνο: ${job.clientPhone!.trim()}');
    }
    if (job.flightOrShip != null && job.flightOrShip!.trim().isNotEmpty) {
      lines.add('Πτήση/Πλοίο: ${job.flightOrShip!.trim()}');
    }
    lines.add('Άτομα: ${job.persons}');
    if (job.luggage > 0) lines.add('Βαλίτσες: ${job.luggage}');
    if (job.childSeat) {
      lines.add('Παιδικά καθίσματα: '
          '${job.childSeatCount > 0 ? job.childSeatCount : "Ναι"}');
    }
    lines.add('Τιμή: ${job.price.toStringAsFixed(2)}€');
    if (job.note != null && job.note!.trim().isNotEmpty) {
      lines.add('Σημ.: ${job.note!.trim()}');
    }
    return lines.join('\n');
  }

  // ─── Helpers μορφοποίησης (RFC 5545) ────────────────────────────────────────

  /// Τοπική ώρα (χωρίz Z) — το ημερολόγιο τη διαβάζει ως «floating» τοπική.
  static String _fmtLocal(DateTime dt) {
    final d = DateFormat('yyyyMMdd').format(dt);
    final t = DateFormat('HHmmss').format(dt);
    return '${d}T$t';
  }

  /// UTC (με Z) — για το DTSTAMP.
  static String _fmtUtc(DateTime dt) {
    final u = dt.toUtc();
    final d = DateFormat('yyyyMMdd').format(u);
    final t = DateFormat('HHmmss').format(u);
    return '${d}T${t}Z';
  }

  /// Escape ειδικών χαρακτήρων κατά RFC 5545 (\, ; , και νέα γραμμή → \n).
  static String _esc(String s) => s
      .replaceAll('\\', '\\\\')
      .replaceAll(';', '\\;')
      .replaceAll(',', '\\,')
      .replaceAll('\r\n', '\\n')
      .replaceAll('\n', '\\n');

  /// Γράφει «KEY:VALUE» με αναδίπλωση γραμμών στους 73 οκτάδες (line folding).
  /// Η συνέχεια ξεκινά με ένα κενό, όπως ορίζει το RFC.
  static void _writeFolded(StringBuffer sb, String key, String value) {
    final full = '$key:$value';
    const maxLen = 73;
    if (full.length <= maxLen) {
      sb.write('$full\r\n');
      return;
    }
    var i = 0;
    var first = true;
    while (i < full.length) {
      final take = first ? maxLen : maxLen - 1;
      final chunk = full.substring(i, (i + take).clamp(0, full.length));
      sb.write(first ? chunk : ' $chunk');
      sb.write('\r\n');
      i += take;
      first = false;
    }
  }
}
