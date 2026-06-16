// lib/notifications_service.dart
//
// Local notifications με κουμπιά Προβολή/Απόρριψη + συνεχόμενο κουδούνι
// σε loop μέχρι ο χρήστης να πατήσει κουμπί.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

// ─── Σταθερές ────────────────────────────────────────────────────────────────
const String kJobChannelId      = 'job_alerts_v3';   // v3 = δυνατή δόνηση
const String kJobChannelName    = 'Νέες Δουλειές';
const String kJobChannelDesc    = 'Ειδοποιήσεις για νέες δουλειές';
const String kPrefsRejectedJobs = 'rejected_jobs_v2_map'; // jobId → rejection timestamp (ms)

// Channel για ειδοποιήσεις αναβάθμισης / υπενθυμίσεων
const String kUpdateChannelId   = 'app_updates_v1';
const String kUpdateChannelName = 'Ενημερώσεις & Υπενθυμίσεις';
const String kUpdateChannelDesc = 'Νέες εκδόσεις και υπενθυμίσεις ραντεβού';

// Channel για αιτήματα έγκρισης (μόνο master)
const String kApprovalChannelId   = 'approval_requests_v1';
const String kApprovalChannelName = 'Αιτήματα Έγκρισης';
const String kApprovalChannelDesc = 'Νέοι οδηγοί που περιμένουν έγκριση';
// Σταθερό id ώστε το notification να ανανεώνεται αντί να πληθαίνει.
const int    kApprovalNotifId     = 880001;

// Channel για επιβιβάσεις (ο admin που έβγαλε τη δουλειά)
const String kBoardChannelId   = 'boarding_alerts_v1';
const String kBoardChannelName = 'Επιβιβάσεις';
const String kBoardChannelDesc = 'Όταν οδηγός επιβιβάζει πελάτη σε δουλειά σου';

// Channel για ειδοποιήσεις OWNER (admin/master που έβγαλε τη δουλειά).
// Βαράει ΠΑΝΤΑ — δεν επηρεάζεται από τη σίγαση (κρίσιμα γεγονότα δουλειάς).
const String kOwnerChannelId   = 'owner_alerts_v1';
const String kOwnerChannelName = 'Δουλειές μου';
const String kOwnerChannelDesc = 'Ποιος πήρε τη δουλειά, λήξη χρόνου, καμία εξυπηρέτηση';

// Δυνατό μοτίβο δόνησης: 4 έντονοι παλμοί 800ms
final Int64List kStrongVibration =
    Int64List.fromList([0, 800, 400, 800, 400, 800, 400, 800]);

const String kActionView        = 'job_view';
const String kActionReject      = 'job_reject';

// ─── Σίγαση (mute) ──────────────────────────────────────────────────────────
// Το ίδιο key που γράφει το map_page.dart (_saveSettings → prefs 'muted').
// Διαβάζεται και από το background isolate του FCM ώστε, σε σίγαση, καμία
// ειδοποίηση να ΜΗΝ έχει ήχο ή δόνηση — εντός, εκτός & με κλειστή εφαρμογή.
const String kMutedPrefKey = 'muted';

/// Επιστρέφει true αν ο χρήστης έχει βάλει σίγαση. Διαβάζει απευθείας από
/// SharedPreferences ώστε να δουλεύει και σε φρέσκο background isolate.
Future<bool> isMutedNow() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(kMutedPrefKey) ?? false;
  } catch (_) {
    return false;
  }
}

// ─── ΣΙΩΠΗΛΑ δίδυμα channels ─────────────────────────────────────────────────
// Στο Android 8+ ο ήχος/δόνηση κλειδώνονται στο channel τη στιγμή που
// δημιουργείται. Για «έρχονται ειδοποιήσεις αλλά χωρίς ήχο/δόνηση» χρειάζονται
// ξεχωριστά channels με playSound:false & enableVibration:false.
const String kJobChannelMutedId      = 'job_alerts_muted_v1';
const String kUpdateChannelMutedId   = 'app_updates_muted_v1';
const String kApprovalChannelMutedId = 'approval_requests_muted_v1';
const String kBoardChannelMutedId    = 'boarding_alerts_muted_v1';

// ─── Υπενθυμίσεις ραντεβού (exact alarms) ───────────────────────────────────
// Χρονικά σημεία πριν το ραντεβού που χτυπάει υπενθύμιση.
const List<int> kReminderOffsets = [30, 10];
// Key όπου κρατάμε τα notifIds των προγραμματισμένων reminders (για cancel).
const String kScheduledReminderIds = 'scheduled_reminder_ids_v2';
// Key που γράφεται όταν ο οδηγός πατήσει το reminder → εμφανίζεται η κάρτα.
const String kPendingReminderCard  = 'pending_reminder_card_v1';

