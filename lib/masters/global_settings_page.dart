// lib/masters/global_settings_page.dart
//
// «ΚΑΘΟΛΙΚΕΣ ΡΥΘΜΙΣΕΙΣ» (πρώην «Διαχειριστές» / masters_admin_page) —
// master-only, ενοποιεί σε ΜΙΑ οθόνη:
//   1) Tenants — λίστα + ΟΛΗ η διαχείριση tenant (δημιουργία, επεξεργασία,
//      ενεργός/κλειδωμένος, Διόρθωση πελατών, Επισκευή πρόσβασης) — η παλιά
//      ξεχωριστή σελίδα TenantAdminPage ΚΑΤΑΡΓΗΘΗΚΕ
//   2) Admins  — κάρτα ανά admin/οδηγό με ΟΛΕΣ τις τιμές (web/calendar/
//      ics/online-form) επεξεργάσιμες με μολυβάκι, toggle Ημερολόγιο,
//      ρόλος (Οδηγός/Διαχειριστής/Master) + Ομάδα + Εγκεκριμένος + Διαγραφή
//   3) Καθολικές τιμές πλατφόρμας:
//        - Προμήθεια εφαρμογής, 1η κράτηση (νέο: appCommissionFirstBooking)
//        - +ανά επιπλέον κράτηση ενωμένη σε shuttle
//          (νέο: appCommissionPerExtraShuttleBooking)
//        - Μηνιαία συνδρομή εφαρμογής (υπάρχον: subscription)
//   Το ΠΑΛΙΟ shuttleExtraMinutesPerBooking (λεπτά διαδρομής, ΟΧΙ χρήματα)
//   ΔΕΝ πειράζεται — παραμένει στις Ζώνες & Τιμές όπου ανήκει λογικά.
//
// Πάνω σε: JobService (νέες μέθοδοι commission), _AdminDriverCard λογική
// (αναδιαμορφωμένη σε AdminCard).

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../app_theme.dart';
import 'admin_role_editor.dart';

class GlobalSettingsPage extends StatefulWidget {
  final String masterUid;
  const GlobalSettingsPage({super.key, required this.masterUid});

  @override
  State<GlobalSettingsPage> createState() => _GlobalSettingsPageState();
}

class _GlobalSettingsPageState extends State<GlobalSettingsPage> {
  bool _loadingTenants = true;
  List<Map<String, dynamic>> _tenants = [];
  String? _expandedTenantId; // ποιο tenant row είναι ανοιχτό (inline διαχείριση)

  @override
  void initState() {
    super.initState();
    _loadTenants();
  }

