// ==========================================
// FILE: ./lib/app_theme.dart
// ==========================================
//
// ΚΕΝΤΡΙΚΟ ΘΕΜΑ ΕΦΑΡΜΟΓΗΣ — Light + Dark mode.
// • AppColors: όλα τα χρώματα του redesign σε ένα σημείο,
//   με light & dark εκδοχή. Τα widgets παίρνουν χρώματα μέσω
//   AppColors.of(context) ώστε να αλλάζουν αυτόματα με το θέμα.
// • ThemeController: επιλογή Φωτεινό / Σκούρο / Αυτόματο,
//   αποθηκεύεται σε SharedPreferences (key: 'theme_mode').
//   Θα συνδεθεί με διακόπτη στις Ρυθμίσεις.
//
// Δουλεύει ΙΔΙΑ σε Android και Web (καμία εξάρτηση από dart:io).

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─────────────────────────────────────────────────────────────────
// Επιλογή θέματος (Φωτεινό / Σκούρο / Αυτόματο = σύστημα)
// ─────────────────────────────────────────────────────────────────
class ThemeController {
  ThemeController._();

  static const _prefsKey = 'theme_mode'; // 'light' | 'dark' | 'system'

  /// Το τρέχον mode — το MaterialApp το ακούει και ξαναχτίζεται.
  static final ValueNotifier<ThemeMode> mode =
      ValueNotifier<ThemeMode>(ThemeMode.system);

  /// Φόρτωση αποθηκευμένης επιλογής (κλήση στο main() πριν το runApp).
  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      switch (prefs.getString(_prefsKey)) {
        case 'light':
          mode.value = ThemeMode.light;
        case 'dark':
          mode.value = ThemeMode.dark;
        default:
          mode.value = ThemeMode.system;
      }
    } catch (_) {/* default: system */}
  }

  /// Αλλαγή + αποθήκευση (θα καλείται από τις Ρυθμίσεις).
  static Future<void> setMode(ThemeMode m) async {
    mode.value = m;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, switch (m) {
        ThemeMode.light => 'light',
        ThemeMode.dark  => 'dark',
        _               => 'system',
      });
    } catch (_) {}
  }
}

// ─────────────────────────────────────────────────────────────────
// Χρωματική παλέτα redesign — light & dark
// ─────────────────────────────────────────────────────────────────
class AppColors {
  final bool isDark;

  // Επιφάνειες
  final Color scaffold;      // φόντο οθόνης
  final Color card;          // λευκές κάρτες
  final Color cardBorder;    // λεπτό περίγραμμα καρτών
  final Color divider;

  // Κείμενο
  final Color textMain;
  final Color textFaint;

  // Ταυτότητα (amber)
  final Color amber;         // κύριο κουμπί (Αποδοχή, FAB)
  final Color onAmber;       // κείμενο πάνω σε amber
  final Color amberSoft;     // ανοιχτό amber φόντο (μπάρα ΤΩΡΑ)
  final Color amberDeep;     // σκούρο amber κείμενο/εικονίδια

  // Μπλε = ραντεβού / προπληρωμένη (ΔΕΝ εισπράττεις)
  final Color blue;          // έντονο (περιγράμματα, γραμμή χάρτη)
  final Color blueSoft;      // φόντο μπάρας ραντεβού
  final Color bluePale;      // φόντο μπλοκ προπληρωμής
  final Color blueDeep;      // σκούρο μπλε κείμενο
  final Color blueFaint;     // αχνό μπλε δευτερεύον κείμενο
  final Color blueDivider;

  // Πράσινο = χρήματα / εισπράττεις
  final Color green;
  final Color greenPale;     // φόντο μπλοκ είσπραξης
  final Color greenDeep;     // σκούρο πράσινο κείμενο
  final Color greenFaint;    // αχνό πράσινο δευτερεύον κείμενο
  final Color greenDivider;

  // Λοιπά σημεία
  final Color pin;           // πινέζα προορισμού (πορτοκαλοκόκκινο)
  final Color pinkSoft;      // φόντο chip παιδικού καθίσματος
  final Color pinkBorder;
  final Color pinkDeep;