/// Ζώνη ώρας της εφαρμογής. Η εφαρμογή λειτουργεί στην Ελλάδα· η βάση
/// timezone χειρίζεται μόνη της τη θερινή/χειμερινή ώρα (DST).
const String kAppTimeZone = 'Europe/Athens';

/// Απλό data holder για ένα προγραμματισμένο ραντεβού.
/// Κρατά το NotificationsService αποσυνδεδεμένο από το μοντέλο Job.
class ReminderSpec {
  final String   jobId;
  final String   from;
  final String   to;
  final DateTime scheduledAt;
  const ReminderSpec({
    required this.jobId,
    required this.from,
    required this.to,
    required this.scheduledAt,
  });
}

// Cross-isolate flag (background isolate → main isolate)
const String kStopRingtoneFlag  = 'stop_ringtone_flag_v1';

// Auto-stop ringtone μετά από 60s για ασφάλεια
const Duration kMaxRingDuration = Duration(seconds: 60);

final FlutterLocalNotificationsPlugin _localNotifs =
    FlutterLocalNotificationsPlugin();

// ─── Ringtone loop ──────────────────────────────────────────────────────────
AudioPlayer? _ringtonePlayer;
Timer?       _stopFlagWatcher;
Timer?       _autoStopTimer;

Future<void> startRingtoneLoop({
  Duration? maxDuration,
  bool keepIfPlaying = false,
}) async {
  // Αν ζητήθηκε να συνεχίσει χωρίς διακοπή και ήδη παίζει,
  // απλώς ανανέωσε το auto-stop cap χωρίς restart του ήχου.
  if (keepIfPlaying && _ringtonePlayer != null) {
    try {
      _autoStopTimer?.cancel();
      _autoStopTimer = Timer(maxDuration ?? kMaxRingDuration, stopRingtoneLoop);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kStopRingtoneFlag, false);
    } catch (_) {}
    return;
  }
  await stopRingtoneLoop();
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kStopRingtoneFlag, false);

    _ringtonePlayer = AudioPlayer();
    await _ringtonePlayer!.setAsset('assets/Notifaction Bell.mp3');
    await _ringtonePlayer!.setLoopMode(LoopMode.one);
    await _ringtonePlayer!.setVolume(1.0);
    // ignore: unawaited_futures
    _ringtonePlayer!.play();

    _stopFlagWatcher = Timer.periodic(const Duration(milliseconds: 300), (_) async {
      try {
        final p = await SharedPreferences.getInstance();
        // ΣΗΜΑΝΤΙΚΟ: ο background isolate (localNotifBgActionHandler) γράφει
        // το flag σε ξεχωριστό isolate. Χωρίς reload() το UI isolate βλέπει
        // πάντα την cached τιμή false → ο ήχος δεν σταματά ποτέ.
        await p.reload();
        if (p.getBool(kStopRingtoneFlag) == true) {
          await stopRingtoneLoop();
        }
      } catch (_) {}
    });

    // Auto-stop ασφαλείας (μεγαλύτερο για υπενθυμίσεις ραντεβού)
    _autoStopTimer = Timer(maxDuration ?? kMaxRingDuration, stopRingtoneLoop);
  } catch (e) {
    debugPrint('[Ringtone] start error: $e');
  }
}

Future<void> stopRingtoneLoop() async {
  _stopFlagWatcher?.cancel();
  _stopFlagWatcher = null;
  _autoStopTimer?.cancel();
  _autoStopTimer = null;
  final player = _ringtonePlayer;
  _ringtonePlayer = null;
  try {
    await player?.stop();
    await player?.dispose();
  } catch (_) {}
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kStopRingtoneFlag, false);
  } catch (_) {}
}

// ─── Background action handler ──────────────────────────────────────────────
@pragma('vm:entry-point')
void localNotifBgActionHandler(NotificationResponse response) {
  _signalStopRingtone();
  if (response.actionId == kActionReject && response.payload != null) {
    _saveRejectedJobId(response.payload!);
  }
  // Tap σε υπενθύμιση ραντεβού → άσε σημάδι να εμφανιστεί η κάρτα στο άνοιγμα.
  if (response.payload != null) {
    _maybeSavePendingReminder(response.payload!);
  }
}

