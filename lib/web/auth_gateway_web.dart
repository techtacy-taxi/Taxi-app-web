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

import '../models.dart';
import '../owner_home_page.dart';
import '../profile_form.dart';
import 'admin_shell.dart';

/// Ρόλος + στοιχεία χρήστη που περνούν στο shell.
class AdminSession {
  final String uid;
  final String displayName;
  final String lastName;
  final bool   isMaster;
  final bool   isAdmin;
  final bool   isTenantOwner;
  final bool   isHomeOwner;
  final String? ownerOfClientId;
  final String? ownerOfClientName;
  final bool   calendarEnabled;
  final List<String> managedGroupIds;

  const AdminSession({
    required this.uid,
    required this.displayName,
    required this.lastName,
    required this.isMaster,
    required this.isAdmin,
    required this.isTenantOwner,
    required this.isHomeOwner,
    required this.ownerOfClientId,
    required this.ownerOfClientName,
    required this.calendarEnabled,
    required this.managedGroupIds,
  });

  String get fullName =>
      [displayName, lastName].where((s) => s.trim().isNotEmpty).join(' ').trim();
}

enum _Stage { loading, signedOut, denied, needsProfile, pendingApproval, ready }

class WebAuthGateway extends StatefulWidget {
  const WebAuthGateway({super.key});

  @override
  State<WebAuthGateway> createState() => _WebAuthGatewayState();
}

class _WebAuthGatewayState extends State<WebAuthGateway> {
  _Stage  _stage = _Stage.loading;
  String? _error;
  String? _deniedEmail;
  bool    _webAccessDenied = false;
  User?   _pendingUser;
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
    setState(() { _stage = _Stage.loading; _error = null; _webAccessDenied = false; });
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

      // ── Εντελώς νέος χρήστης (καμία presence ακόμα) — δείξε τη φόρμα
      // στοιχείων (ίδια με το Android app) αντί να τον διώξουμε αμέσως.
      if (!doc.exists) {
        setState(() { _stage = _Stage.needsProfile; _pendingUser = user; });
        return;
      }

      final data = doc.data() ?? const <String, dynamic>{};

      final isMaster = data['master'] == true;
      final isAdmin  = data['admin']  == true;
      final isTenantOwner = data['tenantOwner'] == true;
      final isHomeOwner   = data['homeOwner'] == true;
      final isApproved    = data['isApproved'] == true;
      final webEnabled    = data['webEnabled'] == true;

      if (!isMaster && !isAdmin && !isHomeOwner) {
        // Ούτε master, ούτε admin, ούτε Home Owner → έξω.
        await FirebaseAuth.instance.signOut();
        setState(() {
          _stage = _Stage.denied;
          _deniedEmail = user.email;
        });
        return;
      }

      if (!isMaster && !isApproved) {
        // Admin ή Home Owner που περιμένει έγκριση από τον master.
        setState(() { _stage = _Stage.pendingApproval; _pendingUser = user; });
        return;
      }

