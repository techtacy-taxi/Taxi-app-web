// lib/fcm_service.dart
//
// Push notifications μέσω Firebase Cloud Messaging (FCM).
//
// ΓΙΑΤΙ ΥΠΑΡΧΕΙ: Ο παλιός μηχανισμός εμφάνιζε ειδοποιήσεις από έναν Firestore
// listener που έτρεχε στο UI isolate — δούλευε ΜΟΝΟ όσο ζούσε το process
// (foreground service). Με swipe-to-close ή kill από το OEM, ο listener
// πέθαινε και δεν χτυπούσε τίποτα.
//
// ΤΩΡΑ: Το backend στέλνει data-only high-priority FCM. Ο
// `fcmBackgroundHandler` (top-level, @pragma vm:entry-point) ξυπνά σε ΔΙΚΟ
// του isolate ακόμη και με τελείως κλειστή εφαρμογή και εμφανίζει την
// ειδοποίηση native (flutter_local_notifications). Δεν χρειάζεται ζωντανό UI.
//
// Ο ήχος για τις δουλειές παίζει native (FLAG_INSISTENT) στο background,
// αντί για το just_audio loop που απαιτεί ζωντανό isolate.

import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'firebase_options.dart';
import 'notifications_service.dart';

// FLAG_INSISTENT (0x4): επαναλαμβάνει ήχο/δόνηση μέχρι ο χρήστης να
// αλληλεπιδράσει — η native εκδοχή του "συνεχόμενου κουδουνιού".
final Int32List _kInsistent = Int32List.fromList(<int>[4]);

/// Πληθώρα μηχανισμών μπορεί να καλέσει αυτόν τον handler. Πρέπει να είναι
/// top-level ή static + @pragma('vm:entry-point') ώστε να βρεθεί από το
/// background isolate.
@pragma('vm:entry-point')
Future<void> fcmBackgroundHandler(RemoteMessage message) async {
  // Σε background isolate ΔΕΝ υπάρχει αρχικοποιημένο Firebase — το κάνουμε εδώ.
  try {
    await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform);
  } catch (_) {/* ήδη initialized */}

  // Χρειαζόμαστε το plugin των local notifications στημένο σε αυτό το isolate.
  final fln = FlutterLocalNotificationsPlugin();
  const androidInit = AndroidInitializationSettings('@mipmap/launcher_icon');
  try {
    await fln.initialize(
      const InitializationSettings(android: androidInit),
    );
  } catch (_) {}
  // Σιγουρεύουμε ότι υπάρχουν τα channels (το isolate μπορεί να είναι φρέσκο).
  await _ensureChannelsBg(fln);

  // Σίγαση: αν ο χρήστης έχει βάλει mute, η ειδοποίηση έρχεται αλλά ΧΩΡΙΣ
  // ήχο/δόνηση (σιωπηλό channel, χωρίς INSISTENT). Διαβάζεται από SharedPrefs
  // — δουλεύει & σε αυτό το background isolate με κλειστή εφαρμογή.
  final muted = await isMutedNow();

  await _displayFromMessage(fln, message.data, muted);
}

/// Εμφανίζει την κατάλληλη native ειδοποίηση ανάλογα με το `type` του payload.
Future<void> _displayFromMessage(
    FlutterLocalNotificationsPlugin fln, Map<String, dynamic> data,
    bool muted) async {
  final type = (data['type'] ?? '').toString();

  switch (type) {
    case 'new_job':
    case 'job_reopened':
      await _showJobBg(fln, data, muted);
      break;
    case 'new_batch':
      await _showBatchBg(fln, data, muted);
      break;
    case 'cancel_job':
      // Η δουλειά ακυρώθηκε / την πήρε άλλος → σταμάτα τον ήχο & σβήσε την.
      await _cancelJobBg(fln, data);
      break;
    case 'boarded':
      await _showBoardedBg(fln, data, muted);
      break;
    case 'approval':
      await _showApprovalBg(fln, data, muted);
      break;
    case 'upgrade':
      await _showUpgradeBg(fln, data);
      break;
    case 'owner_taken':
    case 'owner_stage':
    case 'owner_expired':
      await _showOwnerBg(fln, data);
      break;
    case 'public_booking':
      await _showPublicBookingBg(fln, data);
      break;
    default:
      // Άγνωστος τύπος — εμφάνισε γενικό ώστε να μη χαθεί.
      await _showGenericBg(fln, data, muted);
  }
}