/// Αν το payload είναι τύπου appointment, αποθηκεύει την εκκρεμή κάρτα
/// ώστε ο JobListener να την εμφανίσει μόλις ανοίξει η εφαρμογή.
Future<void> _maybeSavePendingReminder(String payloadJson) async {
  try {
    final data = jsonDecode(payloadJson) as Map<String, dynamic>;
    if (data['type'] != 'appointment') return;
    final jobId = data['jobId'] as String?;
    if (jobId == null || jobId.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kPendingReminderCard, jsonEncode({
      'jobId': jobId,
      'minsBefore': (data['minsBefore'] as num?)?.toInt() ?? 0,
    }));
  } catch (_) {}
}

Future<void> _signalStopRingtone() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kStopRingtoneFlag, true);
  } catch (_) {}
}

Future<void> _saveRejectedJobId(String payloadJson) async {
  try {
    final data  = jsonDecode(payloadJson) as Map<String, dynamic>;
    final jobId = data['jobId'] as String?;
    if (jobId == null || jobId.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getString(kPrefsRejectedJobs);
    final Map<String, dynamic> map =
        raw == null ? <String, dynamic>{} : (jsonDecode(raw) as Map<String, dynamic>);
    map[jobId] = DateTime.now().millisecondsSinceEpoch;
    // Διατήρησε μέγεθος < 200
    if (map.length > 200) {
      final entries = map.entries.toList()
        ..sort((a, b) => (a.value as int).compareTo(b.value as int));
      while (entries.length > 200) {
        map.remove(entries.removeAt(0).key);
      }
    }
    await prefs.setString(kPrefsRejectedJobs, jsonEncode(map));
  } catch (e) {
    debugPrint('rejectJob error: $e');
  }
}

// ─── Αρχικοποίηση plugin + channel ──────────────────────────────────────────
Future<void> initLocalNotifPlugin({
  void Function(NotificationResponse)? onForegroundTap,
}) async {
  // Αρχικοποίηση timezone database — απαραίτητο για zonedSchedule.
  try {
    tzdata.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation(kAppTimeZone));
  } catch (e) {
    debugPrint('tz init error: $e');
  }

  const androidInit = AndroidInitializationSettings('@mipmap/launcher_icon');
  try {
    await _localNotifs.initialize(
      const InitializationSettings(android: androidInit),
      onDidReceiveNotificationResponse:           onForegroundTap,
      onDidReceiveBackgroundNotificationResponse: localNotifBgActionHandler,
    );
  } catch (e) {
    debugPrint('notif initialize error: $e');
  }

  final androidPlugin = _localNotifs.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  if (androidPlugin == null) {
    debugPrint('notif: androidPlugin is null!');
    return;
  }

  // 1. Ζήτησε άδεια ειδοποιήσεων ΠΡΩΤΑ (Android 13+)
  try {
    final granted = await androidPlugin.requestNotificationsPermission();
    debugPrint('notif permission granted: $granted');
  } catch (e) {
    debugPrint('notif permission error: $e');
  }

  // 1b. Ζήτησε άδεια exact alarms (Android 12+) — απαραίτητο ώστε οι
  //     υπενθυμίσεις ραντεβού να χτυπούν στην ΑΚΡΙΒΗ ώρα μέσα από Doze.
  try {
    final canExact = await androidPlugin.canScheduleExactNotifications();
    debugPrint('canScheduleExactNotifications: $canExact');
    if (canExact == false) {
      // Ανοίγει την οθόνη ρυθμίσεων «Alarms & reminders» για να το επιτρέψει.
      await androidPlugin.requestExactAlarmsPermission();
    }
  } catch (e) {
    debugPrint('exact alarm permission error: $e');
  }

  // 2. Διέγραψε ΟΛΑ τα παλιά channels ώστε να μη φαίνονται διπλά
  for (final old in const ['job_alerts', 'job_alerts_v1',
      'job_alerts_v2', 'job_alerts_v3_old']) {
    try {
      await androidPlugin.deleteNotificationChannel(old);
    } catch (_) {}
  }

  // 3. Δημιούργησε τα channels (με logging σε σφάλμα)
  await _ensureChannels(androidPlugin);
}

