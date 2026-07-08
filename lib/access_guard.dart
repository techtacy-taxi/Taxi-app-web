// lib/access_guard.dart
//
// «Φρουρός» πρόσβασης — τυλίγει μια σελίδα (Ημερολόγιο, Διαχειριστές, Ζώνες &
// Τιμές, κ.λπ.) και ακούει ΖΩΝΤΑΝΑ (snapshots) το presence/{uid} του χρήστη.
// Αν ο master αφαιρέσει το σχετικό δικαίωμα ΕΝΩ ο χρήστης είναι ήδη ΜΕΣΑ στη
// σελίδα, τον πετάει έξω ΑΚΑΡΙΑΙΑ (Navigator.pop) με ένα μήνυμα — δεν
// χρειάζεται restart ή re-login για να «πιάσει» η αλλαγή.
//
// Χρήση:
//   Navigator.push(context, MaterialPageRoute(
//     builder: (_) => AccessGuard(
//       uid: uid,
//       hasAccess: (data) => data['calendarEnabled'] == true || data['master'] == true,
//       deniedMessage: 'Η πρόσβαση στο Ημερολόγιο αφαιρέθηκε.',
//       child: CalendarPage(...),
//     ),
//   ));

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class AccessGuard extends StatefulWidget {
  final String uid;
  final bool Function(Map<String, dynamic> data) hasAccess;
  final String deniedMessage;
  final Widget child;

  const AccessGuard({
    super.key,
    required this.uid,
    required this.hasAccess,
    required this.child,
    this.deniedMessage = 'Η πρόσβαση αφαιρέθηκε.',
  });

  @override
  State<AccessGuard> createState() => _AccessGuardState();
}

class _AccessGuardState extends State<AccessGuard> {
  bool _kicked = false;

  @override
  Widget build(BuildContext context) {
    if (widget.uid.isEmpty) return widget.child;
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('presence')
          .doc(widget.uid)
          .snapshots(),
      builder: (context, snap) {
        final data = snap.data?.data();
        if (data != null && !widget.hasAccess(data) && !_kicked) {
          _kicked = true;
          // Πετάμε τον χρήστη έξω ΜΕΤΑ το build (όχι μέσα σε build) — και
          // δείχνουμε το μήνυμα στην ΠΡΟΗΓΟΥΜΕΝΗ σελίδα, αφού αυτή θα κλείσει.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            final nav = Navigator.of(context);
            final messenger = ScaffoldMessenger.of(context);
            if (nav.canPop()) nav.pop();
            messenger.showSnackBar(SnackBar(
              content: Text(widget.deniedMessage),
              backgroundColor: Colors.red.shade700,
              duration: const Duration(seconds: 4),
            ));
          });
        }
        return widget.child;
      },
    );
  }
}
