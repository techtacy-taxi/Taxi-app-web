// lib/masters/global_settings_page.dart
//
// «ΚΑΘΟΛΙΚΕΣ ΡΥΘΜΙΣΕΙΣ» (πρώην «Διαχειριστές» / masters_admin_page) —
// master-only, ενοποιεί σε ΜΙΑ οθόνη:
//   1) Tenants — λίστα με status Viva/Webhook, tap → TenantAdminPage
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
// Πάνω σε: JobService (νέες μέθοδοι commission), TenantAdminPage
// (αμετάβλητο), _AdminDriverCard λογική (αναδιαμορφωμένη σε AdminCard).

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../app_theme.dart';
import '../tenants/tenant_admin_page.dart';
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
        padding: const EdgeInsets.all(14),
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
          InkWell(
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const TenantAdminPage(),
            )),
            child: Icon(Icons.add_rounded, size: 18, color: c.blueDeep),
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
    final name       = (t['name'] as String?) ?? '(χωρίς όνομα)';
    final tenantId   = (t['tenantId'] as String?) ?? '';
    final vivaOk     = t['vivaConnected'] == true;
    final webhookOk  = t['webhookConfirmed'] == true;
    final initials = name.trim().isEmpty
        ? '??'
        : name.trim().split(RegExp(r'\s+')).take(2).map((w) => w[0]).join().toUpperCase();

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => const TenantAdminPage(),
        )),
        child: Container(
          decoration: BoxDecoration(
            color:        c.card,
            borderRadius: BorderRadius.circular(12),
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
                child: Text(name,
                    style: TextStyle(fontSize: 12.5, color: c.textMain)),
              ),
              Icon(Icons.chevron_right_rounded, size: 16, color: c.textFaint),
            ]),
            if (tenantId.isNotEmpty) ...[
              const SizedBox(height: 5),
              Wrap(spacing: 5, children: [
                _statusPill(c, 'Viva', vivaOk),
                _statusPill(c, 'Webhook', webhookOk),
              ]),
            ],
          ]),
        ),
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
              if (resendConnected)
                _statusLine(c, Icons.mail_rounded, 'Resend email συνδεδεμένο'),
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
                  onChanged: resendConnected
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
