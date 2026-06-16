// lib/calendar/google_calendar_service.dart
//
// Google Calendar — σύνδεση «μία φορά για πάντα» (server-side refresh token).
//
//  • Η σύνδεση γίνεται ΜΙΑ φορά: authorizeServer → serverAuthCode → Cloud
//    Function (exchangeCalendarCode) που κρατάει refresh_token server-side.
//  • Από κει & πέρα τα events έρχονται από το Cloud Function getCalendarEvents.
//    Το app ΔΕΝ ξαναζητάει Google login / δεν δείχνει account picker.
//  • Read-only. ΔΕΝ γράφει τίποτα στο Firestore από το app.

import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Λήψη serverAuthCode ανά platform (google_sign_in σε κινητό, GIS σε web).
import '../web/_calendar_auth.dart';

/// Τοπικό flag: έχει ολοκληρωθεί η σύνδεση ημερολογίου (μία φορά).
const String _kPrefsCalendarConnected = 'calendar_connected_v1';

/// Google Calendar colorId για "Basil" (πράσινο βασιλικού) → δουλειά VAN.
const String _kBasilColorId = '10';

/// Ένα συμβάν ημερολογίου, απλοποιημένο.
class CalendarEvent {
  final String   id;
  final String   title;
  final String?  description;
  final String?  location;
  final DateTime start;       // τοπική ώρα
  final bool     allDay;
  final String?  colorId;     // '10' = Basil (πράσινο) → van

  const CalendarEvent({
    required this.id,
    required this.title,
    this.description,
    this.location,
    required this.start,
    this.allDay = false,
    this.colorId,
  });

  DateTime get dayKey => DateTime(start.year, start.month, start.day);

  /// true αν το χρώμα είναι πράσινο "Basil" → δουλειά VAN.
  bool get isBasilGreen => colorId == _kBasilColorId;
}

class GoogleCalendarService {
  GoogleCalendarService._();
  static final GoogleCalendarService instance = GoogleCalendarService._();

  // ─── Κατάσταση σύνδεσης ────────────────────────────────────────────────────

  /// true αν έχει ολοκληρωθεί η σύνδεση ημερολογίου (τοπικό flag, ΧΩΡΙΣ UI).
  Future<bool> isConnected() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_kPrefsCalendarConnected) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _setConnected(bool v) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kPrefsCalendarConnected, v);
    } catch (_) {}
  }

  /// Συμβατότητα με την υπάρχουσα σελίδα: σιωπηλός έλεγχος, χωρίς UI/popup.
  Future<bool> isAuthorizedSilently() => isConnected();

  // ─── Σύνδεση (μία φορά) ─────────────────────────────────────────────────────

  /// Ο χρήστης πατάει «Σύνδεση ημερολογίου». Παίρνει serverAuthCode (μέσω
  /// platform-specific helper: google_sign_in σε κινητό, GIS popup σε web)
  /// και το στέλνει στο Cloud Function για αποθήκευση refresh_token.
  Future<bool> connect() async {
    try {
      // 1) Πάρε authorization code (offline access) — ανά platform.
      final result = await obtainCalendarAuthCode();
      final code = result.code;
      if (code == null || code.isEmpty) return false;

      // 2) Στείλε τον code + redirectUri στο Cloud Function.
      //    (web → 'postmessage', κινητό → '')
      final callable =
          FirebaseFunctions.instance.httpsCallable('exchangeCalendarCode');
      await callable.call(<String, dynamic>{
        'serverAuthCode': code,
        'redirectUri':    result.redirectUri,
      });

      await _setConnected(true);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Αποσύνδεση: σβήνει τα tokens server-side και το τοπικό flag.
  Future<void> disconnect() async {
    try {
      final callable =
          FirebaseFunctions.instance.httpsCallable('disconnectCalendar');
      await callable.call();
    } catch (_) {}
    await _setConnected(false);
  }

  // ─── Ανάκτηση events (μέσω Cloud Function) ──────────────────────────────────

  /// Φέρνει events για το [from, to). Δεν αγγίζει καθόλου Google sign-in.
  Future<List<CalendarEvent>> fetchEvents({
    required DateTime from,
    required DateTime to,
  }) async {
    final callable =
        FirebaseFunctions.instance.httpsCallable('getCalendarEvents');
    final HttpsCallableResult res;
    try {
      res = await callable.call(<String, dynamic>{
        'timeMin': from.toUtc().toIso8601String(),
        'timeMax': to.toUtc().toIso8601String(),
      });
    } on FirebaseFunctionsException catch (e) {
      if (e.code == 'failed-precondition' || e.message == 'NOT_CONNECTED') {
        await _setConnected(false);
        throw const CalendarAuthException('NOT_CONNECTED');
      }
      throw CalendarFetchException(e.message ?? 'Σφάλμα ημερολογίου');
    }

    final data = res.data;
    final rawList = (data is Map && data['events'] is List)
        ? (data['events'] as List)
        : const [];

    final events = <CalendarEvent>[];
    for (final raw in rawList) {
      if (raw is! Map) continue;
      final m = raw;
      DateTime? start;
      bool allDay = false;
      final dt = m['startDateTime'];
      final d  = m['startDate'];
      if (dt is String) {
        start = DateTime.tryParse(dt)?.toLocal();
      } else if (d is String) {
        start = DateTime.tryParse(d);
        allDay = true;
      }
      if (start == null) continue;

      events.add(CalendarEvent(
        id:          (m['id'] as String?) ?? '',
        title:       (m['title'] as String?) ?? '(χωρίς τίτλο)',
        description: m['description'] as String?,
        location:    m['location'] as String?,
        start:       start,
        allDay:      allDay,
        colorId:     m['colorId'] as String?,
      ));
    }

    events.sort((a, b) => a.start.compareTo(b.start));
    return events;
  }
}

class CalendarAuthException implements Exception {
  final String message;
  const CalendarAuthException(this.message);
  @override
  String toString() => message;
}

class CalendarFetchException implements Exception {
  final String message;
  const CalendarFetchException(this.message);
  @override
  String toString() => message;
}
