// ==========================================
// FILE: ./lib/jobs/job_popup.dart
// ==========================================
//
// REDESIGN v2 (εγκεκριμένα mockups):
//  • Επάνω μπάρα ΡΑΝΤΕΒΟΥ (μπλε) / ΤΩΡΑ (κίτρινη) με badge οχήματος δεξιά
//  • Μπλοκ πληρωμής: ΜΠΛΕ = προπληρωμένη (ΜΗΝ εισπράξεις, PulsingBox),
//    ΠΡΑΣΙΝΟ = εισπράττεις (μεγάλο ποσό δεξιά)
//  • Μεγάλος χάρτης (lite/static) με badges στις γωνίες:
//    «Από εσένα Χ χλμ · Υ′» πάνω αριστερά, «Διαδρομή» κάτω δεξιά
//  • Παραλαβή · ώρα ραντεβού — Προορισμός · άφιξη ~ΩΩ:ΛΛ (ραντεβού)
//    ή ~Χ′ (άμεση)
//  • Chips (άτομα/βαλίτσες/παιδικά καθίσματα) ΜΕΤΑ τις διευθύνσεις
//  • Πλήρης υποστήριξη Dark mode (AppColors)
//
// Η ΛΟΓΙΚΗ παραμένει ίδια με πριν: timer, ήχος, δόνηση, watchJob,
// αποδοχή/απόρριψη, banner αναμονής, fallbacks αποστάσεων.

import 'dart:async';
import 'dart:math' as math;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:just_audio/just_audio.dart';
import 'package:vibration/vibration.dart';
import '../app_theme.dart';
import '../notifications_service.dart';
import 'job_model.dart';
import 'job_service.dart';
import 'job_shared_widgets.dart';
import 'places_service.dart';

class JobPopup extends StatefulWidget {
  final Job    job;
  final String uid;
  final String driverName;
  // Πλήθος επόμενων διεκδικήσεων που περιμένουν πίσω από αυτή.
  final ValueListenable<int>? pendingCount;

  const JobPopup({
    super.key,
    required this.job,
    required this.uid,
    required this.driverName,
    this.pendingCount,
  });

  @override
  State<JobPopup> createState() => _JobPopupState();
}

class _JobPopupState extends State<JobPopup> {
  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        // Λεπτή γραμμή στο χρώμα του κουμπιού Αποδοχή γύρω-γύρω — ώστε η
        // καρτέλα να ξεχωρίζει ακόμη κι αν το πίσω φόντο είναι σκούρο/μαύρο.
        side: BorderSide(color: c.amber, width: 1.5),
      ),
      backgroundColor: c.scaffold,
      insetPadding:    const EdgeInsets.symmetric(horizontal: 16, vertical: 26),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22.5),
        child: _JobPopupContent(
          job:          widget.job,
          uid:          widget.uid,
          driverName:   widget.driverName,
          pendingCount: widget.pendingCount,
        ),
      ),
    );
  }
}

class _JobPopupContent extends StatefulWidget {
  final Job    job;
  final String uid;
  final String driverName;
  final ValueListenable<int>? pendingCount;

  const _JobPopupContent({
    required this.job,
    required this.uid,
    required this.driverName,
    this.pendingCount,
  });

  @override
  State<_JobPopupContent> createState() => _JobPopupContentState();
}

