// lib/onboarding_screens.dart
//
// Οθόνες onboarding (εγκεκριμένα mockups):
//  • WelcomeProfileScreen — «Καλώς ήρθες» με το logo (στρογγυλεμένο, με
//    κίτρινο πλαίσιο γύρω-γύρω) → κουμπί «Συμπλήρωση Στοιχείων»
//  • WaitingApprovalScreen — βήμα 4/4, πράσινη γεμάτη μπάρα, κλεψύδρα,
//    «Περιμένεις έγκριση», κάρτα «Κάλεσε τον διαχειριστή», Επεξεργασία,
//    κατάσταση «Σε εκκρεμότητα · ανανεώνεται αυτόματα»
//
// Χρησιμοποιούνται από το map_page.dart στη θέση των παλιών inline Scaffold.
// Πλήρες Dark mode (AppColors). Δουλεύουν ίδια σε Android & Web.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_theme.dart';

/// Το logo της εφαρμογής με στρογγυλεμένες γωνίες και κίτρινο πλαίσιο
/// γύρω-γύρω (padding) ώστε να μην κόβεται τίποτα από το σχέδιο.
class AppLogoBadge extends StatelessWidget {
  final double size;
  const AppLogoBadge({super.key, this.size = 96});

  @override
  Widget build(BuildContext context) {
    return Container(
      width:  size,
      height: size,
      padding: EdgeInsets.all(size * 0.11),
      decoration: BoxDecoration(
        color:        const Color(0xFFF7C93B), // κίτρινο του logo
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.17),
        child: Image.asset('assets/app_icon.png', fit: BoxFit.cover),
      ),
    );
  }
}

/// Μπάρα προόδου onboarding (π.χ. «Σχεδόν έτοιμος! 4/4»)
class OnboardingProgress extends StatelessWidget {
  final String title;
  final int    step;
  final int    total;
  final Color? barColor;

  const OnboardingProgress({
    super.key,
    required this.title,
    required this.step,
    required this.total,
    this.barColor,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Column(children: [
      Row(children: [
        Expanded(
          child: Text(title,
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: c.textMain)),
        ),
        Text('$step / $total',
            style: TextStyle(fontSize: 12, color: c.textFaint)),
      ]),
      const SizedBox(height: 8),
      ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: LinearProgressIndicator(
          value: step / total,
          minHeight: 5,
          backgroundColor: c.divider,
          color: barColor ?? c.amber,
        ),
      ),
    ]);
  }
}

// ─────────────────────────────────────────────────────────────────
// Οθόνη «Καλώς ήρθες — Συμπλήρωση Στοιχείων»
// ─────────────────────────────────────────────────────────────────
class WelcomeProfileScreen extends StatelessWidget {
  final VoidCallback onFillProfile;

