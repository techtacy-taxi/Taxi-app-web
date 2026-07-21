// lib/settings_page.dart
//
// Νέα ενιαία οθόνη «Ρυθμίσεις» (bottom-nav tab), εγκεκριμένο mockup:
//   ΛΟΓΑΡΙΑΣΜΟΣ  — Στοιχεία οδηγού, Σίγαση ειδοποιήσεων          (όλοι)
//   ΕΦΑΡΜΟΓΗ     — Εμφάνιση εφαρμογής, Εμφάνιση κύριου χάρτη,
//                  Έλεγχος ενημέρωσης                            (όλοι)
//   ΟΜΑΔΑ        — Ομάδες οδηγών, Ζώνες & Τιμές,
//                  Ρυθμίσεις Online Φόρμας                       (admin+master)
//   ΠΛΑΤΦΟΡΜΑ    — Καθολικές ρυθμίσεις (tenants/admins/τιμές)     (μόνο master)
//
// Emphasis: «Εμφάνιση εφαρμογής» χρησιμοποιεί ThemeController (γενικό θέμα),
// «Εμφάνιση κύριου χάρτη» χρησιμοποιεί MapThemeController — εντελώς
// ανεξάρτητα μεταξύ τους, όπως ζητήθηκε (πχ σκούρα εφαρμογή + ανοιχτόχρωμος
// χάρτης). Οι μικροί χάρτες σε popup/ειδοποιήσεις ΠΑΝΤΑ ακολουθούν το γενικό
// θέμα εφαρμογής — ΔΕΝ έχουν δική τους επιλογή.

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'masters/global_settings_page.dart';
import 'pricing/pricing_zones_page.dart';
import 'viva_settings_page.dart';
import 'voice/groups_admin.dart';

const String _kSuperAdminEmail = 'techtacy@gmail.com';

class SettingsPage extends StatelessWidget {
  final String uid;
  final bool   isAdmin;
  final bool   isMaster;
  final VoidCallback onEditProfile;
  final VoidCallback onCheckUpdate;
  final VoidCallback onSignOut;
  final bool   muted;
  final ValueChanged<bool> onMuteChanged;
  /// Άνοιγμα του επιλογέα οχήματος (Ταξί/Van/Bus) — ίδιος διάλογος με πριν,
  /// απλά καλείται από εδώ αντί από το παλιό popup menu.
  final VoidCallback onOpenVehiclePicker;
  /// Μόνο master: στέλνει ειδοποίηση αναβάθμισης σε όλους τους οδηγούς.
  final VoidCallback? onBroadcastUpdate;