// Δημιουργία/εξασφάλιση των notification channels.
Future<void> _ensureChannels(
    AndroidFlutterLocalNotificationsPlugin androidPlugin) async {
  try {
    await androidPlugin.createNotificationChannel(
      AndroidNotificationChannel(
        kJobChannelId,
        kJobChannelName,
        description:      kJobChannelDesc,
        importance:       Importance.max,
        playSound:        true,
        enableVibration:  true,
        vibrationPattern: kStrongVibration,
        showBadge:        true,
      ),
    );
    debugPrint('notif: channel $kJobChannelId created');
  } catch (e) {
    debugPrint('notif: job channel error: $e');
  }

  try {
    await androidPlugin.createNotificationChannel(
      AndroidNotificationChannel(
        kUpdateChannelId,
        kUpdateChannelName,
        description:      kUpdateChannelDesc,
        importance:       Importance.high,
        playSound:        true,
        enableVibration:  true,
        vibrationPattern: kStrongVibration,
        showBadge:        true,
      ),
    );
    debugPrint('notif: channel $kUpdateChannelId created');
  } catch (e) {
    debugPrint('notif: update channel error: $e');
  }

  try {
    await androidPlugin.createNotificationChannel(
      AndroidNotificationChannel(
        kApprovalChannelId,
        kApprovalChannelName,
        description:      kApprovalChannelDesc,
        importance:       Importance.high,
        playSound:        true,
        enableVibration:  true,
        vibrationPattern: kStrongVibration,
        showBadge:        true,
      ),
    );
    debugPrint('notif: channel $kApprovalChannelId created');
  } catch (e) {
    debugPrint('notif: approval channel error: $e');
  }

  try {
    await androidPlugin.createNotificationChannel(
      AndroidNotificationChannel(
        kBoardChannelId,
        kBoardChannelName,
        description:      kBoardChannelDesc,
        importance:       Importance.high,
        playSound:        true,
        enableVibration:  true,
        vibrationPattern: kStrongVibration,
        showBadge:        true,
      ),
    );
    debugPrint('notif: channel $kBoardChannelId created');
  } catch (e) {
    debugPrint('notif: board channel error: $e');
  }

  // ── ΣΙΩΠΗΛΑ δίδυμα channels (σίγαση: χωρίς ήχο & χωρίς δόνηση) ──────────────
  Future<void> silentCh(String id, String name, String desc) async {
    try {
      await androidPlugin.createNotificationChannel(
        AndroidNotificationChannel(
          id,
          name,
          description:     desc,
          importance:      Importance.high, // εμφανίζεται κανονικά, απλώς αθόρυβα
          playSound:       false,
          enableVibration: false,
          showBadge:       true,
        ),
      );
    } catch (e) {
      debugPrint('notif: silent channel $id error: $e');
    }
  }

  await silentCh(kJobChannelMutedId,      'Νέες Δουλειές (σίγαση)',     kJobChannelDesc);
  await silentCh(kUpdateChannelMutedId,   'Ενημερώσεις (σίγαση)',       kUpdateChannelDesc);
  await silentCh(kApprovalChannelMutedId, 'Αιτήματα Έγκρισης (σίγαση)', kApprovalChannelDesc);
  await silentCh(kBoardChannelMutedId,    'Επιβιβάσεις (σίγαση)',       kBoardChannelDesc);

  // Owner channel — χτυπά ΠΑΝΤΑ (ήχος + δόνηση), αγνοεί τη σίγαση.
  try {
    await androidPlugin.createNotificationChannel(
      AndroidNotificationChannel(
        kOwnerChannelId,
        kOwnerChannelName,
        description:      kOwnerChannelDesc,
        importance:       Importance.max,
        playSound:        true,
        enableVibration:  true,
        vibrationPattern: kStrongVibration,
        showBadge:        true,
      ),
    );
  } catch (e) {
    debugPrint('notif: owner channel error: $e');
  }
}

// ─── Εμφάνιση notification + ξεκίνημα ringtone loop ─────────────────────────
Future<void> showJobNotification({
  required String jobId,
  required String from,
  required String to,
  String price = '',
  String title = '🚖 Νέα Δουλειά!',
  bool   withReturn = false,
  bool   withStops  = false,
}) async {
  if (jobId.isEmpty) return;

  final tags = <String>[];
  if (withReturn) tags.add('🔄 ΜΕ ΕΠΙΣΤΡΟΦΗ');
  if (withStops)  tags.add('🛑 ΜΕ ΣΤΑΣΕΙΣ');
  final tagLine = tags.isEmpty ? '' : '\n${tags.join('   ')}';

  final body = (price.isNotEmpty
          ? '$from → $to   •   €$price'
          : '$from → $to') +
      tagLine;

  final muted = await isMutedNow();

  final androidDetails = AndroidNotificationDetails(
    muted ? kJobChannelMutedId : kJobChannelId,
    muted ? 'Νέες Δουλειές (σίγαση)' : kJobChannelName,
    channelDescription: kJobChannelDesc,
    importance:         Importance.max,
    priority:           Priority.max,
    category:           AndroidNotificationCategory.call,
    visibility:         NotificationVisibility.public,
    autoCancel:         true,
    ongoing:            !muted,
    playSound:          false,   // ήχος via just_audio loop (μόνο όταν ΟΧΙ σίγαση)
    enableVibration:    !muted,
    vibrationPattern:   muted ? null : kStrongVibration,
    enableLights:       true,
    fullScreenIntent:   !muted,
    styleInformation:   BigTextStyleInformation(body),
    actions: <AndroidNotificationAction>[
      const AndroidNotificationAction(
        kActionView,
        'Προβολή',
        showsUserInterface: true,
        cancelNotification: true,
      ),
      const AndroidNotificationAction(
        kActionReject,
        'Απόρριψη',
        showsUserInterface: false,
        cancelNotification: true,
      ),
    ],
  );

  final notifId = jobId.hashCode.abs() & 0x7FFFFFFF;

  try {
    await _localNotifs.show(
      notifId,
      title,
      body,
      NotificationDetails(android: androidDetails),
      payload: jsonEncode({'jobId': jobId}),
    );
    if (!muted) await startRingtoneLoop();
  } catch (e) {
    debugPrint('showJobNotification error: $e');
  }
}