/// Ακυρώνει την ειδοποίηση μιας δουλειάς (ίδιο ID με αυτό που τη δημιούργησε).
/// Το cancel σταματά αμέσως τον FLAG_INSISTENT ήχο/δόνηση.
Future<void> _cancelJobBg(
    FlutterLocalNotificationsPlugin fln, Map<String, dynamic> d) async {
  final jobId = (d['jobId'] ?? '').toString();
  if (jobId.isEmpty) return;
  try {
    await fln.cancel(jobId.hashCode.abs() & 0x7FFFFFFF);
  } catch (_) {}
}

// ── Native εμφανίσεις (χωρίς just_audio — δουλεύουν με νεκρό process) ────────

Future<void> _showJobBg(
    FlutterLocalNotificationsPlugin fln, Map<String, dynamic> d,
    bool muted) async {
  final jobId = (d['jobId'] ?? '').toString();
  if (jobId.isEmpty) return;
  final from  = (d['fromAddr'] ?? '').toString();
  final to    = (d['toAddr'] ?? '').toString();
  final price = (d['price'] ?? '').toString();
  final title = (d['title'] ?? '🚖 Νέα Δουλειά!').toString();
  final body  = price.isNotEmpty ? '$from → $to   •   €$price' : '$from → $to';

  final android = AndroidNotificationDetails(
    muted ? kJobChannelMutedId : kJobChannelId,
    muted ? 'Νέες Δουλειές (σίγαση)' : kJobChannelName,
    channelDescription: kJobChannelDesc,
    importance:        Importance.max,
    priority:          Priority.max,
    category:          AndroidNotificationCategory.call,
    visibility:        NotificationVisibility.public,
    fullScreenIntent:  !muted,
    autoCancel:        true,
    playSound:         !muted,
    audioAttributesUsage: AudioAttributesUsage.alarm,
    enableVibration:   !muted,
    vibrationPattern:  muted ? null : kStrongVibration,
    enableLights:      true,
    additionalFlags:   muted ? null : _kInsistent,
    styleInformation:  BigTextStyleInformation(body),
    actions: const <AndroidNotificationAction>[
      AndroidNotificationAction(kActionView, 'Προβολή',
          showsUserInterface: true, cancelNotification: true),
      AndroidNotificationAction(kActionReject, 'Απόρριψη',
          showsUserInterface: false, cancelNotification: true),
    ],
  );

  await fln.show(
    jobId.hashCode.abs() & 0x7FFFFFFF,
    title,
    body,
    NotificationDetails(android: android),
    payload: jsonEncode({'jobId': jobId}),
  );
}

