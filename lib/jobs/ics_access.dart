// lib/jobs/ics_access.dart
//
// Έλεγχος άδειας για το κουμπί «Προσθήκη στο ημερολόγιο» (ICS export).
//
// Ο master το βλέπει ΠΑΝΤΑ. Οποιοσδήποτε άλλος (admin ή οδηγός) το βλέπει
// μόνο αν ο master του έχει δώσει την άδεια `icsExportEnabled` στο
// presence/{uid}. Αν δεν έχει άδεια, το κουμπί ΚΡΥΒΕΤΑΙ τελείως.
//
// Λειτουργεί ίδια σε Android & Web. Διαβάζει 1 φορά το presence του τρέχοντος
// χρήστη και κρατά την τιμή σε cache για την υπόλοιπη ζωή της εφαρμογής
// (τήρηση «100m rule» — αποφυγή επαναλαμβανόμενων reads).

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class IcsAccess {
  IcsAccess._();

  static bool? _cached;
  static Future<bool>? _inFlight;

  /// True αν ο τρέχων χρήστης επιτρέπεται να δει το κουμπί ICS.
  /// (master → πάντα true· αλλιώς → presence.icsExportEnabled.)
  static Future<bool> canExport() {
    if (_cached != null) return Future.value(_cached);
    return _inFlight ??= _resolve();
  }

  /// Συγχρονισμένη τιμή αν είναι ήδη γνωστή (αλλιώς null → άγνωστο ακόμη).
  static bool? get cached => _cached;

  static Future<bool> _resolve() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _cached = false;
      _inFlight = null;
      return false;
    }
    try {
      final doc = await FirebaseFirestore.instance
          .collection('presence')
          .doc(user.uid)
          .get();
      final data = doc.data() ?? const <String, dynamic>{};
      final isMaster = data['master'] == true;
      final allowed = isMaster || data['icsExportEnabled'] == true;
      _cached = allowed;
      return allowed;
    } catch (_) {
      // Σε αποτυχία read: συντηρητικά κρύβουμε το κουμπί.
      _cached = false;
      return false;
    } finally {
      _inFlight = null;
    }
  }

  /// Καθαρισμός cache (π.χ. σε αποσύνδεση/αλλαγή χρήστη).
  static void reset() {
    _cached = null;
    _inFlight = null;
  }
}