// ─── Notification αναβάθμισης (όταν εκτός εφαρμογής) ────────────────────────
Future<void> showUpgradeNotification() async {
  // Η αναβάθμιση χτυπά ΠΑΝΤΑ — δεν επηρεάζεται από τη σίγαση.
  final androidDetails = AndroidNotificationDetails(
    kUpdateChannelId,
    kUpdateChannelName,
    channelDescription: kUpdateChannelDesc,
    importance:         Importance.high,
    priority:           Priority.high,
    visibility:         NotificationVisibility.public,
    autoCancel:         true,
    enableVibration:    true,
    vibrationPattern:   kStrongVibration,
    enableLights:       true,
  );
  try {
    await _localNotifs.show(
      990001,
      '🔄 Καινούργια ενημέρωση διαθέσιμη',
      'Παρακαλώ αναβαθμίστε στη νέα έκδοση της εφαρμογής.',
      NotificationDetails(android: androidDetails),
      payload: jsonEncode({'type': 'upgrade'}),
    );
  } catch (e) {
    debugPrint('showUpgradeNotification error: $e');
  }
}

// ─── Notification αιτήματος έγκρισης (μόνο master, όταν εκτός εφαρμογής) ────
Future<void> showApprovalNotification({
  required int    count,
  String          latestName = '',
}) async {
  final muted = await isMutedNow();
  final androidDetails = AndroidNotificationDetails(
    muted ? kApprovalChannelMutedId : kApprovalChannelId,
    muted ? 'Αιτήματα Έγκρισης (σίγαση)' : kApprovalChannelName,
    channelDescription: kApprovalChannelDesc,
    importance:         Importance.max,
    priority:           Priority.max,
    visibility:         NotificationVisibility.public,
    autoCancel:         true,
    onlyAlertOnce:      false,
    enableVibration:    !muted,
    vibrationPattern:   muted ? null : kStrongVibration,
    enableLights:       true,
  );

  final title = count > 1
      ? '👤 $count οδηγοί περιμένουν έγκριση'
      : '👤 Νέο αίτημα έγκρισης';
  final body = count > 1
      ? 'Πάτησε για να τους δεις και να εγκρίνεις.'
      : (latestName.isNotEmpty
          ? '$latestName περιμένει την έγκρισή σου.'
          : 'Ένας οδηγός περιμένει την έγκρισή σου.');

  try {
    await _localNotifs.show(
      kApprovalNotifId,
      title,
      body,
      NotificationDetails(android: androidDetails),
      payload: jsonEncode({'type': 'approval'}),
    );
  } catch (e) {
    debugPrint('showApprovalNotification error: $e');
  }
}

Future<void> cancelApprovalNotification() async {
  try {
    await _localNotifs.cancel(kApprovalNotifId);
  } catch (_) {}
}