Future<void> _showBatchBg(
    FlutterLocalNotificationsPlugin fln, Map<String, dynamic> d,
    bool muted) async {
  final batchId = (d['batchId'] ?? '').toString();
  if (batchId.isEmpty) return;
  final count = (d['count'] ?? '').toString();
  final total = (d['totalPrice'] ?? '').toString();
  final title = (d['title'] ?? '🚖 Πρόγραμμα δουλειών για σένα').toString();
  final n     = int.tryParse(count) ?? 0;
  final body  = total.isNotEmpty
      ? '$n δουλειές • σύνολο €$total'
      : '$n δουλειές';

  final android = AndroidNotificationDetails(
    muted ? kJobChannelMutedId : kJobChannelId,
    muted ? 'Νέες Δουλειές (σίγαση)' : kJobChannelName,
    channelDescription: kJobChannelDesc,
    importance:        Importance.max,
    priority:          Priority.max,
    category:          AndroidNotificationCategory.call,
    visibility:        NotificationVisibility.public,
    fullScreenIntent:  !muted,
    autoCancel:        true,
    playSound:         !muted,
    audioAttributesUsage: AudioAttributesUsage.alarm,
    enableVibration:   !muted,
    vibrationPattern:  muted ? null : kStrongVibration,
    enableLights:      true,
    additionalFlags:   muted ? null : _kInsistent,
    styleInformation:  BigTextStyleInformation(body),
    actions: const <AndroidNotificationAction>[
      AndroidNotificationAction(kActionView, 'Προβολή',
          showsUserInterface: true, cancelNotification: true),
    ],
  );

  await fln.show(
    (batchId.hashCode.abs() & 0x7FFFFFFF) ^ 0x0BA7C,
    title,
    body,
    NotificationDetails(android: android),
    payload: jsonEncode({'batchId': batchId, 'type': 'batch'}),
  );
}

Future<void> _showBoardedBg(
    FlutterLocalNotificationsPlugin fln, Map<String, dynamic> d,
    bool muted) async {
  final jobId  = (d['jobId'] ?? '').toString();
  final driver = (d['driverName'] ?? '').toString();
  final from   = (d['fromAddr'] ?? '').toString();
  final to     = (d['toAddr'] ?? '').toString();

  final android = AndroidNotificationDetails(
    muted ? kBoardChannelMutedId : kBoardChannelId,
    muted ? 'Επιβιβάσεις (σίγαση)' : kBoardChannelName,
    channelDescription: kBoardChannelDesc,
    importance:       Importance.max,
    priority:         Priority.max,
    visibility:       NotificationVisibility.public,
    autoCancel:       true,
    enableVibration:  !muted,
    vibrationPattern: muted ? null : kStrongVibration,
    enableLights:     true,
    styleInformation: BigTextStyleInformation('$from → $to'),
  );

  await fln.show(
    (jobId.hashCode.abs() & 0x7FFFFFFF) ^ 0x0B0AD,
    driver.isNotEmpty ? '🚗 Επιβίβαση — $driver' : '🚗 Επιβίβαση πελάτη',
    '$from → $to',
    NotificationDetails(android: android),
    payload: jsonEncode({'jobId': jobId, 'type': 'boarded'}),
  );
}

Future<void> _showApprovalBg(
    FlutterLocalNotificationsPlugin fln, Map<String, dynamic> d,
    bool muted) async {
  final name    = (d['pendingName'] ?? '').toString();
  final phone   = (d['phone'] ?? '').toString();
  final vModel  = (d['vehicleModel'] ?? '').toString();
  final plate   = (d['plateNumber'] ?? '').toString();
  final vType   = (d['vehicleType'] ?? '').toString();
  final vLabel  = vType == 'van' ? 'Van' : (vType == 'taxi' ? 'Taxi' : '');

  final lines = <String>[
    if (phone.isNotEmpty) '📞 $phone',
    if (vModel.isNotEmpty || plate.isNotEmpty || vLabel.isNotEmpty)
      '🚗 ${[vLabel, vModel, plate].where((s) => s.isNotEmpty).join(' • ')}',
  ];
  final body = name.isNotEmpty
      ? '$name περιμένει έγκριση'
      : 'Νέος οδηγός περιμένει έγκριση';
  final big = ([body, ...lines]).join('\n');

  final android = AndroidNotificationDetails(
    muted ? kApprovalChannelMutedId : kApprovalChannelId,
    muted ? 'Αιτήματα Έγκρισης (σίγαση)' : kApprovalChannelName,
    channelDescription: kApprovalChannelDesc,
    importance:       Importance.max,
    priority:         Priority.max,
    visibility:       NotificationVisibility.public,
    autoCancel:       true,
    enableVibration:  !muted,
    vibrationPattern: muted ? null : kStrongVibration,
    enableLights:     true,
    styleInformation: BigTextStyleInformation(big),
  );

  await fln.show(
    kApprovalNotifId,
    '👤 Νέο αίτημα έγκρισης',
    lines.isNotEmpty ? '$body  •  ${lines.join('  ')}' : body,
    NotificationDetails(android: android),
    payload: jsonEncode({'type': 'approval'}),
  );
}

