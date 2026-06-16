// ============================================================================
// FILE: ./lib/web/_map_picker_web.dart
// ============================================================================
//
// Stub επιλογής σημείου στον χάρτη για Web.
// Στο web ΔΕΝ φορτώνουμε το google_maps_flutter (native plugin), οπότε ο
// picker χάρτη δεν είναι διαθέσιμος. Ο χρήστης βρίσκει σημεία μέσω της
// αναζήτησης Google (autocomplete) — που δουλεύει κανονικά στο web.
//
// Το PlaceField ελέγχει το kMapPickerAvailable και ΚΡΥΒΕΙ το κουμπί-πινέζα.

import 'package:flutter/material.dart';

import '../jobs/places_service.dart';

/// Στο web ο χάρτης-picker ΔΕΝ είναι διαθέσιμος.
const bool kMapPickerAvailable = false;

/// Δεν καλείται ποτέ στο web (το κουμπί κρύβεται), αλλά πρέπει να υπάρχει
/// ώστε να ταιριάζει η υπογραφή με την io έκδοση.
Future<PlacePick?> openMapPicker(
  BuildContext context, {
  required String title,
  double? initialLat,
  double? initialLng,
}) async {
  return null;
}
