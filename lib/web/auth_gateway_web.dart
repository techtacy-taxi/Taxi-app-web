// ============================================================================
// FILE: ./lib/web/auth_gateway_web.dart
// ============================================================================
//
// Σύνδεση & έλεγχος ρόλου ΓΙΑ WEB.
//
// Ροή:
//   1) signInWithPopup(Google)  → Firebase Auth
//   2) Διάβασμα presence/{uid}  → master / admin / isApproved
//   3) ΜΟΝΟ master ή admin περνούν στο panel. Οδηγοί απορρίπτονται.
//
// Ο έλεγχος ρόλου ακολουθεί ΑΚΡΙΒΩΣ τη λογική του Android (map_page):
//   data['master'], data['admin'], data['isApproved'].
//
// ⚠️  Η πραγματική ασφάλεια είναι στα Firestore Rules (server-side). Αυτό
//     το gate είναι μόνο για UX — δεν δείχνει το panel σε μη εξουσιοδοτημένους.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'admin_shell.dart';

/// Ρόλος + στοιχεία χρήστη που περνούν στο shell.
class AdminSession {
  final String uid;
  final String displayName;
  final String lastName;
  final bool   isMaster;
  final bool   isAdmin;
  final bool   calendarEnabled;
  final List<String> managedGroupIds;

  const AdminSession({
    required this.uid,
    required this.displayName,
    required this.lastName,
    required this.isMaster,
    required this.isAdmin,
    required this.calendarEnabled,
    required this.managedGroupIds,
  });

  String get fullName =>
      [displayName, lastName].where((s) => s.trim().isNotEmpty).join(' ').trim();
}

enum _Stage { loading, signedOut, denied, ready }

class WebAuthGateway extends StatefulWidget {
  const WebAuthGateway({super.key});

  @override
  State<WebAuthGateway> createState() => _WebAuthGatewayState();
}

class _WebAuthGatewayState extends State<WebAuthGateway> {
  _Stage  _stage = _Stage.loading;
  String? _error;
  String? _deniedEmail;
  AdminSession? _session;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null && !user.isAnonymous) {
      await _resolveRole(user);
    } else {
      setState(() => _stage = _Stage.signedOut);
    }
  }

  Future<void> _signIn() async {
    setState(() { _stage = _Stage.loading; _error = null; });
    try {
      final provider = GoogleAuthProvider()
        ..setCustomParameters({'prompt': 'select_account'});
      final cred = await FirebaseAuth.instance.signInWithPopup(provider);
      final user = cred.user;
      if (user == null) {
        setState(() {
          _stage = _Stage.signedOut;
          _error = 'Η σύνδεση δεν ολοκληρώθηκε. Δοκίμασε ξανά.';
        });
        return;
      }
      await _resolveRole(user);
    } catch (e) {
      setState(() {
        _stage = _Stage.signedOut;
        _error = 'Σφάλμα σύνδεσης. Έλεγξε τη σύνδεσή σου και δοκίμασε ξανά.';
      });
      debugPrint('web sign-in error: $e');
    }
  }

  Future<void> _resolveRole(User user) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('presence').doc(user.uid).get();
      final data = doc.data() ?? const <String, dynamic>{};

      final isMaster = data['master'] == true;
      final isAdmin  = data['admin']  == true;

      if (!isMaster && !isAdmin) {
        // Οδηγός ή μη εξουσιοδοτημένος → έξω.
        await FirebaseAuth.instance.signOut();
        setState(() {
          _stage = _Stage.denied;
          _deniedEmail = user.email;
        });
        return;
      }

      setState(() {
        _session = AdminSession(
          uid:             user.uid,
          displayName:     (data['displayName'] as String?) ?? 'Διαχειριστής',
          lastName:        (data['lastName'] as String?) ?? '',
          isMaster:        isMaster,
          isAdmin:         isAdmin,
          calendarEnabled: data['calendarEnabled'] == true,
          managedGroupIds:
              List<String>.from(data['managedGroupIds'] ?? const []),
        );
        _stage = _Stage.ready;
      });
    } catch (e) {
      // Π.χ. PERMISSION_DENIED — αντιμετωπίζεται ως άρνηση πρόσβασης.
      await FirebaseAuth.instance.signOut();
      setState(() {
        _stage = _Stage.denied;
        _deniedEmail = user.email;
      });
      debugPrint('presence read failed: $e');
    }
  }

  Future<void> _backToSignIn() async {
    await FirebaseAuth.instance.signOut();
    setState(() {
      _stage = _Stage.signedOut;
      _deniedEmail = null;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    switch (_stage) {
      case _Stage.loading:
        return const _CenteredCard(child: _Loading());
      case _Stage.ready:
        return AdminShell(session: _session!);
      case _Stage.denied:
        return _CenteredCard(
          child: _DeniedView(email: _deniedEmail, onRetry: _backToSignIn),
        );
      case _Stage.signedOut:
        return _CenteredCard(
          child: _SignInView(onSignIn: _signIn, error: _error),
        );
    }
  }
}

// ─── Κοινό κεντραρισμένο layout (responsive) ────────────────────────────────

class _CenteredCard extends StatelessWidget {
  final Widget child;
  const _CenteredCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();
  @override
  Widget build(BuildContext context) {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 34, height: 34,
          child: CircularProgressIndicator(
              strokeWidth: 3, color: Color(0xFFFFB300)),
        ),
        SizedBox(height: 18),
        Text('Σύνδεση…', style: TextStyle(color: Colors.black54)),
      ],
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand();
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Image.asset(
            'assets/app_icon.png',
            width: 88, height: 88,
            fit: BoxFit.cover,
          ),
        ),
        const SizedBox(height: 18),
        const Text('Athens Taxi',
            style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text('Πίνακας διαχείρισης',
            style: TextStyle(fontSize: 15, color: Colors.grey[600])),
      ],
    );
  }
}

class _SignInView extends StatelessWidget {
  final VoidCallback onSignIn;
  final String?      error;
  const _SignInView({required this.onSignIn, this.error});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const _Brand(),
        const SizedBox(height: 36),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: onSignIn,
            icon: const Icon(Icons.login_rounded),
            label: const Text('Σύνδεση με Google',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ),
        ),
        const SizedBox(height: 14),
        Text('Πρόσβαση μόνο για master και εργολάβους.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: Colors.grey[500])),
        if (error != null) ...[
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.red.shade50,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.red.shade700, fontSize: 13)),
          ),
        ],
      ],
    );
  }
}

class _DeniedView extends StatelessWidget {
  final String?      email;
  final VoidCallback onRetry;
  const _DeniedView({required this.email, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.lock_outline_rounded, size: 56, color: Colors.grey.shade400),
        const SizedBox(height: 18),
        const Text('Δεν έχετε πρόσβαση',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        Text(
          email == null
              ? 'Ο λογαριασμός δεν έχει δικαιώματα διαχείρισης.'
              : 'Ο λογαριασμός $email δεν έχει δικαιώματα διαχείρισης.\n'
                'Αυτός ο πίνακας είναι μόνο για master και εργολάβους.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey[600], fontSize: 14, height: 1.4),
        ),
        const SizedBox(height: 24),
        OutlinedButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.arrow_back_rounded),
          label: const Text('Σύνδεση με άλλον λογαριασμό'),
        ),
      ],
    );
  }
}