  Future<void> _loadTenants() async {
    try {
      final res =
          await FirebaseFunctions.instance.httpsCallable('listTenants').call();
      final list = (res.data['tenants'] as List?) ?? [];
      if (!mounted) return;
      setState(() {
        _tenants = list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _loadingTenants = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingTenants = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Scaffold(
      backgroundColor: c.scaffold,
      appBar: AppBar(
        title: const Text('Καθολικές ρυθμίσεις'),
        backgroundColor: c.scaffold,
        foregroundColor: c.textMain,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        // Κάτω padding + ύψος Android navigation bar — να μην κρύβεται
        // το τέλος της λίστας (ΤΙΜΕΣ ΠΛΑΤΦΟΡΜΑΣ κλπ).
        padding: EdgeInsets.fromLTRB(
            14, 14, 14,
            30 + MediaQuery.of(context).viewPadding.bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionLabel(c, 'TENANTS'),
            const SizedBox(height: 8),
            _tenantsBlock(c),

            const SizedBox(height: 18),
            _sectionLabel(c, 'ADMINS'),
            const SizedBox(height: 8),
            _adminsBlock(c),

            const SizedBox(height: 18),
            _sectionLabel(c, 'ΤΙΜΕΣ ΠΛΑΤΦΟΡΜΑΣ'),
            const SizedBox(height: 8),
            const _PlatformPricingBlock(),

            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(AppColors c, String text) => Text(text,
      style: TextStyle(
          fontSize: 12, fontWeight: FontWeight.w700, color: c.blueDeep));

  Widget _tenantsBlock(AppColors c) {
    return Container(
      decoration: BoxDecoration(
        color:        c.bluePale,
        borderRadius: BorderRadius.circular(16),
        border:       Border.all(color: c.blueSoft, width: 0.8),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(children: [
        Row(children: [
          Icon(Icons.store_rounded, size: 16, color: c.blueDeep),
          const SizedBox(width: 8),
          Expanded(
            child: Text('Tenants · ${_tenants.length}',
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: c.blueDeep)),
          ),
          // «Νέα Online Φόρμα» — μεταφέρθηκε εδώ από την παλιά σελίδα.
          InkWell(
            borderRadius: BorderRadius.circular(9),
            onTap: _openCreateDialog,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(
                color:        c.blueDeep,
                borderRadius: BorderRadius.circular(9),
              ),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.add_business_rounded, size: 14, color: Colors.white),
                SizedBox(width: 5),
                Text('Νέα',
                    style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: Colors.white)),
              ]),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        if (_loadingTenants)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(
                child: SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))),
          )
        else if (_tenants.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text('Κανένας tenant ακόμη.',
                style: TextStyle(fontSize: 12, color: c.blueFaint)),
          )
        else
          ..._tenants.map((t) => _tenantRow(c, t)),
      ]),
    );
  }

  Widget _tenantRow(AppColors c, Map<String, dynamic> t) {
    // Σωστά πεδία από το listTenants (τα παλιά name/vivaConnected/
    // webhookConfirmed δεν υπήρχαν ποτέ στην απάντηση — γι' αυτό τα pills
    // έδειχναν πάντα ✗).
    final rawName  = (t['businessName'] as String?)?.trim() ?? '';
    final name     = rawName.isEmpty ? '(χωρίς όνομα)' : rawName;
    final tenantId = (t['tenantId'] as String?) ?? '';
    final email    = (t['masterEmail'] as String?) ?? '';
    final active   = t['active'] != false;
    final vivaOk   = t['hasVivaCredentials'] == true;
    final expanded = _expandedTenantId == tenantId;
    final initials = rawName.isEmpty
        ? '??'
        : rawName.split(RegExp(r'\s+')).take(2).map((w) => w[0]).join().toUpperCase();

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(
            () => _expandedTenantId = expanded ? null : tenantId),
        child: Container(
          decoration: BoxDecoration(
            color:        c.card,
            borderRadius: BorderRadius.circular(12),
            border: active
                ? null
                : Border.all(color: const Color(0xFFD64545), width: 1),
          ),
          padding: const EdgeInsets.all(9),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                width: 26, height: 26,
                decoration: BoxDecoration(
                  color:        c.amberSoft,
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Text(initials,
                    style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: c.amberDeep)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name,
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: c.textMain)),
                  if (email.isNotEmpty)
                    Text(email,
                        style: TextStyle(fontSize: 10.5, color: c.textFaint)),
                ]),
              ),
              InkWell(
                onTap: () => _openEditDialog(t),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(Icons.edit_rounded, size: 15, color: c.textFaint),
                ),
              ),
              Icon(expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 18, color: c.textFaint),
            ]),
            if (tenantId.isNotEmpty) ...[
              const SizedBox(height: 5),
              Wrap(spacing: 5, children: [
                _statusPill(c, 'Viva', vivaOk),
                _statusPill(c, active ? 'Ενεργός' : 'Κλειδωμένος', active),
              ]),
            ],

            // ── Ανοιχτό: όλες οι ενέργειες της παλιάς σελίδας ──────────────
            if (expanded) ...[
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: Text(
                      active
                          ? 'Δέχεται νέες online κρατήσεις'
                          : 'ΚΛΕΙΔΩΜΕΝΟΣ — η φόρμα του δεν δέχεται κρατήσεις',
                      style: TextStyle(
                          fontSize: 10.5,
                          color: active
                              ? c.textFaint
                              : const Color(0xFFA32D2D))),
                ),
                Transform.scale(
                  scale: 0.8,
                  child: Switch(
                    value: active,
                    onChanged: (v) => _toggleActive(tenantId, v),
                    activeThumbColor: Colors.white,
                    activeTrackColor: c.green,
                  ),
                ),
              ]),
              const SizedBox(height: 4),
              Row(children: [
                Expanded(
                  child: _actionChip(c,
                      icon: Icons.link_rounded,
                      label: 'Webhook URL',
                      color: c.blueDeep,
                      onTap: () => _copyWebhookUrl(tenantId)),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _actionChip(c,
                      icon: Icons.badge_rounded,
                      label: 'EformID',
                      color: c.blueDeep,
                      onTap: () => _copyEformId(tenantId)),
                ),
              ]),
              const SizedBox(height: 6),
              _actionChip(c,
                  icon: Icons.build_circle_rounded,
                  label: 'Διόρθωση πελατών (π.χ. AIRSTAY)',
                  color: const Color(0xFFA66A00),
                  onTap: () => _fixClientsPrompt(tenantId, name)),
              const SizedBox(height: 6),
              _actionChip(c,
                  icon: Icons.health_and_safety_rounded,
                  label: 'Επισκευή πρόσβασης (permission-denied)',
                  color: const Color(0xFFA32D2D),
                  onTap: () => _repairAccess(tenantId, name, email)),
            ],
          ]),
        ),
      ),
    );
  }

  Widget _actionChip(AppColors c, {
    required IconData icon,
    required String   label,
    required Color    color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(9),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        decoration: BoxDecoration(
          color:        color.withValues(alpha: 0.08),
          border:       Border.all(color: color.withValues(alpha: 0.4), width: 0.8),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: color)),
          ),
        ]),
      ),
    );
  }

  Widget _statusPill(AppColors c, String label, bool ok) {
    final bg = ok ? c.greenPale : const Color(0xFFF6D5D5);
    final fg = ok ? const Color(0xFF3B6D11) : const Color(0xFFA32D2D);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Text('$label ${ok ? "✓" : "✗"}',
          style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700, color: fg)),
    );
  }

  Map<String, dynamic>? _statusForTenant(String? tenantId) {
    if (tenantId == null || tenantId.isEmpty) return null;
    for (final t in _tenants) {
      if (t['tenantId'] == tenantId) return t;
    }
    return null;
  }

  // ═══ Μεταφέρθηκαν από την παλιά TenantAdminPage (η σελίδα καταργήθηκε) ═══

  String _webhookUrlFor(String tenantId) =>
      'https://us-central1-my-taxi-app-bbc7c.cloudfunctions.net/vivaWebhook?tenantId=$tenantId';

  Future<void> _copyWebhookUrl(String tenantId) async {
    final url = _webhookUrlFor(tenantId);
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Αντιγράφηκε: $url'),
        duration: const Duration(seconds: 3),
        backgroundColor: const Color(0xFF1E8E3E),
      ));
    }
  }

  Future<void> _copyEformId(String tenantId) async {
    await Clipboard.setData(ClipboardData(text: tenantId));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Αντιγράφηκε: $tenantId — βάλ\' το στη γραμμή EFORM_ID του booking2.html'),
        duration: const Duration(seconds: 3),
        backgroundColor: Colors.indigo,
      ));
    }
  }

  Future<void> _fixClientsPrompt(String tenantId, String businessName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Διόρθωση πελατών'),
        content: Text(
          'Θα βρεθούν όλοι οι admins/χρήστες του «$businessName» και θα '
          'διορθωθεί το tenantId στους πελάτες (π.χ. AIRSTAY) που έχουν '
          'φτιάξει — χρήσιμο αν κάποιος πελάτης δεν εμφανίζεται στη φόρμα. '
          'Ασφαλές, δεν αγγίζει τίποτα άλλο.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dctx).pop(false), child: const Text('Άκυρο')),
          FilledButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child: const Text('Εκτέλεση'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final callable = FirebaseFunctions.instance.httpsCallable('fixClientsForTenant');
      final res = await callable.call({'tenantId': tenantId});
      final total = res.data['total'] ?? 0;
      final updated = res.data['updated'] ?? 0;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Διορθώθηκαν $updated από $total πελάτες.'),
          backgroundColor: const Color(0xFF1E8E3E),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Σφάλμα: $e'), backgroundColor: Colors.red.shade700));
      }
    }
  }

  Future<void> _toggleActive(String tenantId, bool newActive) async {
    // Αισιόδοξη ενημέρωση UI, με επαναφορά αν αποτύχει.
    setState(() {
      final i = _tenants.indexWhere((t) => t['tenantId'] == tenantId);
      if (i != -1) _tenants[i]['active'] = newActive;
    });
    try {
      final callable = FirebaseFunctions.instance.httpsCallable('setTenantActive');
      await callable.call({'tenantId': tenantId, 'active': newActive});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(newActive
              ? 'Ο πελάτης ενεργοποιήθηκε ξανά.'
              : 'Ο πελάτης απενεργοποιήθηκε — δεν θα δέχεται νέες κρατήσεις.'),
          backgroundColor: newActive ? const Color(0xFF1E8E3E) : Colors.red.shade700,
        ));
      }
    } catch (e) {
      // Επαναφορά αν αποτύχει η κλήση.
      setState(() {
        final i = _tenants.indexWhere((t) => t['tenantId'] == tenantId);
        if (i != -1) _tenants[i]['active'] = !newActive;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Σφάλμα: $e'), backgroundColor: Colors.red.shade700));
      }
    }
  }

  Future<void> _openCreateDialog() async {
    final created = await showDialog<bool>(
      context: context,
      builder: (_) => const _CreateTenantDialog(),
    );
    if (created == true) _loadTenants();
  }

  Future<void> _openEditDialog(Map<String, dynamic> tenant) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => _EditTenantDialog(tenant: tenant),
    );
    if (changed == true) _loadTenants();
  }

  Future<void> _repairAccess(String tenantId, String businessName, String masterEmail) async {
    final emailCtrl = TextEditingController(text: masterEmail);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Επισκευή πρόσβασης'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Θα ξαναμπούν όλα τα δικαιώματα (Διαχειριστής, Ιδιοκτήτης Online '
              'Φόρμας, έγκριση, web) στον λογαριασμό «$businessName» παρακάτω.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: emailCtrl,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Email λογαριασμού προς επισκευή',
                  helperText: 'Άλλαξέ το αν το πρόβλημα το έχει άλλος (π.χ. υπάλληλος), όχι ο ιδιοκτήτης',
                  border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dctx).pop(false), child: const Text('Άκυρο')),
          FilledButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child: const Text('Επισκευή'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final targetEmail = emailCtrl.text.trim();
    try {
      final callable = FirebaseFunctions.instance.httpsCallable('repairTenantOwnerAccess');
      final res = await callable.call({
        'tenantId': tenantId,
        if (targetEmail.isNotEmpty && targetEmail != masterEmail) 'email': targetEmail,
      });
      final saved = (res.data['saved'] as Map?) ?? {};
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (dctx) => AlertDialog(
            title: const Text('Επισκευή ολοκληρώθηκε'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Λογαριασμός: ${res.data['targetEmail'] ?? masterEmail}'),
                const SizedBox(height: 8),
                Text('admin: ${saved['admin']}'),
                Text('tenantOwner: ${saved['tenantOwner']}'),
                Text('isApproved: ${saved['isApproved']}'),
                Text('webEnabled: ${saved['webEnabled']}'),
                Text('tenantId: ${saved['tenantId']}'),
                const SizedBox(height: 12),
                const Text(
                  'Αν όλα δείχνουν true, ζήτησέ του να κάνει ΠΛΗΡΗ αποσύνδεση '
                  '(κουμπί Αποσύνδεση στα Στοιχεία οδηγού) και ξανά σύνδεση. '
                  'Αν συνεχίζει, στείλε μου screenshot αυτού του παραθύρου.',
                  style: TextStyle(fontSize: 12.5),
                ),
              ],
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(dctx).pop(),
                child: const Text('Κατάλαβα'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Σφάλμα: $e'), backgroundColor: Colors.red.shade700));
      }
    }
  }

  Widget _adminsBlock(AppColors c) {
    return Container(
      decoration: BoxDecoration(
        color:        c.bluePale,
        borderRadius: BorderRadius.circular(16),
        border:       Border.all(color: c.blueSoft, width: 0.8),
      ),
      padding: const EdgeInsets.all(10),
      child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance.collection('presence').snapshots(),
        builder: (context, snap) {
          final docs = snap.data?.docs ?? [];
          final sorted = [...docs]..sort((a, b) {
              int rank(Map<String, dynamic> d) {
                if (d['master'] == true) return 0;
                if (d['admin']  == true) return 1;
                return 2;
              }
              return rank(a.data()).compareTo(rank(b.data()));
            });

          return Column(children: [
            Row(children: [
              Icon(Icons.groups_rounded, size: 16, color: c.blueDeep),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Admins · ${sorted.where((d) => d.data()['admin'] == true || d.data()['master'] == true).length}',
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: c.blueDeep)),
              ),
            ]),
            const SizedBox(height: 8),
            if (snap.connectionState == ConnectionState.waiting)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(
                    child: SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))),
              )
            else
              ...sorted.map((doc) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: AdminCard(
                      docId:     doc.id,
                      data:      doc.data(),
                      masterUid: widget.masterUid,
                      isSelf:    doc.id == widget.masterUid,
                      tenantStatus: _statusForTenant(
                          doc.data()['tenantId'] as String?),
                    ),
                  )),
          ]);
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// Κάρτα admin/οδηγού — όλες οι τιμές επεξεργάσιμες με μολυβάκι
// ─────────────────────────────────────────────────────────────────
class AdminCard extends StatelessWidget {
  final String docId;
  final Map<String, dynamic> data;
  final String masterUid;
  final bool   isSelf;
  /// Κατάσταση συνδέσεων του tenant του (από listTenants) — null αν δεν
  /// είναι tenant-owner ή δεν έχουν φορτώσει ακόμη οι tenants.
  final Map<String, dynamic>? tenantStatus;

