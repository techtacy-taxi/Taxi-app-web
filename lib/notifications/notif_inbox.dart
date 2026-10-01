// ============================================================================
// FILE: ./lib/notifications/notif_inbox.dart
// ============================================================================
//
// ΚΑΜΠΑΝΑΚΙ ΕΙΔΟΠΟΙΗΣΕΩΝ — ιστορικό ειδοποιήσεων με σήμα «αδιάβαστη».
//
// • Κάθε ειδοποίηση (εκτός από αυτές που «χτυπάνε» και έχουν δική τους ροή:
//   νέα δουλειά, παρτίδα, ακύρωση, υπενθύμιση ραντεβού, στάδιο κλιμάκωσης)
//   καταγράφεται εδώ — ΚΑΙ από το background isolate (κλειστή εφαρμογή) ΚΑΙ
//   από το foreground (ανοιχτή εφαρμογή, όπου πριν κάποιες χάνονταν τελείως).
// • Μένει «αδιάβαστη» (κουκκίδα + αριθμός στο καμπανάκι) μέχρι να την πατήσεις
//   στη λίστα ή στην ειδοποίηση του κινητού.
// • Το πάτημα σε πηγαίνει στη σωστή οθόνη (π.χ. «Εκκρεμεί καθαρισμός» →
//   Χρεώσεις, «Αναφορά έτοιμη» → ανοίγει το PDF, «Νέα κράτηση» → Αποθηκευμένες).
//
// ΤΟΠΙΚΟ ΑΝΑ ΣΥΣΚΕΥΗ (SharedPreferences), όπως και το σήμα «ΝΕΑ».
// Κρατά τις 60 πιο πρόσφατες, έως 30 ημέρες.

import 'dart:async';
import 'dart:convert';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_theme.dart';
import '../models.dart' show kUpdateUrl;
import '../notifications_service.dart';
import '../jobs/new_saved_badge_store.dart';

class NotifEntry {
  final String id;
  final String type;
  final String title;
  final String body;
  final int ts;
  final bool seen;
  final Map<String, String> data;

  const NotifEntry({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.ts,
    required this.seen,
    required this.data,
  });

  NotifEntry copyWith({bool? seen}) => NotifEntry(
      id: id, type: type, title: title, body: body, ts: ts,
      seen: seen ?? this.seen, data: data);

  Map<String, dynamic> toJson() => {
        'id': id, 'type': type, 'title': title, 'body': body,
        'ts': ts, 'seen': seen, 'data': data,
      };

  static NotifEntry? fromJson(dynamic j) {
    if (j is! Map) return null;
    try {
      final d = <String, String>{};
      final raw = j['data'];
      if (raw is Map) {
        raw.forEach((k, v) => d[k.toString()] = (v ?? '').toString());
      }
      return NotifEntry(
        id: (j['id'] ?? '').toString(),
        type: (j['type'] ?? '').toString(),
        title: (j['title'] ?? '').toString(),
        body: (j['body'] ?? '').toString(),
        ts: (j['ts'] is int) ? j['ts'] as int : 0,
        seen: j['seen'] == true,
        data: d,
      );
    } catch (_) {
      return null;
    }
  }

  /// Κλειδί αντικειμένου (κράτηση/δουλειά) για ταίριασμα & αποφυγή διπλών.
  String get objectKey => data['savedJobId'] ?? data['jobId'] ?? '';
}

class NotifInbox {
  NotifInbox._();

  static const String _kKey = 'notif_inbox_v1';
  static const int _kMax = 60;
  static const Duration _kTtl = Duration(days: 30);

  /// Τύποι που ΔΕΝ μπαίνουν στη λίστα — έχουν δική τους ροή (popup που
  /// χτυπάει μέχρι να απαντήσεις) ή είναι τεχνικά σήματα.
  static const Set<String> _excluded = {
    'new_job', 'job_reopened', 'new_batch', 'cancel_job',
    'appointment_reminder', 'owner_stage',
  };

