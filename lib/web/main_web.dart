// ============================================================================
// FILE: ./lib/web/main_web.dart
// ============================================================================
//
// Entry point ΓΙΑ WEB (Cloudflare Pages).
// Build:  flutter build web --release -t lib/web/main_web.dart
//
// ⚠️  ΔΕΝ αγγίζει το lib/main.dart (Android). Εδώ ΔΕΝ αρχικοποιούμε:
//      • foreground task / location  • FCM background handler
//      • geolocator                  • notifications service
//     Αυτά είναι native-only και άχρηστα για τον master/admin σε browser.
//
// Φορτώνει ΜΟΝΟ Firebase (Auth + Firestore + Functions) και το admin panel.

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import '../firebase_options.dart';
import 'auth_gateway_web.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.web,
  );
  runApp(const AthensTaxiAdminApp());
}

class AthensTaxiAdminApp extends StatelessWidget {
  const AthensTaxiAdminApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Athens Taxi — Διαχείριση',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(),
      home: const WebAuthGateway(),
    );
  }

  ThemeData _buildTheme() {
    const amber = Color(0xFFFFB300); // κίτρινο accent (Athens Taxi)
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: amber,
        primary: amber,
        brightness: Brightness.light,
      ),
      scaffoldBackgroundColor: const Color(0xFFF7F8FA),
      fontFamily: 'Roboto',
    );
    return base.copyWith(
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
        scrolledUnderElevation: 1,
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: Colors.grey.shade200),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: amber,
          foregroundColor: Colors.black87,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }
}
