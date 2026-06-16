// lib/permissions.dart

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'jobs/job_shared_widgets.dart';

/// Ζητά τα απαραίτητα permissions (τοποθεσία «Πάντα», battery, notifications).
///
/// ΑΛΛΑΓΗ vs παλιά έκδοση:
///   • Καμία `Future.delayed(minutes: 5)` ή `delayed(seconds: 2)` — δεν
///     μπλοκάρουμε τη ροή με «μάντεμα χρόνου».
///   • Όταν στέλνουμε τον χρήστη στις Ρυθμίσεις, περιμένουμε event-driven να
///     ΕΠΙΣΤΡΕΨΕΙ στην εφαρμογή (AppLifecycleState.resumed) και τότε
///     ξαναελέγχουμε την άδεια. Αν δεν επιστρέψει, υπάρχει timeout ασφαλείας.
Future<void> requestPermissions({
  required BuildContext context,
  required String? uid,
}) async {
  // Βήμα 1: whileInUse (απαιτείται πριν ζητήσουμε always)
  var perm = await Geolocator.checkPermission();

  if (perm == LocationPermission.denied) {
    perm = await Geolocator.requestPermission();
  }

  // Βήμα 2: Dialog 1 — αν δεν έχει "always" ακόμα
  if (perm != LocationPermission.always) {
    if (context.mounted) {
      final goSettings = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.location_on_rounded, color: Colors.amber, size: 28),
              SizedBox(width: 8),
              Text('Τοποθεσία', style: TextStyle(fontSize: 18)),
            ],
          ),
          content: const Text(
            'Η εφαρμογή χρειάζεται πρόσβαση στην τοποθεσία σου "Πάντα" '
                'για να στέλνει τη θέση σου στους συναδέλφους ακόμα και όταν '
                'τρέχει στο παρασκήνιο.',
            style: TextStyle(fontSize: 15, height: 1.5),
          ),
          actions: [
            AppButtonTonal(
              label: 'Αργότερα',
              onPressed: () => Navigator.of(ctx).pop(false),
            ),
            AppButton(
              label: 'Συνέχεια',
              icon: Icons.arrow_forward_rounded,
              color: Colors.amber,
              fg: Colors.black,
              onPressed: () => Navigator.of(ctx).pop(true),
            ),
          ],
        ),
      );

      if (goSettings == true) {
        await ph.openAppSettings();
        // Περιμένουμε να επιστρέψει ο χρήστης στην εφαρμογή (όχι σταθερό delay).
        perm = await _waitForReturnAndRecheck();
      }
    }
  }

  // Dialog 2 — αναλυτικές οδηγίες με βήματα, αν ΑΚΟΜΑ δεν έχει always
  if (perm != LocationPermission.always) {
    if (context.mounted) {
      final goSettings = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.warning_rounded, color: Colors.orange, size: 28),
              SizedBox(width: 8),
              Text('Απαιτείται Άδεια', style: TextStyle(fontSize: 18)),
            ],
          ),
          content: RichText(
            text: const TextSpan(
              style: TextStyle(color: Colors.black87, fontSize: 18, height: 1.7),
              children: [
                TextSpan(
                  text: 'Χωρίς άδεια "Πάντα" η εφαρμογή δεν μπορεί να στέλνει '
                      'την τοποθεσία σου στους συναδέλφους.\n\n',
                ),
                TextSpan(
                    text: 'Βήματα:\n',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                TextSpan(
                    text: '➤  ',
                    style: TextStyle(
                        color: Color(0xFFFFB300), fontWeight: FontWeight.bold)),
                TextSpan(text: 'Πάτα '),
                TextSpan(
                    text: '"Άνοιγμα Ρυθμίσεων"',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                TextSpan(text: ' παρακάτω\n'),
                TextSpan(
                    text: '➤  ',
                    style: TextStyle(
                        color: Color(0xFFFFB300), fontWeight: FontWeight.bold)),
                TextSpan(text: 'Πάτα '),
                TextSpan(
                    text: '"Δικαιώματα"',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                TextSpan(text: '\n'),
                TextSpan(
                    text: '➤  ',
                    style: TextStyle(
                        color: Color(0xFFFFB300), fontWeight: FontWeight.bold)),
                TextSpan(text: 'Πάτα '),
                TextSpan(
                    text: '"Τοποθεσία"',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                TextSpan(text: '\n'),
                TextSpan(
                    text: '➤  ',
                    style: TextStyle(
                        color: Color(0xFFFFB300), fontWeight: FontWeight.bold)),
                TextSpan(text: 'Επίλεξε '),
                TextSpan(
                    text: '"Να επιτρέπεται πάντα"',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          actions: [
            AppButtonTonal(
              label: 'Αργότερα',
              onPressed: () => Navigator.of(ctx).pop(false),
            ),
            AppButton(
              label: 'Άνοιγμα Ρυθμίσεων',
              icon: Icons.settings_rounded,
              color: Colors.amber,
              fg: Colors.black,
              onPressed: () => Navigator.of(ctx).pop(true),
            ),
          ],
        ),
      );

      if (goSettings == true) {
        await ph.openAppSettings();
        perm = await _waitForReturnAndRecheck();
      }
    }
  }

  // Βήμα 4: αποθηκεύουμε στο Firestore αν έχει always ή όχι
  final hasAlways = perm == LocationPermission.always;
  if (uid != null) {
    await FirebaseFirestore.instance.collection('presence').doc(uid).set({
      'locationAlways': hasAlways,
      'updatedAt':      FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  // Βήμα 5: battery optimization & notifications
  // ΣΗΜΑΝΤΙΚΟ (Xiaomi/Poco/MIUI/HyperOS): ζητάμε εξαίρεση μπαταρίας ΜΟΝΟ αν
  // δεν είναι ήδη ενεργή. Αλλιώς το σύστημα ανοίγει τις Ρυθμίσεις σε κάθε
  // εκκίνηση, ακόμα κι όταν ο χρήστης έχει ήδη επιλέξει «Χωρίς περιορισμό».
  try {
    final alreadyIgnoring =
        await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    if (!alreadyIgnoring) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
  } catch (_) {
    // Σε κάποιες συσκευές το API πετάει — αγνοούμε, δεν είναι κρίσιμο.
  }
  final notifStatus = await FlutterForegroundTask.checkNotificationPermission();
  if (notifStatus != NotificationPermission.granted) {
    await FlutterForegroundTask.requestNotificationPermission();
  }
}

/// Περιμένει event-driven να επιστρέψει η εφαρμογή στο foreground
/// (AppLifecycleState.resumed) μετά το άνοιγμα των Ρυθμίσεων, και τότε
/// ξαναελέγχει την άδεια τοποθεσίας. Με timeout ασφαλείας 90s ώστε να μην
/// κρεμάσει ποτέ αν ο χρήστης δεν γυρίσει.
Future<LocationPermission> _waitForReturnAndRecheck() async {
  final observer = _ResumeObserver();
  WidgetsBinding.instance.addObserver(observer);
  try {
    await observer.resumed.future.timeout(
      const Duration(seconds: 90),
      onTimeout: () {},
    );
  } catch (_) {
    // αγνοούμε — απλώς ξαναελέγχουμε την άδεια ό,τι κι αν έγινε
  } finally {
    WidgetsBinding.instance.removeObserver(observer);
  }
  return Geolocator.checkPermission();
}

/// Παρατηρητής που συμπληρώνει το future μόλις η εφαρμογή γίνει resumed.
class _ResumeObserver with WidgetsBindingObserver {
  final Completer<void> resumed = Completer<void>();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !resumed.isCompleted) {
      resumed.complete();
    }
  }
}