/// Ειδοποίηση «νέα αναβάθμιση διαθέσιμη» — χτυπά δυνατά (FLAG_INSISTENT)
/// ακόμη και με τελείως κλειστή εφαρμογή. Σταθερό ID ώστε να μη
/// συσσωρεύονται διπλές αν σταλεί ξανά.
Future<void> _showUpgradeBg(
    FlutterLocalNotificationsPlugin fln, Map<String, dynamic> d) async {
  final title = (d['title'] ?? '⬆️ Νέα αναβάθμιση!').toString();
  final body  = (d['body'] ?? 'Διαθέσιμη νέα έκδοση της εφαρμογής. '
      'Παρακαλώ αναβαθμιστείτε.').toString();

  // Η αναβάθμιση χτυπά ΠΑΝΤΑ δυνατά — ακόμη & σε σίγαση (κρίσιμη ειδοποίηση).
  final android = AndroidNotificationDetails(
    kUpdateChannelId,
    kUpdateChannelName,
    channelDescription: kUpdateChannelDesc,
    importance:       Importance.max,
    priority:         Priority.max,
    category:         AndroidNotificationCategory.call,
    visibility:       NotificationVisibility.public,
    fullScreenIntent: true,
    autoCancel:       true,
    playSound:        true,
    audioAttributesUsage: AudioAttributesUsage.alarm,
    enableVibration:  true,
    vibrationPattern: kStrongVibration,
    enableLights:     true,
    additionalFlags:  _kInsistent,
    styleInformation: BigTextStyleInformation(body),
  );

  await fln.show(
    0x0FDA7E, // σταθερό ID αναβάθμισης
    title,
    body,
    NotificationDetails(android: android),
    payload: jsonEncode({'type': 'upgrade'}),
  );
}

/// Owner ειδοποίηση (admin/master που έβγαλε τη δουλειά). Βαράει ΠΑΝΤΑ — και
/// σε σίγαση. Δείχνεται όταν η εφαρμογή είναι εκτός/κλειστή· σε foreground τη
/// δείχνει αντ' αυτής το in-app dialog (owner_alerts.dart).
Future<void> _showOwnerBg(
    FlutterLocalNotificationsPlugin fln, Map<String, dynamic> d) async {
  final type  = (d['type'] ?? '').toString();
  final jobId = (d['jobId'] ?? '').toString();
  final title = (d['title'] ?? 'Ειδοποίηση δουλειάς').toString();
  final from  = (d['fromAddr'] ?? '').toString();
  final to    = (d['toAddr'] ?? '').toString();
  final baseBody = (d['body'] ?? '').toString();
  final route = (from.isNotEmpty || to.isNotEmpty) ? '$from → $to' : '';
  final body  = [baseBody, route].where((s) => s.isNotEmpty).join('\n');

  final android = AndroidNotificationDetails(
    kOwnerChannelId,
    kOwnerChannelName,
    channelDescription: kOwnerChannelDesc,
    importance:       Importance.max,
    priority:         Priority.max,
    category:         AndroidNotificationCategory.call,
    visibility:       NotificationVisibility.public,
    autoCancel:       true,
    playSound:        true,
    audioAttributesUsage: AudioAttributesUsage.alarm,
    enableVibration:  true,
    vibrationPattern: kStrongVibration,
    enableLights:     true,
    styleInformation: BigTextStyleInformation(body),
  );

  // Μοναδικό id ανά (δουλειά, τύπος) ώστε να μη σβήνει το ένα το άλλο.
  final notifId =
      ((jobId.hashCode.abs() & 0x7FFFFFFF) ^ type.hashCode) & 0x7FFFFFFF;
  await fln.show(
    notifId,
    title,
    body,
    NotificationDetails(android: android),
    payload: jsonEncode({'jobId': jobId, 'type': type}),
  );
}