  const AppColors._({
    required this.isDark,
    required this.scaffold, required this.card, required this.cardBorder,
    required this.divider,
    required this.textMain, required this.textFaint,
    required this.amber, required this.onAmber,
    required this.amberSoft, required this.amberDeep,
    required this.blue, required this.blueSoft, required this.bluePale,
    required this.blueDeep, required this.blueFaint, required this.blueDivider,
    required this.green, required this.greenPale, required this.greenDeep,
    required this.greenFaint, required this.greenDivider,
    required this.pin,
    required this.pinkSoft, required this.pinkBorder, required this.pinkDeep,
  });

  static const light = AppColors._(
    isDark:      false,
    scaffold:    Color(0xFFFAFAF7),
    card:        Colors.white,
    cardBorder:  Color(0xFFE5E3DC),
    divider:     Color(0xFFEFEEE8),
    textMain:    Color(0xFF2C2C2A),
    textFaint:   Color(0xFF888780),
    amber:       Color(0xFFEF9F27),
    onAmber:     Color(0xFF412402),
    amberSoft:   Color(0xFFFAEEDA),
    amberDeep:   Color(0xFF854F0B),
    blue:        Color(0xFF378ADD),
    blueSoft:    Color(0xFFB5D4F4),
    bluePale:    Color(0xFFE6F1FB),
    blueDeep:    Color(0xFF042C53),
    blueFaint:   Color(0xFF5C93C9),
    blueDivider: Color(0xFF85B7EB),
    green:       Color(0xFF97C459),
    greenPale:   Color(0xFFEAF3DE),
    greenDeep:   Color(0xFF173404),
    greenFaint:  Color(0xFF7FA657),
    greenDivider:Color(0xFFC0DD97),
    pin:         Color(0xFF993C1D),
    pinkSoft:    Color(0xFFFBEAF0),
    pinkBorder:  Color(0xFFED93B1),
    pinkDeep:    Color(0xFF72243E),
  );

  static const dark = AppColors._(
    isDark:      true,
    scaffold:    Color(0xFF1A1A18),
    card:        Color(0xFF232320),
    cardBorder:  Color(0xFF3A3A36),
    divider:     Color(0xFF33332F),
    textMain:    Color(0xFFEDEDEA),
    textFaint:   Color(0xFF8A8983),
    amber:       Color(0xFFEF9F27),
    onAmber:     Color(0xFF412402),
    amberSoft:   Color(0xFF3A2C12),
    amberDeep:   Color(0xFFE9B45C),
    blue:        Color(0xFF378ADD),
    blueSoft:    Color(0xFF123253),
    bluePale:    Color(0xFF0E2C4A),
    blueDeep:    Color(0xFFD9EAFB),
    blueFaint:   Color(0xFF6E9CC7),
    blueDivider: Color(0xFF2A5580),
    green:       Color(0xFF97C459),
    greenPale:   Color(0xFF1C2A10),
    greenDeep:   Color(0xFFDFF0C8),
    greenFaint:  Color(0xFF8FB365),
    greenDivider:Color(0xFF3E5A22),
    pin:         Color(0xFFE88B63),
    pinkSoft:    Color(0xFF3A1D28),
    pinkBorder:  Color(0xFF8A4A61),
    pinkDeep:    Color(0xFFF0B7C9),
  );

  /// Η σωστή παλέτα για το τρέχον θέμα.
  static AppColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

// ─────────────────────────────────────────────────────────────────
// ThemeData — ενιαία γλώσσα σχήματος:
// κάρτες 16, dialogs/sheets 24, κουμπιά pill 24, λεπτά περιγράμματα.
// ─────────────────────────────────────────────────────────────────
ThemeData _base(AppColors c, Brightness b) {
  final scheme = ColorScheme.fromSeed(
    seedColor:  c.amber,
    brightness: b,
  ).copyWith(surface: c.card);

  return ThemeData(
    useMaterial3:            true,
    brightness:              b,
    colorScheme:             scheme,
    scaffoldBackgroundColor: c.scaffold,
    dividerColor:            c.divider,
    cardTheme: CardThemeData(
      color:     c.card,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side:         BorderSide(color: c.cardBorder, width: 0.8),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.scaffold,
      elevation:       0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.scaffold,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.amber,
        foregroundColor: c.onAmber,
        padding:         const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.textFaint,
        side:            BorderSide(color: c.cardBorder),
        padding:         const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
  );
}

ThemeData appThemeLight() => _base(AppColors.light, Brightness.light);
ThemeData appThemeDark()  => _base(AppColors.dark,  Brightness.dark);
