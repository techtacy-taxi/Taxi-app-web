// ============================================================================
// FILE: ./lib/web/admin_shell.dart
// ============================================================================
//
// Κέλυφος (shell) του πίνακα διαχείρισης ΓΙΑ WEB.
//
// Responsive:
//   • PC / tablet (≥ 900px)  → μόνιμο sidebar αριστερά + περιεχόμενο δεξιά
//   • Κινητό / iPhone (< 900) → AppBar με drawer + bottom navigation
//
// Ενότητες (ανάλογα με ρόλο):
//   Δουλειές   → JobAdminPage  (μέσα: Ανοιχτές/Αποθηκευμένες/Ιστορικό/
//                               Πηγές/Πελάτες + κουμπί «Νέα Δουλειά»)
//   Χρεώσεις   → BillingPage
//   Ομάδες     → GroupsAdminPage
//   Ημερολόγιο → JobsCalendarPage (ίδιο ημερολόγιο με την εφαρμογή κινητού,
//                               με κουμπί Google Calendar)   (αν calendarEnabled ή master)
//   Εισαγωγή   → ICS upload
//   Διαχείριση → MastersAdminPage (μόνο master)

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../jobs/job_admin_page.dart';
import '../jobs/billing_page.dart';
import '../calendar/jobs_calendar_page.dart';
import '../voice/groups_admin.dart';
import '../pricing/pricing_zones_page.dart';
import '../viva_settings_page.dart';
import '../masters/global_settings_page.dart';
import 'auth_gateway_web.dart';
import 'ics_upload_web.dart';
import 'map_web_page.dart';
import 'web_settings_page.dart';

const double _kDesktopBreakpoint = 900;

class _Section {
  final String   label;
  final IconData icon;
  final Widget   page;
  const _Section({required this.label, required this.icon, required this.page});
}

class AdminShell extends StatefulWidget {
  final AdminSession session;
  const AdminShell({super.key, required this.session});

  @override
  State<AdminShell> createState() => _AdminShellState();
}

class _AdminShellState extends State<AdminShell> {
  int _index = 0;
  late AdminSession _session = widget.session;
  late List<_Section> _sections = _buildSections();
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _presenceSub;

