// lib/permissions.dart
//
// REDESIGN (εγκεκριμένο mockup «Ρύθμιση εφαρμογής 2/4»):
// Αντί για διαδοχικά AlertDialogs, μία οθόνη-checklist με κάρτες:
//   • Ειδοποιήσεις (για να χτυπάει η νέα δουλειά)
//   • Τοποθεσία — Πάντα ενεργή
//   • Μπαταρία χωρίς περιορισμούς
//   • Μικρόφωνο (φωνητικά μηνύματα)
// Κάθε κάρτα δείχνει ✓ όταν ολοκληρωθεί· η εκκρεμής έχει κίτρινο περίγραμμα
// και κουμπί «Άνοιξε». Η οθόνη εμφανίζεται ΜΟΝΟ αν λείπει κάτι κρίσιμο —
// αν όλα είναι ήδη εντάξει, η ροή περνάει σιωπηλά (κανένα ενοχλητικό popup).
//
// Η ΛΟΓΙΚΗ παραμένει ίδια με πριν:
//   • whileInUse πριν από always
//   • Event-driven αναμονή επιστροφής από τις Ρυθμίσεις (resumed) + timeout
//   • Αποθήκευση locationAlways στο presence/{uid}
//   • MIUI/HyperOS guard: εξαίρεση μπαταρίας ΜΟΝΟ αν δεν είναι ήδη ενεργή
//
// Το signature requestPermissions(context, uid) ΔΕΝ αλλάζει — το map_page
// συνεχίζει να την καλεί όπως πριν.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

import 'app_theme.dart';
import 'onboarding_screens.dart';

/// Ζητά τα απαραίτητα permissions. Αν όλα είναι ήδη εντάξει → σιωπηλή
/// επιστροφή. Αλλιώς ανοίγει η οθόνη-checklist (βήμα 2/4).
Future<void> requestPermissions({
  required BuildContext context,
  required String? uid,
}) async {
  // Γρήγορος έλεγχος: αν ΟΛΑ τα κρίσιμα είναι ήδη εντάξει, μην ενοχλείς.
  final status = await _PermissionStatusSnapshot.read();
  if (!status.needsWizard) {
    await _saveLocationAlways(uid, status.locationAlways);
    return;
  }

  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => _PermissionsWizardPage(uid: uid),
  ));
}