// ─── Notification επιβίβασης (admin που έβγαλε τη δουλειά, εκτός εφαρμογής) ──
Future<void> showBoardedNotification({
  required String jobId,
  required String driverName,
  required String from,
  required String to,
}) async {
  final muted = await isMutedNow();
  final androidDetails = AndroidNotificationDetails(
    muted ? kBoardChannelMutedId : kBoardChannelId,
    muted ? 'Επιβιβάσεις (σίγαση)' : kBoardChannelName,
    channelDescription: kBoardChannelDesc,
    importance:         Importance.max,
    priority:           Priority.max,
    visibility:         NotificationVisibility.public,
    autoCancel:         true,
    enableVibration:    !muted,
    vibrationPattern:   muted ? null : kStrongVibration,
    enableLights:       true,
    styleInformation:   BigTextStyleInformation('$from → $to'),
  );

  final title = driverName.isNotEmpty
      ? '🚗 Επιβίβαση — $driverName'
      : '🚗 Επιβίβαση πελάτη';

  try {
    // Μοναδικό id ανά δουλειά (διαφορετικό από το id της δουλειάς).
    final notifId = (jobId.hashCode.abs() & 0x7FFFFFFF) ^ 0x0B0AD;
    await _localNotifs.show(
      notifId,
      title,
      '$from → $to',
      NotificationDetails(android: androidDetails),
      payload: jsonEncode({'jobId': jobId, 'type': 'boarded'}),
    );
  } catch (e) {
    debugPrint('showBoardedNotification error: $e');
  }
}
Future<void> showAppointmentNotification({
  required String jobId,
  required String from,
  required String to,
  String when = '',
}) async {
  final androidDetails = AndroidNotificationDetails(
    kUpdateChannelId,
    kUpdateChannelName,
    channelDescription: kUpdateChannelDesc,
    importance:         Importance.max,
    priority:           Priority.max,
    category:           AndroidNotificationCategory.reminder,
    visibility:         NotificationVisibility.public,
    autoCancel:         true,
    ongoing:            true,    // μένει μέχρι να ανοίξει η εφαρμογή
    playSound:          false,   // ο ήχος παίζει σε loop μέσω just_audio
    enableVibration:    true,
    vibrationPattern:   kStrongVibration,
    enableLights:       true,
    fullScreenIntent:   true,
  );
  final body = when.isNotEmpty
      ? '$when  •  $from → $to'
      : '$from → $to';
  try {
    await _localNotifs.show(
      // Μοναδικό id ανά δουλειά για reminders
      (jobId.hashCode.abs() & 0x7FFFFFFF) ^ 0x55555,
      '⏰ Υπενθύμιση ραντεβού',
      body,
      NotificationDetails(android: androidDetails),
      payload: jsonEncode({'jobId': jobId, 'type': 'appointment'}),
    );
    // Συνεχόμενος ήχος μέχρι να ανοίξει η εφαρμογή.
    // keepIfPlaying: αν ξαναχτυπήσει η υπενθύμιση ενώ ο ήχος ήδη παίζει,
    // δεν τον διακόπτουμε — απλώς ανανεώνουμε το cap ασφαλείας (2′),
    // αρκετό ώστε να καλύπτει τα re-fires κάθε 30″.
    await startRingtoneLoop(
      maxDuration:  const Duration(minutes: 2),
      keepIfPlaying: true,
    );
  } catch (e) {
    debugPrint('showAppointmentNotification error: $e');
  }
}

// ─── Public API ─────────────────────────────────────────────────────────────
class NotificationsService {
  /// Global navigator key — επιτρέπει να εμφανίζονται dialogs/popups ΠΑΝΩ
  /// από οποιαδήποτε οθόνη (Ιστορικό, Χρεώσεις κ.λπ.), όχι μόνο στον χάρτη.
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  static final ValueNotifier<String?> pendingViewJobId =
      ValueNotifier<String?>(null);

  /// Τίθεται όταν πατηθεί ειδοποίηση ομαδικής ανάθεσης (batch) → ο JobListener
  /// εμφανίζει τη λίστα «Αποδοχή όλων».
  static final ValueNotifier<String?> pendingViewBatchId =
      ValueNotifier<String?>(null);

  /// Αυξάνεται όταν πατηθεί reminder ραντεβού ενώ η εφαρμογή είναι ανοιχτή,
  /// ώστε ο JobListener να εμφανίσει αμέσως την κάρτα.
  static final ValueNotifier<int> reminderTapTick = ValueNotifier<int>(0);

  /// Αυξάνεται όταν πατηθεί ειδοποίηση αιτήματος έγκρισης, ώστε ο master να
  /// οδηγηθεί στη σελίδα Διαχειριστών.
  static final ValueNotifier<int> approvalTapTick = ValueNotifier<int>(0);

  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    await initLocalNotifPlugin(onForegroundTap: _onForegroundTap);