  /// Γενικοί τύποι χωρίς δική τους εμφάνιση στο foreground — πριν ΧΑΝΟΝΤΑΝ
  /// αν ερχόντουσαν με ανοιχτή την εφαρμογή. Τώρα δείχνουμε μήνυμα.
  static const Set<String> _foregroundToast = {
    'purge_reminder', 'monthly_report',
    'invoice_credit_issued', 'invoice_cancellation_needed',
  };

  static List<NotifEntry> _cache = [];
  static bool _loaded = false;

  /// ΑΝΑ ΧΡΗΣΤΗ: αν στην ίδια συσκευή συνδεθεί άλλος λογαριασμός, ΔΕΝ βλέπει
  /// τις ειδοποιήσεις του προηγούμενου. Το uid γράφεται στη σύνδεση και το
  /// διαβάζει και το background isolate (κλειστή εφαρμογή).
  static const String _kUidKey = 'notif_inbox_uid';
  static String? _uid;

  static Future<String> _storageKey() async {
    if (_uid == null) {
      try {
        final prefs = await SharedPreferences.getInstance();
        try { await prefs.reload(); } catch (_) {}
        _uid = prefs.getString(_kUidKey) ?? '';
      } catch (_) {
        _uid = '';
      }
    }
    return _uid!.isEmpty ? _kKey : '${_kKey}_$_uid';
  }

