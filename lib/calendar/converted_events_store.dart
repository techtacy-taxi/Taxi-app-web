// lib/calendar/converted_events_store.dart
//
// Κρατάει ΤΟΠΙΚΑ (SharedPreferences) ποια events ημερολογίου έχουν ήδη
// μετατραπεί σε δουλειές, με ΚΑΤΑΣΤΑΣΗ: "saved" (αποθηκεύτηκε) ή "sent"
// (στάλθηκε), ώστε να δείχνουμε αντίστοιχο σήμα στην κάρτα.
//
//  • Per-device (δεν συγχρονίζεται — μηδέν write cost Firestore).
//  • Auto-cleanup: ό,τι είναι παλαιότερο από 4 μήνες σβήνεται αυτόματα.
//  • Συμβατότητα: παλιές εγγραφές (μόνο timestamp) διαβάζονται ως "sent".

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Κατάσταση μετατροπής ενός event ημερολογίου.
enum ConvertState { none, saved, sent }

class ConvertedEventsStore {
  ConvertedEventsStore._();
  static final ConvertedEventsStore instance = ConvertedEventsStore._();

  static const String _key = 'calendar_converted_events_v1';
  static const int _maxAgeDays = 120; // ~4 μήνες

  // Μνήμη: eventId → { ts: epochMillis, state: 'saved'|'sent' }.
  Map<String, _Entry> _cache = {};
  bool _loaded = false;

  Future<void> _load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload(); // αποφυγή stale cache
    final raw = prefs.getString(_key);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        _cache = decoded.map((k, v) {
          if (v is num) {
            // Παλιό format: μόνο timestamp → θεωρείται "sent" (έγινε δουλειά).
            return MapEntry(k, _Entry(v.toInt(), ConvertState.sent));
          }
          final m = v as Map<String, dynamic>;
          final ts = (m['ts'] as num?)?.toInt() ??
              DateTime.now().millisecondsSinceEpoch;
          final st = (m['state'] as String?) == 'saved'
              ? ConvertState.saved
              : ConvertState.sent;
          return MapEntry(k, _Entry(ts, st));
        });
      } catch (_) {
        _cache = {};
      }
    }
    _loaded = true;
    await _cleanup();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final out = _cache.map((k, e) =>
        MapEntry(k, {'ts': e.ts, 'state': e.state == ConvertState.saved ? 'saved' : 'sent'}));
    await prefs.setString(_key, jsonEncode(out));
  }

  Future<void> _cleanup() async {
    final cutoff = DateTime.now()
        .subtract(const Duration(days: _maxAgeDays))
        .millisecondsSinceEpoch;
    final before = _cache.length;
    _cache.removeWhere((_, e) => e.ts < cutoff);
    if (_cache.length != before) await _save();
  }

  /// Σημειώνει ένα event ως ΑΠΟΘΗΚΕΥΜΕΝΟ (draft).
  Future<void> markSaved(String eventId) async {
    if (eventId.isEmpty) return;
    await _load();
    _cache[eventId] =
        _Entry(DateTime.now().millisecondsSinceEpoch, ConvertState.saved);
    await _save();
  }

  /// Σημειώνει ένα event ως ΣΤΑΛΜΕΝΟ (έγινε ανοιχτή δουλειά).
  Future<void> markSent(String eventId) async {
    if (eventId.isEmpty) return;
    await _load();
    _cache[eventId] =
        _Entry(DateTime.now().millisecondsSinceEpoch, ConvertState.sent);
    await _save();
  }

  /// Παλιό API — διατηρείται για συμβατότητα· ισοδυναμεί με markSent.
  Future<void> markConverted(String eventId) => markSent(eventId);

  /// Αναιρεί τη σήμανση (χειροκίνητο σβήσιμο από admin/master).
  Future<void> unmark(String eventId) async {
    await _load();
    if (_cache.remove(eventId) != null) await _save();
  }

  /// Κατάσταση ενός event.
  Future<ConvertState> stateOf(String eventId) async {
    await _load();
    return _cache[eventId]?.state ?? ConvertState.none;
  }

  /// Χάρτης eventId → κατάσταση (για μαζικό έλεγχο στη λίστα).
  Future<Map<String, ConvertState>> statesMap() async {
    await _load();
    return _cache.map((k, e) => MapEntry(k, e.state));
  }

  /// true αν έχει οποιαδήποτε σήμανση (saved ή sent).
  Future<bool> isConverted(String eventId) async {
    await _load();
    return _cache.containsKey(eventId);
  }

  /// Σύνολο eventIds με οποιαδήποτε σήμανση.
  Future<Set<String>> convertedIds() async {
    await _load();
    return _cache.keys.toSet();
  }
}

class _Entry {
  final int ts;
  final ConvertState state;
  const _Entry(this.ts, this.state);
}
