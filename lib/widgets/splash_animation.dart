// lib/widgets/splash_animation.dart
//
// Οθόνη φόρτωσης (splash) — αντικαθιστά το κυκλάκι που γύριζε.
//
// Σενάριο (≈2,8s):
//   0,00s  έρχεται το βαν (από βάθος, προς τα εκεί που «κοιτάει»)
//   0,50s  έρχεται το πούλμαν
//   1,00s  έρχεται το ταξί στη μέση (μπροστά από τα άλλα δύο)
//          κάθε όχημα «κάθεται» λίγο όταν φρενάρει
//   1,75s  σκάει το σήμα από πάνω + όνομα εφαρμογής
//   2,25s  το ταξί αναβοσβήνει δύο φορές τα φώτα
//
// Αν η εφαρμογή ΔΕΝ είναι ακόμα έτοιμη όταν τελειώσει το σενάριο, το σήμα
// «αναπνέει» και το ταξί ξανα-αναβοσβήνει τα φώτα κάθε ~2,4s μέχρι να γίνει
// έτοιμη. Μόλις γίνει → fade out (0,35s) → onFinished().
//
// Το «έτοιμη» το δίνει το SplashController.ready (ValueNotifier):
//   • HomeMapPage το κάνει true όταν ολοκληρωθεί το _initPage
//   • AuthGateway το κάνει true αν ο χρήστης δεν είναι συνδεδεμένος
//   • WebAuthGateway το κάνει true όταν τελειώσει το bootstrap
// Ασφάλεια: μετά από kSplashMaxWait κλείνει ούτως ή άλλως.
//
// Καθαρό Flutter (χωρίς πακέτα) → δουλεύει ίδια σε Android ΚΑΙ web.
// Assets: assets/splash/van.png, assets/splash/taxi.png, assets/splash/bus.png

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Κίτρινο φόντο splash (ίδιο με το κίτρινο της εικόνας των οχημάτων).
const Color kSplashYellow = Color(0xFFFED302);

/// Μέγιστη αναμονή πριν κλείσει το splash ακόμη κι αν δεν ήρθε «έτοιμο».
const Duration kSplashMaxWait = Duration(seconds: 12);

class SplashController {
  SplashController._();

  /// true = η οθόνη από κάτω είναι έτοιμη να φανεί.
  static final ValueNotifier<bool> ready = ValueNotifier<bool>(false);
}

class SplashAnimation extends StatefulWidget {
  final ValueListenable<bool> ready;
  final VoidCallback onFinished;

  const SplashAnimation({
    super.key,
    required this.ready,
    required this.onFinished,
  });

  @override
  State<SplashAnimation> createState() => _SplashAnimationState();
}

