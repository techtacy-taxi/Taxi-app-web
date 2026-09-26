// ============================================================================
// FILE: ./lib/jobs/new_saved_badge_store.dart
// ============================================================================
//
// Σήμα «ΝΕΑ» σε αποθηκευμένες κρατήσεις που ΔΕΝ έχεις ανοίξει ακόμη.
//
// ΣΥΜΠΕΡΙΦΟΡΑ (όπως συμφωνήθηκε):
//   • Μπαίνει μόλις έρθει νέα κράτηση από τη δημόσια φόρμα.
//   • ΦΕΥΓΕΙ ΜΟΝΟ όταν ανοίξεις την καρτέλα λεπτομερειών της κράτησης.
//   • ΔΕΝ φεύγει αν πατήσεις «Αργότερα», αν απλώς δεις τη λίστα, ή αν
//     κλείσεις την εφαρμογή.
//   • Επιβιώνει σε επανεκκίνηση (SharedPreferences).
//
// ⚠️ ΤΟΠΙΚΟ ΑΝΑ ΣΥΣΚΕΥΗ — σκόπιμα.
// Αν τη δεις στο κινητό, στο web θα φαίνεται ακόμη νέα. Ίδιο μοτίβο με τα
// converted calendar events. Εναλλακτική θα ήταν πεδίο στο Firestore, αλλά
// αυτό προσθέτει εγγραφή σε ΚΑΘΕ προβολή και αλλαγή στους κανόνες.
//
// Αυτόματο καθάρισμα μετά από 30 ημέρες ώστε να μη φουσκώνει η αποθήκευση.

import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NewSavedBadgeStore {
  NewSavedBadgeStore._();

  static const String _kKey = 'new_saved_badges_v1';
  static const Duration _kTtl = Duration(days: 30);

  /// savedJobId -> millisecondsSinceEpoch που σημειώθηκε ως νέα.
  static final Map<String, int> _cache = {};
  static bool _loaded = false;

  /// Αυξάνεται σε κάθε αλλαγή ώστε το UI να ξαναχτίζεται.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static Future<void> _load() async {
    // ⚠️ ΚΡΙΣΙΜΟ BUGFIX: ΠΑΝΤΑ ξαναδιαβάζουμε από τον δίσκο (όχι μία φορά).
    // Όταν η κράτηση έρχεται με την εφαρμογή στο ΠΑΡΑΣΚΗΝΙΟ (π.χ. ο master
    // είναι στο Chrome και πληρώνει ο πελάτης), το background isolate του FCM
    // γράφει το «ΝΕΑ» στα SharedPreferences — αλλά η ανοιχτή εφαρμογή είχε
    // ήδη φορτωμένη στη μνήμη την παλιά λίστα και ΔΕΝ το έβλεπε ποτέ (και στο
    // επόμενο persist το έσβηνε κιόλας). Τώρα: reload + ένωση δίσκου/μνήμης.
    try {
      final prefs = await SharedPreferences.getInstance();
      try { await prefs.reload(); } catch (_) {}
      final raw = prefs.getString(_kKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          var changed = false;
          decoded.forEach((k, v) {
            final id = k.toString();
            if (!_cache.containsKey(id)) {
              _cache[id] = (v is int) ? v : 0;
              changed = true;
            }
          });
          if (changed && _loaded) revision.value++;
        }
      }
    } catch (_) {}
    _loaded = true;
    _pruneExpired();
  }

  static void _pruneExpired() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final cutoff = now - _kTtl.inMilliseconds;
    _cache.removeWhere((_, ts) => ts < cutoff);
  }

  static Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kKey, jsonEncode(_cache));
    } catch (_) {}
    revision.value++;
  }

  /// Φόρτωση / συγχρονισμός με τον δίσκο — καλείται από το SavedJobsTab,
  /// το popup νέας κράτησης και την επιστροφή της εφαρμογής στο προσκήνιο.
  static Future<void> ensureLoaded() => _load();

  /// Σημειώνει μια κράτηση ως ΝΕΑ (μη ειδωμένη).
  static Future<void> markNew(String savedJobId) async {
    if (savedJobId.isEmpty) return;
    await _load();
    if (_cache.containsKey(savedJobId)) return;   // ήδη σημειωμένη
    _cache[savedJobId] = DateTime.now().millisecondsSinceEpoch;
    _pruneExpired();
    await _persist();
  }

  /// Σβήνει το σήμα — ΜΟΝΟ όταν ο χρήστης ανοίξει την κράτηση.
  static Future<void> markSeen(String savedJobId) async {
    if (savedJobId.isEmpty) return;
    await _load();
    if (_cache.remove(savedJobId) == null) return;  // δεν ήταν σημειωμένη
    await _persist();
  }

  /// Είναι νέα/μη ειδωμένη; (σύγχρονο — για χρήση μέσα σε build)
  static bool isNew(String savedJobId) {
    if (!_loaded || savedJobId.isEmpty) return false;
    return _cache.containsKey(savedJobId);
  }

  /// Πόσες μη ειδωμένες υπάρχουν ΑΠΟ ΑΥΤΕΣ που φαίνονται τώρα στη λίστα.
  /// Περνάμε τα ορατά ids ώστε ο μετρητής να μη μετράει κρατήσεις που
  /// έχουν διαγραφεί ή δεν περνούν τα φίλτρα.
  static int countVisible(Iterable<String> visibleIds) {
    if (!_loaded) return 0;
    var n = 0;
    for (final id in visibleIds) {
      if (_cache.containsKey(id)) n++;
    }
    return n;
  }
}

