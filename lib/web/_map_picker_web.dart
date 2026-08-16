// ============================================================================
// FILE: ./lib/web/_map_picker_web.dart
// ============================================================================
//
// Επιλογή σημείου στον χάρτη — ΕΚΔΟΣΗ WEB.
//
// ΙΣΤΟΡΙΚΟ / ΓΙΑΤΙ ΑΛΛΑΞΕ:
// Παλιότερα αυτό το αρχείο ήταν STUB (kMapPickerAvailable = false) και το
// PlaceField ΕΚΡΥΒΕ το κουμπί-πινέζα στο web. Ο λόγος ήταν ότι δεν
// φορτωνόταν το google_maps_flutter στο web.
//
// ΑΥΤΟ ΔΕΝ ΙΣΧΥΕΙ ΠΙΑ:
//   • Το pubspec.yaml έχει ήδη google_maps_flutter_web
//   • Το web/index.html φορτώνει ήδη το Maps JavaScript API
//   • Το lib/web/map_web_page.dart χρησιμοποιεί ήδη GoogleMap() στο web
//   • Το _map_picker_io.dart ΔΕΝ χρησιμοποιεί dart:io — μόνο material και
//     google_maps_flutter, άρα είναι 100% συμβατό με web
//
// Οπότε το web χρησιμοποιεί πλέον ΤΟΝ ΙΔΙΟ picker με το Android: ένας
// κώδικας, ίδια συμπεριφορά και στα δύο. Καμία διπλή συντήρηση.
//
// (Το αρχείο μένει για να μη σπάσει το conditional export στο
//  _map_picker.dart — απλώς προωθεί στην πραγματική υλοποίηση.)

export '_map_picker_io.dart';
