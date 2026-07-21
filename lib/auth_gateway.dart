// lib/auth_gateway.dart
//
// REDESIGN (εγκεκριμένο mockup «Καλωσόρισμα + Σύνδεση»):
//  • Logo με στρογγυλεμένες γωνίες + κίτρινο πλαίσιο γύρω-γύρω (AppLogoBadge)
//  • Τίτλος + υπότιτλος «Δουλειές, ραντεβού και πληρωμές — όλα σε μία εφαρμογή»
//  • Pill κουμπί «Σύνδεση με Google»
//  • Dark mode (AppColors)
//
// Η ΛΟΓΙΚΗ ΣΥΝΔΕΣΗΣ παραμένει ΙΔΙΑ: αναμονή αποκατάστασης session στο cold
// start, καμία αυτόματη Google lightweight κλήση, serverClientId initialize.

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'app_theme.dart';
import 'map/map_page.dart';
import 'onboarding_screens.dart';

class AuthGateway extends StatefulWidget {
  const AuthGateway({super.key});

  @override
  State<AuthGateway> createState() => _AuthGatewayState();
}

class _AuthGatewayState extends State<AuthGateway> {
  bool    _loading  = true;
  bool    _signedIn = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _checkOrSignIn();
  }

  Future<void> _checkOrSignIn() async {
    // Το currentUser μπορεί να είναι προσωρινά null στο cold start ενώ το
    // Firebase αποκαθιστά το session από τον δίσκο. Περίμενε να αποκατασταθεί.
    User? current = FirebaseAuth.instance.currentUser;
    if (current == null) {
      try {
        current = await FirebaseAuth.instance
            .authStateChanges()
            .firstWhere((u) => u != null)
            .timeout(const Duration(seconds: 8));
      } catch (_) {
        current = FirebaseAuth.instance.currentUser;
      }
    }

    // Ήδη συνδεδεμένος με Firebase → κατευθείαν στον χάρτη.
    // ΔΕΝ καλούμε Google lightweight εδώ — προκαλούσε περιττό popup επιλογής
    // λογαριασμού στο startup. Το ημερολόγιο παίρνει τον λογαριασμό μόνο του.
    if (current != null && !current.isAnonymous) {
      if (mounted) setState(() { _signedIn = true; _loading = false; });
      return;
    }

    // Μη συνδεδεμένος → δείξε την οθόνη σύνδεσης (χωρίς αυτόματο popup).
    if (mounted) setState(() { _signedIn = false; _loading = false; });
  }

  Future<void> _signInWithGoogle() async {
    if (mounted) setState(() { _loading = true; _error = null; });
    try {
      // Αρχικοποίηση με serverClientId (μία φορά) πριν το authenticate.
      try {
        await GoogleSignIn.instance.initialize(
          serverClientId:
              '566987559821-tlphsu640nfhfdhtevutr7kj58tpu2vq.apps.googleusercontent.com',
        );
      } catch (_) {}
      final account = await GoogleSignIn.instance.authenticate();
      await _firebaseSignIn(account);
    } catch (e) {
      if (mounted) setState(() { _error = 'Σφάλμα σύνδεσης: $e'; _loading = false; });
    }
  }

  Future<void> _firebaseSignIn(GoogleSignInAccount googleUser) async {
    try {
      final auth = googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        idToken: auth.idToken,
      );
      await FirebaseAuth.instance.signInWithCredential(credential);
      if (mounted) setState(() { _signedIn = true; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = 'Firebase error: $e'; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    if (_loading) {
      return Scaffold(
        backgroundColor: c.scaffold,
        body: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppLogoBadge(size: 116),
              SizedBox(height: 28),
              SizedBox(
                width: 32, height: 32,
                child: CircularProgressIndicator(
                    color: Color(0xFFEF9F27), strokeWidth: 3),
              ),
            ],
          ),
        ),
      );
    }

    if (_signedIn) return const HomeMapPage();

    return Scaffold(
      backgroundColor: c.scaffold,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const AppLogoBadge(size: 104),
                  const SizedBox(height: 20),
                  Text(
                    'Taxi Athens Driver',
                    style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w600,
                        color: c.textMain),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Δουλειές, ραντεβού και πληρωμές —\nόλα σε μία εφαρμογή.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13.5, color: c.textFaint),
                  ),
                  const SizedBox(height: 34),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _signInWithGoogle,
                      style: OutlinedButton.styleFrom(
                        backgroundColor: c.card,
                        foregroundColor: c.textMain,
                        side: BorderSide(color: c.cardBorder, width: 0.8),
                      ),
                      icon: const Icon(Icons.login_rounded,
                          color: Colors.red, size: 22),
                      label: const Text('Σύνδεση με Google'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Με τη σύνδεση αποδέχεσαι τους όρους χρήσης',
                    style: TextStyle(
                        fontSize: 11,
                        color: c.textFaint.withValues(alpha: 0.7)),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(_error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.red)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