  const AdminCard({
    super.key,
    required this.docId,
    required this.data,
    required this.masterUid,
    required this.isSelf,
    this.tenantStatus,
  });

  Future<void> _editPrice(BuildContext context, {
    required String field,
    required String label,
    required double current,
  }) async {
    final ctrl = TextEditingController(text: current.toStringAsFixed(2));
    final c = AppColors.of(context);
    final result = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.scaffold,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(label, style: TextStyle(fontSize: 16, color: c.textMain)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(suffixText: '€ / μήνα'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Άκυρο')),
          FilledButton(
            onPressed: () {
              final v = double.tryParse(ctrl.text.trim().replaceAll(',', '.'));
              Navigator.of(ctx).pop(v);
            },
            child: const Text('Αποθήκευση'),
          ),
        ],
      ),
    );
    if (result == null) return;
    await FirebaseFirestore.instance
        .collection('presence')
        .doc(docId)
        .set({field: result}, SetOptions(merge: true));
  }

  Future<void> _toggleField(String field, bool value) async {
    await FirebaseFirestore.instance
        .collection('presence')
        .doc(docId)
        .set({field: value}, SetOptions(merge: true));
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    final name  = '${data['displayName'] ?? ''} ${data['lastName'] ?? ''}'.trim();
    final groupName = (data['managedGroupName'] as String?) ?? '';
    final isMaster  = data['master'] == true;
    final isAdmin   = data['admin']  == true;

    final webEnabled      = data['webEnabled']      == true;
    final calendarEnabled = data['calendarEnabled'] == true;
    final icsEnabled      = data['icsExportEnabled'] == true;
    final tenantOwner     = data['tenantOwner']      == true;

    final webPrice      = (data['webPrice']      as num?)?.toDouble() ?? 0.0;
    final calendarPrice = (data['calendarPrice'] as num?)?.toDouble() ?? 0.0;
    final icsPrice      = (data['icsPrice']      as num?)?.toDouble() ?? 0.0;
    final formPrice      = (data['onlineFormPrice'] as num?)?.toDouble() ?? 0.0;

    final initials = name.isEmpty
        ? '??'
        : name.trim().split(RegExp(r'\s+')).take(2).map((w) => w[0]).join().toUpperCase();

    String roleLabel = isMaster ? 'Master' : (isAdmin ? 'Διαχειριστής' : 'Οδηγός');

    return Container(
      decoration: BoxDecoration(
        color:        c.card,
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.all(11),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 32, height: 32,
            decoration: BoxDecoration(color: c.amberSoft, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: Text(initials,
                style: TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w700, color: c.amberDeep)),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name.isEmpty ? '(χωρίς όνομα)' : name,
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600, color: c.textMain)),
              if (groupName.isNotEmpty)
                Text('Ομάδα: $groupName',
                    style: TextStyle(fontSize: 10.5, color: c.textFaint)),
            ]),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
            decoration: BoxDecoration(
              color:        c.amberSoft,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text(roleLabel,
                style: TextStyle(
                    fontSize: 10.5, fontWeight: FontWeight.w700, color: c.amberDeep)),
          ),
          if (!isSelf) ...[
            const SizedBox(width: 4),
            InkWell(
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => AdminRoleEditorPage(docId: docId, data: data),
              )),
              child: Icon(Icons.edit_rounded, size: 16, color: c.textFaint),
            ),
          ],
        ]),

        if (isAdmin || isMaster) ...[
          const SizedBox(height: 9),
          _priceRow(context, c,
              icon: Icons.public_rounded,
              label: 'Πρόσβαση web app',
              enabled: webEnabled,
              price: webPrice,
              onToggle: (v) => _toggleField('webEnabled', v),
              onEditPrice: () => _editPrice(context,
                  field: 'webPrice', label: 'Πρόσβαση web app', current: webPrice)),
          _priceRow(context, c,
              icon: Icons.calendar_month_rounded,
              label: 'Ημερολόγιο Google',
              enabled: calendarEnabled,
              price: calendarPrice,
              onToggle: (v) => _toggleField('calendarEnabled', v),
              onEditPrice: () => _editPrice(context,
                  field: 'calendarPrice', label: 'Ημερολόγιο Google', current: calendarPrice)),
          _priceRow(context, c,
              icon: Icons.event_available_rounded,
              label: 'Δουλειές στο ημερολόγιό μου',
              enabled: icsEnabled,
              price: icsPrice,
              onToggle: (v) => _toggleField('icsExportEnabled', v),
              onEditPrice: () => _editPrice(context,
                  field: 'icsPrice', label: 'Δουλειές στο ημερολόγιό μου', current: icsPrice)),

          const SizedBox(height: 6),
          _onlineFormBlock(context, c,
              tenantOwner: tenantOwner, formPrice: formPrice),
        ],
      ]),
    );
  }

  Widget _priceRow(BuildContext context, AppColors c, {
    required IconData icon,
    required String   label,
    required bool     enabled,
    required double   price,
    required ValueChanged<bool> onToggle,
    required VoidCallback onEditPrice,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Icon(icon, size: 15, color: c.textFaint),
        const SizedBox(width: 8),
        Expanded(
          child: Text(label, style: TextStyle(fontSize: 12, color: c.textMain)),
        ),
        Text('${price.toStringAsFixed(0)}€/μήνα',
            style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: c.blueDeep)),
        InkWell(
          onTap: onEditPrice,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5),
            child: Icon(Icons.edit_rounded, size: 12, color: c.blueFaint),
          ),
        ),
        Switch(
          value: enabled,
          onChanged: onToggle,
          activeThumbColor: Colors.white,
          activeTrackColor: c.green,
        ),
      ]),
    );
  }

  Widget _onlineFormBlock(BuildContext context, AppColors c, {
    required bool   tenantOwner,
    required double formPrice,
  }) {
    final tenantId = (data['tenantId'] as String?) ?? '';
    // Πραγματικές καταστάσεις από το listTenants (Secret Manager) — τα
    // παλιά flags του presence δεν τα έγραφε ποτέ κανείς, γι' αυτό δεν
    // έδειχνε τίποτα (π.χ. Σερέτης με live Viva). Κρατάμε τα presence
    // flags μόνο ως fallback.
    final ts = tenantStatus;
    final vivaConnected   = (ts?['hasVivaCredentials'] == true) ||
        data['vivaConnected'] == true;
    final vivaDemo        = ts?['vivaDemo'] == true;
    final stripeConnected = ts?['hasStripeCredentials'] == true;
    final activeProvider  = ts?['paymentProvider'] as String?;
    final googleOwnKey    = (ts?['hasMapsApiKey'] == true) ||
        data['googleOwnKeyConnected'] == true;
    final resendConnected = (ts?['resendConnected'] == true) ||
        data['resendConnected'] == true;
    final hasOwnResend    = ts?['hasOwnResendKey'] == true;
    final invoiceProvider = ts?['invoiceProvider'] as String?;
    final invoiceEnabled  = ts?['invoiceEnabled'] == true;
    final hasReceiptCreds = ts?['hasReceiptCredentials'] == true;
    // Auto-email: αν χρησιμοποιεί το ΔΙΚΟ ΜΑΣ Resend, ο διακόπτης είναι
    // by-default ενεργός αλλά χειροκίνητος. Αν συνδέσει ΔΙΚΟ ΤΟΥ Resend
    // key, ο διακόπτης "κλειδώνει" ενεργός (η δική του υπηρεσία στέλνει
    // πλέον τα emails — δεν υπάρχει λόγος να το σβήσει).
    final autoEmailEnabled = (data['autoEmailEnabled'] as bool?) ?? true;

    return Container(
      decoration: BoxDecoration(
        color:        c.bluePale,
        border:       Border.all(color: c.blue, width: 1.3),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(9, 8, 9, 8),
          child: Row(children: [
            Icon(Icons.dvr_rounded, size: 15, color: c.blueDeep),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Online φόρμα κράτησης',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: c.blueDeep)),
            ),
            Text('${formPrice.toStringAsFixed(0)}€/μήνα',
                style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: c.blueDeep)),
            InkWell(
              onTap: () => _editPrice(context,
                  field: 'onlineFormPrice',
                  label: 'Online φόρμα κράτησης',
                  current: formPrice),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5),
                child: Icon(Icons.edit_rounded, size: 12, color: c.blueFaint),
              ),
            ),
            Switch(
              value: tenantOwner,
              onChanged: (v) => _toggleField('tenantOwner', v),
              activeThumbColor: Colors.white,
              activeTrackColor: c.blue,
            ),
          ]),
        ),
        if (tenantOwner) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(9, 0, 9, 9),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // ── Στοιχεία tenant (μεταφέρθηκαν από την παλιά σελίδα) ──
              if (ts != null) ...[
                Text(((ts['businessName'] as String?) ?? '').isEmpty
                        ? '(χωρίς όνομα επιχείρησης)'
                        : (ts['businessName'] as String),
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        color: c.textMain)),
                if (((ts['masterEmail'] as String?) ?? '').isNotEmpty)
                  Text(ts['masterEmail'] as String,
                      style: TextStyle(fontSize: 11, color: c.textFaint)),
                Text('eformId: $tenantId',
                    style: TextStyle(fontSize: 10, color: c.blueFaint)),
                const SizedBox(height: 5),
              ],

              // ── Status συνδέσεων (δικές μας ή δικές του) ──
              if (vivaConnected)
                _statusLine(c, Icons.credit_card_rounded,
                    'Viva συνδεδεμένη (${vivaDemo ? "demo" : "live"})'
                    '${activeProvider == 'viva' && stripeConnected ? ' · ενεργός πάροχος' : ''}'),
              if (stripeConnected)
                _statusLine(c, Icons.credit_card_rounded,
                    'Stripe συνδεδεμένο'
                    '${activeProvider == 'stripe' ? ' · ενεργός πάροχος' : ''}'),
              if (googleOwnKey)
                _statusLine(c, Icons.vpn_key_rounded, 'Google Console συνδεδεμένη'),
              // Resend: ξεχωρίζουμε ΔΙΚΟ ΤΟΥ κλειδί από το ΔΙΚΟ ΜΑΣ
              // (κοινό) — πριν έγραφε «συνδεδεμένο» ενώ ήταν το δικό μας.
              if (hasOwnResend)
                _statusLine(c, Icons.mail_rounded,
                    'Resend email συνδεδεμένο (δικό του κλειδί)')
              else if (resendConnected)
                _statusLineInfo(c, Icons.mail_rounded,
                    'Auto-email μέσω του δικού μας Resend'),
              // ── Αποδείξεις (myDATA / Epsilon / Oxygen) ──
              if (invoiceProvider != null)
                hasReceiptCreds
                    ? _statusLine(c, Icons.receipt_long_rounded,
                        'Αποδείξεις: ${_receiptName(invoiceProvider)} '
                        'συνδεδεμένο${invoiceEnabled ? '' : ' (ανενεργό)'}')
                    : _statusLineWarn(c, Icons.receipt_long_rounded,
                        'Αποδείξεις: ${_receiptName(invoiceProvider)} — '
                        'λείπει κλειδί'),

              if (tenantId.isNotEmpty) ...[
                const SizedBox(height: 6),
                Row(children: [
                  Expanded(child: _copyChip(context, c, 'Webhook URL', Icons.link_rounded,
                      'https://us-central1-my-taxi-app-bbc7c.cloudfunctions.net/vivaWebhook?tenantId=$tenantId')),
                  const SizedBox(width: 6),
                  Expanded(child: _copyChip(context, c, 'EformID', Icons.badge_rounded, tenantId)),
                ]),
              ],

              // ── Χάρτης/Places: ΔΙΚΑ ΜΑΣ keys — απενεργοποιούνται
              //    αυτόματα (μη επεξεργάσιμα) αν ο tenant έχει συνδέσει
              //    ΔΙΚΟ ΤΟΥ Google key. ΔΕΝ μπορεί να τα ενεργοποιήσει
              //    πίσω από εδώ — αν θέλει επιστροφή, σβήνει ο ίδιος το
              //    δικό του key από τη ρίζα (Google Console).
              const SizedBox(height: 6),
              Opacity(
                opacity: googleOwnKey ? 0.5 : 1,
                child: Row(children: [
                  Expanded(
                    child: _miniToggleRow(c,
                        icon: Icons.map_rounded,
                        label: googleOwnKey ? 'Χάρτης (δικό μας key)' : 'Χάρτης',
                        value: (data['mapKeyEnabled'] as bool?) ?? true,
                        locked: googleOwnKey,
                        onChanged: googleOwnKey
                            ? null
                            : (v) => _toggleField('mapKeyEnabled', v)),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _miniToggleRow(c,
                        icon: Icons.location_on_rounded,
                        label: googleOwnKey ? 'Places (δικό μας key)' : 'Places',
                        value: (data['placesKeyEnabled'] as bool?) ?? true,
                        locked: googleOwnKey,
                        onChanged: googleOwnKey
                            ? null
                            : (v) => _toggleField('placesKeyEnabled', v)),
                  ),
                ]),
              ),
              if (googleOwnKey)
                Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: Text(
                    '⚠ Έχει δικό του Google key — αν το σβήσει χωρίς να '
                    'ενεργοποιήσει ξανά τα δικά μας, χάρτης/αναζήτηση θα '
                    'σταματήσουν να δουλεύουν.',
                    style: TextStyle(fontSize: 9.5, color: const Color(0xFFA66A00)),
                  ),
                ),

              // ── Auto-email ──
              const SizedBox(height: 6),
              Row(children: [
                Icon(Icons.forward_to_inbox_rounded, size: 13, color: c.blueDeep),
                const SizedBox(width: 7),
                Expanded(
                  child: Text('Auto-email επιβεβαίωσης πελάτη',
                      style: TextStyle(fontSize: 11, color: c.blueDeep)),
                ),
                Switch(
                  value: autoEmailEnabled,
                  // Αν χρησιμοποιεί ΔΙΚΟ ΤΟΥ Resend, ο διακόπτης είναι
                  // μόνιμα ενεργός — δεν έχει νόημα να τον σβήσει αφού
                  // πλέον η υπηρεσία του κάνει τη δουλειά ούτως ή άλλως.
                  onChanged: hasOwnResend
                      ? null
                      : (v) => _toggleField('autoEmailEnabled', v),
                  activeThumbColor: Colors.white,
                  activeTrackColor: c.blue,
                ),
              ]),
            ]),
          ),
        ],
      ]),
    );
  }

  String _receiptName(String p) => p == 'mydata'
      ? 'myDATA'
      : p == 'epsilon'
          ? 'Epsilon Smart'
          : p == 'oxygen'
              ? 'Oxygen'
              : p;

  Widget _statusLineInfo(AppColors c, IconData icon, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Row(children: [
          Icon(icon, size: 12, color: c.textFaint),
          const SizedBox(width: 5),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: c.textFaint)),
          ),
        ]),
      );

  Widget _statusLineWarn(AppColors c, IconData icon, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Row(children: [
          Icon(icon, size: 12, color: const Color(0xFFA66A00)),
          const SizedBox(width: 5),
          Expanded(
            child: Text(text,
                style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFFA66A00))),
          ),
        ]),
      );

  Widget _statusLine(AppColors c, IconData icon, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Row(children: [
          Icon(icon, size: 12, color: const Color(0xFF3B6D11)),
          const SizedBox(width: 5),
          Text(text,
              style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: const Color(0xFF3B6D11))),
        ]),
      );

  Widget _copyChip(BuildContext context, AppColors c, String label, IconData icon, String value) {
    return InkWell(
      borderRadius: BorderRadius.circular(9),
      onTap: () {
        Clipboard.setData(ClipboardData(text: value));
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Αντιγράφηκε: $label'),
          backgroundColor: const Color(0xFF1E8E3E),
        ));
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color:        c.card,
          border:       Border.all(color: c.blueSoft, width: 0.8),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 12, color: c.blueDeep),
          const SizedBox(width: 5),
          Flexible(
            child: Text(label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10, color: c.blueDeep)),
          ),
          const SizedBox(width: 4),
          Icon(Icons.copy_rounded, size: 11, color: c.blueFaint),
        ]),
      ),
    );
  }

  Widget _miniToggleRow(AppColors c, {
    required IconData icon,
    required String   label,
    required bool     value,
    required bool     locked,
    required ValueChanged<bool>? onChanged,
  }) {
    return Container(
      decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(9)),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(children: [
        Icon(icon, size: 13, color: c.textFaint),
        const SizedBox(width: 6),
        Expanded(
          child: Text(label,
              style: TextStyle(fontSize: 10, color: c.textMain),
              overflow: TextOverflow.ellipsis),
        ),
        if (locked)
          Text('—', style: TextStyle(fontSize: 11, color: c.textFaint))
        else
          Transform.scale(
            scale: 0.7,
            child: Switch(
              value: value,
              onChanged: onChanged,
              activeThumbColor: Colors.white,
              activeTrackColor: c.green,
            ),
          ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// Καθολικές τιμές πλατφόρμας — commission/subscription
// ─────────────────────────────────────────────────────────────────
class _PlatformPricingBlock extends StatefulWidget {
  const _PlatformPricingBlock();

  @override
  State<_PlatformPricingBlock> createState() => _PlatformPricingBlockState();
}

class _PlatformPricingBlockState extends State<_PlatformPricingBlock> {
  bool _loading = true;
  double _firstBooking   = 0.60;
  double _extraShuttle   = 0.10;
  double _subscription   = 5.00;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('app_settings').doc('config').get();
      final d = doc.data();
      if (!mounted) return;
      setState(() {
        _firstBooking = (d?['appCommissionFirstBooking'] as num?)?.toDouble()
            // fallback στο παλιό σταθερό appCommission αν δεν έχει οριστεί ακόμη
            ?? (d?['appCommission'] as num?)?.toDouble() ?? 0.60;
        _extraShuttle = (d?['appCommissionPerExtraShuttleBooking'] as num?)
                ?.toDouble() ?? 0.10;
        _subscription = (d?['subscription'] as num?)?.toDouble() ?? 5.00;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _editValue({
    required String field,
    required String label,
    required double current,
    required String suffix,
    required void Function(double) applyLocal,
  }) async {
    final c = AppColors.of(context);
    final ctrl = TextEditingController(text: current.toStringAsFixed(2));
    final result = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.scaffold,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(label, style: TextStyle(fontSize: 15, color: c.textMain)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(suffixText: suffix),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Άκυρο')),
          FilledButton(
            onPressed: () {
              final v = double.tryParse(ctrl.text.trim().replaceAll(',', '.'));
              Navigator.of(ctx).pop(v);
            },
            child: const Text('Αποθήκευση'),
          ),
        ],
      ),
    );
    if (result == null) return;
    await FirebaseFirestore.instance
        .collection('app_settings')
        .doc('config')
        .set({field: result}, SetOptions(merge: true));
    setState(() => applyLocal(result));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Η ρύθμιση αποθηκεύτηκε'),
        backgroundColor: Color(0xFF1E8E3E),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return Container(
      decoration: BoxDecoration(
        color:        c.bluePale,
        border:       Border.all(color: c.blueSoft, width: 0.8),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(children: [
        _row(
          c,
          icon:  Icons.tune_rounded,
          label: 'Προμήθεια εφαρμογής — 1η κράτηση',
          value: '${_firstBooking.toStringAsFixed(2)} €',
          onTap: () => _editValue(
            field: 'appCommissionFirstBooking',
            label: 'Προμήθεια — 1η κράτηση',
            current: _firstBooking,
            suffix: '€',
            applyLocal: (v) => _firstBooking = v,
          ),
        ),
        Divider(height: 1, color: c.blueSoft),
        _row(
          c,
          icon:  Icons.layers_rounded,
          label: 'Κάθε επιπλέον κράτηση σε shuttle',
          value: '+${_extraShuttle.toStringAsFixed(2)} €',
          onTap: () => _editValue(
            field: 'appCommissionPerExtraShuttleBooking',
            label: 'Επιπλέον κράτηση σε shuttle',
            current: _extraShuttle,
            suffix: '€',
            applyLocal: (v) => _extraShuttle = v,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'π.χ. 2 κρατήσεις σε 1 shuttle = '
              '${(_firstBooking + _extraShuttle).toStringAsFixed(2)}€ · '
              '3 κρατήσεις = ${(_firstBooking + _extraShuttle * 2).toStringAsFixed(2)}€',
              style: TextStyle(fontSize: 10, color: c.blueFaint),
            ),
          ),
        ),
        Divider(height: 1, color: c.blueSoft),
        _row(
          c,
          icon:  Icons.smartphone_rounded,
          label: 'Μηνιαία συνδρομή εφαρμογής',
          value: '${_subscription.toStringAsFixed(2)} €',
          onTap: () => _editValue(
            field: 'subscription',
            label: 'Μηνιαία συνδρομή εφαρμογής',
            current: _subscription,
            suffix: '€ / μήνα',
            applyLocal: (v) => _subscription = v,
          ),
        ),
      ]),
    );
  }

  Widget _row(AppColors c, {
    required IconData icon,
    required String   label,
    required String   value,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(children: [
        Icon(icon, size: 16, color: c.blueDeep),
        const SizedBox(width: 9),
        Expanded(
          child: Text(label, style: TextStyle(fontSize: 12.5, color: c.blueDeep)),
        ),
        Text(value,
            style: TextStyle(
                fontSize: 13, fontWeight: FontWeight.w700, color: c.blueDeep)),
        InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Icon(Icons.edit_rounded, size: 14, color: c.blueFaint),
          ),
        ),
      ]),
    );
  }
}

// ═══ Dialogs δημιουργίας/επεξεργασίας tenant — μεταφέρθηκαν από την
// παλιά TenantAdminPage (η σελίδα καταργήθηκε) ═══

class _CreateTenantDialog extends StatefulWidget {
  const _CreateTenantDialog();

  @override
  State<_CreateTenantDialog> createState() => _CreateTenantDialogState();
}

class _CreateTenantDialogState extends State<_CreateTenantDialog> {
  final _formKey = GlobalKey<FormState>();
  final _businessNameCtrl = TextEditingController();
  final _masterEmailCtrl = TextEditingController();
  final _tenantIdCtrl = TextEditingController();
  final _vivaClientIdCtrl = TextEditingController();
  final _vivaClientSecretCtrl = TextEditingController();
  final _vivaMerchantIdCtrl = TextEditingController();
  final _vivaApiKeyCtrl = TextEditingController();
  final _vivaSourceCodeCtrl = TextEditingController();
  bool _vivaDemo = true;
  bool _showVivaFields = false;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _businessNameCtrl.dispose();
    _masterEmailCtrl.dispose();
    _tenantIdCtrl.dispose();
    _vivaClientIdCtrl.dispose();
    _vivaClientSecretCtrl.dispose();
    _vivaMerchantIdCtrl.dispose();
    _vivaApiKeyCtrl.dispose();
    _vivaSourceCodeCtrl.dispose();
    super.dispose();
  }

  // Μετατρέπει «Rhodes Taxi» → «rhodes_taxi» — βοηθητική προεπιλογή, ο χρήστης
  // μπορεί να το αλλάξει ελεύθερα πριν την υποβολή.
  void _suggestTenantId() {
    if (_tenantIdCtrl.text.trim().isNotEmpty) return;
    final slug = _businessNameCtrl.text
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s]'), '')
        .replaceAll(RegExp(r'\s+'), '_');
    _tenantIdCtrl.text = slug;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _submitting = true; _error = null; });
    try {
      final callable = FirebaseFunctions.instance.httpsCallable('createTenant');
      await callable.call({
        'tenantId': _tenantIdCtrl.text.trim(),
        'businessName': _businessNameCtrl.text.trim(),
        'masterEmail': _masterEmailCtrl.text.trim(),
        if (_vivaClientIdCtrl.text.trim().isNotEmpty)
          'vivaClientId': _vivaClientIdCtrl.text.trim(),
        if (_vivaClientSecretCtrl.text.trim().isNotEmpty)
          'vivaClientSecret': _vivaClientSecretCtrl.text.trim(),
        if (_vivaMerchantIdCtrl.text.trim().isNotEmpty)
          'vivaMerchantId': _vivaMerchantIdCtrl.text.trim(),
        if (_vivaApiKeyCtrl.text.trim().isNotEmpty)
          'vivaApiKey': _vivaApiKeyCtrl.text.trim(),
        if (_vivaSourceCodeCtrl.text.trim().isNotEmpty)
          'vivaSourceCode': _vivaSourceCodeCtrl.text.trim(),
        'vivaDemo': _vivaDemo,
      });
      if (mounted) Navigator.of(context).pop(true);
    } on FirebaseFunctionsException catch (e) {
      setState(() => _error = e.message ?? e.code);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Form(
            key: _formKey,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Νέα Online Φόρμα',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(
                    'Ο πελάτης πρέπει να έχει ήδη κάνει τουλάχιστον ένα login '
                    'στην εφαρμογή πριν συμπληρώσεις τη φόρμα.',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                  const SizedBox(height: 16),

                  TextFormField(
                    controller: _businessNameCtrl,
                    onChanged: (_) => _suggestTenantId(),
                    decoration: const InputDecoration(
                        labelText: 'Όνομα επιχείρησης *',
                        border: OutlineInputBorder()),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Υποχρεωτικό' : null,
                  ),
                  const SizedBox(height: 12),

                  TextFormField(
                    controller: _masterEmailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                        labelText: 'Email πελάτη (ήδη έχει κάνει login) *',
                        border: OutlineInputBorder()),
                    validator: (v) => (v == null || !v.contains('@'))
                        ? 'Έγκυρο email' : null,
                  ),
                  const SizedBox(height: 12),

                  TextFormField(
                    controller: _tenantIdCtrl,
                    decoration: const InputDecoration(
                        labelText: 'Αναγνωριστικό (EformID) *',
                        helperText: 'Μόνο λατινικά/αριθμοί/underscore, μοναδικό',
                        border: OutlineInputBorder()),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) return 'Υποχρεωτικό';
                      if (!RegExp(r'^[a-z0-9_]+$').hasMatch(v.trim())) {
                        return 'Μόνο a-z, 0-9, _';
                      }
                      if (v.trim() == 'default') return '"default" είναι δεσμευμένο';
                      return null;
                    },
                  ),
                  const SizedBox(height: 8),

                  TextButton.icon(
                    onPressed: () => setState(() => _showVivaFields = !_showVivaFields),
                    icon: Icon(_showVivaFields
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded),
                    label: Text(_showVivaFields
                        ? 'Απόκρυψη στοιχείων Viva'
                        : 'Στοιχεία Viva (προαιρετικά τώρα)'),
                  ),
                  if (_showVivaFields) ...[
                    TextFormField(
                      controller: _vivaClientIdCtrl,
                      decoration: const InputDecoration(
                          labelText: 'Viva Client ID', border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _vivaClientSecretCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(
                          labelText: 'Viva Client Secret', border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _vivaMerchantIdCtrl,
                      decoration: const InputDecoration(
                          labelText: 'Viva Merchant ID', border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _vivaApiKeyCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(
                          labelText: 'Viva API Key', border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _vivaSourceCodeCtrl,
                      decoration: const InputDecoration(
                          labelText: 'Viva Source Code (4ψήφιο)',
                          border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 10),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Demo λογαριασμός Viva'),
                      value: _vivaDemo,
                      onChanged: (v) => setState(() => _vivaDemo = v),
                    ),
                  ],

                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
                  ],

                  const SizedBox(height: 18),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: _submitting
                            ? null
                            : () => Navigator.of(context).pop(false),
                        child: const Text('Άκυρο'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: _submitting ? null : _submit,
                        child: _submitting
                            ? const SizedBox(
                                width: 18, height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2))
                            : const Text('Δημιουργία'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Dialog επεξεργασίας υπάρχοντος tenant — Όνομα/Email/EformID
// ─────────────────────────────────────────────────────────────────────────
class _EditTenantDialog extends StatefulWidget {
  final Map<String, dynamic> tenant;
  const _EditTenantDialog({required this.tenant});

  @override
  State<_EditTenantDialog> createState() => _EditTenantDialogState();
}

class _EditTenantDialogState extends State<_EditTenantDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _businessNameCtrl;
  late final TextEditingController _masterEmailCtrl;
  late final TextEditingController _tenantIdCtrl;
  late final String _originalTenantId;
  late final String _originalBusinessName;
  late final String _originalEmail;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _originalTenantId = widget.tenant['tenantId'] as String? ?? '';
    _originalBusinessName = widget.tenant['businessName'] as String? ?? '';
    _originalEmail = widget.tenant['masterEmail'] as String? ?? '';
    _businessNameCtrl = TextEditingController(text: _originalBusinessName);
    _masterEmailCtrl = TextEditingController(text: _originalEmail);
    _tenantIdCtrl = TextEditingController(text: _originalTenantId);
  }

  @override
  void dispose() {
    _businessNameCtrl.dispose();
    _masterEmailCtrl.dispose();
    _tenantIdCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _submitting = true; _error = null; });
    try {
      final newBusinessName = _businessNameCtrl.text.trim();
      final newEmail = _masterEmailCtrl.text.trim();
      final newTenantId = _tenantIdCtrl.text.trim();

      // 1) Όνομα/Email — απλή ενημέρωση πεδίων.
      if (newBusinessName != _originalBusinessName || newEmail != _originalEmail) {
        final callable = FirebaseFunctions.instance.httpsCallable('updateTenantOwnerInfo');
        await callable.call({
          'tenantId': _originalTenantId,
          if (newBusinessName != _originalBusinessName) 'businessName': newBusinessName,
          if (newEmail != _originalEmail) 'masterEmail': newEmail,
        });
      }

      // 2) EformID — πιο ευαίσθητη αλλαγή (είναι το ίδιο το document ID,
      // χρησιμοποιείται στο webhook URL, στο booking2.html, στα secrets).
      if (newTenantId != _originalTenantId) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dctx) => AlertDialog(
            title: const Text('Αλλαγή EformID'),
            content: Text(
              'Το EformID «$_originalTenantId» θα γίνει «$newTenantId».\n\n'
              'Αν ο πελάτης έχει ήδη βάλει το παλιό webhook URL στο Viva dashboard '
              'ή το παλιό EformID στο booking2.html, θα χρειαστεί να τα ενημερώσεις '
              'ξανά μετά την αλλαγή. Ασφαλές μόνο αν ο tenant δεν έχει ακόμα '
              'πραγματικές δουλειές/πελάτες/χρεώσεις.',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(dctx).pop(false), child: const Text('Άκυρο')),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () => Navigator.of(dctx).pop(true),
                child: const Text('Συνέχεια'),
              ),
            ],
          ),
        );
        if (confirmed != true) {
          if (mounted) setState(() => _submitting = false);
          return;
        }
        final renameCallable = FirebaseFunctions.instance.httpsCallable('renameTenantEformId');
        await renameCallable.call({
          'tenantId': _originalTenantId,
          'newTenantId': newTenantId,
        });
      }

      if (mounted) Navigator.of(context).pop(true);
    } on FirebaseFunctionsException catch (e) {
      setState(() => _error = e.message ?? e.code);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Form(
            key: _formKey,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Επεξεργασία Online Φόρμας',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),

                  TextFormField(
                    controller: _businessNameCtrl,
                    decoration: const InputDecoration(
                        labelText: 'Όνομα επιχείρησης *', border: OutlineInputBorder()),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Υποχρεωτικό' : null,
                  ),
                  const SizedBox(height: 12),

                  TextFormField(
                    controller: _masterEmailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                        labelText: 'Email πελάτη *',
                        helperText: 'Αν το αλλάξεις, ο πελάτης πρέπει να έχει ήδη κάνει login με το νέο email',
                        border: OutlineInputBorder()),
                    validator: (v) => (v == null || !v.contains('@'))
                        ? 'Έγκυρο email' : null,
                  ),
                  const SizedBox(height: 12),

                  TextFormField(
                    controller: _tenantIdCtrl,
                    decoration: const InputDecoration(
                        labelText: 'Αναγνωριστικό (EformID) *',
                        helperText: 'Μόνο λατινικά/αριθμοί/underscore — άλλαξέ το μόνο για διόρθωση typo',
                        border: OutlineInputBorder()),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) return 'Υποχρεωτικό';
                      if (!RegExp(r'^[a-z0-9_]+$').hasMatch(v.trim())) {
                        return 'Μόνο a-z, 0-9, _';
                      }
                      if (v.trim() == 'default') return '"default" είναι δεσμευμένο';
                      return null;
                    },
                  ),

                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
                  ],

                  const SizedBox(height: 18),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: _submitting
                            ? null
                            : () => Navigator.of(context).pop(false),
                        child: const Text('Άκυρο'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: _submitting ? null : _submit,
                        child: _submitting
                            ? const SizedBox(
                                width: 18, height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2))
                            : const Text('Αποθήκευση'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Μία γραμμή οδηγιών «πού το βάζεις» — «Ετικέτα: κείμενο» ─────────────────