/// Αίτημα «άνοιξε τις Αποθηκευμένες».
///
/// Τίθεται από το popup «Νέα κράτηση από φόρμα» όταν ο χρήστης πατήσει
/// «Δες την τώρα». Το ακούν το map_page (Android) και το admin_shell (web),
/// που ξέρουν τα στοιχεία του χρήστη και ανοίγουν τη σωστή σελίδα/καρτέλα.
final ValueNotifier<int> openSavedJobsRequest = ValueNotifier<int>(0);

/// Συντονισμός ανάμεσα στους listeners, ώστε να μη γίνει διπλή ενέργεια.
///
/// ΓΙΑΤΙ ΧΡΕΙΑΖΕΤΑΙ:
///  • Android — αν το JobAdminPage είναι ΗΔΗ ανοιχτό, ενεργοποιούνται ΚΑΙ ο
///    δικός του listener (αλλάζει καρτέλα) ΚΑΙ του map_page (κάνει push νέα
///    σελίδα) → δύο σελίδες στοιβαγμένες. Το [jobAdminPageOpen] το αποτρέπει:
///    το map_page κάνει push ΜΟΝΟ αν η σελίδα δεν είναι ήδη ανοιχτή.
///  • Web — το admin_shell ΔΕΝ κρατά τη σελίδα ζωντανή (δεν είναι IndexedStack).
///    Το JobAdminPage φτιάχνεται ΜΕΤΑ την αλλαγή ενότητας, οπότε ο listener
///    του δεν προλαβαίνει το event. Το [pendingOpenSavedTab] λύνει αυτό: το
///    JobAdminPage το ελέγχει στο initState και ξεκινά κατευθείαν στη σωστή
///    καρτέλα.
class SavedTabNav {
  SavedTabNav._();

  /// true όσο υπάρχει ζωντανό JobAdminPage στην οθόνη.
  static bool jobAdminPageOpen = false;

  /// true όταν έχει ζητηθεί άνοιγμα Αποθηκευμένων αλλά η σελίδα δεν είχε
  /// προλάβει να δημιουργηθεί. Καταναλώνεται μία φορά από το JobAdminPage.
  static bool pendingOpenSavedTab = false;

  /// Η οθόνη (route) που φιλοξενεί το JobAdminPage.
  ///  • Android: η σελίδα «Δουλειές» που έχει ανοίξει πάνω από τον χάρτη.
  ///  • Web: το route του admin_shell (το JobAdminPage ζει μέσα σε αυτό).
  /// Χρησιμοποιείται από το [popToSavedAnchor].
  static Route<dynamic>? jobAdminRoute;

  /// Το route του admin_shell (web) — «σπίτι» του panel.
  static Route<dynamic>? shellRoute;

  /// Κλείνει τις οθόνες που είναι ανοιχτές ΠΑΝΩ από τη σελίδα «Δουλειές»
  /// (π.χ. φόρμα Νέας Δουλειάς) — αλλά ΟΧΙ την ίδια τη σελίδα «Δουλειές».
  ///
  /// ⚠️ ΚΡΙΣΙΜΟ BUGFIX: πριν γινόταν popUntil(isFirst), που έκλεινε ΚΑΙ τη
  /// σελίδα «Δουλειές». Επειδή το dispose της τρέχει μετά το animation, τη
  /// στιγμή του αιτήματος το [jobAdminPageOpen] ήταν ακόμη true — ο χάρτης
  /// νόμιζε ότι είναι ανοιχτή και δεν την ξανάνοιγε → ο χρήστης κατέληγε
  /// στην κεντρική σελίδα αντί για τις Αποθηκευμένες.
  static void popToSavedAnchor(NavigatorState? nav) {
    if (nav == null) return;
    nav.popUntil((r) =>
        r.isFirst ||
        (jobAdminRoute != null && r == jobAdminRoute) ||
        (shellRoute != null && r == shellRoute));
  }

  /// Διαβάζει ΚΑΙ μηδενίζει το αίτημα (one-shot).
  static bool consumePending() {
    final v = pendingOpenSavedTab;
    pendingOpenSavedTab = false;
    return v;
  }
}