  @override
  void initState() {
    super.initState();
    // ── Ζωντανή παρακολούθηση του δικού μας presence — ΑΚΑΡΙΑΙΑ αντίδραση
    // αν ο master αλλάξει δικαιώματα ΕΝΩ είμαστε ήδη μέσα στο web panel: το
    // μενού ανανεώνεται αμέσως (νέες ενότητες εμφανίζονται/εξαφανίζονται),
    // και αν χαθεί εντελώς η πρόσβαση, μας βγάζει έξω από τη σύνδεση.
    _presenceSub = FirebaseFirestore.instance
        .collection('presence')
        .doc(_session.uid)
        .snapshots()
        .listen((doc) {
      if (!mounted) return;
      final data = doc.data();
      if (data == null) return;

      final isMaster       = data['master']       == true;
      final isAdmin        = data['admin']        == true;
      final isTenantOwner  = data['tenantOwner']  == true;
      final isHomeOwner    = data['homeOwner']    == true;
      final isApproved     = data['isApproved']   == true;
      final webEnabled     = data['webEnabled']   == true;

      // ── Πλήρης απώλεια πρόσβασης — ίδιοι κανόνες με την πύλη σύνδεσης
      // (auth_gateway_web). Αν παύει να πληρούνται, βγαίνει αμέσως έξω.
      final stillAllowed = isMaster ||
          ((isAdmin || isHomeOwner) && isApproved &&
              (isTenantOwner || webEnabled));
      if (!stillAllowed) {
        _forceSignOut();
        return;
      }

      setState(() {
        _session = AdminSession(
          uid:             _session.uid,
          displayName:     _session.displayName,
          lastName:        _session.lastName,
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
        _sections = _buildSections();
        // Αν η ενότητα που έβλεπε μόλις εξαφανίστηκε (π.χ. έκλεισε το
        // Ημερολόγιο ενώ ήταν μέσα), γύρνα τον στην πρώτη διαθέσιμη.
        if (_index >= _sections.length) _index = 0;
      });
    });
  }

  Future<void> _forceSignOut() async {
    await FirebaseAuth.instance.signOut();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Η πρόσβασή σου αφαιρέθηκε από τον master.'),
      backgroundColor: Colors.red,
      duration: Duration(seconds: 4),
    ));
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const WebAuthGateway()),
      (_) => false,
    );
  }

  List<_Section> _buildSections() {
    final s = _session;
    final sections = <_Section>[
      _Section(
        label: 'Δουλειές',
        icon: Icons.work_rounded,
        page: JobAdminPage(
          adminUid:       s.uid,
          adminName:      s.fullName,
          isAdmin:        s.isAdmin,
          isMaster:       s.isMaster,
          managedGroupIds: s.managedGroupIds,
        ),
      ),
      _Section(
        label: 'Χάρτης',
        icon: Icons.map_rounded,
        page: MapWebPage(uid: s.uid),
      ),
      _Section(
        label: 'Χρεώσεις',
        icon: Icons.receipt_long_rounded,
        page: BillingPage(
          uid:             s.uid,
          userName:        s.fullName,
          isMaster:        s.isMaster,
          isAdmin:         s.isAdmin,
          managedGroupIds: s.managedGroupIds,
        ),
      ),
      _Section(
        label: 'Ομάδες',
        icon: Icons.groups_rounded,
        page: GroupsAdminPage(uid: s.uid),
      ),
      _Section(
        label: 'Ρυθμίσεις',
        icon: Icons.settings_rounded,
        page: WebSettingsPage(
          uid:      s.uid,
          isAdmin:  s.isAdmin,
          isMaster: s.isMaster,
        ),
      ),
    ];

    // Ημερολόγιο: master πάντα· admin μόνο αν calendarEnabled.
    if (s.isMaster || s.calendarEnabled) {
      sections.add(_Section(
        label: 'Ημερολόγιο',
        icon: Icons.calendar_month_rounded,
        page: JobsCalendarPage(
          uid:                    s.uid,
          isAdmin:                s.isAdmin,
          isMaster:               s.isMaster,
          googleCalendarEnabled:  s.isMaster || s.calendarEnabled,
        ),
      ));
    }

    // Εισαγωγή ICS (διαθέσιμη σε όλους τους διαχειριστές).
    sections.add(_Section(
      label: 'Εισαγωγή ICS',
      icon: Icons.upload_file_rounded,
      page: IcsUploadPage(
        adminUid:  s.uid,
        adminName: s.fullName,
        isMaster:  s.isMaster,
      ),
    ));

    // Η παλιά «Διαχείριση» (MastersAdminPage) ΚΑΤΑΡΓΗΘΗΚΕ — ενοποιήθηκε
    // πλήρως μέσα στις «Καθολικές ρυθμίσεις» (GlobalSettingsPage), block
    // ΧΡΗΣΤΕΣ (ρόλος/ομάδες/τιμές/διαγραφή, με αναζήτηση).

    // Ζώνες & Τιμές (τιμοκατάλογος δημόσιας φόρμας κράτησης) — master ή
    // tenantOwner (πελάτης multi-tenant, βλέπει ΜΟΝΟ αυτό το επιπλέον menu,
    // πέρα από τα κανονικά admin δικαιώματα που ήδη έχει).
    if (s.isMaster || s.isTenantOwner) {
      sections.add(const _Section(
        label: 'Ζώνες & Τιμές',
        icon: Icons.price_change_rounded,
        page: PricingZonesPage(),
      ));
    }

    // Ρυθμίσεις Viva (credentials — αυτοεξυπηρέτηση) — master ή tenantOwner.
    if (s.isMaster || s.isTenantOwner) {
      sections.add(const _Section(
        label: 'Ρυθμίσεις Online Φόρμας',
        icon: Icons.payment_rounded,
        page: VivaSettingsPage(),
      ));
    }

    // Η ξεχωριστή σελίδα «Online Φόρμα» (TenantAdminPage) ΚΑΤΑΡΓΗΘΗΚΕ —
    // όλη η διαχείριση tenants ζει πλέον στις «Καθολικές ρυθμίσεις»
    // (GlobalSettingsPage), block TENANTS + κάρτες admins.
    if (FirebaseAuth.instance.currentUser?.email == 'techtacy@gmail.com') {
      sections.add(_Section(
        label: 'Καθολικές ρυθμίσεις',
        icon: Icons.storefront_rounded,
        page: GlobalSettingsPage(
            masterUid: FirebaseAuth.instance.currentUser?.uid ?? ''),
      ));
    }

    return sections;
  }

  @override
  void dispose() {
    _presenceSub?.cancel();
    super.dispose();
  }

  Future<void> _signOut() async {
    await FirebaseAuth.instance.signOut();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const WebAuthGateway()),
      (_) => false,
    );
  }

  void _select(int i) {
    setState(() => _index = i);
    // Στο κινητό, αν είναι ανοιχτό το drawer, κλείσ' το.
    final nav = Navigator.of(context);
    if (nav.canPop() && MediaQuery.of(context).size.width < _kDesktopBreakpoint) {
      nav.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop =
        MediaQuery.of(context).size.width >= _kDesktopBreakpoint;
    return isDesktop ? _buildDesktop() : _buildMobile();
  }

  // ─── DESKTOP: μόνιμο sidebar ──────────────────────────────────────────────

  Widget _buildDesktop() {
    final c = AppColors.of(context);
    return Scaffold(
      backgroundColor: c.scaffold,
      body: Row(
        children: [
          _Sidebar(
            sections: _sections,
            index: _index,
            onSelect: (i) => setState(() => _index = i),
            session: _session,
            onSignOut: _signOut,
          ),
          VerticalDivider(width: 1, color: c.divider),
          Expanded(
            child: ClipRect(
              child: _sections[_index].page,
            ),
          ),
        ],
      ),
    );
  }

  // ─── MOBILE: AppBar + drawer + bottom navigation ─────────────────────────

  Widget _buildMobile() {
    final c = AppColors.of(context);
    // Στο bottom bar χωράνε έως ~5· τα υπόλοιπα πάνε στο drawer.
    final bottomCount = _sections.length <= 5 ? _sections.length : 4;
    final inBottom = _sections.take(bottomCount).toList();
    final bottomActive = _index < bottomCount;

    return Scaffold(
      backgroundColor: c.scaffold,
      appBar: AppBar(
        title: Text(_sections[_index].label),
        backgroundColor: c.scaffold,
        foregroundColor: c.textMain,
        elevation: 0,
      ),
      drawer: Drawer(
        backgroundColor: c.scaffold,
        child: _DrawerContent(
          sections: _sections,
          index: _index,
          onSelect: _select,
          session: _session,
          onSignOut: _signOut,
        ),
      ),
      body: _sections[_index].page,
      bottomNavigationBar: NavigationBar(
        selectedIndex: bottomActive ? _index : 0,
        onDestinationSelected: (i) => setState(() => _index = i),
        backgroundColor: c.card,
        indicatorColor: c.amberSoft,
        destinations: [
          for (final s in inBottom)
            NavigationDestination(
              icon: Icon(s.icon, color: c.textFaint),
              selectedIcon: Icon(s.icon, color: c.amberDeep),
              label: s.label,
            ),
        ],
      ),
    );
  }
}

