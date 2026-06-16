// ============================================================================
// FILE: ./lib/web/_platform_http.dart
// ============================================================================
//
// Διαστρωματικό (platform-agnostic) HTTP για το PlacesService.
//
// Επιλέγει αυτόματα την σωστή υλοποίηση μέσω conditional import:
//   • Android / iOS  → _platform_http_io.dart   (dart:io HttpClient)
//   • Web            → _platform_http_web.dart   (package:http)
//
// Το PlacesService καλεί ΜΟΝΟ την platformJsonRequest(...) — δεν ξέρει
// ποια υλοποίηση τρέχει από κάτω. Έτσι ο ίδιος κώδικας δουλεύει παντού.
//
// ⚠️  ΣΗΜΑΝΤΙΚΟ: Η συμπεριφορά σε Android παραμένει ΑΚΡΙΒΩΣ ίδια — το
//     dart:io μονοπάτι κάνει την ίδια δουλειά με τον παλιό HttpClient.

// Default (όταν κανένα από τα dart libraries δεν είναι διαθέσιμο — δεν
// συμβαίνει στην πράξη, αλλά χρειάζεται για να μεταγλωττίζει).
export '_platform_http_io.dart'
    if (dart.library.io) '_platform_http_io.dart'
    if (dart.library.html) '_platform_http_web.dart';
