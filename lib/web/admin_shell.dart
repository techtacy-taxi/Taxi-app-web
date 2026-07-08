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
//   Ημερολόγιο → CalendarPage   (αν calendarEnabled ή master)
//   Εισαγωγή   → ICS upload
//   Διαχείριση → MastersAdminPage (μόνο master)

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../jobs/job_admin_page.dart';
import '../jobs/billing_page.dart';
import '../calendar/calendar_page.dart';
import '../voice/groups_admin.dart';
import '../masters/masters_admin_page.dart';
import '../pricing/pricing_zones_page.dart';
import '../viva_settings_page.dart';
import '../tenants/tenant_admin_page.dart';
import 'auth_gateway_web.dart';
import 'ics_upload_web.dart';
import 'map_web_page.dart';

const double _kDesktopBreakpoint = 900;
const Color  _kAmber = Color(0xFFFFB300);

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
    ];

    // Ημερολόγιο: master πάντα· admin μόνο αν calendarEnabled.
    if (s.isMaster || s.calendarEnabled) {
      sections.add(_Section(
        label: 'Ημερολόγιο',
        icon: Icons.calendar_month_rounded,
        page: CalendarPage(
          adminUid:  s.uid,
          adminName: s.fullName,
          isMaster:  s.isMaster,
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

    // Διαχείριση χρηστών/ρόλων — μόνο master.
    if (s.isMaster) {
      sections.add(_Section(
        label: 'Διαχείριση',
        icon: Icons.admin_panel_settings_rounded,
        page: MastersAdminPage(masterUid: s.uid),
      ));
    }

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
        label: 'Ρυθμίσεις Viva',
        icon: Icons.payment_rounded,
        page: VivaSettingsPage(),
      ));
    }

    // Online Φόρμα (πρώην «Πελάτες/Tenants») — ΜΟΝΟ ο πραγματικός super-admin
    // (εσύ). Ο έλεγχος email είναι ΕΠΙΠΛΕΟΝ ασφαλιστική δικλείδα — η ίδια η
    // TenantAdminPage κάνει ξανά τον ίδιο έλεγχο εσωτερικά.
    if (FirebaseAuth.instance.currentUser?.email == 'techtacy@gmail.com') {
      sections.add(const _Section(
        label: 'Online Φόρμα',
        icon: Icons.storefront_rounded,
        page: TenantAdminPage(),
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
    return Scaffold(
      body: Row(
        children: [
          _Sidebar(
            sections: _sections,
            index: _index,
            onSelect: (i) => setState(() => _index = i),
            session: _session,
            onSignOut: _signOut,
          ),
          const VerticalDivider(width: 1),
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
    // Στο bottom bar χωράνε έως ~5· τα υπόλοιπα πάνε στο drawer.
    final bottomCount = _sections.length <= 5 ? _sections.length : 4;
    final inBottom = _sections.take(bottomCount).toList();
    final bottomActive = _index < bottomCount;

    return Scaffold(
      appBar: AppBar(
        title: Text(_sections[_index].label),
        backgroundColor: _kAmber,
        foregroundColor: Colors.black87,
      ),
      drawer: Drawer(
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
        backgroundColor: Colors.white,
        indicatorColor: _kAmber.withValues(alpha: 0.25),
        destinations: [
          for (final s in inBottom)
            NavigationDestination(
              icon: Icon(s.icon),
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
    return Container(
      width: 250,
      color: Colors.white,
      child: Column(
        children: [
          const SizedBox(height: 22),
          _Header(session: session),
          const SizedBox(height: 14),
          const Divider(height: 1),
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
          const Divider(height: 1),
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
    return SafeArea(
      child: Column(
        children: [
          const SizedBox(height: 18),
          _Header(session: session),
          const SizedBox(height: 14),
          const Divider(height: 1),
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
          const Divider(height: 1),
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
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          ),
        ),
        const SizedBox(height: 3),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: _kAmber.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(roleLabel,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.amber.shade900)),
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Material(
        color: selected ? _kAmber.withValues(alpha: 0.18) : Colors.transparent,
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
                    color: selected ? Colors.amber.shade900 : Colors.grey[700]),
                const SizedBox(width: 14),
                Text(section.label,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight:
                          selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected ? Colors.black87 : Colors.grey[800],
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
    return ListTile(
      leading: Icon(Icons.logout_rounded, color: Colors.grey[700]),
      title: const Text('Αποσύνδεση'),
      onTap: onSignOut,
    );
  }
}
