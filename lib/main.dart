// lib/main.dart

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_theme.dart';
import 'auth_gateway.dart';
import 'fcm_service.dart';
import 'firebase_options.dart';
import 'models.dart';
import 'notifications_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Foreground Task Handler — ΜΟΝΟ για location.
// Τα notifications δουλειών στήνονται από το UI isolate (job_badge.dart)
// που παραμένει ζωντανό όσο ζει το foreground service.
//
// ⚙️  ΑΞΙΟΠΙΣΤΗ ΑΝΑΝΕΩΣΗ ΜΕ ΚΛΕΙΣΤΗ ΟΘΟΝΗ
//  Η ανανέωση γίνεται με ΔΥΟ μηχανισμούς που συνεργάζονται:
//   1) GPS stream — χτυπάει όποτε κινείται το αυτοκίνητο. Δουλεύει με
//      κλειστή οθόνη γιατί τρέφεται από το foreground service (location).
//   2) onRepeatEvent — κάθε 1′. Αν ο stream είναι σιωπηλός (π.χ. ο οδηγός
//      σταμάτησε) παίρνει φρέσκο GPS fix μόνος του.
//  Και οι δύο περνούν από τον ΙΔΙΟ έλεγχο (_maybePublish): interval
//  (3′ διαθέσιμος / 15′ μη διαθέσιμος) + μετακίνηση πάνω από 100μ.
// ─────────────────────────────────────────────────────────────────────────────
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(_LocationTaskHandler());
}

class _LocationTaskHandler extends TaskHandler {
  StreamSubscription<Position>? _positionSub;

  // Τελευταία γνωστή θέση από τον GPS stream (στη μνήμη — όχι write).
  Position? _latestPos;
  DateTime? _latestPosAt;

