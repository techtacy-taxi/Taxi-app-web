// lib/auth_gateway.dart

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'map/map_page.dart';

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
    if (_loading) {
      return Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: Image.asset('assets/app_icon.png',
                    width: 120, height: 120),
              ),
              const SizedBox(height: 28),
              const SizedBox(
                width: 32, height: 32,
                child: CircularProgressIndicator(
                    color: Colors.amber, strokeWidth: 3),
              ),
            ],
          ),
        ),
      );
    }

    if (_signedIn) return const HomeMapPage();

    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Image.asset('assets/app_icon.png', width: 100, height: 100),
              ),
              const SizedBox(height: 24),
              const Text(
                'Athens Taxi',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                'Σύνδεση για οδηγούς',
                style: TextStyle(fontSize: 16, color: Colors.grey[600]),
              ),
              const SizedBox(height: 48),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _signInWithGoogle,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    side: BorderSide(color: Colors.grey[300]!),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: const Icon(Icons.login_rounded, color: Colors.red, size: 24),
                  label: const Text(
                    'Σύνδεση με Google',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.black87,
                    ),
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!, style: const TextStyle(color: Colors.red)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}