  const WelcomeProfileScreen({super.key, required this.onFillProfile});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Scaffold(
      backgroundColor: c.scaffold,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const AppLogoBadge(size: 100),
                  const SizedBox(height: 20),
                  Text('Καλώς ήρθες!',
                      style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                          color: c.textMain)),
                  const SizedBox(height: 6),
                  Text(
                    'Ένα βήμα έμεινε — συμπλήρωσε τα στοιχεία σου\nγια να σε εγκρίνει ο διαχειριστής.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13.5, color: c.textFaint),
                  ),
                  const SizedBox(height: 26),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: onFillProfile,
                      icon: const Icon(Icons.person_outline_rounded),
                      label: const Text('Συμπλήρωση Στοιχείων'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// Οθόνη «Περιμένεις έγκριση» (βήμα 4/4)
// ─────────────────────────────────────────────────────────────────
class WaitingApprovalScreen extends StatelessWidget {
  final VoidCallback onEditProfile;
  /// Τηλέφωνο διαχειριστή (προαιρετικό) — αν λείπει, η κάρτα κλήσης κρύβεται.
  final String? adminPhone;

  const WaitingApprovalScreen({
    super.key,
    required this.onEditProfile,
    this.adminPhone,
  });

  Future<void> _callAdmin() async {
    final phone = adminPhone;
    if (phone == null || phone.isEmpty) return;
    final uri = Uri(scheme: 'tel', path: phone);
    try {
      await launchUrl(uri);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Scaffold(
      backgroundColor: c.scaffold,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(children: [
                const OnboardingProgress(
                  title: 'Σχεδόν έτοιμος!',
                  step: 4, total: 4,
                  barColor: Color(0xFF97C459),
                ),
                const SizedBox(height: 28),

                // Κλεψύδρα με διακεκομμένο κύκλο που περιστρέφεται αργά
                const _HourglassBadge(),
                const SizedBox(height: 16),

                Text('Περιμένεις έγκριση',
                    style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: c.textMain)),
                const SizedBox(height: 6),
                Text(
                  'Τα στοιχεία σου στάλθηκαν στον διαχειριστή.\n'
                  'Μόλις εγκριθείς, θα λάβεις ειδοποίηση και\n'
                  'θα ξεκινήσεις να λαμβάνεις δουλειές.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: c.textFaint),
                ),
                const SizedBox(height: 20),

                if (adminPhone != null && adminPhone!.isNotEmpty) ...[
                  InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: _callAdmin,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 13, vertical: 11),
                      decoration: BoxDecoration(
                        color: c.card,
                        borderRadius: BorderRadius.circular(16),
                        border:
                            Border.all(color: c.cardBorder, width: 0.8),
                      ),
                      child: Row(children: [
                        Container(
                          width: 36, height: 36,
                          decoration: BoxDecoration(
                            color: c.greenPale,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(Icons.phone_rounded,
                              size: 18, color: c.greenDeep),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                Text('Κάλεσε τον διαχειριστή',
                                    style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: c.textMain)),
                                Text('Αν βιάζεσαι, ένα τηλέφωνο βοηθάει',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: c.textFaint)),
                              ]),
                        ),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 14),
                ],

                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: onEditProfile,
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Επεξεργασία Στοιχείων'),
                  ),
                ),
                const SizedBox(height: 16),

                Text.rich(
                  TextSpan(
                    text: 'Κατάσταση: ',
                    style: TextStyle(fontSize: 12, color: c.textFaint),
                    children: const [
                      TextSpan(
                        text: 'Σε εκκρεμότητα',
                        style: TextStyle(
                            color: Color(0xFFA66A00),
                            fontWeight: FontWeight.w600),
                      ),
                      TextSpan(text: ' · ανανεώνεται αυτόματα'),
                    ],
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Κλεψύδρα σε κίτρινο κύκλο με αργά περιστρεφόμενο διακεκομμένο δαχτυλίδι.
class _HourglassBadge extends StatefulWidget {
  const _HourglassBadge();

  @override
  State<_HourglassBadge> createState() => _HourglassBadgeState();
}

class _HourglassBadgeState extends State<_HourglassBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 14),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return SizedBox(
      width: 84, height: 84,
      child: Stack(alignment: Alignment.center, children: [
        RotationTransition(
          turns: _ctrl,
          child: CustomPaint(
            size: const Size(84, 84),
            painter: _DashedRingPainter(color: c.amber),
          ),
        ),
        Container(
          width: 66, height: 66,
          decoration: BoxDecoration(
            color: c.amberSoft,
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.hourglass_top_rounded,
              size: 30, color: c.amberDeep),
        ),
      ]),
    );
  }
}

class _DashedRingPainter extends CustomPainter {
  final Color color;
  _DashedRingPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 1;
    const dashCount = 14;
    const sweep = 3.14159 * 2 / dashCount * 0.55;
    for (var i = 0; i < dashCount; i++) {
      final start = 3.14159 * 2 / dashCount * i;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        start, sweep, false, paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRingPainter old) =>
      old.color != color;
}