  // Κλείδωμα ώστε stream & onRepeatEvent να μην γράφουν ταυτόχρονα.
  bool _publishing = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform);

    // Σε ΝΕΟ isolate το auth session δεν είναι ακόμα φορτωμένο από τον δίσκο.
    // Περίμενε (best-effort) να αποκατασταθεί ώστε τα writes να περνούν.
    await _ensureAuth();

    // Ο GPS stream στήνεται ΟΠΩΣΔΗΠΟΤΕ (ακόμη κι αν το auth αργήσει).
    // Κάθε νέα θέση: αποθήκευση στη μνήμη + έλεγχος για write.
    // 🔋 accuracy high (όχι best) — ακρίβεια ~10μ, αρκετή για dispatch με
    // φίλτρο 100μ, με αισθητά μικρότερη κατανάλωση GPS.
    // distanceFilter 40μ — το φίλτρο δημοσίευσης είναι έτσι κι αλλιώς 100μ.
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy:       LocationAccuracy.high,
        distanceFilter: 40,
      ),
    ).listen((pos) {
      _latestPos   = pos;
      _latestPosAt = DateTime.now();
      // ignore: unawaited_futures
      _maybePublish(pos);
    });

    // Άμεση πρώτη προσπάθεια ανανέωσης (να μην περιμένει 1′ τον πρώτο κύκλο).
    try {
      final first = await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 15));
      _latestPos   = first;
      _latestPosAt = DateTime.now();
      await _maybePublish(first);
    } catch (_) {}
  }

  // Περιμένει να αποκατασταθεί ο συνδεδεμένος χρήστης (μέχρι 12s).
  Future<User?> _ensureAuth() async {
    final current = FirebaseAuth.instance.currentUser;
    if (current != null) return current;
    try {
      return await FirebaseAuth.instance
          .authStateChanges()
          .firstWhere((u) => u != null)
          .timeout(const Duration(seconds: 12));
    } catch (_) {
      return FirebaseAuth.instance.currentUser;
    }
  }

  // ── Ο πραγματικός έλεγχος ανανέωσης τοποθεσίας ──────────────────────────────
  // Χτυπάει κάθε 1′ (βλ. ForegroundTaskEventAction.repeat παρακάτω).
  // Αν ο GPS stream είναι σιωπηλός (ακίνητος οδηγός) παίρνει φρέσκο fix.
  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {
    Position? pos = _latestPos;

    // Είναι «φρέσκια» η θέση του stream; (< 90s)
    final fresh = pos != null &&
        _latestPosAt != null &&
        DateTime.now().difference(_latestPosAt!).inSeconds < 90;

    if (!fresh) {
      // 🔋 ΟΙΚΟΝΟΜΙΑ ΜΠΑΤΑΡΙΑΣ: Πριν ανάψουμε το GPS για φρέσκο fix,
      // έλεγξε αν έχει καν περάσει το interval δημοσίευσης (3′/15′).
      // Πριν, ο ακίνητος οδηγός έπαιρνε άσκοπο GPS fix ΚΑΘΕ 1′ —
      // δηλ. έως 15 fixes μέγιστης ακρίβειας πριν από κάθε write.
      // Τώρα το GPS ανάβει μόνο όταν πλησιάζει η ώρα δημοσίευσης.
      if (!await _publishIntervalElapsed()) return;

      // Ο stream δεν χτύπησε πρόσφατα → πάρε φρέσκο GPS fix μόνος σου.
      try {
        pos = await Geolocator.getCurrentPosition(
          locationSettings:
              const LocationSettings(accuracy: LocationAccuracy.high),
        ).timeout(const Duration(seconds: 15));
        _latestPos   = pos;
        _latestPosAt = DateTime.now();
      } catch (_) {}
    }

    if (pos == null) return; // δεν υπάρχει ακόμα GPS fix
    await _maybePublish(pos);
  }

  // 🔋 Επιστρέφει true ΜΟΝΟ αν έχει περάσει το interval δημοσίευσης
  // (3′ διαθέσιμος / 15′ μη διαθέσιμος) από το τελευταίο write.
  // Χρησιμοποιείται για να ΜΗΝ ανάβει το GPS άσκοπα σε ακίνητο οδηγό.
  Future<bool> _publishIntervalElapsed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final lastMs = prefs.getInt(kPrefsLastPubMs);
      if (lastMs == null) return true; // δεν έχει σταλεί ποτέ → επιτρέπεται
      final available = prefs.getBool(kPrefsAvailableKey) ?? false;
      final interval  = available
          ? kPublishIntervalAvailable
          : kPublishIntervalUnavailable;
      final elapsed = DateTime.now().millisecondsSinceEpoch - lastMs;
      return elapsed >= interval.inMilliseconds;
    } catch (_) {
      return true; // σε σφάλμα, μην μπλοκάρεις τη ροή — όπως πριν
    }
  }

  // Γράφει στο Firebase ΜΟΝΟ αν ισχύουν ΚΑΙ τα δύο:
  //   1) έχει περάσει το interval (3′ διαθέσιμος / 15′ μη διαθέσιμος)
  //   2) ο οδηγός κινήθηκε πάνω από 100μ από την τελευταία σταλμένη θέση
  Future<void> _maybePublish(Position pos) async {
    if (_publishing) return;
    _publishing = true;
    try {
      final user = await _ensureAuth();
      if (user == null) return;

      final prefs = await SharedPreferences.getInstance();
      // ΣΗΜΑΝΤΙΚΟ: το UI isolate γράφει σε αυτά τα prefs. Χωρίς reload()
      // το background isolate βλέπει παλιές (cached) τιμές.
      await prefs.reload();

      final available = prefs.getBool(kPrefsAvailableKey) ?? false;

      // 1) Έλεγχος interval
      final lastMs   = prefs.getInt(kPrefsLastPubMs);
      final interval = available
          ? kPublishIntervalAvailable
          : kPublishIntervalUnavailable;
      if (lastMs != null) {
        final elapsed = DateTime.now().millisecondsSinceEpoch - lastMs;
        if (elapsed < interval.inMilliseconds) return;
      }

      // 2) Έλεγχος απόστασης — κινήθηκε πάνω από 100μ;
      final lastLat = prefs.getDouble(kPrefsLastPubLat);
      final lastLng = prefs.getDouble(kPrefsLastPubLng);
      if (lastLat != null && lastLng != null) {
        final moved = Geolocator.distanceBetween(
          lastLat, lastLng, pos.latitude, pos.longitude,
        );
        if (moved < kMinMoveMeters) return; // ακίνητος → καμία ανανέωση
      }

      // Περάσαμε και τους δύο ελέγχους → γράφουμε στο Firebase.
      final name    = prefs.getString(kPrefsNameKey)    ?? 'Driver';
      final vehicle = prefs.getString(kPrefsVehicleKey) ?? 'taxi';

      await FirebaseFirestore.instance
          .collection('presence')
          .doc(user.uid)
          .set({
        'lat':         pos.latitude,
        'lng':         pos.longitude,
        'displayName': name,
        'vehicleType': vehicle,
        'online':      true,
        'available':   available,
        'updatedAt':   FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      // Καταγραφή της σταλμένης θέσης για τους επόμενους ελέγχους.
      await prefs.setDouble(kPrefsLastPubLat, pos.latitude);
      await prefs.setDouble(kPrefsLastPubLng, pos.longitude);
      await prefs.setInt(kPrefsLastPubMs,
          DateTime.now().millisecondsSinceEpoch);
    } catch (_) {
      // σφάλμα δικτύου/GPS → αγνόησε, θα ξαναπροσπαθήσει στον επόμενο κύκλο
    } finally {
      _publishing = false;
    }
  }

  @override
  Future<void> onNotificationPressed() async {
    FlutterForegroundTask.launchApp('/');
  }

  @override
  void onReceiveData(Object data) {
    // Μπορεί να χρησιμοποιηθεί από το UI για επικοινωνία με τον task
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    await _positionSub?.cancel();
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    await FirebaseFirestore.instance
        .collection('presence')
        .doc(user.uid)
        .update({
      'online':    false,
      'available': false,
    });
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Entry point
// ─────────────────────────────────────────────────────────────────────────────
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await NotificationsService.init();
  // Δήλωση του FCM background handler ΠΡΙΝ το runApp — ξυπνά σε δικό του
  // isolate ακόμη και με τελείως κλειστή εφαρμογή. Τυλιγμένο σε try ώστε
  // ένα σφάλμα FCM να ΜΗΝ μπλοκάρει ποτέ το ξεκίνημα της εφαρμογής.
  try {
    FcmService.registerBackgroundHandler();
  } catch (e) {
    debugPrint('FCM bg handler register error: $e');
  }
  await GoogleSignIn.instance.initialize();

  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId:          'mytaxi_location',
      channelName:        'Athens Taxi — Τοποθεσία',
      channelDescription: 'Στέλνει την τοποθεσία σου στο παρασκήνιο.',
      onlyAlertOnce:      true,
      playSound:          false,
      enableVibration:    false,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: true,
      playSound:        false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      // Χτυπάει κάθε 1′. Το onRepeatEvent αποφασίζει μόνο του αν θα
      // γράψει (interval 3′/15′ + φίλτρο 100μ) και παίρνει φρέσκο GPS
      // fix αν ο stream είναι σιωπηλός — δουλεύει με κλειστή οθόνη.
      eventAction:   ForegroundTaskEventAction.repeat(60000),
      autoRunOnBoot: true,
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );

  // Φόρτωση αποθηκευμένης επιλογής θέματος (Φωτεινό/Σκούρο/Αυτόματο)
  await ThemeController.load();
  runApp(const MyTaxiApp());
}

class MyTaxiApp extends StatelessWidget {
  const MyTaxiApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Το MaterialApp ακούει το ThemeController.mode και αλλάζει ζωντανά
    // Φωτεινό / Σκούρο / Αυτόματο (σύστημα) — επιλογή από τις Ρυθμίσεις.
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeController.mode,
      builder: (_, themeMode, _) => MaterialApp(
        title: 'Athens Taxi Booking',
        navigatorKey: NotificationsService.navigatorKey,
        theme:     appThemeLight(),
        darkTheme: appThemeDark(),
        themeMode: themeMode,
        home: WithForegroundTask(child: const AuthGateway()),
      ),
    );
  }
}
