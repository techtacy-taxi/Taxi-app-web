// ==========================================
// FILE: ./lib/public_booking_alert.dart
// ==========================================
//
// ΕΙΔΟΠΟΙΗΣΗ «ΝΕΑ ΚΡΑΤΗΣΗ ΑΠΟ ΦΟΡΜΑ» — foreground popup (στη μέση).
//
// Πότε εμφανίζεται:
//   • Όταν η εφαρμογή είναι ΑΝΟΙΧΤΗ (foreground) και φτάσει FCM type
//     'public_booking' → δείχνουμε ένα κεντρικό dialog που πρέπει ο master
//     να πατήσει «ΟΚ» για να κλείσει.
//   • Αν έρθουν ΚΙ ΑΛΛΕΣ κρατήσεις πριν πατηθεί το «ΟΚ», ΔΕΝ ανοίγουν νέα
//     dialogs — ο μετρητής μέσα στο ίδιο dialog αυξάνεται (1 → 2 → 3 …).
//
// Όταν η εφαρμογή είναι killed/background, αναλαμβάνει ο background handler
// (fcm_service.dart → _showPublicBookingBg) που δείχνει native ειδοποίηση.
//
// Σύνδεση: στο main.dart, μέσα στο αρχικοποιημένο App, κάλεσε
//   PublicBookingAlerts.instance.start();
// μία φορά (αφού υπάρχει ο navigatorKey).

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'notifications_service.dart';

class PublicBookingAlerts {
  PublicBookingAlerts._();
  static final PublicBookingAlerts instance = PublicBookingAlerts._();

  StreamSubscription<RemoteMessage>? _sub;
  bool _dialogOpen = false;
  int _pendingCount = 0;            // πόσες έχουν έρθει & δεν έχουν «διαβαστεί»
  void Function(void Function())? _setStateInDialog;

  /// Ξεκινά τον foreground listener. Ασφαλές να κληθεί πολλές φορές.
  void start() {
    _sub ??= FirebaseMessaging.onMessage.listen((msg) {
      final type = (msg.data['type'] ?? '').toString();
      if (type == 'public_booking') {
        _onBooking();
      }
    });
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
  }

  void _onBooking() {
    _pendingCount++;
    if (_dialogOpen) {
      // Ήδη ανοιχτό → απλώς ανανέωσε τον μετρητή μέσα στο dialog.
      _setStateInDialog?.call(() {});
      return;
    }
    _showDialog();
  }

  Future<void> _showDialog() async {
    final nav = NotificationsService.navigatorKey.currentState;
    final ctx = nav?.overlay?.context;
    if (ctx == null) return;   // η εφαρμογή δεν έχει UI έτοιμο ακόμα

    _dialogOpen = true;
    await showDialog<void>(
      context: ctx,
      barrierDismissible: false,
      builder: (dctx) => StatefulBuilder(
        builder: (c, setLocal) {
          _setStateInDialog = setLocal;
          final n = _pendingCount;
          final word = n == 1 ? 'καινούργια δουλειά' : 'καινούργιες δουλειές';
          return Dialog(
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(22)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 24, 22, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Εικονίδιο υδρόγειος μέσα σε κίτρινο κύκλο
                  Center(
                    child: Container(
                      width: 64, height: 64,
                      decoration: const BoxDecoration(
                        color: Color(0xFFFFF3CD),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.public_rounded,
                          color: Color(0xFFB8860B), size: 36),
                    ),
                  ),
                  const SizedBox(height: 14),
                  // Μετρητής + κείμενο
                  Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 5),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFB300),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text('$n',
                          style: const TextStyle(
                              color: Color(0xFF5A3D00),
                              fontSize: 20,
                              fontWeight: FontWeight.w900)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Center(
                    child: Text(
                      n == 1
                          ? '1 $word από τη φόρμα'
                          : '$n $word από τη φόρμα',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Center(
                    child: Text(
                      'Βρες τες στις «Αποθηκευμένες».',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 13.5, color: Colors.black54),
                    ),
                  ),
                  const SizedBox(height: 20),
                  // Κουμπί ΟΚ — κλείνει & μηδενίζει
                  SizedBox(
                    height: 48,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFFFB300),
                        foregroundColor: const Color(0xFF5A3D00),
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
          );
        },
      ),
    );

    // Έκλεισε το dialog → reset
    _dialogOpen = false;
    _pendingCount = 0;
    _setStateInDialog = null;
  }
}