/// Ειδοποίηση ΝΕΑΣ ΚΡΑΤΗΣΗΣ ΑΠΟ ΤΗ ΦΟΡΜΑ της ιστοσελίδας (μόνο στον master).
/// Η δουλειά έχει ήδη μπει στις «Αποθηκευμένες». Έντονη ειδοποίηση (owner
/// channel) με 🌐 στην αρχή του τίτλου ώστε να ξεχωρίζει αμέσως.
Future<void> _showPublicBookingBg(
    FlutterLocalNotificationsPlugin fln, Map<String, dynamic> d) async {
  final from = (d['from'] ?? '').toString();
  final to   = (d['to'] ?? '').toString();
  final name = (d['clientName'] ?? '').toString();
  final when = (d['when'] ?? '').toString();
  final savedJobId = (d['savedJobId'] ?? '').toString();

  final title = '🌐 ${(d['title'] ?? 'Νέα κράτηση από φόρμα')}';
  final route = (from.isNotEmpty || to.isNotEmpty) ? '$from → $to' : '';
  final extra = [name, when].where((s) => s.isNotEmpty).join(' · ');
  final body  = [route, extra].where((s) => s.isNotEmpty).join('\n');

  final android = AndroidNotificationDetails(
    kOwnerChannelId,
    kOwnerChannelName,
    channelDescription: kOwnerChannelDesc,
    importance:       Importance.max,
    priority:         Priority.max,
    category:         AndroidNotificationCategory.message,
    visibility:       NotificationVisibility.public,
    autoCancel:       true,
    playSound:        true,
    audioAttributesUsage: AudioAttributesUsage.alarm,
    enableVibration:  true,
    vibrationPattern: kStrongVibration,
    enableLights:     true,
    styleInformation: BigTextStyleInformation(body),
  );

  final notifId =
      (('booking'.hashCode ^ savedJobId.hashCode).abs()) & 0x7FFFFFFF;
  await fln.show(
    notifId,
    title,
    body,
    NotificationDetails(android: android),
    payload: jsonEncode({'savedJobId': savedJobId, 'type': 'public_booking'}),
  );
}

Future<void> _showGenericBg(
    FlutterLocalNotificationsPlugin fln, Map<String, dynamic> d,
    bool muted) async {
  final title = (d['title'] ?? 'Ειδοποίηση').toString();
  final android = AndroidNotificationDetails(
    muted ? kUpdateChannelMutedId : kUpdateChannelId,
    muted ? 'Ενημερώσεις (σίγαση)' : kUpdateChannelName,
    channelDescription: kUpdateChannelDesc,
    importance: Importance.high,
    priority: Priority.high,
    enableVibration: !muted,
    vibrationPattern: muted ? null : kStrongVibration,
  );
  await fln.show(
    DateTime.now().millisecondsSinceEpoch & 0x7FFFFFFF,
    title, (d['body'] ?? '').toString(),
    NotificationDetails(android: android),
    payload: jsonEncode(d),
  );
}