  /// Ορίζει τον συνδεδεμένο χρήστη (map_page / admin_shell στη σύνδεση).
  static Future<void> setUser(String uid) async {
    if (uid.isEmpty || uid == _uid) return;
    _uid = uid;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kUidKey, uid);
    } catch (_) {}
    _cache = [];
    _loaded = false;
    await _sync();
    revision.value++;
  }

  /// Αυξάνεται σε κάθε αλλαγή — το καμπανάκι/η λίστα ξαναχτίζονται.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  // ── Δίσκος ────────────────────────────────────────────────────────────────

  static Future<List<NotifEntry>> _readDisk() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      try { await prefs.reload(); } catch (_) {}
      final raw = prefs.getString(await _storageKey());
      if (raw == null || raw.isEmpty) return [];
      final list = jsonDecode(raw);
      if (list is! List) return [];
      return list.map(NotifEntry.fromJson).whereType<NotifEntry>().toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _writeDisk(List<NotifEntry> list) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(await _storageKey(),
          jsonEncode(list.map((e) => e.toJson()).toList()));
    } catch (_) {}
  }

  /// Ένωση δίσκου + μνήμης. Γράφει ΚΑΙ το background isolate, οπότε ΠΑΝΤΑ
  /// ξαναδιαβάζουμε πριν από αλλαγή. «Διαβασμένη» αν έστω μία πλευρά το λέει.
  static Future<void> _sync() async {
    final disk = await _readDisk();
    final byId = <String, NotifEntry>{};
    for (final e in disk) {
      byId[e.id] = e;
    }
    for (final e in _cache) {
      final d = byId[e.id];
      byId[e.id] = d == null ? e : d.copyWith(seen: d.seen || e.seen);
    }
    final cutoff =
        DateTime.now().millisecondsSinceEpoch - _kTtl.inMilliseconds;
    final merged = byId.values.where((e) => e.ts >= cutoff).toList()
      ..sort((a, b) => b.ts.compareTo(a.ts));
    _cache = merged.length > _kMax ? merged.sublist(0, _kMax) : merged;
    _loaded = true;
  }

  static Future<void> _commit() async {
    await _writeDisk(_cache);
    revision.value++;
  }

  // ── Δημόσιο API ──────────────────────────────────────────────────────────

  /// Φόρτωση/συγχρονισμός (π.χ. στο άνοιγμα ή επιστροφή της εφαρμογής).
  static Future<void> refresh() async {
    final before = _signature();
    await _sync();
    if (_signature() != before) revision.value++;
  }

  static String _signature() =>
      _cache.map((e) => '${e.id}${e.seen ? 1 : 0}').join(',');

  static List<NotifEntry> get entries => List.unmodifiable(_cache);

  static int get unreadCount =>
      _loaded ? _cache.where((e) => !e.seen).length : 0;

  /// Καταγράφει μια ειδοποίηση από FCM data. Επιστρέφει το id (ή null αν
  /// δεν καταγράφεται). Δουλεύει ΚΑΙ στο background isolate.
  static Future<String?> record(Map<String, dynamic> data) async {
    try {
      final type = (data['type'] ?? '').toString();
      final title = (data['title'] ?? '').toString().trim();
      if (type.isEmpty || title.isEmpty || _excluded.contains(type)) {
        return null;
      }
      await _sync();
      final now = DateTime.now().millisecondsSinceEpoch;
      final d = <String, String>{};
      for (final k in const ['savedJobId', 'jobId', 'link', 'bookingNumber']) {
        final v = (data[k] ?? '').toString();
        if (v.isNotEmpty) d[k] = v;
      }
      final key = d['savedJobId'] ?? d['jobId'] ?? '';
      // Αποφυγή διπλών (π.χ. ίδιο μήνυμα από δύο μονοπάτια) — 10 λεπτά.
      for (final e in _cache) {
        if (e.type == type && e.title == title && e.objectKey == key &&
            now - e.ts < 10 * 60 * 1000) {
          return e.id;
        }
      }
      final id = '${type}_$now';
      _cache.insert(
        0,
        NotifEntry(
          id: id, type: type, title: title,
          body: (data['body'] ?? '').toString(),
          ts: now, seen: false, data: d,
        ),
      );
      if (_cache.length > _kMax) _cache = _cache.sublist(0, _kMax);
      await _commit();
      return id;
    } catch (_) {
      return null;
    }
  }

  static Future<void> markSeen(String id) async {
    await _sync();
    var changed = false;
    _cache = _cache.map((e) {
      if (e.id == id && !e.seen) {
        changed = true;
        return e.copyWith(seen: true);
      }
      return e;
    }).toList();
    if (changed) await _commit();
  }

  /// Όταν δεις το αντικείμενο ΑΠΟ ΑΛΛΟΥ (π.χ. άνοιξες την κράτηση στις
  /// Αποθηκευμένες) → φεύγει και από εδώ το «αδιάβαστη».
  static Future<void> markObjectSeen(String type, String objectKey) async {
    if (objectKey.isEmpty) return;
    await _sync();
    var changed = false;
    _cache = _cache.map((e) {
      if (!e.seen && e.type == type && e.objectKey == objectKey) {
        changed = true;
        return e.copyWith(seen: true);
      }
      return e;
    }).toList();
    if (changed) await _commit();
  }

  /// Όταν ανοίξεις την οθόνη που αφορά (π.χ. Χρεώσεις, Εγκρίσεις).
  /// Γρήγορο: δεν αγγίζει τον δίσκο αν δεν υπάρχει τίποτα αδιάβαστο.
  static Future<void> markTypesSeen(Set<String> types) async {
    if (_loaded && !_cache.any((e) => !e.seen && types.contains(e.type))) {
      return;
    }
    await _sync();
    var changed = false;
    _cache = _cache.map((e) {
      if (!e.seen && types.contains(e.type)) {
        changed = true;
        return e.copyWith(seen: true);
      }
      return e;
    }).toList();
    if (changed) await _commit();
  }

  static Future<void> markAllSeen() async {
    await _sync();
    if (_cache.every((e) => e.seen)) return;
    _cache = _cache.map((e) => e.copyWith(seen: true)).toList();
    await _commit();
  }

  /// Σημειώνει ως διαβασμένη την ειδοποίηση που πατήθηκε στο κινητό.
  /// Με inboxId → ακριβώς αυτή. Αλλιώς → όσες ίδιου τύπου/αντικειμένου.
  static Future<void> _markFromPayload(Map<String, dynamic> data) async {
    await _sync();
    final inboxId = (data['inboxId'] ?? '').toString();
    final type = (data['type'] ?? '').toString();
    final key =
        (data['savedJobId'] ?? data['jobId'] ?? '').toString();
    var changed = false;
    _cache = _cache.map((e) {
      if (e.seen) return e;
      final match = inboxId.isNotEmpty
          ? e.id == inboxId
          : (e.type == type && (key.isEmpty || e.objectKey == key));
      if (match) {
        changed = true;
        return e.copyWith(seen: true);
      }
      return e;
    }).toList();
    if (changed) await _commit();
  }

  // ── Πλοήγηση ─────────────────────────────────────────────────────────────

  /// Αίτημα «άνοιξε τις Χρεώσεις». Το ακούν map_page (Android) και
  /// admin_shell (web), που ξέρουν τα στοιχεία του χρήστη.
  static final ValueNotifier<int> openBillingRequest = ValueNotifier<int>(0);
  static bool _pendingBilling = false;

  /// Για cold start: αν το αίτημα ήρθε πριν στηθεί ο listener.
  static bool consumePendingBilling() {
    final v = _pendingBilling;
    _pendingBilling = false;
    return v;
  }

  static void _requestBilling() {
    _pendingBilling = true;
    openBillingRequest.value++;
  }

  /// Ο listener καλεί αυτό όταν ΑΝΟΙΞΕ τις Χρεώσεις.
  static void billingOpened() => _pendingBilling = false;

  /// Τύποι που οι υπάρχοντες tap handlers ΔΕΝ χειρίζονται — εδώ τους
  /// δίνουμε προορισμό.
  static bool _handledElsewhere(String type) => const {
        'public_booking', 'approval', 'boarded',
        'flight_delay_update', 'owner_taken', 'owner_boarded',
        'owner_expired',
      }.contains(type);

  /// Πάτημα ειδοποίησης ΚΙΝΗΤΟΥ (από notifications_service).
  static Future<void> onSystemTap(Map<String, dynamic> data) async {
    try {
      await _markFromPayload(data);
      final type = (data['type'] ?? '').toString();
      if (_handledElsewhere(type)) return; // κρατάμε την υπάρχουσα συμπεριφορά
      await _route(type, (data['link'] ?? '').toString(), fromInbox: false);
    } catch (_) {}
  }

  /// Πάτημα στοιχείου της λίστας.
  static Future<void> openEntry(NotifEntry e) async {
    await markSeen(e.id);
    await _route(e.type, e.data['link'] ?? '', fromInbox: true,
        entry: e);
  }

  static Future<void> _route(String type, String link,
      {required bool fromInbox, NotifEntry? entry}) async {
    switch (type) {
      case 'purge_reminder':
        _requestBilling();
        return;
      case 'monthly_report':
        if (link.startsWith('http')) {
          try {
            await launchUrl(Uri.parse(link),
                mode: LaunchMode.externalApplication);
            return;
          } catch (_) {}
        }
        _requestBilling();
        return;
      case 'public_booking':
        SavedTabNav.popToSavedAnchor(
            NotificationsService.navigatorKey.currentState);
        openSavedJobsRequest.value++;
        return;
      case 'approval':
        NotificationsService.approvalTapTick.value++;
        return;
      case 'upgrade':
        // Πριν: το πάτημα δεν έκανε τίποτα. Τώρα ανοίγει τη σελίδα λήψης.
        if (!kIsWeb) {
          try {
            await launchUrl(Uri.parse(kUpdateUrl),
                mode: LaunchMode.externalApplication);
            return;
          } catch (_) {}
        }
        if (fromInbox && entry != null) _showDetails(entry);
        return;
      default:
        // flight_delay / owner_* / boarded: η ειδοποίηση του κινητού έχει ήδη
        // τη δική της συμπεριφορά· από τη λίστα δείχνουμε όλο το κείμενο.
        // Ενημερωτικές (π.χ. παραστατικά για κράτηση που διαγράφηκε) —
        // δεν υπάρχει οθόνη· από τη λίστα δείχνουμε όλο το κείμενο.
        if (fromInbox && entry != null) _showDetails(entry);
        if (!fromInbox) openInboxSheetFromAnywhere();
    }
  }

  // ── Foreground: καταγραφή + μήνυμα για όσες χάνονταν ─────────────────────

  static StreamSubscription<RemoteMessage>? _fgSub;
  static bool _lifecycleHooked = false;

  /// Ασφαλές να καλείται πολλές φορές (map_page / admin_shell).
  static void startForeground({String uid = ''}) {
    if (uid.isNotEmpty && uid != _uid) {
      // ignore: unawaited_futures
      setUser(uid);
    } else {
      // ignore: unawaited_futures
      refresh();
    }
    if (!_lifecycleHooked) {
      _lifecycleHooked = true;
      WidgetsBinding.instance.addObserver(_ResumeObserver());
    }
    _fgSub ??= FirebaseMessaging.onMessage.listen((msg) async {
      final data = Map<String, dynamic>.from(msg.data);
      final id = await record(data);
      final type = (data['type'] ?? '').toString();
      final known = _excluded.contains(type) || _handledElsewhere(type);
      if (id != null && (_foregroundToast.contains(type) || !known)) {
        _toast(data, id);
      }
    });
  }

  static void _toast(Map<String, dynamic> data, String id) {
    final ctx = NotificationsService.navigatorKey.currentContext;
    if (ctx == null) return;
    final messenger = ScaffoldMessenger.maybeOf(ctx);
    if (messenger == null) return;
    final title = (data['title'] ?? '').toString();
    messenger.showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 8),
      content: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      action: SnackBarAction(
        label: 'Άνοιγμα',
        onPressed: () {
          final e = _cache.where((x) => x.id == id);
          if (e.isNotEmpty) {
            // ignore: unawaited_futures
            openEntry(e.first);
          } else {
            openInboxSheetFromAnywhere();
          }
        },
      ),
    ));
  }

  // ── UI: λίστα ειδοποιήσεων ───────────────────────────────────────────────

  static void openInboxSheetFromAnywhere({int retries = 3}) {
    final ctx = NotificationsService.navigatorKey.currentContext;
    if (ctx != null) {
      openInboxSheet(ctx);
    } else if (retries > 0) {
      // Cold start: η εφαρμογή δεν έχει στηθεί ακόμη — ξαναδοκίμασε.
      Future.delayed(const Duration(milliseconds: 1500),
          () => openInboxSheetFromAnywhere(retries: retries - 1));
    }
  }

  static void openInboxSheet(BuildContext context) {
    // ignore: unawaited_futures
    refresh();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      useRootNavigator: true,
      showDragHandle: true,
      builder: (_) => const _InboxSheet(),
    );
  }

  static void _showDetails(NotifEntry e) {
    final ctx = NotificationsService.navigatorKey.currentContext;
    if (ctx == null) return;
    showDialog<void>(
      context: ctx,
      useRootNavigator: true,
      builder: (dctx) => AlertDialog(
        title: Text(e.title),
        content: SingleChildScrollView(child: SelectableText(e.body)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}

class _ResumeObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Επιστροφή στην εφαρμογή → πάρε ό,τι έγραψε το background isolate.
    if (state == AppLifecycleState.resumed) {
      // ignore: unawaited_futures
      NotifInbox.refresh();
    }
  }
}

// ── Καμπανάκι με αριθμό αδιάβαστων ─────────────────────────────────────────

class NotifBellButton extends StatelessWidget {
  /// Μέγεθος κύκλου (48 για τον χάρτη, μικρότερο για το web panel).
  final double size;
  const NotifBellButton({super.key, this.size = 48});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return ValueListenableBuilder<int>(
      valueListenable: NotifInbox.revision,
      builder: (context, _, _) {
        final n = NotifInbox.unreadCount;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Material(
              color: c.card,
              shape: CircleBorder(
                  side: BorderSide(color: c.cardBorder, width: 0.8)),
              elevation: 2,
              shadowColor: Colors.black26,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => NotifInbox.openInboxSheet(context),
                child: SizedBox(
                  width: size, height: size,
                  child: Icon(
                    n > 0
                        ? Icons.notifications_active_rounded
                        : Icons.notifications_none_rounded,
                    size: size * 0.5,
                    color: c.amberDeep,
                  ),
                ),
              ),
            ),
            if (n > 0)
              Positioned(
                right: -2, top: -2,
                child: IgnorePointer(
                  child: Container(
                    constraints:
                        const BoxConstraints(minWidth: 20, minHeight: 20),
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFFC5221F),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white, width: 1.5),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      n > 99 ? '99+' : '$n',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _InboxSheet extends StatelessWidget {
  const _InboxSheet();

  static String _when(int ts) {
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final hm = '${two(d.hour)}:${two(d.minute)}';
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return hm;
    if (diff == 1) return 'χθες $hm';
    return '${two(d.day)}/${two(d.month)} $hm';
  }

  static IconData _icon(String type) {
    switch (type) {
      case 'purge_reminder': return Icons.inventory_2_rounded;
      case 'monthly_report': return Icons.bar_chart_rounded;
      case 'invoice_credit_issued':
      case 'invoice_cancellation_needed': return Icons.receipt_long_rounded;
      case 'public_booking': return Icons.event_available_rounded;
      case 'approval': return Icons.person_add_alt_1_rounded;
      case 'upgrade': return Icons.system_update_rounded;
      case 'flight_delay_update': return Icons.flight_land_rounded;
      default: return Icons.notifications_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final bottom = MediaQuery.of(context).padding.bottom;
    return ValueListenableBuilder<int>(
      valueListenable: NotifInbox.revision,
      builder: (context, _, _) {
        final items = NotifInbox.entries;
        final unread = NotifInbox.unreadCount;
        return ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('Ειδοποιήσεις',
                          style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              color: c.textMain)),
                    ),
                    if (unread > 0)
                      TextButton.icon(
                        onPressed: NotifInbox.markAllSeen,
                        icon: const Icon(Icons.done_all_rounded, size: 18),
                        label: const Text('Όλες διαβασμένες'),
                      ),
                  ],
                ),
              ),
              if (items.isEmpty)
                Padding(
                  padding: EdgeInsets.fromLTRB(24, 24, 24, 32 + bottom),
                  child: Text('Δεν υπάρχουν ειδοποιήσεις',
                      style: TextStyle(color: c.textFaint)),
                )
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: EdgeInsets.only(bottom: 16 + bottom),
                    itemCount: items.length,
                    separatorBuilder: (_, _) =>
                        Divider(height: 1, color: c.divider),
                    itemBuilder: (context, i) {
                      final e = items[i];
                      return InkWell(
                        onTap: () {
                          Navigator.of(context).pop();
                          // ignore: unawaited_futures
                          NotifInbox.openEntry(e);
                        },
                        child: Container(
                          color: e.seen ? null : c.amberSoft.withValues(alpha: 0.45),
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 12,
                                child: e.seen
                                    ? null
                                    : Padding(
                                        padding: const EdgeInsets.only(top: 6),
                                        child: Container(
                                          width: 8, height: 8,
                                          decoration: const BoxDecoration(
                                            color: Color(0xFFC5221F),
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                      ),
                              ),
                              Icon(_icon(e.type),
                                  size: 22, color: c.amberDeep),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(e.title,
                                        style: TextStyle(
                                            fontSize: 14.5,
                                            fontWeight: e.seen
                                                ? FontWeight.w500
                                                : FontWeight.w800,
                                            color: c.textMain)),
                                    if (e.body.isNotEmpty) ...[
                                      const SizedBox(height: 2),
                                      Text(e.body,
                                          maxLines: 3,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                              fontSize: 13,
                                              color: c.textFaint)),
                                    ],
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(_when(e.ts),
                                  style: TextStyle(
                                      fontSize: 12, color: c.textFaint)),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
