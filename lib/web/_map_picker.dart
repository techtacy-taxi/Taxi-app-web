// ============================================================================
// FILE: ./lib/web/_map_picker.dart
// ============================================================================
//
// Επιλογή ακριβούς σημείου στον χάρτη — platform-agnostic πρόσοψη.
//
//   • Android / iOS → _map_picker_io.dart  (πραγματικό GoogleMap picker)
//   • Web           → _map_picker_web.dart  (μη διαθέσιμο — επιστρέφει null)
//
// Το PlaceField καλεί openMapPicker(...) και ελέγχει το kMapPickerAvailable
// για να αποφασίσει αν θα δείξει το κουμπί-πινέζα. Στο web το κουμπί κρύβεται.

export '_map_picker_io.dart'
    if (dart.library.io) '_map_picker_io.dart'
    if (dart.library.html) '_map_picker_web.dart';
