// ==========================================
// FILE: ./lib/jobs/job_popup.dart
// ==========================================
//
// ΝΕΟ ΣΤΙΛ ΚΑΡΤΑΣ ΝΕΑΣ ΔΟΥΛΕΙΑΣ (προς διεκδίκηση).
// Ίδιο με το job_popup.dart με προσθήκη:
//  • χάρτη με τα 2 σημεία (Από / Προς)
//  • απόσταση διαδρομής σε χλμ
//  • απόσταση του οδηγού από το σημείο "Από"
// Χρησιμοποιείται μόνο όταν ο διακόπτης "Νέα Φόρμα Δουλειάς" είναι ON
// και η δουλειά έχει συντεταγμένες.

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
import 'job_model.dart';
import 'job_service.dart';
import 'places_service.dart';
import '../notifications_service.dart';

class JobPopup extends StatefulWidget {
  final Job    job;
  final String uid;
  final String driverName;
  // Πλήθος επόμενων διεκδικήσεων που περιμένουν πίσω από αυτή.
  // Ενημερώνεται ζωντανά όσο φτάνουν νέες δουλειές.
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
    return Dialog(
      shape:           RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      backgroundColor: Colors.white,
      insetPadding:    const EdgeInsets.symmetric(horizontal: 20, vertical: 30),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
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

  // Απόσταση του οδηγού από το σημείο "Από" (οδήγηση, χλμ)
  double? _driverDistanceKm;
  bool    _distanceLoading = true;
  bool    _driverDistanceIsAir = false; // true = ευθεία (fallback)

  // Χρόνος διαδρομής (fallback για παλιές δουλειές χωρίς αποθηκευμένο routeMinutes)
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

  // Αν η δουλειά ΔΕΝ έχει αποθηκευμένο χρόνο (παλιές δουλειές), τον υπολογίζουμε
  // μία φορά. Ραντεβού → πρόβλεψη κίνησης για την ώρα ραντεβού· άμεση → τώρα.
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

  // Βρίσκει την τρέχουσα θέση του οδηγού και υπολογίζει την απόσταση
  // ΟΔΗΓΗΣΗΣ μέχρι το σημείο "Από" (πού βρίσκεται ο πελάτης).
  // Κάθε οδηγός είναι αλλού → ο καθένας βλέπει τη δική του απόσταση.
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
        _driverDistanceIsAir = route == null;
        _distanceLoading     = false;
      });
    } catch (_) {
      if (mounted) setState(() => _distanceLoading = false);
    }
  }

  // Παρακολουθεί τη δουλειά — αν ο admin πατήσει ΣΤΟΠ, ή την πάρει άλλος,
  // ή διαγραφεί → κλείνει αυτόματα το popup & σταματά ο ήχος.
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
    // Δυνατή, συνεχόμενη δόνηση όσο εμφανίζεται το popup
    bool hasVibrator = false;
    try {
      hasVibrator = await Vibration.hasVibrator();
    } catch (_) {}

    if (hasVibrator) {
      // Μοτίβο: 4 έντονοι παλμοί 800ms, με μέγιστη ένταση
      try {
        Vibration.vibrate(
          pattern:   const [0, 800, 400, 800, 400, 800, 400, 800],
          intensities: const [0, 255, 0, 255, 0, 255, 0, 255],
        );
      } catch (_) {
        HapticFeedback.heavyImpact();
      }
      // Επανάληψη κάθε 4.5s (όσο διαρκεί το μοτίβο)
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
    // ΠΡΟΣΟΧΗ: παίρνουμε το messenger ΠΡΙΝ το pop — μετά το pop το context
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
          Text('Ανέλαβες: ${widget.job.from} → ${widget.job.to}'),
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

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final job = widget.job;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [

        // 0. BANNER ΑΝΑΜΟΝΗΣ — πόσες ακόμη διεκδικήσεις περιμένουν πίσω.
        //    Εμφανίζεται μόνο όταν υπάρχουν >0 και ενημερώνεται ζωντανά.
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
                    const Icon(Icons.layers_rounded,
                        size: 16, color: Colors.amber),
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

        // 1. ΣΤΑΘΕΡΟ HEADER
        Container(
          width:  double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: const BoxDecoration(
            color: Colors.amber,
          ),
          child: Column(children: [
            const Icon(Icons.work_rounded, size: 32, color: Colors.black87),
            const SizedBox(height: 4),
            const Text('Νέα Διεκδίκηση!',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.black87)),
            const SizedBox(height: 8),
            AnimatedBuilder(
              animation: _shakeAnim,
              builder: (_, child) => Transform.translate(
                offset: Offset(
                  _secondsLeft <= 10 ? (_shakeCtrl.value < 0.5 ? _shakeAnim.value : -_shakeAnim.value) : 0,
                  0,
                ),
                child: child,
              ),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                curve:    Curves.easeInOut,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                decoration: BoxDecoration(
                  color:        _timerColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                  border:       Border.all(color: _timerColor, width: 2),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.timer_rounded, size: 16, color: _timerColor),
                  const SizedBox(width: 6),
                  Text(_timeLabel, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _timerColor)),
                ]),
              ),
            ),
          ]),
        ),

        // 1b. ΜΠΑΡΑ ΚΑΤΑΣΤΑΣΗΣ — από άκρη σε άκρη, κάτω από το header.
        //     Μπλε «Προγραμματισμένη» αν είναι ραντεβού, αλλιώς πράσινη «ΑΜΕΣΑ».
        if (job.scheduledAt != null)
          Container(
            width: double.infinity,
            color: const Color(0xFF185FA5),
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.schedule_rounded, size: 16, color: Colors.white),
                const SizedBox(width: 8),
                Text(
                  'Προγραμματισμένη: ${job.scheduledAt!.day}/${job.scheduledAt!.month} ${job.scheduledAt!.hour.toString().padLeft(2, "0")}:${job.scheduledAt!.minute.toString().padLeft(2, "0")}',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600),
                ),
              ],
            ),
          )
        else
          Container(
            width: double.infinity,
            color: const Color(0xFF1E8E3E),
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.bolt_rounded, size: 18, color: Colors.white),
                SizedBox(width: 8),
                Text(
                  'ΑΜΕΣΑ',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5),
                ),
              ],
            ),
          ),

        // 2. SCROLLABLE BODY
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [

                // Το απόλυτα διορθωμένο Timeline (ΧΩΡΙΣ errors)
                _routeRow(job.from, job.to),
                const SizedBox(height: 12),
                // ── Χάρτης με τα 2 σημεία + αποστάσεις ──────────────────────
                _mapSection(job),
                const SizedBox(height: 16),
                Divider(color: Colors.grey[200], height: 1),
                const SizedBox(height: 12),

                // Οικονομικά στοιχεία
                Row(children: [
                  Expanded(child: _infoCell(
                    icon:  Icons.euro_rounded,
                    label: job.fullyPaid ? 'Πληρώθηκε online' : (job.depositPaid ? 'Να εισπράξεις' : 'Τιμή'),
                    value: '${job.remainingToCollect.toStringAsFixed(2)}€',
                    color: const Color(0xFF1E8E3E),
                    large: true,
                  )),
                  if (job.commission > 0)
                    Expanded(child: _infoCell(
                      icon:  Icons.handshake_rounded,
                      label: 'Γιαούρτι',
                      value: '-${job.commission.toStringAsFixed(2)}€',
                      color: Colors.orange,
                    )),
                  Expanded(child: _infoCell(
                    icon:  Icons.account_balance_wallet_rounded,
                    label: 'Κέρδος',
                    value: '${job.driverEarning.toStringAsFixed(2)}€',
                    color: Colors.blue,
                    large: true,
                  )),
                ]),
                // Σημείωση προκαταβολής/πλήρους πληρωμής — ώστε ο οδηγός να
                // καταλάβει γιατί το ποσό που θα εισπράξει διαφέρει.
                if (job.depositPaid) ...[
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.blue.shade200),
                    ),
                    child: Row(children: [
                      Icon(Icons.info_outline_rounded, size: 15, color: Colors.blue.shade700),
                      const SizedBox(width: 7),
                      Expanded(child: Text(
                        job.fullyPaid
                            ? 'Ο πελάτης έχει ήδη πληρώσει ΟΛΟΚΛΗΡΗ την τιμή (${job.depositAmount.toStringAsFixed(2)}€) online. Δεν χρειάζεται να εισπράξεις τίποτα!'
                            : 'Ο πελάτης πλήρωσε προκαταβολή ${job.depositAmount.toStringAsFixed(2)}€ online στον master. '
                              'Το ποσό ${job.price.toStringAsFixed(2)}€ πάνω είναι ήδη το ΥΠΟΛΟΙΠΟ που θα εισπράξεις — δεν αφαιρείται τίποτα άλλο.',
                        style: TextStyle(fontSize: 11.5, color: Colors.blue.shade900),
                      )),
                    ]),
                  ),
                ],
                const SizedBox(height: 12),

                // Χαρακτηριστικά διαδρομής
                Row(children: [
                  Expanded(child: _infoCell(
                    icon:  Icons.person_rounded,
                    label: 'Άτομα',
                    value: '${job.persons}',
                  )),
                  Expanded(child: _infoCell(
                    icon:  Icons.luggage_rounded,
                    label: 'Βαλίτσες',
                    value: '${job.luggage}',
                  )),
                  Expanded(child: _infoCell(
                    icon:  job.vehicleType == 'van' ? Icons.airport_shuttle_rounded : Icons.local_taxi_rounded,
                    label: 'Όχημα',
                    value: job.vehicleLabel,
                  )),
                  if (job.childSeat)
                    Expanded(child: _infoCell(
                      icon:  Icons.child_care_rounded,
                      label: 'Παιδικά καθίσματα',
                      value: job.childSeatCount > 0
                          ? '${job.childSeatCount}'
                          : 'Ναι',
                      color: Colors.purple,
                    )),
                ]),

                // Ευδιάκριτα σήματα: επιστροφή / στάσεις
                if (job.withReturn || job.withStops) ...[
                  const SizedBox(height: 10),
                  Row(children: [
                    if (job.withReturn)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: _routeTag(
                          icon:  Icons.swap_horiz_rounded,
                          label: 'ΜΕ ΕΠΙΣΤΡΟΦΗ',
                          color: const Color(0xFF1565C0),
                        ),
                      ),
                    if (job.withStops)
                      _routeTag(
                        icon:  Icons.more_horiz_rounded,
                        label: 'ΜΕ ΣΤΑΣΕΙΣ',
                        color: const Color(0xFFAD1457),
                      ),
                  ]),
                ],

                // Κάρτα Στοιχείων Πελάτη — ΜΟΝΟ πτήση/πλοίο φαίνεται
                // Όνομα και τηλέφωνο κρυμμένα μέχρι να ανατεθεί η δουλειά
                if (job.flightOrShip != null && job.flightOrShip!.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color:        Colors.amber.shade50.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(14),
                      border:       Border.all(color: Colors.amber.shade200),
                    ),
                    child: _clientInfoLine(
                        Icons.flight_rounded,
                        'Πτήση / Πλοίο: ${job.flightOrShip!}'),
                  ),
                ],

                // (Η ένδειξη «Προγραμματισμένη / ΑΜΕΣΑ» εμφανίζεται πλέον
                //  ως μπάρα κάτω από το header.)

                // Σημειώσεις
                if (job.note != null && job.note!.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Container(
                    width:   double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color:        Colors.grey.shade50,
                      borderRadius: BorderRadius.circular(10),
                      border:       Border.all(color: Colors.grey.shade200),
                    ),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(Icons.notes_rounded, size: 16, color: Colors.grey[600]),
                      const SizedBox(width: 8),
                      Expanded(child: Text(job.note!, style: TextStyle(fontSize: 13, color: Colors.grey[700]))),
                    ]),
                  ),
                ],

                if (job.commissionLabel.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(job.commissionLabel, style: TextStyle(fontSize: 11, color: Colors.grey[500])),
                ],
              ],
            ),
          ),
        ),

        // 3. ΣΤΑΘΕΡΟ FOOTER BUTTONS
        Container(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: Colors.grey.shade100, width: 1)),
          ),
          child: Row(children: [
            Expanded(
              flex: 2,
              child: OutlinedButton.icon(
                onPressed: _isTaking ? null : _decline,
                style: OutlinedButton.styleFrom(
                  padding:       const EdgeInsets.symmetric(vertical: 14),
                  side:          BorderSide(color: Colors.grey.shade300),
                  shape:         RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  foregroundColor: Colors.grey[700],
                ),
                icon:  const Icon(Icons.close_rounded),
                label: const Text('Όχι', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 3,
              child: FilledButton.icon(
                onPressed: _isTaking ? null : _accept,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF1E8E3E),
                  foregroundColor: Colors.white,
                  padding:         const EdgeInsets.symmetric(vertical: 14),
                  shape:           RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                icon: _isTaking
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.check_rounded, size: 22),
                label: Text(
                  _isTaking ? 'Αποδοχή...' : 'Αποδέχομαι',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ]),
        ),
      ],
    );
  }

  // ─── Shared widgets ───────────────────────────────────────────────────────

  // Χάρτης με τα 2 σημεία + αποστάσεις
  Widget _mapSection(Job job) {
    if (!job.hasRouteCoords) return const SizedBox.shrink();

    final from = LatLng(job.fromLat!, job.fromLng!);
    final to   = LatLng(job.toLat!,   job.toLng!);

    // Απόσταση διαδρομής: αποθηκευμένη (routeKm) ή ευθεία
    final routeKm = job.routeKm ??
        haversineKm(job.fromLat!, job.fromLng!, job.toLat!, job.toLng!);

    // Χρόνος διαδρομής: αποθηκευμένος ή υπολογισμένος επιτόπου (fallback)
    final routeMin = job.routeMinutes ?? _routeMinutesFallback;

    // Polyline: αποθηκευμένη διαδρομή ή ευθεία γραμμή
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
        icon: BitmapDescriptor.defaultMarkerWithHue(
            BitmapDescriptor.hueGreen),
        infoWindow: const InfoWindow(title: 'Από'),
      ),
      Marker(
        markerId: const MarkerId('to'),
        position: to,
        icon: BitmapDescriptor.defaultMarkerWithHue(
            BitmapDescriptor.hueRed),
        infoWindow: const InfoWindow(title: 'Προς'),
      ),
    };

    final polylines = <Polyline>{
      Polyline(
        polylineId: const PolylineId('route'),
        points:     linePts,
        color:      const Color(0xFF1565C0),
        width:      4,
      ),
    };

    final bounds = _boundsOf([from, to]);
    final latSpan = (bounds.northeast.latitude - bounds.southwest.latitude).abs();
    final lngSpan = (bounds.northeast.longitude - bounds.southwest.longitude).abs();
    // Κέντρο: γεωμετρικό μέσο, ελαφρώς μετατοπισμένο προς τα ΠΑΝΩ ώστε οι
    // κορυφές των πινέζων (που "δείχνουν" πάνω) να μην κόβονται.
    final center = LatLng(
      (bounds.southwest.latitude + bounds.northeast.latitude) / 2
          + latSpan * 0.12,
      (bounds.southwest.longitude + bounds.northeast.longitude) / 2,
    );
    final zoom    = _zoomForSpan(latSpan, lngSpan);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            height: 240,
            width:  double.infinity,
            child: Stack(
              children: [
                GoogleMap(
                  liteModeEnabled:         true,
                  initialCameraPosition:
                      CameraPosition(target: center, zoom: zoom),
                  markers:                 markers,
                  polylines:               polylines,
                  zoomControlsEnabled:     false,
                  mapToolbarEnabled:       false,
                  myLocationButtonEnabled: false,
                ),
                // Label χρόνου διαδρομής (στιλ Google Maps), πάνω δεξιά.
                if (routeMin != null)
                  Positioned(
                    top:   10,
                    right: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color:        Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.18),
                            blurRadius: 4,
                            offset: const Offset(0, 1),
                          ),
                        ],
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.schedule_rounded,
                            size: 15, color: Color(0xFF6A1B9A)),
                        const SizedBox(width: 5),
                        Text(
                          formatRouteMinutes(routeMin),
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF6A1B9A)),
                        ),
                      ]),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: _distanceChip(
              icon:  Icons.straighten_rounded,
              label: 'Διαδρομή',
              value: '${routeKm.toStringAsFixed(1)} χλμ',
              color: const Color(0xFF1565C0),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _distanceChip(
              icon:  Icons.schedule_rounded,
              label: job.scheduledAt != null ? 'Χρόνος (ραντεβού)' : 'Χρόνος',
              value: routeMin != null
                  ? formatRouteMinutes(routeMin)
                  : '—',
              color: const Color(0xFF6A1B9A),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _distanceChip(
              icon:  Icons.directions_car_rounded,
              label: _driverDistanceIsAir
                  ? 'Απόσταση πελάτη (ευθεία)'
                  : 'Απόσταση πελάτη',
              value: _distanceLoading
                  ? '…'
                  : (_driverDistanceKm != null
                      ? '${_driverDistanceKm!.toStringAsFixed(1)} χλμ'
                      : '—'),
              color: const Color(0xFF1E8E3E),
            ),
          ),
        ]),
      ],
    );
  }

  // Υπολογίζει επίπεδο zoom ώστε να φαίνονται ΚΑΙ ΟΙ 2 πινέζες με περιθώριο.
  double _zoomForSpan(double latSpan, double lngSpan) {
    // Στο γεωγραφικό πλάτος της Ελλάδας το μήκος "συμπιέζεται" ~0.78.
    var span = math.max(latSpan, lngSpan * 0.78);
    // Λίγο buffer ώστε οι πινέζες να μην κόβονται, αλλά ΟΧΙ υπερβολικό —
    // αλλιώς ο χάρτης βγαίνει υπερβολικά zoomed-out και δεν φαίνεται η διαδρομή.
    span = span * 1.12 + 0.003;
    if (span <= 0.0008) return 14.5;
    final z = math.log(360.0 / span) / math.ln2;
    // -0.15 ώστε να μένει ελάχιστο περιθώριο γύρω-γύρω.
    return (z - 0.15).clamp(4.0, 16.5);
  }

  // Όρια που περιέχουν όλα τα σημεία
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

  Widget _distanceChip({
    required IconData icon,
    required String   label,
    required String   value,
    required Color    color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 10),
      decoration: BoxDecoration(
        color:        color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border:       Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 10, color: Colors.grey[600])),
              Text(value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: color)),
            ],
          ),
        ),
      ]),
    );
  }

  // ΤΟ ΑΠΟΛΥΤΩΣ SAFE TIMELINE (ΧΩΡΙΣ EXPANDED ΣΕ INTRINSIC HEIGHT)
  Widget _routeRow(String from, String to) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Αντί για Column με Expanded, βάζουμε Stack! Δεν краσάρει ποτέ!
              SizedBox(
                width: 18,
                child: Stack(
                  alignment: Alignment.topCenter,
                  children: [
                    // Γραμμή που γεμίζει από την κορυφή (κάτω από το πρώτο icon) μέχρι το τέλος
                    Positioned(
                      top: 18,
                      bottom: 0,
                      child: Container(width: 2, color: Colors.grey.shade300),
                    ),
                    const Icon(Icons.trip_origin_rounded, color: Colors.amber, size: 18),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 16), // Κενό μέχρι τον προορισμό
                  child: Text(
                    from,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(
              width: 18,
              child: Icon(Icons.place_rounded, color: Colors.red, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                to,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // Ευδιάκριτο σήμα διαδρομής (επιστροφή / στάσεις)
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
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.4),
              blurRadius: 6, offset: const Offset(0, 2)),
        ],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 16, color: Colors.white),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(
            fontSize: 12, fontWeight: FontWeight.bold,
            color: Colors.white, letterSpacing: 0.5)),
      ]),
    );
  }

  Widget _infoCell({
    required IconData icon,
    required String   label,
    required String   value,
    Color?            color,
    bool              large = false,
  }) {
    final c = color ?? Colors.grey[700]!;
    return Container(
      margin:  const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      decoration: BoxDecoration(
        color:        c.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(children: [
        Icon(icon, size: 18, color: c),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value, 
            style: TextStyle(fontSize: large ? 14 : 12, fontWeight: FontWeight.bold, color: c),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 2),
        Text(label, style: TextStyle(fontSize: 10, color: Colors.grey[500])),
      ]),
    );
  }

  Widget _clientInfoLine(IconData icon, String text, {bool isLink = false}) {
    return Row(
      children: [
        Icon(icon, size: 16, color: isLink ? Colors.blue.shade700 : Colors.amber.shade900),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 13,
              fontWeight: isLink ? FontWeight.bold : FontWeight.w500,
              color: isLink ? Colors.blue.shade800 : Colors.black87,
              decoration: isLink ? TextDecoration.underline : TextDecoration.none,
            ),
          ),
        ),
      ],
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
  // Εμφάνιση με scale + fade (280ms) — πιο «ζωντανό» χτύπημα δουλειάς.
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