class _SplashAnimationState extends State<SplashAnimation>
    with TickerProviderStateMixin {
  // ── χρονισμός (δευτερόλεπτα) ──────────────────────────────────────────────
  static const double _tVan   = 0.00;
  static const double _tBus   = 0.50;
  static const double _tTaxi  = 1.00;
  static const double _drive  = 0.80; // διάρκεια «οδήγησης» κάθε οχήματος
  static const double _brake  = 0.40; // διάρκεια «καθίσματος» στο φρενάρισμα
  static const double _tBadge = 1.75;
  static const double _tFlash = 2.25;
  static const double _total  = 2.85;

  static const _driveCurve = Cubic(0.15, 0.7, 0.25, 1.0);

  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: (_total * 1000).round()),
  );
  late final AnimationController _idle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 350),
  );

  bool _introDone = false;
  bool _closing   = false;
  bool _precached = false;
  DateTime? _startedAt;

  @override
  void initState() {
    super.initState();
    _startedAt = DateTime.now();
    widget.ready.addListener(_maybeClose);
    _intro.addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        _introDone = true;
        if (!widget.ready.value) _idle.repeat();
        _maybeClose();
      }
    });
    // Δίχτυ ασφαλείας: ποτέ κολλημένο splash.
    Future.delayed(kSplashMaxWait, () {
      if (mounted && !_closing) _close();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_precached) return;
    _precached = true;
    // Φόρτωσε τις εικόνες ΠΡΙΝ ξεκινήσει η κίνηση (όχι «σκάσιμο» στη μέση).
    final imgs = [
      'assets/splash/van.png',
      'assets/splash/bus.png',
      'assets/splash/taxi.png',
      'assets/app_icon.png',
    ];
    Future.wait(imgs.map((p) => precacheImage(AssetImage(p), context)
        .catchError((_) {}))).whenComplete(() {
      if (!mounted) return;
      final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
      if (reduce) {
        _intro.value = 1.0; // χωρίς κίνηση → κατευθείαν τελικό καρέ
      } else {
        _intro.forward();
      }
    });
  }

  void _maybeClose() {
    if (_introDone && widget.ready.value && !_closing) _close();
  }

  Future<void> _close() async {
    _closing = true;
    // Αν ο χρόνος έληξε πριν τελειώσει η εισαγωγή, πήγαινε στο τελικό καρέ.
    if (!_introDone) _intro.value = 1.0;
    await _fade.forward();
    if (mounted) widget.onFinished();
  }

  @override
  void dispose() {
    widget.ready.removeListener(_maybeClose);
    _intro.dispose();
    _idle.dispose();
    _fade.dispose();
    super.dispose();
  }

  // ── βοηθητικά ─────────────────────────────────────────────────────────────
  static double _seg(double t, double start, double dur) =>
      ((t - start) / dur).clamp(0.0, 1.0);

  /// Κάθισμα φρεναρίσματος: (scaleX, scaleY) με keyframes.
  static Offset _brakeScale(double u) {
    if (u <= 0 || u >= 1) return const Offset(1, 1);
    const k = [
      [0.00, 1.000, 1.000],
      [0.30, 1.015, 0.975],
      [0.65, 0.995, 1.010],
      [1.00, 1.000, 1.000],
    ];
    for (var i = 0; i < k.length - 1; i++) {
      if (u <= k[i + 1][0]) {
        final f = (u - k[i][0]) / (k[i + 1][0] - k[i][0]);
        return Offset(
          k[i][1] + (k[i + 1][1] - k[i][1]) * f,
          k[i][2] + (k[i + 1][2] - k[i][2]) * f,
        );
      }
    }
    return const Offset(1, 1);
  }

  /// Δύο αναλαμπές φώτων μέσα σε 0,6s. Επιστρέφει ένταση 0..1.
  static double _doubleFlash(double sec) {
    if (sec < 0 || sec > 0.6) return 0;
    final u = (sec % 0.3) / 0.3;
    return math.sin(u * math.pi);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_intro, _idle, _fade]),
      builder: (context, _) {
        final t = _intro.value * _total;
        final idleSec = _idle.isAnimating ? _idle.value * 2.4 : -1.0;

        // Σήμα
        final bu = _seg(t, _tBadge, 0.6);
        final bScale = Curves.easeOutBack.transform(bu);
        final breathe = _idle.isAnimating
            ? 1 + 0.045 * math.sin(_idle.value * 2 * math.pi)
            : 1.0;
        final titleOp = _seg(t, _tBadge + 0.35, 0.4);
        final subOp   = _seg(t, _tBadge + 0.50, 0.4);

        // Φώτα ταξί
        final flash = math.max(
          _doubleFlash(t - _tFlash),
          _doubleFlash(idleSec),
        );

        return Opacity(
          opacity: 1 - _fade.value,
          child: Material(
            color: kSplashYellow,
            child: Container(
              decoration: const BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment(0, -0.15),
                  radius: 1.1,
                  colors: [Color(0xFFFFE04A), kSplashYellow, Color(0xFFF2C200)],
                  stops: [0.0, 0.55, 1.0],
                ),
              ),
              child: SafeArea(
                child: Center(
                  child: SingleChildScrollView(
                    physics: const NeverScrollableScrollPhysics(),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // ── σήμα ──
                        Opacity(
                          opacity: (bu / 0.5).clamp(0.0, 1.0),
                          child: Transform.translate(
                            offset: Offset(0, 40 * (1 - bScale.clamp(0.0, 1.0))),
                            child: Transform.scale(
                              scale: bScale * breathe,
                              child: const _SplashBadge(size: 96),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Opacity(
                          opacity: titleOp,
                          child: Transform.translate(
                            offset: Offset(0, 6 * (1 - titleOp)),
                            child: const Text(
                              'Taxi Athens Driver',
                              style: TextStyle(
                                fontSize: 19,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF16130A),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Opacity(
                          opacity: subOp,
                          child: const Text(
                            'Δουλειές, ραντεβού και πληρωμές',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF4A3F10),
                            ),
                          ),
                        ),
                        const SizedBox(height: 30),
                        // ── οχήματα ──
                        _buildLot(t, flash),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // Διάταξη όπως η αρχική εικόνα: αναλογία 1146 x 265.
  Widget _buildLot(double t, double flash) {
    return LayoutBuilder(builder: (context, c) {
      final w = math.min(c.maxWidth - 16, 520.0);
      final h = w * 265 / 1146;

      Widget vehicle({
        required String asset,
        required double left,   // % του πλάτους
        required double top,    // % του ύψους
        required double width,  // % του πλάτους
        required double aspect, // πλάτος / ύψος εικόνας
        required double start,
        required Offset from,   // μετατόπιση εκκίνησης σε κλάσματα του μεγέθους
        required Alignment origin,
        Widget? overlay,
      }) {
        final vw = w * width;
        final vh = vw / aspect;
        final u  = _seg(t, start, _drive);
        final e  = _driveCurve.transform(u);
        final op = (u / 0.35).clamp(0.0, 1.0);
        final sc = 0.40 + 0.60 * e;
        final bs = _brakeScale(_seg(t, start + _drive, _brake));

        Widget img = Image.asset(asset,
            width: vw, height: vh, fit: BoxFit.contain, gaplessPlayback: true);
        if (overlay != null) {
          img = Stack(clipBehavior: Clip.none, children: [img, overlay]);
        }

        return Positioned(
          left: w * left,
          top:  h * top,
          width: vw,
          height: vh,
          child: Opacity(
            opacity: op,
            child: Transform.translate(
              offset: Offset(from.dx * vw * (1 - e), from.dy * vh * (1 - e)),
              child: Transform(
                alignment: origin,
                transform: Matrix4.diagonal3Values(sc * bs.dx, sc * bs.dy, 1),
                child: img,
              ),
            ),
          ),
        );
      }

      // Φώτα ταξί: κέντρα προβολέων στο taxi.png (288x228) ≈ (11%,57%) & (86,5%,57%)
      final taxiW = w * 0.2513;
      final taxiH = taxiW / (288 / 228);
      Widget glow(double fx, double fy) {
        final s = taxiW * 0.75;
        return Positioned(
          left: taxiW * fx - s / 2,
          top:  taxiH * fy - s / 2,
          width: s,
          height: s,
          child: IgnorePointer(
            child: Opacity(
              opacity: flash.clamp(0.0, 1.0),
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(colors: [
                    Color(0xFFFFFFFF),
                    Color(0xD9FFF3C0),
                    Color(0x59FFE680),
                    Color(0x00FFE680),
                  ], stops: [0.0, 0.31, 0.64, 1.0]),
                ),
              ),
            ),
          ),
        );
      }

      return SizedBox(
        width: w,
        height: h,
        child: Stack(clipBehavior: Clip.none, children: [
          vehicle(
            asset: 'assets/splash/van.png',
            left: 0.0, top: 0.136, width: 0.3735, aspect: 428 / 229,
            start: _tVan, from: const Offset(0.7, -0.4),
            origin: const Alignment(-0.4, 1),
          ),
          vehicle(
            asset: 'assets/splash/bus.png',
            left: 0.6318, top: 0.0, width: 0.3682, aspect: 422 / 253,
            start: _tBus, from: const Offset(-0.7, -0.4),
            origin: const Alignment(0.5, 1),
          ),
          vehicle(
            asset: 'assets/splash/taxi.png',
            left: 0.3805, top: 0.1396, width: 0.2513, aspect: 288 / 228,
            start: _tTaxi, from: const Offset(0, -0.55),
            origin: const Alignment(0, 1),
            overlay: flash > 0
                ? Stack(clipBehavior: Clip.none, children: [
                    glow(0.111, 0.57),
                    glow(0.865, 0.57),
                  ])
                : null,
          ),
        ]),
      );
    });
  }
}

/// Λογότυπο με μαύρο πλαίσιο (πάνω σε κίτρινο φόντο).
class _SplashBadge extends StatelessWidget {
  final double size;
  const _SplashBadge({required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.055),
      decoration: BoxDecoration(
        color: const Color(0xFF111111),
        borderRadius: BorderRadius.circular(size * 0.28),
        boxShadow: const [
          BoxShadow(
            color: Color(0x593C2D00),
            blurRadius: 26,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.23),
        child: Image.asset('assets/app_icon.png', fit: BoxFit.cover),
      ),
    );
  }
}