// ─── Sidebar (desktop) ──────────────────────────────────────────────────────

class _Sidebar extends StatelessWidget {
  final List<_Section>   sections;
  final int              index;
  final ValueChanged<int> onSelect;
  final AdminSession     session;
  final VoidCallback     onSignOut;
  const _Sidebar({
    required this.sections,
    required this.index,
    required this.onSelect,
    required this.session,
    required this.onSignOut,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      width: 250,
      color: c.card,
      child: Column(
        children: [
          const SizedBox(height: 22),
          _Header(session: session),
          const SizedBox(height: 14),
          Divider(height: 1, color: c.divider),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                for (var i = 0; i < sections.length; i++)
                  _NavTile(
                    section: sections[i],
                    selected: i == index,
                    onTap: () => onSelect(i),
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: c.divider),
          _SignOutTile(onSignOut: onSignOut),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

// ─── Drawer content (mobile) ────────────────────────────────────────────────

class _DrawerContent extends StatelessWidget {
  final List<_Section>   sections;
  final int              index;
  final ValueChanged<int> onSelect;
  final AdminSession     session;
  final VoidCallback     onSignOut;
  const _DrawerContent({
    required this.sections,
    required this.index,
    required this.onSelect,
    required this.session,
    required this.onSignOut,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return SafeArea(
      child: Column(
        children: [
          const SizedBox(height: 18),
          _Header(session: session),
          const SizedBox(height: 14),
          Divider(height: 1, color: c.divider),
          Expanded(
            child: ListView(
              children: [
                for (var i = 0; i < sections.length; i++)
                  _NavTile(
                    section: sections[i],
                    selected: i == index,
                    onTap: () => onSelect(i),
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: c.divider),
          _SignOutTile(onSignOut: onSignOut),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final AdminSession session;
  const _Header({required this.session});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final roleLabel = session.isMaster ? 'Master' : 'Εργολάβος';
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(15),
          child: Image.asset(
            'assets/app_icon.png',
            width: 56, height: 56,
            fit: BoxFit.cover,
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            session.fullName.isEmpty ? 'Διαχειριστής' : session.fullName,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: c.textMain),
          ),
        ),
        const SizedBox(height: 3),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: c.amberSoft,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(roleLabel,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: c.amberDeep)),
        ),
      ],
    );
  }
}

class _NavTile extends StatelessWidget {
  final _Section    section;
  final bool        selected;
  final VoidCallback onTap;
  const _NavTile({
    required this.section,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Material(
        color: selected ? c.amberSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: Row(
              children: [
                Icon(section.icon,
                    size: 22,
                    color: selected ? c.amberDeep : c.textFaint),
                const SizedBox(width: 14),
                Text(section.label,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight:
                          selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected ? c.textMain : c.textFaint,
                    )),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SignOutTile extends StatelessWidget {
  final VoidCallback onSignOut;
  const _SignOutTile({required this.onSignOut});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return ListTile(
      leading: Icon(Icons.logout_rounded, color: c.textFaint),
      title: Text('Αποσύνδεση', style: TextStyle(color: c.textMain)),
      onTap: onSignOut,
    );
  }
}