Future<void> _ensureChannelsBg(FlutterLocalNotificationsPlugin fln) async {
  final android = fln.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  if (android == null) return;
  Future<void> ch(String id, String name, String desc) async {
    try {
      await android.createNotificationChannel(AndroidNotificationChannel(
        id, name,
        description: desc,
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
        vibrationPattern: kStrongVibration,
      ));
    } catch (_) {}
  }
  await ch(kJobChannelId, kJobChannelName, kJobChannelDesc);
  await ch(kBoardChannelId, kBoardChannelName, kBoardChannelDesc);
  await ch(kApprovalChannelId, kApprovalChannelName, kApprovalChannelDesc);
  await ch(kUpdateChannelId, kUpdateChannelName, kUpdateChannelDesc);

  // Σιωπηλά δίδυμα channels (σίγαση: χωρίς ήχο & χωρίς δόνηση).
  Future<void> silent(String id, String name, String desc) async {
    try {
      await android.createNotificationChannel(AndroidNotificationChannel(
        id, name,
        description: desc,
        importance: Importance.high,
        playSound: false,
        enableVibration: false,
      ));
    } catch (_) {}
  }
  await silent(kJobChannelMutedId,      'Νέες Δουλειές (σίγαση)',     kJobChannelDesc);
  await silent(kBoardChannelMutedId,    'Επιβιβάσεις (σίγαση)',       kBoardChannelDesc);
  await silent(kApprovalChannelMutedId, 'Αιτήματα Έγκρισης (σίγαση)', kApprovalChannelDesc);
  await silent(kUpdateChannelMutedId,   'Ενημερώσεις (σίγαση)',       kUpdateChannelDesc);

  // Owner channel — χτυπά ΠΑΝΤΑ.
  try {
    await android.createNotificationChannel(AndroidNotificationChannel(
      kOwnerChannelId, kOwnerChannelName,
      description: kOwnerChannelDesc,
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      vibrationPattern: kStrongVibration,
    ));
  } catch (_) {}
}

// ─── Public API ─────────────────────────────────────────────────────────────

class FcmService {
  static final FirebaseMessaging _fm = FirebaseMessaging.instance;

  /// Καλείται από το main() ΠΡΙΝ το runApp. Δηλώνει τον background handler.
  static void registerBackgroundHandler() {
    FirebaseMessaging.onBackgroundMessage(fcmBackgroundHandler);
  }

  /// Καλείται ΜΕΤΑ το login (όταν ξέρουμε το uid). Παίρνει το token, το
  /// αποθηκεύει στο presence/{uid}.fcmToken και στήνει τους foreground
  /// listeners. Επανακαλείται αυτόματα όταν αλλάζει το token.
  static Future<void> initForUser(String uid) async {
    if (uid.isEmpty) return;

    // Άδεια ειδοποιήσεων (Android 13+ / iOS).
    try {
      await _fm
          .requestPermission(alert: true, badge: true, sound: true)
          .timeout(const Duration(seconds: 8));
    } catch (_) {}

    // Πάρε & αποθήκευσε το token — με timeout ώστε να ΜΗΝ κρεμάει ποτέ.
    try {
      final token = await _fm.getToken().timeout(const Duration(seconds: 10));
      if (token != null) await _saveToken(uid, token);
    } catch (e) {
      debugPrint('FCM getToken error/timeout: $e');
    }

    // Ανανέωση token (μπορεί να αλλάξει).
    try {
      _fm.onTokenRefresh.listen((t) => _saveToken(uid, t));
    } catch (_) {}
  }

  static Future<void> _saveToken(String uid, String token) async {
    try {
      // update (όχι set) ώστε να ΜΗΝ δημιουργεί presence doc για νέο χρήστη
      // που δεν έχει ακόμη συμπληρώσει τη φόρμα — αλλιώς μπερδεύεται η ροή
      // εγγραφής. Αν το doc δεν υπάρχει, το update αποτυγχάνει αθόρυβα και
      // το token θα γραφτεί την επόμενη φορά (αφού φτιαχτεί το προφίλ).
      await FirebaseFirestore.instance
          .collection('presence')
          .doc(uid)
          .update({
            'fcmToken': token,
            'fcmUpdatedAt': FieldValue.serverTimestamp(),
          });
      debugPrint('FCM token saved for $uid');
    } catch (e) {
      debugPrint('FCM save token skipped (no presence doc yet?): $e');
    }
  }

  /// Καλείται στο logout — καθαρίζει το token ώστε να μη λαμβάνει άλλο.
  static Future<void> clearToken(String uid) async {
    try {
      await FirebaseFirestore.instance
          .collection('presence')
          .doc(uid)
          .set({'fcmToken': null}, SetOptions(merge: true));
      await _fm.deleteToken();
    } catch (_) {}
  }
}