/// Αποθήκευση στο Firestore αν έχει «Πάντα» ή όχι (όπως πριν).
Future<void> _saveLocationAlways(String? uid, bool hasAlways) async {
  if (uid == null) return;
  try {
    await FirebaseFirestore.instance.collection('presence').doc(uid).set({
      'locationAlways': hasAlways,
      'updatedAt':      FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  } catch (_) {}
}

// ─────────────────────────────────────────────────────────────────
// Στιγμιότυπο κατάστασης αδειών
// ─────────────────────────────────────────────────────────────────
class _PermissionStatusSnapshot {
  final bool notifications;
  final bool locationAlways;
  final bool locationWhileInUse;
  final bool battery;
  final bool microphone;

  _PermissionStatusSnapshot({
    required this.notifications,
    required this.locationAlways,
    required this.locationWhileInUse,
    required this.battery,
    required this.microphone,
  });

  /// Ο οδηγός ΠΡΕΠΕΙ να περάσει από το wizard αν λείπει κάτι κρίσιμο.
  /// (Το μικρόφωνο δεν είναι κρίσιμο — ζητιέται και επιτόπου στην ηχογράφηση.)
  bool get needsWizard => !notifications || !locationAlways || !battery;

  static Future<_PermissionStatusSnapshot> read() async {
    // Τοποθεσία
    LocationPermission loc;
    try {
      loc = await Geolocator.checkPermission();
    } catch (_) {
      loc = LocationPermission.denied;
    }

    // Ειδοποιήσεις
    bool notif = false;
    try {
      notif = await FlutterForegroundTask.checkNotificationPermission() ==
          NotificationPermission.granted;
    } catch (_) {}

    // Μπαταρία
    bool battery = false;
    try {
      battery = await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    } catch (_) {
      battery = true; // αν το API σκάει σε κάποια συσκευή, μην μπλοκάρεις
    }

    // Μικρόφωνο
    bool mic = false;
    try {
      mic = await ph.Permission.microphone.isGranted;
    } catch (_) {}

    return _PermissionStatusSnapshot(
      notifications:      notif,
      locationAlways:     loc == LocationPermission.always,
      locationWhileInUse: loc == LocationPermission.always ||
          loc == LocationPermission.whileInUse,
      battery:            battery,
      microphone:         mic,
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// Οθόνη-checklist (βήμα 2/4)
// ─────────────────────────────────────────────────────────────────
class _PermissionsWizardPage extends StatefulWidget {
  final String? uid;
  const _PermissionsWizardPage({required this.uid});

  @override
  State<_PermissionsWizardPage> createState() =>
      _PermissionsWizardPageState();
}

class _PermissionsWizardPageState extends State<_PermissionsWizardPage> {
  _PermissionStatusSnapshot? _status;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final s = await _PermissionStatusSnapshot.read();
    if (!mounted) return;
    setState(() => _status = s);
    // Κάθε φορά που αλλάζει η κατάσταση, ενημερώνουμε το Firestore.
    await _saveLocationAlways(widget.uid, s.locationAlways);
  }

  // ── Ενέργειες ανά κάρτα ──────────────────────────────────────────

  Future<void> _fixNotifications() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await FlutterForegroundTask.requestNotificationPermission();
    } catch (_) {}
    setState(() => _busy = false);
    await _refresh();
  }

  Future<void> _fixLocation() async {
    if (_busy) return;
    setState(() => _busy = true);

    // Βήμα 1: whileInUse (απαιτείται πριν ζητήσουμε always)
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }

    // Βήμα 2: αν δεν έχει always → Ρυθμίσεις με αναλυτικές οδηγίες,
    // και event-driven αναμονή επιστροφής (όπως πριν).
    if (perm != LocationPermission.always && mounted) {
      final goSettings = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          final c = AppColors.of(ctx);
          return AlertDialog(
            title: Row(children: [
              Icon(Icons.location_on_rounded, color: c.amber, size: 26),
              const SizedBox(width: 8),
              const Text('Τοποθεσία «Πάντα»',
                  style: TextStyle(fontSize: 17)),
            ]),
            content: Text(
              'Για να σε βλέπει ο συντονιστής και με κλειστή οθόνη:\n\n'
              '➤  Πάτα «Άνοιγμα Ρυθμίσεων»\n'
              '➤  Πάτα «Δικαιώματα» → «Τοποθεσία»\n'
              '➤  Επίλεξε «Να επιτρέπεται πάντα»',
              style: TextStyle(
                  fontSize: 14.5, height: 1.6, color: c.textMain),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Αργότερα'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.of(ctx).pop(true),
                icon: const Icon(Icons.settings_rounded, size: 18),
                label: const Text('Άνοιγμα Ρυθμίσεων'),
              ),
            ],
          );
        },
      );

      if (goSettings == true) {
        await ph.openAppSettings();
        // Αναμονή event-driven να ΕΠΙΣΤΡΕΨΕΙ στην εφαρμογή + timeout 90s.
        await _waitForReturn();
      }
    }

    setState(() => _busy = false);
    await _refresh();
  }

  Future<void> _fixBattery() async {
    if (_busy) return;
    setState(() => _busy = true);
    // MIUI/HyperOS guard: ζητάμε ΜΟΝΟ αν δεν είναι ήδη ενεργή η εξαίρεση —
    // αλλιώς το σύστημα ανοίγει τις Ρυθμίσεις σε κάθε εκκίνηση.
    try {
      final already =
          await FlutterForegroundTask.isIgnoringBatteryOptimizations;
      if (!already) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
        await _waitForReturn(short: true);
      }
    } catch (_) {
      // Σε κάποιες συσκευές το API πετάει — δεν είναι κρίσιμο.
    }
    setState(() => _busy = false);
    await _refresh();
  }

  Future<void> _fixMicrophone() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ph.Permission.microphone.request();
    } catch (_) {}
    setState(() => _busy = false);
    await _refresh();
  }

  /// Περιμένει resumed (επιστροφή από Ρυθμίσεις) με timeout ασφαλείας.
  Future<void> _waitForReturn({bool short = false}) async {
    final observer = _ResumeObserver();
    WidgetsBinding.instance.addObserver(observer);
    try {
      await observer.resumed.future.timeout(
        Duration(seconds: short ? 45 : 90),
        onTimeout: () {},
      );
    } catch (_) {
    } finally {
      WidgetsBinding.instance.removeObserver(observer);
    }
  }

  // ── UI ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final s = _status;

    final allCriticalOk = s != null && !s.needsWizard;

    return Scaffold(
      backgroundColor: c.scaffold,
      body: SafeArea(
        child: s == null
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                padding: const EdgeInsets.all(18),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const OnboardingProgress(
                          title: 'Ρύθμιση εφαρμογής', step: 2, total: 4),
                      const SizedBox(height: 8),
                      Text(
                        'Για να λαμβάνεις δουλειές αξιόπιστα, η εφαρμογή χρειάζεται τα εξής:',
                        style:
                            TextStyle(fontSize: 12.5, color: c.textFaint),
                      ),
                      const SizedBox(height: 14),

                      _permCard(
                        c: c,
                        done: s.notifications,
                        icon: Icons.notifications_active_rounded,
                        iconBg: c.greenPale,
                        iconColor: c.greenDeep,
                        title: 'Ειδοποιήσεις',
                        subtitle: 'Για να χτυπάει η νέα δουλειά',
                        onTap: _fixNotifications,
                      ),
                      const SizedBox(height: 10),
                      _permCard(
                        c: c,
                        done: s.locationAlways,
                        highlight: !s.locationAlways,
                        icon: Icons.location_on_rounded,
                        iconBg: c.amberSoft,
                        iconColor: c.amberDeep,
                        title: 'Τοποθεσία — Πάντα ενεργή',
                        subtitle: s.locationWhileInUse && !s.locationAlways
                            ? 'Έχεις «Κατά τη χρήση» — διάλεξε «Να επιτρέπεται πάντα» για να σε βλέπει ο συντονιστής και με κλειστή οθόνη'
                            : 'Διάλεξε «Να επιτρέπεται πάντα» για να σε βλέπει ο συντονιστής και με κλειστή οθόνη',
                        actionLabel: 'Άνοιξε',
                        onTap: _fixLocation,
                      ),
                      const SizedBox(height: 10),
                      _permCard(
                        c: c,
                        done: s.battery,
                        icon: Icons.battery_saver_rounded,
                        iconBg: c.isDark
                            ? const Color(0xFF2E2E2A)
                            : const Color(0xFFF1EFE8),
                        iconColor: c.textFaint,
                        title: 'Μπαταρία χωρίς περιορισμούς',
                        subtitle:
                            'Να μην «κοιμίζει» το Android την εφαρμογή — αλλιώς χάνονται δουλειές',
                        onTap: _fixBattery,
                      ),
                      const SizedBox(height: 10),
                      _permCard(
                        c: c,
                        done: s.microphone,
                        icon: Icons.mic_rounded,
                        iconBg: c.isDark
                            ? const Color(0xFF2E2E2A)
                            : const Color(0xFFF1EFE8),
                        iconColor: c.textFaint,
                        title: 'Μικρόφωνο',
                        subtitle:
                            'Για φωνητικά μηνύματα με τους άλλους οδηγούς (προαιρετικό)',
                        onTap: _fixMicrophone,
                      ),

                      const SizedBox(height: 12),
                      if (!allCriticalOk)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 9),
                          decoration: BoxDecoration(
                            color: c.isDark
                                ? const Color(0xFF3A2C12)
                                : const Color(0xFFFBEFDC),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(Icons.warning_amber_rounded,
                                    size: 16, color: Color(0xFFA66A00)),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Χωρίς αυτά, οι δουλειές μπορεί να ΜΗΝ χτυπούν όταν το κινητό είναι κλειδωμένο.',
                                    style: TextStyle(
                                        fontSize: 11.5,
                                        color: c.isDark
                                            ? const Color(0xFFE9B45C)
                                            : const Color(0xFF7A4E00)),
                                  ),
                                ),
                              ]),
                        ),

                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed:
                              _busy ? null : () => Navigator.of(context).pop(),
                          child: Text(allCriticalOk
                              ? 'Συνέχεια'
                              : 'Συνέχεια χωρίς αυτά'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  Widget _permCard({
    required AppColors c,
    required bool done,
    required IconData icon,
    required Color iconBg,
    required Color iconColor,
    required String title,
    required String subtitle,
    required Future<void> Function() onTap,
    String? actionLabel,
    bool highlight = false,
  }) {
    return Opacity(
      opacity: done ? 0.72 : 1,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: done || _busy ? null : onTap,
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            color: c.card,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: highlight && !done ? c.amber : c.cardBorder,
              width: highlight && !done ? 2 : 0.8,
            ),
          ),
          child: Row(children: [
            Container(
              width: 40, height: 40,
              decoration:
                  BoxDecoration(color: iconBg, shape: BoxShape.circle),
              child: Icon(icon, size: 20, color: iconColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: c.textMain)),
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: 11, color: c.textFaint)),
                  ]),
            ),
            const SizedBox(width: 8),
            if (done)
              const Icon(Icons.check_circle_rounded,
                  size: 24, color: Color(0xFF97C459))
            else if (actionLabel != null)
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 13, vertical: 8),
                decoration: BoxDecoration(
                  color: c.amber,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(actionLabel,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: c.onAmber)),
              )
            else
              Icon(Icons.chevron_right_rounded,
                  size: 22, color: c.textFaint),
          ]),
        ),
      ),
    );
  }
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