    // Cold start από notification tap
    final launchDetails =
        await _localNotifs.getNotificationAppLaunchDetails();
    if (launchDetails?.didNotificationLaunchApp == true) {
      // ignore: unawaited_futures
      stopRingtoneLoop();

      final resp = launchDetails!.notificationResponse;
      if (resp != null && resp.payload != null) {
        try {
          final data  = jsonDecode(resp.payload!) as Map<String, dynamic>;
          final jobId = data['jobId'] as String?;
          if (resp.actionId == kActionReject && jobId != null) {
            await _saveRejectedJobId(resp.payload!);
          } else if (data['type'] == 'approval') {
            approvalTapTick.value++;
          } else if (data['type'] == 'boarded') {
            // Ενημερωτικό μόνο — απλώς ανοίγει η εφαρμογή.
          } else if (data['type'] == 'appointment' && jobId != null) {
            // Υπενθύμιση ραντεβού → εμφάνισε την κάρτα, όχι το job popup.
            await _maybeSavePendingReminder(resp.payload!);
          } else if (data['type'] == 'batch') {
            final batchId = data['batchId'] as String?;
            if (batchId != null && batchId.isNotEmpty) {
              pendingViewBatchId.value = batchId;
            }
          } else if (jobId != null && jobId.isNotEmpty) {
            pendingViewJobId.value = jobId;
          }
        } catch (_) {}
      }
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kStopRingtoneFlag, false);
    } catch (_) {}
  }

  static void _onForegroundTap(NotificationResponse response) {
    // ignore: unawaited_futures
    stopRingtoneLoop();

    if (response.payload == null) return;
    try {
      final data  = jsonDecode(response.payload!) as Map<String, dynamic>;
      if (data['type'] == 'approval') {
        approvalTapTick.value++;
        return;
      }
      if (data['type'] == 'boarded') {
        return; // ενημερωτικό μόνο
      }
      if (data['type'] == 'batch') {
        final batchId = data['batchId'] as String?;
        if (batchId != null && batchId.isNotEmpty) {
          pendingViewBatchId.value = batchId;
        }
        return;
      }
      final jobId = data['jobId'] as String?;
      if (jobId == null || jobId.isEmpty) return;
      if (response.actionId == kActionReject) {
        // ignore: unawaited_futures
        _saveRejectedJobId(response.payload!);
      } else if (data['type'] == 'appointment') {
        // ignore: unawaited_futures
        _maybeSavePendingReminder(response.payload!).then((_) {
          reminderTapTick.value++;
        });
      } else {
        pendingViewJobId.value = jobId;
      }
    } catch (_) {}
  }

  /// Σταμάτημα ringtone από εξωτερικό κώδικα (π.χ. όταν ανοίγει popup μέσα στην εφαρμογή)
  static Future<void> silenceRingtone() async {
    await stopRingtoneLoop();
  }

  /// Ακυρώνει το notification μιας δουλειάς + σταματά τον ήχο.
  /// Καλείται όταν η δουλειά ανελήφθη από άλλον.
  static Future<void> cancelJobNotification(String jobId) async {
    try {
      final notifId = jobId.hashCode.abs() & 0x7FFFFFFF;
      await _localNotifs.cancel(notifId);
      await stopRingtoneLoop();
    } catch (_) {}
  }

  // ─── Υπενθυμίσεις ραντεβού με EXACT ALARMS ─────────────────────────────────
  //
  // Αντί για polling με Timer (που παγώνει σε Doze), προγραμματίζουμε εκ των
  // προτέρων exact alarms μέσω AlarmManager (setExactAndAllowWhileIdle). Έτσι
  // χτυπούν στην ΑΚΡΙΒΗ ώρα ακόμη και με κλειστή οθόνη ή κλειστή εφαρμογή.
  // Ο ήχος επαναλαμβάνεται native (FLAG_INSISTENT) μέχρι ο χρήστης να
  // αλληλεπιδράσει — δεν χρειάζεται ζωντανό Dart isolate.

  /// Σταθερό, μοναδικό notifId ανά (δουλειά, offset).
  static int _reminderNotifId(String jobId, int offset) {
    final base = jobId.hashCode.abs() & 0x7FFFFFFF;
    return (base ^ (offset == 30 ? 0x30303 : 0x10101)) & 0x7FFFFFFF;
  }

  /// Συγχρονίζει τα προγραμματισμένα reminders με την τρέχουσα λίστα
  /// ραντεβού. Προγραμματίζει όσα λείπουν, ακυρώνει όσα δεν ισχύουν πλέον
  /// (π.χ. δουλειά που ολοκληρώθηκε/ακυρώθηκε ή άλλαξε ώρα).
  ///
  /// Καλείται από τον JobListener κάθε φορά που αλλάζει το snapshot των
  /// δουλειών που έχει αναλάβει ο οδηγός.
  static Future<void> syncAppointmentReminders(List<ReminderSpec> specs) async {
    final prefs = await SharedPreferences.getInstance();
    final now   = DateTime.now();
    final desired = <int>{};

    for (final s in specs) {
      for (final off in kReminderOffsets) {
        final fireAt = s.scheduledAt.subtract(Duration(minutes: off));
        // Προγραμμάτισε μόνο αν το σημείο είναι στο μέλλον (5″ περιθώριο).
        if (fireAt.isBefore(now.add(const Duration(seconds: 5)))) continue;
        final id = _reminderNotifId(s.jobId, off);
        desired.add(id);
        await _scheduleOneReminder(id: id, spec: s, offset: off, fireAt: fireAt);
      }
    }

    // Ακύρωσε ό,τι ήταν προγραμματισμένο και δεν χρειάζεται πλέον.
    final prev = prefs.getStringList(kScheduledReminderIds) ?? const <String>[];
    for (final idStr in prev) {
      final id = int.tryParse(idStr);
      if (id != null && !desired.contains(id)) {
        try { await _localNotifs.cancel(id); } catch (_) {}
      }
    }
    await prefs.setStringList(
        kScheduledReminderIds, desired.map((e) => e.toString()).toList());
  }

  static Future<void> _scheduleOneReminder({
    required int         id,
    required ReminderSpec spec,
    required int         offset,
    required DateTime    fireAt,
  }) async {
    final whenStr = _fmtReminderDateTime(spec.scheduledAt);
    final body    = '$whenStr  •  ${spec.from} → ${spec.to}';

    final androidDetails = AndroidNotificationDetails(
      kUpdateChannelId,
      kUpdateChannelName,
      channelDescription:  kUpdateChannelDesc,
      importance:          Importance.max,
      priority:            Priority.max,
      category:            AndroidNotificationCategory.reminder,
      visibility:          NotificationVisibility.public,
      autoCancel:          true,
      fullScreenIntent:    true,                       // οθόνη «κλήσης»
      enableVibration:     true,
      vibrationPattern:    kStrongVibration,
      enableLights:        true,
      playSound:           true,                       // native ήχος (channel)
      audioAttributesUsage: AudioAttributesUsage.alarm, // δυνατά σαν ξυπνητήρι
      // FLAG_INSISTENT (0x4): επαναλαμβάνει ήχο/δόνηση μέχρι αλληλεπίδραση —
      // χωρίς να χρειάζεται ζωντανό isolate.
      additionalFlags:     Int32List.fromList(<int>[4]),
      actions: const <AndroidNotificationAction>[
        AndroidNotificationAction(
          kActionView, 'Προβολή',
          showsUserInterface: true, cancelNotification: true,
        ),
      ],
    );

    try {
      await _localNotifs.zonedSchedule(
        id,
        '⏰ Υπενθύμιση ραντεβού σε $offset′',
        body,
        tz.TZDateTime.from(fireAt, tz.local),
        NotificationDetails(android: androidDetails),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        payload: jsonEncode({
          'jobId': spec.jobId, 'type': 'appointment', 'minsBefore': offset,
        }),
      );
    } catch (e) {
      debugPrint('zonedSchedule reminder error: $e');
    }
  }

  static String _fmtReminderDateTime(DateTime dt) {
    final d = '${dt.day.toString().padLeft(2, '0')}/'
        '${dt.month.toString().padLeft(2, '0')}';
    final t = '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
    return '$d $t';
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  /// Επιστρέφει map jobId → timestamp (ms) που έγινε rejection.
  static Future<Map<String, int>> getRejectedJobMap() async {
    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getString(kPrefsRejectedJobs);
    if (raw == null) return <String, int>{};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k, (v as num).toInt()));
    } catch (_) {
      return <String, int>{};
    }
  }

  /// Set των jobIds που έχει απορρίψει ο χρήστης (συμβατότητα με παλιό API).
  static Future<Set<String>> getRejectedJobIds() async {
    final map = await getRejectedJobMap();
    return map.keys.toSet();
  }

  static Future<void> rejectJobLocally(String jobId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getString(kPrefsRejectedJobs);
    final Map<String, dynamic> map =
        raw == null ? <String, dynamic>{} : (jsonDecode(raw) as Map<String, dynamic>);
    map[jobId] = DateTime.now().millisecondsSinceEpoch;
    if (map.length > 200) {
      final entries = map.entries.toList()
        ..sort((a, b) => (a.value as int).compareTo(b.value as int));
      while (entries.length > 200) {
        map.remove(entries.removeAt(0).key);
      }
    }
    await prefs.setString(kPrefsRejectedJobs, jsonEncode(map));
  }

  static Future<void> cleanupRejected(Set<String> currentOpenJobIds) async {
    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getString(kPrefsRejectedJobs);
    if (raw == null) return;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      map.removeWhere((k, _) => !currentOpenJobIds.contains(k));
      await prefs.setString(kPrefsRejectedJobs, jsonEncode(map));
    } catch (_) {}
  }
}