      // ── Πρόσβαση web — ΞΕΧΩΡΙΣΤΗ άδεια από το isApproved. Ο master έχει
      // πάντα πρόσβαση. Ο tenantOwner ΕΠΙΣΗΣ πάντα (χρειάζεται το web panel
      // για να διαχειρίζεται μόνος του Viva/τιμές/στοιχεία επιχείρησης —
      // δεν είναι το χρεώσιμο «Web» add-on, είναι μέρος της ίδιας της
      // Online Φόρμας του). Απλός admin/Home Owner ΜΟΝΟ αν ο master έχει
      // ενεργοποιήσει ρητά το «Web» switch (masters_admin_page) γι' αυτόν.
      if (!isMaster && !isTenantOwner && !webEnabled) {
        await FirebaseAuth.instance.signOut();
        setState(() {
          _stage = _Stage.denied;
          _deniedEmail = user.email;
          _webAccessDenied = true;
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
          isTenantOwner:   isTenantOwner,
          isHomeOwner:     isHomeOwner,
          ownerOfClientId:   data['ownerOfClientId'] as String?,
          ownerOfClientName: data['ownerOfClientName'] as String?,
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

  Future<void> _openProfileFormWeb() async {
    final user = _pendingUser;
    if (user == null) return;
    await showProfileForm(
      context: context,
      uid: user.uid,
      appVersion: 'web',
      displayName: user.displayName ?? '',
      lastName: '',
      phone: user.phoneNumber ?? '',
      vehicleModel: '',
      referredBy: '',
      plateNumber: '',
      vehicleType: VehicleType.taxi,
      onSaved: ({
        required name, required lastName, required phone,
        required vehicleModel, required referredBy, required plateNumber,
        required vehicleType, required homeOwner, required ownerOfClientId,
        required ownerOfClientName,
      }) async {
        await FirebaseFirestore.instance.collection('presence').doc(user.uid).set({
          'displayName': name,
          'lastName': lastName,
          'phone': phone,
          'vehicleModel': vehicleModel,
          'referredBy': referredBy,
          'plateNumber': plateNumber,
          'vehicleType': vehicleType.name,
          'homeOwner': homeOwner,
          if (homeOwner) 'ownerOfClientId': ownerOfClientId,
          if (homeOwner) 'ownerOfClientName': ownerOfClientName,
          'isApproved': false,
          'email': user.email,
        }, SetOptions(merge: true));
        if (!mounted) return;
        await _resolveRole(user);
      },
    );
  }

  Future<void> _backToSignIn() async {
    await FirebaseAuth.instance.signOut();
    setState(() {
      _stage = _Stage.signedOut;
      _deniedEmail = null;
      _error = null;
      _webAccessDenied = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    switch (_stage) {
      case _Stage.loading:
        return const _CenteredCard(child: _Loading());
      case _Stage.ready:
        // Home Owner (ιδιοκτήτης καταλύματος) που ΔΕΝ είναι επιπλέον admin/
        // master → περιορισμένη οθόνη (Ανοιχτές/Αποθηκευμένες/Ιστορικό),
        // ΟΧΙ το κανονικό AdminShell.
        if (_session!.isHomeOwner && !_session!.isMaster && !_session!.isAdmin) {
          return OwnerHomePage(
            uid: _session!.uid,
            displayName: _session!.fullName,
            ownerOfClientId: _session!.ownerOfClientId ?? '',
            ownerOfClientName: _session!.ownerOfClientName ?? '',
          );
        }
        return AdminShell(session: _session!);
      case _Stage.needsProfile:
        return _CenteredCard(
          child: _NeedsProfileView(onFillProfile: _openProfileFormWeb),
        );
      case _Stage.pendingApproval:
        return _CenteredCard(
          child: _PendingApprovalView(
            onRefresh: () => _pendingUser != null ? _resolveRole(_pendingUser!) : null,
            onSignOut: _backToSignIn,
          ),
        );
      case _Stage.denied:
        return _CenteredCard(
          child: _DeniedView(
            email: _deniedEmail,
            webAccessDenied: _webAccessDenied,
            onRetry: _backToSignIn,
          ),
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
  final bool         webAccessDenied;
  final VoidCallback onRetry;
  const _DeniedView({
    required this.email,
    this.webAccessDenied = false,
    required this.onRetry,
  });

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
          webAccessDenied
              ? (email == null
                  ? 'Ο λογαριασμός έχει δικαιώματα διαχειριστή, αλλά δεν έχει '
                    'ενεργοποιημένη πρόσβαση στο web panel.'
                  : 'Ο λογαριασμός $email έχει δικαιώματα διαχειριστή, αλλά δεν έχει '
                    'ενεργοποιημένη πρόσβαση στο web panel.\n'
                    'Ζήτησε από τον master να ενεργοποιήσει το «Web» στη σελίδα '
                    'Διαχείριση.')
              : (email == null
                  ? 'Ο λογαριασμός δεν έχει δικαιώματα διαχείρισης.'
                  : 'Ο λογαριασμός $email δεν έχει δικαιώματα διαχείρισης.\n'
                    'Αυτός ο πίνακας είναι μόνο για master και εργολάβους.'),
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

class _NeedsProfileView extends StatelessWidget {
  final VoidCallback onFillProfile;
  const _NeedsProfileView({required this.onFillProfile});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const _Brand(),
        const SizedBox(height: 28),
        Icon(Icons.badge_rounded, size: 48, color: Colors.indigo.shade300),
        const SizedBox(height: 14),
        const Text('Πρώτη σύνδεση',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(
          'Συμπλήρωσε τα στοιχεία σου για να συνεχίσεις. Αν είσαι διαχειριστής '
          'καταλύματος (Home Owner), θα το επιλέξεις εκεί.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey[600], fontSize: 13.5, height: 1.4),
        ),
        const SizedBox(height: 22),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: onFillProfile,
            icon: const Icon(Icons.edit_rounded),
            label: const Text('Συμπλήρωσε τα στοιχεία σου'),
          ),
        ),
      ],
    );
  }
}

class _PendingApprovalView extends StatelessWidget {
  final VoidCallback onRefresh;
  final VoidCallback onSignOut;
  const _PendingApprovalView({required this.onRefresh, required this.onSignOut});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.hourglass_top_rounded, size: 56, color: Colors.orange.shade400),
        const SizedBox(height: 18),
        const Text('Περιμένεις έγκριση',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        Text(
          'Η αίτησή σου εστάλη. Θα αποκτήσεις πρόσβαση μόλις εγκριθεί από τον '
          'διαχειριστή.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey[600], fontSize: 14, height: 1.4),
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Έλεγχος ξανά'),
          ),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: onSignOut,
          icon: const Icon(Icons.logout_rounded),
          label: const Text('Αποσύνδεση'),
        ),
      ],
    );
  }
}