  const SettingsPage({
    super.key,
    required this.uid,
    required this.isAdmin,
    required this.isMaster,
    required this.onEditProfile,
    required this.onCheckUpdate,
    required this.onSignOut,
    required this.muted,
    required this.onMuteChanged,
    required this.onOpenVehiclePicker,
    this.onBroadcastUpdate,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Scaffold(
      backgroundColor: c.scaffold,
      appBar: AppBar(
        title: const Text('Ρυθμίσεις'),
        backgroundColor: c.scaffold,
        foregroundColor: c.textMain,
        elevation: 0,
      ),
      body: ListView(
        // Κάτω: +ύψος Android navigation bar να μην κρύβεται το τέλος.
        padding: EdgeInsets.fromLTRB(
            14, 14, 14,
            30 + MediaQuery.of(context).viewPadding.bottom),
        children: [
          _sectionLabel(c, 'ΛΟΓΑΡΙΑΣΜΟΣ'),
          const SizedBox(height: 8),
          _card(c, [
            _tile(context, c,
                icon: Icons.person_outline_rounded,
                label: 'Στοιχεία οδηγού',
                onTap: onEditProfile),
            _divider(c),
            _tile(context, c,
                icon: Icons.local_taxi_rounded,
                label: 'Όχημα',
                onTap: onOpenVehiclePicker),
            _divider(c),
            _switchTile(context, c,
                icon: Icons.notifications_off_rounded,
                label: 'Σίγαση ειδοποιήσεων',
                value: muted,
                onChanged: onMuteChanged),
          ]),

          const SizedBox(height: 18),
          _sectionLabel(c, 'ΕΦΑΡΜΟΓΗ'),
          const SizedBox(height: 8),
          _card(c, [
            _AppearanceTile(
              icon:  Icons.dark_mode_rounded,
              label: 'Εμφάνιση εφαρμογής',
              controllerMode: ThemeController.mode,
              onSelect: ThemeController.setMode,
            ),
            _divider(c),
            _AppearanceTile(
              icon:  Icons.map_rounded,
              label: 'Εμφάνιση κύριου χάρτη',
              controllerMode: MapThemeController.mode,
              onSelect: MapThemeController.setMode,
            ),
            _divider(c),
            _tile(context, c,
                icon: Icons.system_update_rounded,
                label: 'Έλεγχος ενημέρωσης',
                onTap: onCheckUpdate),
          ]),

          if (isAdmin || isMaster) ...[
            const SizedBox(height: 18),
            _sectionLabel(c, 'ΟΜΑΔΑ'),
            const SizedBox(height: 8),
            _card(c, [
              _tile(context, c,
                  icon: Icons.groups_rounded,
                  label: 'Ομάδες οδηγών',
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => GroupsAdminPage(uid: uid),
                      ))),
              _divider(c),
              _tile(context, c,
                  icon: Icons.map_outlined,
                  label: 'Ζώνες και τιμές',
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const PricingZonesPage(),
                      ))),
              _divider(c),
              _tile(context, c,
                  icon: Icons.dvr_rounded,
                  label: 'Ρυθμίσεις Online Φόρμας',
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const VivaSettingsPage(),
                      ))),
            ]),
          ],

          if (isMaster) ...[
            const SizedBox(height: 18),
            Text('ΠΛΑΤΦΟΡΜΑ · MASTER',
                style: TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w700, color: c.blueDeep)),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color:        c.bluePale,
                border:       Border.all(color: c.blueSoft, width: 0.8),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(children: [
                _tile(context, c,
                    icon: Icons.admin_panel_settings_rounded,
                    label: 'Καθολικές ρυθμίσεις',
                    labelColor: c.blueDeep,
                    iconColor: c.blueDeep,
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => GlobalSettingsPage(masterUid: uid),
                        ))),
                // Online Φόρμα (διαχείριση tenants) — ΜΟΝΟ ο πραγματικός
                // super-admin (ίδιος έλεγχος με πριν στο popup menu).
                if (FirebaseAuth.instance.currentUser?.email == _kSuperAdminEmail) ...[
                ],
                if (onBroadcastUpdate != null) ...[
                  Divider(height: 1, color: c.blueSoft),
                  _tile(context, c,
                      icon: Icons.campaign_rounded,
                      label: 'Ειδοποίηση αναβάθμισης σε όλους',
                      labelColor: c.blueDeep,
                      iconColor: c.blueDeep,
                      onTap: onBroadcastUpdate!),
                ],
              ]),
            ),
          ],

          const SizedBox(height: 22),
          Center(
            child: TextButton.icon(
              onPressed: onSignOut,
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              icon: const Icon(Icons.logout_rounded, size: 20),
              label: const Text('Αποσύνδεση'),
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _sectionLabel(AppColors c, String text) => Text(text,
      style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: c.textFaint));

  Widget _card(AppColors c, List<Widget> children) => Container(
        decoration: BoxDecoration(
          color:        c.card,
          borderRadius: BorderRadius.circular(14),
          border:       Border.all(color: c.cardBorder, width: 0.8),
        ),
        child: Column(children: children),
      );

  Widget _divider(AppColors c) => Divider(height: 1, color: c.divider);

  Widget _tile(BuildContext context, AppColors c, {
    required IconData icon,
    required String   label,
    required VoidCallback onTap,
    String? trailingText,
    Color? labelColor,
    Color? iconColor,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        child: Row(children: [
          Icon(icon, size: 21, color: iconColor ?? c.textFaint),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label,
                style: TextStyle(fontSize: 15.5, color: labelColor ?? c.textMain)),
          ),
          if (trailingText != null) ...[
            Text(trailingText, style: TextStyle(fontSize: 14, color: c.textFaint)),
            const SizedBox(width: 6),
          ],
          Icon(Icons.chevron_right_rounded, size: 18, color: c.textFaint),
        ]),
      ),
    );
  }

  Widget _switchTile(BuildContext context, AppColors c, {
    required IconData icon,
    required String   label,
    required bool      value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(children: [
        Icon(icon, size: 21, color: c.textFaint),
        const SizedBox(width: 10),
        Expanded(
          child: Text(label, style: TextStyle(fontSize: 15.5, color: c.textMain)),
        ),
        Switch(
          value: value,
          onChanged: onChanged,
          activeThumbColor: Colors.white,
          activeTrackColor: c.green,
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// Γραμμή «Εμφάνιση» — ανοίγει bottom sheet με 3 επιλογές
// (Φωτεινό/Σκούρο/Αυτόματο), δείχνει την τρέχουσα επιλογή δεξιά.
// Χρησιμοποιείται ΚΑΙ για το γενικό θέμα ΚΑΙ για τον κύριο χάρτη —
// περνάμε διαφορετικό ValueNotifier<ThemeMode> + setter σε κάθε χρήση,
// ώστε οι δύο επιλογές να μένουν εντελώς ανεξάρτητες.
// ─────────────────────────────────────────────────────────────────
class _AppearanceTile extends StatelessWidget {
  final IconData icon;
  final String   label;
  final ValueNotifier<ThemeMode> controllerMode;
  final Future<void> Function(ThemeMode) onSelect;

  const _AppearanceTile({
    required this.icon,
    required this.label,
    required this.controllerMode,
    required this.onSelect,
  });

  String _modeLabel(ThemeMode m) => switch (m) {
        ThemeMode.light  => 'Φωτεινό',
        ThemeMode.dark   => 'Σκούρο',
        ThemeMode.system => 'Αυτόματο',
      };

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: controllerMode,
      builder: (context, mode, _) => InkWell(
        onTap: () => _openPicker(context, c, mode),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(children: [
            Icon(icon, size: 21, color: c.textFaint),
            const SizedBox(width: 10),
            Expanded(
              child: Text(label, style: TextStyle(fontSize: 15.5, color: c.textMain)),
            ),
            Text(_modeLabel(mode), style: TextStyle(fontSize: 14, color: c.textFaint)),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right_rounded, size: 18, color: c.textFaint),
          ]),
        ),
      ),
    );
  }

  Future<void> _openPicker(BuildContext context, AppColors c, ThemeMode current) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.scaffold,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(label,
                style: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600, color: c.textMain)),
            const SizedBox(height: 12),
            _option(ctx, c, ThemeMode.light,  'Φωτεινό',  Icons.light_mode_rounded, current),
            _option(ctx, c, ThemeMode.dark,   'Σκούρο',   Icons.dark_mode_rounded,  current),
            _option(ctx, c, ThemeMode.system, 'Αυτόματο', Icons.brightness_auto_rounded, current),
          ]),
        ),
      ),
    );
  }

  Widget _option(BuildContext context, AppColors c, ThemeMode m, String label,
      IconData icon, ThemeMode current) {
    final selected = m == current;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () async {
        await onSelect(m);
        if (context.mounted) Navigator.of(context).pop();
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color:        selected ? c.amberSoft : c.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? c.amber : c.cardBorder,
            width: selected ? 1.5 : 0.8,
          ),
        ),
        child: Row(children: [
          Icon(icon, size: 21, color: selected ? c.amberDeep : c.textFaint),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label,
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected ? c.amberDeep : c.textMain)),
          ),
          if (selected) Icon(Icons.check_rounded, size: 20, color: c.amberDeep),
        ]),
      ),
    );
  }
}
