// ============================================================================
// FILE: ./lib/web/_voice_io_mobile.dart
// ============================================================================
//
// Τοπική διαχείριση ηχητικών αρχείων για Android / iOS.
// Ίδια λογική με τον παλιό κώδικα του VoiceService (saveLocally / loadLocal
// / readAsBytes) — απλώς απομονωμένη ώστε το web να μην τραβάει dart:io.

import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Διαβάζει bytes από ένα ηχητικό αρχείο (που έχει εγγραφεί τοπικά).
Future<List<int>> readAudioBytes(Object audioFile) async {
  final file = audioFile as File;
  return file.readAsBytes();
}

/// Αποθηκεύει bytes τοπικά ως voice_<id>.aac και επιστρέφει το path.
/// Αν υπάρχει ήδη, το επιστρέφει χωρίς να ξαναγράψει.
Future<String> saveAudioLocally(String messageId, List<int> bytes) async {
  final dir  = await getApplicationDocumentsDirectory();
  final file = File('${dir.path}/voice_$messageId.aac');
  if (await file.exists()) return file.path;
  await file.writeAsBytes(bytes);
  return file.path;
}

/// Επιστρέφει το path τοπικού αρχείου αν υπάρχει, αλλιώς null.
Future<String?> localAudioPath(String messageId) async {
  final dir  = await getApplicationDocumentsDirectory();
  final file = File('${dir.path}/voice_$messageId.aac');
  return await file.exists() ? file.path : null;
}

/// Στο κινητό η τοπική αποθήκευση είναι διαθέσιμη.
const bool kLocalAudioAvailable = true;