class _JobPopupContentState extends State<_JobPopupContent>
    with SingleTickerProviderStateMixin {

  late int            _secondsLeft;
  Timer?              _timer;
  Timer?              _vibrationTimer;
  bool                _isTaking  = false;
  bool                _closing   = false;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _jobSub;
  late AnimationController _shakeCtrl;
  late Animation<double>   _shakeAnim;

  final AudioPlayer _popupAudioPlayer = AudioPlayer();

  // Απόσταση/χρόνος ΟΔΗΓΗΣΗΣ του οδηγού μέχρι το σημείο «Από»
  double? _driverDistanceKm;
  int?    _driverDistanceMin;
  bool    _distanceLoading = true;
  bool    _driverDistanceIsAir = false; // true = ευθεία (fallback)

  // Χρόνος διαδρομής (fallback για παλιές δουλειές χωρίς routeMinutes)
  int?    _routeMinutesFallback;

  @override
  void initState() {
    super.initState();
    _secondsLeft = widget.job.secondsRemaining;

    _shakeCtrl = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 400),
    );
    _shakeAnim = Tween<double>(begin: 0, end: 12).animate(
      CurvedAnimation(parent: _shakeCtrl, curve: Curves.elasticIn),
    );

    _startTimer();
    _playAlertSound();
    _startVibration();
    _watchJob();
    _computeDriverDistance();
    _ensureRouteMinutes();
  }

  // Αν η δουλειά ΔΕΝ έχει αποθηκευμένο χρόνο (παλιές δουλειές), τον
  // υπολογίζουμε μία φορά. Ραντεβού → πρόβλεψη κίνησης για την ώρα
  // ραντεβού· άμεση → τώρα.
  Future<void> _ensureRouteMinutes() async {
    final job = widget.job;
    if (job.routeMinutes != null) return;
    if (job.fromLat == null || job.fromLng == null ||
        job.toLat == null   || job.toLng == null) {
      return;
    }
    try {
      final route = await PlacesService.route(
        fromLat: job.fromLat!, fromLng: job.fromLng!,
        toLat:   job.toLat!,   toLng:   job.toLng!,
        departureTime: job.scheduledAt,
      );
      if (!mounted || route?.minutes == null) return;
      setState(() => _routeMinutesFallback = route!.minutes);
    } catch (_) {/* αγνόησε — απλώς δεν δείχνουμε χρόνο */}
  }

  // Θέση οδηγού → απόσταση + χρόνος ΟΔΗΓΗΣΗΣ μέχρι το σημείο «Από».
  Future<void> _computeDriverDistance() async {
    final job = widget.job;
    if (job.fromLat == null || job.fromLng == null) {
      if (mounted) setState(() => _distanceLoading = false);
      return;
    }
    try {
      // Φρέσκια θέση οδηγού (με fallback στην τελευταία γνωστή)
      Position? pos;
      try {
        pos = await Geolocator.getCurrentPosition(
          locationSettings:
              const LocationSettings(accuracy: LocationAccuracy.high),
        ).timeout(const Duration(seconds: 10));
      } catch (_) {
        pos = await Geolocator.getLastKnownPosition();
      }
      if (pos == null) {
        if (mounted) setState(() => _distanceLoading = false);
        return;
      }

      // Απόσταση ΟΔΗΓΗΣΗΣ μέσω Routes API
      final route = await PlacesService.route(
        fromLat: pos.latitude,  fromLng: pos.longitude,
        toLat:   job.fromLat!,  toLng:   job.fromLng!,
      );

      // Αν το Routes API αποτύχει → fallback σε ευθεία
      final km = route?.km ??
          haversineKm(pos.latitude, pos.longitude,
              job.fromLat!, job.fromLng!);

      if (!mounted) return;
      setState(() {
        _driverDistanceKm    = km;
        _driverDistanceMin   = route?.minutes;
        _driverDistanceIsAir = route == null;
        _distanceLoading     = false;
      });
    } catch (_) {
      if (mounted) setState(() => _distanceLoading = false);
    }
  }

  // Αν ο admin πατήσει ΣΤΟΠ, ή την πάρει άλλος, ή διαγραφεί →
  // κλείνει αυτόματα το popup & σταματά ο ήχος.
  void _watchJob() {
    _jobSub = FirebaseFirestore.instance
        .collection('jobs')
        .doc(widget.job.id)
        .snapshots()
        .listen((doc) {
      if (!mounted || _closing || _isTaking) return;
      final stopped = doc.exists && doc.data()?['stopped'] == true;
      final status  = doc.data()?['status'] ?? 'open';
      if (!doc.exists || stopped || status != 'open') {
        _autoClose();
      }
    });
  }

  void _autoClose() {
    if (_closing || !mounted) return;
    _closing = true;
    _timer?.cancel();
    _stopSound();
    Navigator.of(context).pop(false);
  }

  Future<void> _startVibration() async {
    bool hasVibrator = false;
    try {
      hasVibrator = await Vibration.hasVibrator();
    } catch (_) {}

    if (hasVibrator) {
      try {
        Vibration.vibrate(
          pattern:   const [0, 800, 400, 800, 400, 800, 400, 800],
          intensities: const [0, 255, 0, 255, 0, 255, 0, 255],
        );
      } catch (_) {
        HapticFeedback.heavyImpact();
      }
      _vibrationTimer = Timer.periodic(const Duration(milliseconds: 4500), (_) {
        try {
          Vibration.vibrate(
            pattern:   const [0, 800, 400, 800, 400, 800, 400, 800],
            intensities: const [0, 255, 0, 255, 0, 255, 0, 255],
          );
        } catch (_) {
          HapticFeedback.heavyImpact();
        }
      });
    } else {
      HapticFeedback.heavyImpact();
      _vibrationTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        HapticFeedback.heavyImpact();
      });
    }
  }

  void _stopVibration() {
    _vibrationTimer?.cancel();
    _vibrationTimer = null;
    try {
      Vibration.cancel();
    } catch (_) {}
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _secondsLeft--);
      if (_secondsLeft <= 10 && _secondsLeft > 0) {
        _shakeCtrl.forward(from: 0);
      }
      if (_secondsLeft <= 0) {
        _timer?.cancel();
        _stopSound();
        if (mounted && !_closing) {
          _closing = true;
          Navigator.of(context).pop(false);
        }
      }
    });
  }

  Future<void> _playAlertSound() async {
    FlutterForegroundTask.sendDataToTask({'action': 'stopSound'});
    try {
      await _popupAudioPlayer.setLoopMode(LoopMode.one);
      await _popupAudioPlayer.setAsset('assets/Notifaction Bell.mp3');
      await _popupAudioPlayer.play();
    } catch (e) {
      debugPrint("Σφάλμα αναπαραγωγής ήχου popup: $e");
    }
  }

  Future<void> _stopSound() async {
    _stopVibration();
    try {
      await _popupAudioPlayer.stop();
    } catch (_) {}
    try {
      await NotificationsService.silenceRingtone();
    } catch (_) {}
  }

  @override
  void dispose() {
    _jobSub?.cancel();
    _stopVibration();
    _timer?.cancel();
    _shakeCtrl.dispose();
    _popupAudioPlayer.dispose();
    super.dispose();
  }

  Future<void> _accept() async {
    _timer?.cancel();
    await _stopSound();
    setState(() => _isTaking = true);
    final success = await JobService.takeJob(
      jobId: widget.job.id,
      uid:   widget.uid,
      name:  widget.driverName,
    );
    if (!mounted) return;
    // Παίρνουμε το messenger ΠΡΙΝ το pop — μετά το pop το context
    // του popup απενεργοποιείται και το ScaffoldMessenger.of(context) σκάει.
    final messenger = ScaffoldMessenger.of(context);
    _closing = true;
    if (success) {
      Navigator.of(context).pop(true);
      _showConfirmation(messenger);
    } else {
      Navigator.of(context).pop(false);
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Η δουλειά ανελήφθη από άλλον οδηγό!'),
          backgroundColor: Colors.orange,
        ),
      );
    }
  }

  void _decline() {
    _timer?.cancel();
    _stopSound();
    Navigator.of(context).pop(false);
  }

  void _showConfirmation(ScaffoldMessengerState messenger) {
    messenger.showSnackBar(
      SnackBar(
        content: Row(children: [
          const Icon(Icons.check_circle_rounded, color: Colors.white),
          const SizedBox(width: 10),
          Expanded(child: Text('Ανέλαβες: ${widget.job.from} → ${widget.job.to}',
              maxLines: 2, overflow: TextOverflow.ellipsis)),
        ]),
        backgroundColor: const Color(0xFF1E8E3E),
        duration:        const Duration(seconds: 4),
      ),
    );
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  String get _timeLabel {
    final m = _secondsLeft ~/ 60;
    final s = _secondsLeft  % 60;
    return m > 0 ? '$m:${s.toString().padLeft(2, '0')}' : '$s';
  }

  Color get _timerColor {
    if (_secondsLeft > 30) return const Color(0xFF1E8E3E);
    if (_secondsLeft > 10) return Colors.orange;
    return Colors.red;
  }

  static String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, "0")}:${t.minute.toString().padLeft(2, "0")}';

  // «Αύριο, Τρ 21/07 · 14:30» — φιλική ετικέτα ραντεβού
  String _scheduleLabel(DateTime t) {
    const days = ['Δε', 'Τρ', 'Τε', 'Πε', 'Πα', 'Σα', 'Κυ'];
    final now      = DateTime.now();
    final today    = DateTime(now.year, now.month, now.day);
    final thatDay  = DateTime(t.year, t.month, t.day);
    final diffDays = thatDay.difference(today).inDays;
    final dayPart  = switch (diffDays) {
      0 => 'Σήμερα',
      1 => 'Αύριο',
      _ => days[t.weekday - 1],
    };
    final dm = '${t.day.toString().padLeft(2, "0")}/${t.month.toString().padLeft(2, "0")}';
    return '$dayPart $dm · ${_hhmm(t)}';
  }

  IconData get _vehicleIcon => switch (widget.job.vehicleType) {
        'van'     => Icons.airport_shuttle_rounded,
        'bus'     => Icons.directions_bus_rounded,
        'shuttle' => Icons.directions_bus_rounded,
        _         => Icons.local_taxi_rounded,
      };

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    final c   = AppColors.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [

        // 0. BANNER ΑΝΑΜΟΝΗΣ — πόσες ακόμη διεκδικήσεις περιμένουν πίσω.
        if (widget.pendingCount != null)
          ValueListenableBuilder<int>(
            valueListenable: widget.pendingCount!,
            builder: (_, waiting, _) {
              if (waiting <= 0) return const SizedBox.shrink();
              return Container(
                width: double.infinity,
                color: Colors.black87,
                padding:
                    const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.layers_rounded, size: 16, color: c.amber),
                    const SizedBox(width: 8),
                    Text(
                      waiting == 1
                          ? '1 διεκδίκηση σε αναμονή'
                          : '$waiting διεκδικήσεις σε αναμονή',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              );
            },
          ),

        // 1. ΛΕΠΤΟ HEADER: «Νέα δουλειά» + χρονόμετρο (με shake στα <10″)
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
          child: Row(children: [
            Icon(Icons.work_rounded, size: 18, color: c.amberDeep),
            const SizedBox(width: 8),
            Text('Νέα δουλειά',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: c.textMain)),
            const Spacer(),
            AnimatedBuilder(
              animation: _shakeAnim,
              builder: (_, child) => Transform.translate(
                offset: Offset(
                  _secondsLeft <= 10
                      ? (_shakeCtrl.value < 0.5
                          ? _shakeAnim.value
                          : -_shakeAnim.value)
                      : 0,
                  0,
                ),
                child: child,
              ),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                curve:    Curves.easeInOut,
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 5),
                decoration: BoxDecoration(
                  color:        _timerColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(20),
                  border:       Border.all(color: _timerColor, width: 2),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.timer_rounded, size: 15, color: _timerColor),
                  const SizedBox(width: 5),
                  Text(_timeLabel,
                      style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          color: _timerColor)),
                ]),
              ),
            ),
          ]),
        ),

        // 2. SCROLLABLE BODY
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [

                // ── Μπάρα ΡΑΝΤΕΒΟΥ / ΤΩΡΑ με badge οχήματος δεξιά ──
                _scheduleBar(job, c),
                const SizedBox(height: 12),

                // ── Μπλοκ πληρωμής: μπλε = ΜΗΝ εισπράξεις,
                //    πράσινο = εισπράττεις ──
                _paymentBlock(job, c),
                const SizedBox(height: 12),

                // ── Κάρτα: χάρτης (badges στις γωνίες) + διευθύνσεις ──
                _routeCard(job, c),

                // ── Chips: άτομα / βαλίτσες / παιδικά καθίσματα ──
                const SizedBox(height: 12),
                _detailChips(job, c),

                // ── Σήματα: επιστροφή / στάσεις ──
                if (job.withReturn || job.withStops) ...[
                  const SizedBox(height: 10),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    if (job.withReturn)
                      _routeTag(
                        icon:  Icons.swap_horiz_rounded,
                        label: 'ΜΕ ΕΠΙΣΤΡΟΦΗ',
                        color: const Color(0xFF1565C0),
                      ),
                    if (job.withStops)
                      _routeTag(
                        icon:  Icons.more_horiz_rounded,
                        label: 'ΜΕ ΣΤΑΣΕΙΣ',
                        color: const Color(0xFFAD1457),
                      ),
                  ]),
                ],

                // ── Πτήση / Πλοίο (όνομα & τηλέφωνο κρυμμένα πριν την
                //    ανάθεση) ──
                if (job.flightOrShip != null &&
                    job.flightOrShip!.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color:        c.amberSoft,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(children: [
                      Icon(Icons.flight_rounded,
                          size: 17, color: c.amberDeep),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text('Πτήση / Πλοίο: ${job.flightOrShip!}',
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: c.isDark
                                    ? c.amberDeep
                                    : const Color(0xFF633806))),
                      ),
                    ]),
                  ),
                ],

                // ── Σημειώσεις ──
                if (job.note != null && job.note!.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Container(
                    width:   double.infinity,
                    padding: const EdgeInsets.all(11),
                    decoration: BoxDecoration(
                      color:        c.card,
                      borderRadius: BorderRadius.circular(14),
                      border:       Border.all(color: c.cardBorder, width: 0.8),
                    ),
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.notes_rounded,
                              size: 16, color: c.textFaint),
                          const SizedBox(width: 8),
                          Expanded(
                              child: Text(job.note!,
                                  style: TextStyle(
                                      fontSize: 13, color: c.textMain))),
                        ]),
                  ),
                ],

                if (job.commissionLabel.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(job.commissionLabel,
                      style: TextStyle(fontSize: 11, color: c.textFaint)),
                ],
              ],
            ),
          ),
        ),

        // 3. ΣΤΑΘΕΡΑ ΚΟΥΜΠΙΑ (pill) — SafeArea για το κάτω navigation bar
        SafeArea(
          top: false,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
            decoration: BoxDecoration(
              color:  c.scaffold,
              border: Border(top: BorderSide(color: c.divider, width: 1)),
            ),
            child: Row(children: [
              Expanded(
                flex: 2,
                child: OutlinedButton(
                  onPressed: _isTaking ? null : _decline,
                  child: const Text('Απόρριψη'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 3,
                child: FilledButton(
                  onPressed: _isTaking ? null : _accept,
                  child: _isTaking
                      ? const SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Αποδοχή'),
                ),
              ),
            ]),
          ),
        ),
      ],
    );
  }

  // ─── Τμήματα UI ───────────────────────────────────────────────────────────

  // Μπάρα ΡΑΝΤΕΒΟΥ (μπλε) / ΤΩΡΑ (κίτρινη) με badge οχήματος δεξιά
  Widget _scheduleBar(Job job, AppColors c) {
    final isScheduled = job.scheduledAt != null;

    final bg        = isScheduled ? c.blueSoft : c.amberSoft;
    final iconColor = isScheduled
        ? (c.isDark ? const Color(0xFF7FB3E8) : const Color(0xFF0C447C))
        : c.amberDeep;
    final textColor = isScheduled
        ? c.blueDeep
        : (c.isDark ? c.amberDeep : const Color(0xFF633806));
    final badgeBg   = isScheduled
        ? (c.isDark ? const Color(0xFF7FB3E8) : const Color(0xFF042C53))
        : (c.isDark ? c.amberDeep : const Color(0xFF633806));
    final badgeFg   = isScheduled
        ? (c.isDark ? const Color(0xFF0A2540) : c.blueSoft)
        : (c.isDark ? const Color(0xFF2A1A05) : c.amberSoft);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      decoration: BoxDecoration(
        color:        bg,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(children: [
        Icon(
          isScheduled ? Icons.event_rounded : Icons.bolt_rounded,
          size: 22, color: iconColor,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: isScheduled
              ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('ΡΑΝΤΕΒΟΥ',
                      style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          color: iconColor)),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(_scheduleLabel(job.scheduledAt!),
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: textColor)),
                  ),
                ])
              : Text('ΤΩΡΑ — Άμεση παραλαβή',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: textColor)),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          decoration: BoxDecoration(
            color:        badgeBg,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(_vehicleIcon, size: 15, color: badgeFg),
            const SizedBox(width: 5),
            Text(job.vehicleLabel.toUpperCase(),
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: badgeFg)),
          ]),
        ),
      ]),
    );
  }

  // Μπλοκ πληρωμής
  Widget _paymentBlock(Job job, AppColors c) {
    // Ανάλυση: Γιαούρτι / Προμήθεια app — μικρή γραμμή κάτω (χωρίς Ναύλος,
    // αφού το ποσό δείχνεται ήδη μεγάλο πάνω-πάνω).
    String breakdownLeft() {
      final parts = <String>[];
      if (job.commission > 0) {
        parts.add('Γιαούρτι −${job.commission.toStringAsFixed(2)} €');
      }
      if (job.appCommission > 0) {
        parts.add('App −${job.appCommission.toStringAsFixed(2)} €');
      }
      return parts.join(' · ');
    }

    final earning = 'Κέρδος ${job.driverEarning.toStringAsFixed(2)} €';

    // ── ΜΠΛΕ: πλήρως προπληρωμένη → ΔΕΝ εισπράττει τίποτα ──
    if (job.fullyPaid) {
      final block = Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
        decoration: BoxDecoration(
          color:        c.bluePale,
          border:       Border.all(color: c.blue, width: 2),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(children: [
          Row(children: [
            Icon(Icons.credit_card_rounded,
                size: 24,
                color: c.isDark ? const Color(0xFF7FB3E8) : const Color(0xFF0C447C)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('ΠΡΟΠΛΗΡΩΜΕΝΗ — ΜΗΝ εισπράξεις',
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: c.blueDeep)),
                    Text('Ο πελάτης έχει πληρώσει',
                        style:
                            TextStyle(fontSize: 12, color: c.blueFaint)),
                  ]),
            ),
          ]),
          Padding(
            padding: const EdgeInsets.only(top: 9),
            child: Column(children: [
              Divider(height: 1, color: c.blueDivider),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: Text(breakdownLeft(),
                      style: TextStyle(fontSize: 12, color: c.blueFaint)),
                ),
                Text(earning,
                    style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: c.blueDeep)),
              ]),
            ]),
          ),
        ]),
      );
      // «Ανασαίνει» ώστε να ΜΗΝ χαθεί σε καμία περίπτωση.
      return PulsingBox(child: block);
    }

    // ── ΠΡΑΣΙΝΟ: εισπράττει (πλήρες ποσό ή υπόλοιπο μετά προκαταβολή) ──
    final subtitle = job.depositPaid
        ? 'Ο πελάτης πλήρωσε προκαταβολή ${job.depositAmount.toStringAsFixed(2)} € online — εισπράττεις μόνο το υπόλοιπο'
        : 'Πληρωμή από τον πελάτη στο ταξί';

    final amountText = Text(
      '${job.remainingToCollect.toStringAsFixed(2)} €',
      style: TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.w700,
          height: 1.05,
          color: c.greenDeep),
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
      decoration: BoxDecoration(
        color:        c.greenPale,
        border:       Border.all(color: c.green, width: 2),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.payments_rounded, size: 24, color: c.greenDeep),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Εισπράττεις',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: c.greenFaint)),
                job.depositPaid
                    ? PulsingBox(child: amountText)
                    : amountText,
              ],
            ),
          ),
        ]),
        Padding(
          padding: const EdgeInsets.only(left: 34, top: 3),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(subtitle,
                style: TextStyle(fontSize: 12, color: c.greenFaint)),
          ),
        ),
        if (breakdownLeft().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Column(children: [
              Divider(height: 1, color: c.greenDivider),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: Text(breakdownLeft(),
                      style: TextStyle(fontSize: 12, color: c.greenFaint)),
                ),
                Text(earning,
                    style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: c.greenDeep)),
              ]),
            ]),
          )
        else
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Column(children: [
              Divider(height: 1, color: c.greenDivider),
              const SizedBox(height: 8),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                Text(earning,
                    style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: c.greenDeep)),
              ]),
            ]),
          ),
      ]),
    );
  }

  // Κάρτα: μεγάλος χάρτης (badges στις γωνίες) + διευθύνσεις από κάτω
  Widget _routeCard(Job job, AppColors c) {
    final routeMin = job.routeMinutes ?? _routeMinutesFallback;

    // Ετικέτα προορισμού: ραντεβού → ώρα άφιξης, άμεση → λεπτά διαδρομής
    String destLabel() {
      if (job.scheduledAt != null && routeMin != null) {
        final eta = job.scheduledAt!.add(Duration(minutes: routeMin));
        return 'Προορισμός · άφιξη ~${_hhmm(eta)}';
      }
      if (job.scheduledAt == null && routeMin != null) {
        return 'Προορισμός · ~${formatRouteMinutes(routeMin)}';
      }
      return 'Προορισμός';
    }

    return Container(
      decoration: BoxDecoration(
        color:        c.card,
        borderRadius: BorderRadius.circular(16),
        border:       Border.all(color: c.cardBorder, width: 0.8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        if (job.hasRouteCoords) _mapWithBadges(job, c, routeMin),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(Icons.trip_origin_rounded,
                    size: 16,
                    color: c.isDark
                        ? const Color(0xFF5FA8F0)
                        : const Color(0xFF185FA5)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(TextSpan(
                        text: 'Παραλαβή',
                        style:
                            TextStyle(fontSize: 11, color: c.textFaint),
                        children: [
                          if (job.scheduledAt != null)
                            TextSpan(
                              text: ' · ${_hhmm(job.scheduledAt!)}',
                              style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: c.isDark
                                      ? const Color(0xFFC9E0F7)
                                      : c.blueDeep),
                            ),
                        ],
                      )),
                      Text(job.from,
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: c.textMain)),
                    ]),
              ),
            ]),
            const SizedBox(height: 10),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(Icons.place_rounded, size: 16, color: c.pin),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(destLabel(),
                          style:
                              TextStyle(fontSize: 11, color: c.textFaint)),
                      Text(job.to,
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: c.textMain)),
                    ]),
              ),
            ]),
          ]),
        ),
      ]),
    );
  }

  // Χάρτης lite (static εικόνα σε Android) με 2 badges στις γωνίες
  Widget _mapWithBadges(Job job, AppColors c, int? routeMin) {
    final from = LatLng(job.fromLat!, job.fromLng!);
    final to   = LatLng(job.toLat!,   job.toLng!);

    final routeKm = job.routeKm ??
        haversineKm(job.fromLat!, job.fromLng!, job.toLat!, job.toLng!);

    final List<LatLng> linePts;
    if (job.routePolyline != null && job.routePolyline!.isNotEmpty) {
      linePts = decodePolyline(job.routePolyline!)
          .map((p) => LatLng(p[0], p[1]))
          .toList();
    } else {
      linePts = [from, to];
    }

    final markers = <Marker>{
      Marker(
        markerId: const MarkerId('from'),
        position: from,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
      ),
      Marker(
        markerId: const MarkerId('to'),
        position: to,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
      ),
    };

    final polylines = <Polyline>{
      Polyline(
        polylineId: const PolylineId('route'),
        points:     linePts,
        color:      c.blue,
        width:      4,
      ),
    };

    final bounds  = _boundsOf([from, to]);
    final latSpan = (bounds.northeast.latitude - bounds.southwest.latitude).abs();
    final lngSpan = (bounds.northeast.longitude - bounds.southwest.longitude).abs();
    // Κέντρο ελαφρώς προς τα πάνω ώστε οι πινέζες να μην κόβονται.
    final center = LatLng(
      (bounds.southwest.latitude + bounds.northeast.latitude) / 2
          + latSpan * 0.12,
      (bounds.southwest.longitude + bounds.northeast.longitude) / 2,
    );
    final zoom = _zoomForSpan(latSpan, lngSpan);

    // Badge «Από εσένα Χ χλμ · Υ′» (πάνω αριστερά, σκούρο)
    String? driverBadge;
    if (_distanceLoading) {
      driverBadge = 'Από εσένα …';
    } else if (_driverDistanceKm != null) {
      final air = _driverDistanceIsAir ? '~' : '';
      final min = _driverDistanceMin != null && !_driverDistanceIsAir
          ? ' · ${_driverDistanceMin!}′'
          : '';
      driverBadge =
          'Από εσένα $air${_driverDistanceKm!.toStringAsFixed(1)} χλμ$min';
    }

    // Badge «Διαδρομή» (κάτω δεξιά, ανοιχτό)
    final routeBadge = routeMin != null
        ? '${routeKm.toStringAsFixed(1)} χλμ · ${formatRouteMinutes(routeMin)}'
        : '${routeKm.toStringAsFixed(1)} χλμ';

    return SizedBox(
      height: 220,
      width:  double.infinity,
      child: Stack(children: [
        Positioned.fill(
          child: GoogleMap(
            liteModeEnabled:         true,
            initialCameraPosition:   CameraPosition(target: center, zoom: zoom),
            markers:                 markers,
            polylines:               polylines,
            zoomControlsEnabled:     false,
            mapToolbarEnabled:       false,
            myLocationButtonEnabled: false,
          ),
        ),
        if (driverBadge != null)
          Positioned(
            top: 8, left: 8,
            child: _mapBadge(
              text: driverBadge,
              icon: Icons.navigation_rounded,
              bg:   Colors.black.withValues(alpha: 0.78),
              fg:   Colors.white,
            ),
          ),
        Positioned(
          bottom: 8, right: 8,
          child: _mapBadge(
            text: routeBadge,
            icon: Icons.route_rounded,
            bg:   c.isDark
                ? const Color(0xFF3A3A36).withValues(alpha: 0.92)
                : Colors.white.withValues(alpha: 0.92),
            fg:   c.textMain,
          ),
        ),
      ]),
    );
  }

  Widget _mapBadge({
    required String   text,
    required IconData icon,
    required Color    bg,
    required Color    fg,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color:        bg,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 15, color: fg),
        const SizedBox(width: 6),
        Text(text,
            style: TextStyle(
                fontSize: 13.5, fontWeight: FontWeight.w700, color: fg)),
      ]),
    );
  }

  // Chips: άτομα / βαλίτσες / παιδικά καθίσματα
  Widget _detailChips(Job job, AppColors c) {
    Widget chip(IconData icon, String label,
        {Color? bg, Color? border, Color? fg, bool bold = false}) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color:        bg ?? c.card,
          borderRadius: BorderRadius.circular(12),
          border:       Border.all(color: border ?? c.cardBorder, width: 0.8),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 16, color: fg ?? c.textFaint),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: bold ? FontWeight.w600 : FontWeight.w500,
                  color: fg ?? c.textMain)),
        ]),
      );
    }

    return Wrap(spacing: 8, runSpacing: 8, children: [
      chip(Icons.person_rounded,
          job.persons == 1 ? '1 άτομο' : '${job.persons} άτομα'),
      chip(Icons.luggage_rounded,
          job.luggage == 1 ? '1 βαλίτσα' : '${job.luggage} βαλίτσες'),
      if (job.childSeat)
        chip(
          Icons.child_care_rounded,
          job.childSeatCount > 1
              ? '${job.childSeatCount} παιδικά καθίσματα'
              : '1 παιδικό κάθισμα',
          bg:     c.pinkSoft,
          border: c.pinkBorder,
          fg:     c.pinkDeep,
          bold:   true,
        ),
    ]);
  }

  // Σήμα διαδρομής (επιστροφή / στάσεις)
  Widget _routeTag({
    required IconData icon,
    required String   label,
    required Color    color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 12),
      decoration: BoxDecoration(
        color:        color,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 16, color: Colors.white),
        const SizedBox(width: 6),
        Text(label,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.white,
                letterSpacing: 0.5)),
      ]),
    );
  }

  // Zoom ώστε να φαίνονται ΚΑΙ ΟΙ 2 πινέζες με περιθώριο —
  // και οι γωνίες (badges) να μένουν ελεύθερες.
  double _zoomForSpan(double latSpan, double lngSpan) {
    var span = math.max(latSpan, lngSpan * 0.78);
    // Μεγαλύτερο περιθώριο (was 1.18/0.003) ώστε οι 2 πινέζες να μην
    // ακουμπάνε ποτέ στις άκρες του χάρτη — να φαίνονται καθαρά αρχή/τέλος.
    span = span * 1.55 + 0.006;
    if (span <= 0.0012) return 14.0;
    final z = math.log(360.0 / span) / math.ln2;
    return (z - 0.35).clamp(4.0, 16.0);
  }

  LatLngBounds _boundsOf(List<LatLng> pts) {
    double minLat = pts.first.latitude,  maxLat = pts.first.latitude;
    double minLng = pts.first.longitude, maxLng = pts.first.longitude;
    for (final p in pts) {
      if (p.latitude  < minLat) minLat = p.latitude;
      if (p.latitude  > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    return LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );
  }
}

Future<bool> showJobPopup({
  required BuildContext context,
  required Job          job,
  required String       uid,
  required String       driverName,
  ValueListenable<int>? pendingCount,
}) async {
  // Εμφάνιση με scale + fade (280ms) — «ζωντανό» χτύπημα δουλειάς.
  final result = await showGeneralDialog<bool>(
    context:            context,
    barrierDismissible: false,
    barrierLabel:       'job_popup',
    barrierColor:       Colors.black.withValues(alpha: 0.6),
    transitionDuration: const Duration(milliseconds: 280),
    pageBuilder: (_, _, _) => JobPopup(
      job:          job,
      uid:          uid,
      driverName:   driverName,
      pendingCount: pendingCount,
    ),
    transitionBuilder: (_, anim, _, child) {
      final curved =
          CurvedAnimation(parent: anim, curve: Curves.easeOutBack);
      return FadeTransition(
        opacity: anim,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.85, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
  return result ?? false;
}
