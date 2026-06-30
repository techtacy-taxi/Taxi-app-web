// lib/jobs/ics_export_web.dart
//
// Web υλοποίηση εξαγωγής .ics — κατεβάζει το αρχείο μέσω blob download.
// Ο browser/OS το ανοίγει με την default εφαρμογή ημερολογίου.

// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

Future<bool> saveAndOpenIcs(String content, String fileName) async {
  try {
    final bytes = html.Blob([content], 'text/calendar;charset=utf-8');
    final url = html.Url.createObjectUrlFromBlob(bytes);
    final anchor = html.AnchorElement(href: url)
      ..setAttribute('download', fileName)
      ..style.display = 'none';
    html.document.body?.append(anchor);
    anchor.click();
    anchor.remove();
    html.Url.revokeObjectUrl(url);
    return true;
  } catch (_) {
    return false;
  }
}
