// ==========================================
// FILE: ./lib/jobs/flight_delay_alert.dart
// ==========================================
//
// ΕΙΔΟΠΟΙΗΣΗ «Η ΩΡΑ ΑΛΛΑΞΕ ΛΟΓΩ ΠΤΗΣΗΣ» — foreground popup, ΟΠΟΥΔΗΠΟΤΕ στο
// app. Ίδιο μοτίβο με το public_booking_alert.dart, αλλά πιο απλό: μόνο FCM
// data-only μήνυμα (type: flight_delay_update) από το checkFlightDelays
// scheduler, στέλνεται ΚΑΙ στον δημιουργό ΚΑΙ στον οδηγό που πήρε τη δουλειά.
//
// Εκκίνηση: FlightDelayAlerts.instance.start();  (για ΚΑΘΕ συνδεδεμένο χρήστη,
// όχι μόνο master/admin — ο οδηγός πρέπει επίσης να το βλέπει).

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'notifications_service.dart';

class FlightDelayAlerts {
  FlightDelayAlerts._();
  static final FlightDelayAlerts instance = FlightDelayAlerts._();

  StreamSubscription<RemoteMessage>? _fcmSub;
  bool _dialogOpen = false;

  void start() {
    _fcmSub ??= FirebaseMessaging.onMessage.listen((msg) {
      final type = (msg.data['type'] ?? '').toString();
      if (type != 'flight_delay_update') return;
      _show(msg.data);
    });
  }

  void dispose() {
    _fcmSub?.cancel();
    _fcmSub = null;
  }

  Future<void> _show(Map<String, dynamic> data) async {
    final nav = NotificationsService.navigatorKey.currentState;
    final ctx = nav?.overlay?.context;
    if (ctx == null || _dialogOpen) return;

    final bookingNumber = (data['bookingNumber'] ?? '').toString();
    final flightNumber  = (data['flightNumber'] ?? '').toString();
    final delayMinutes  = (data['delayMinutes'] ?? '0').toString();
    final oldIso = data['oldTimeIso'] as String?;
    final newIso = data['newTimeIso'] as String?;
    String fmt(String? iso) {
      if (iso == null) return '—';
      try {
        final d = DateTime.parse(iso).toLocal();
        return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
      } catch (_) {
        return '—';
      }
    }
    final oldTime = fmt(oldIso);
    final newTime = fmt(newIso);

    _dialogOpen = true;
    await showDialog<void>(
      context: ctx,
      barrierDismissible: false,
      builder: (dctx) => PopScope(
        canPop: false,
        child: Dialog(
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: double.infinity,
                color: const Color(0xFFEF9F27),
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.flight_land_rounded,
                        color: Color(0xFF412402), size: 26),
                    const SizedBox(width: 10),
                    const Flexible(
                      child: Text('Η ώρα άλλαξε λόγω πτήσης',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: Color(0xFF412402),
                              fontSize: 17,
                              fontWeight: FontWeight.w900)),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (bookingNumber.isNotEmpty || flightNumber.isNotEmpty)
                      Center(
                        child: Text(
                          [
                            if (bookingNumber.isNotEmpty) 'Δουλειά #$bookingNumber',
                            if (flightNumber.isNotEmpty) flightNumber,
                          ].join(' · '),
                          style: const TextStyle(fontSize: 13.5, color: Colors.black54),
                        ),
                      ),
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFAEEDA),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Column(children: [
                            const Text('Ήταν',
                                style: TextStyle(fontSize: 11, color: Colors.black45)),
                            Text(oldTime,
                                style: const TextStyle(
                                    fontSize: 15,
                                    color: Colors.black45,
                                    decoration: TextDecoration.lineThrough)),
                          ]),
                          const SizedBox(width: 14),
                          const Icon(Icons.arrow_forward_rounded,
                              size: 18, color: Colors.black45),
                          const SizedBox(width: 14),
                          Column(children: [
                            const Text('Τώρα',
                                style: TextStyle(
                                    fontSize: 11, color: Color(0xFF854F0B))),
                            Text(newTime,
                                style: const TextStyle(
                                    fontSize: 19,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF854F0B))),
                          ]),
                          const SizedBox(width: 14),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: const Color(0xFF854F0B),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text('+$delayMinutes\'',
                                style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700)),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      height: 48,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFEF9F27),
                          foregroundColor: const Color(0xFF412402),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: () => Navigator.of(dctx).pop(),
                        child: const Text('OK',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w900)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    _dialogOpen = false;
  }
}
