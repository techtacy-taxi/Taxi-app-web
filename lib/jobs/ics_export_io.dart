// lib/jobs/ics_export_io.dart
//
// Mobile/Desktop υλοποίηση εξαγωγής .ics.
// Γράφει το περιεχόμενο σε προσωρινό αρχείο και ζητά από το native
// (MainActivity.kt → μέθοδος "openIcs") να το ανοίξει με ACTION_VIEW
// (mime text/calendar) μέσω FileProvider → ανοίγει το Ημερολόγιο.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

const MethodChannel _channel = MethodChannel('athens_taxi/ics');

Future<bool> saveAndOpenIcs(String content, String fileName) async {
  try {
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/$fileName';
    final file = File(path);
    await file.writeAsString(content, flush: true);

    final ok = await _channel.invokeMethod<bool>('openIcs', {'path': path});
    return ok ?? false;
  } catch (_) {
    return false;
  }
}
