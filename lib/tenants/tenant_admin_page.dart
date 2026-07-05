// lib/tenants/tenant_admin_page.dart
//
// Διαχείριση multi-tenant πελατών (Φάση 1). ΟΡΑΤΗ ΜΟΝΟ στον super-admin
// (techtacy@gmail.com) — ο ίδιος έλεγχος με τα Firestore rules. Κάθε άλλος
// χρήστης που προσπαθήσει να την ανοίξει βλέπει μήνυμα «Δεν έχεις πρόσβαση».
//
// Λειτουργίες:
//   • Λίστα όλων των tenants (listTenants Cloud Function)
//   • Δημιουργία νέου tenant (createTenant Cloud Function)
//   • Ενεργοποίηση/Απενεργοποίηση tenant — «κλείδωμα» πελάτη που δεν
//     πληρώνει, χωρίς να διαγράφονται τα δεδομένα του (setTenantActive)
//
// Πλοήγηση εδώ: πρόσθεσε όπου θες ένα κουμπί/menu item που κάνει:
//   Navigator.push(context, MaterialPageRoute(builder: (_) => const TenantAdminPage()));
// Θα εμφανιστεί μόνο το περιεχόμενο — αν δεν είσαι ο super-admin, βλέπεις
// απλά μια οθόνη «Δεν έχεις πρόσβαση» (καμία διαρροή πληροφορίας).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';

const String kSuperAdminEmail = 'techtacy@gmail.com';

class TenantAdminPage extends StatefulWidget {
  const TenantAdminPage({super.key});

  @override
  State<TenantAdminPage> createState() => _TenantAdminPageState();
}

class _TenantAdminPageState extends State<TenantAdminPage> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _tenants = [];

  bool get _isSuperAdmin =>
      FirebaseAuth.instance.currentUser?.email == kSuperAdminEmail;

  @override
  void initState() {
    super.initState();
    if (_isSuperAdmin) _loadTenants();
  }

  Future<void> _loadTenants() async {
    setState(() { _loading = true; _error = null; });
    try {
      final callable = FirebaseFunctions.instance.httpsCallable('listTenants');
      final res = await callable.call();
      final list = (res.data['tenants'] as List?) ?? [];
      setState(() {
        _tenants = list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _loading = false;
      });
    } catch (e) {
      setState(() { _error = 'Σφάλμα φόρτωσης: $e'; _loading = false; });
    }
  }

  // Το ακριβές URL που πρέπει να καταχωρήσει ο πελάτης στο ΔΙΚΟ ΤΟΥ Viva
  // dashboard (Settings → API Access → Webhooks) — το ?tenantId=... στο
  // τέλος είναι ΑΠΑΡΑΙΤΗΤΟ ώστε το vivaWebhook να ξέρει ποια credentials
  // να χρησιμοποιήσει για την επαλήθευση.
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

  @override
  Widget build(BuildContext context) {
    // ── Ασφάλεια: κανείς άλλος δεν βλέπει τίποτα από αυτή τη σελίδα ──
    if (!_isSuperAdmin) {
      return Scaffold(
        appBar: AppBar(title: const Text('Πελάτες (Tenants)')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text('Δεν έχεις πρόσβαση σε αυτή τη σελίδα.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: Colors.grey)),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Πελάτες (Tenants)'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loadTenants,
            tooltip: 'Ανανέωση',
          ),
        ],
      ),
      // SafeArea ώστε το FAB να μην κρύβεται πίσω από το κάτω navigation bar
      // Android σε συσκευές με gesture bar.
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(child: Text(_error!, style: const TextStyle(color: Colors.red)))
                : RefreshIndicator(
                    onRefresh: _loadTenants,
                    child: _tenants.isEmpty
                        ? ListView(
                            children: const [
                              SizedBox(height: 80),
                              Center(
                                  child: Text('Δεν υπάρχουν ακόμα άλλοι πελάτες.',
                                      style: TextStyle(color: Colors.grey))),
                            ],
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
                            itemCount: _tenants.length,
                            itemBuilder: (context, i) {
                              final t = _tenants[i];
                              final active = t['active'] == true;
                              return Card(
                                margin: const EdgeInsets.only(bottom: 10),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                    side: BorderSide(
                                        color: active
                                            ? Colors.grey.shade200
                                            : Colors.red.shade200)),
                                child: Padding(
                                  padding: const EdgeInsets.all(14),
                                  child: Row(children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(t['businessName'] ?? '',
                                              style: const TextStyle(
                                                  fontSize: 16, fontWeight: FontWeight.bold)),
                                          const SizedBox(height: 3),
                                          Text(t['masterEmail'] ?? '',
                                              style: TextStyle(
                                                  fontSize: 12.5, color: Colors.grey[600])),
                                          const SizedBox(height: 3),
                                          Text('tenantId: ${t['tenantId']}',
                                              style: TextStyle(
                                                  fontSize: 11, color: Colors.grey[400])),
                                          const SizedBox(height: 6),
                                          Row(children: [
                                            Icon(
                                                t['hasVivaCredentials'] == true
                                                    ? Icons.check_circle_rounded
                                                    : Icons.warning_amber_rounded,
                                                size: 14,
                                                color: t['hasVivaCredentials'] == true
                                                    ? const Color(0xFF1E8E3E)
                                                    : Colors.orange),
                                            const SizedBox(width: 5),
                                            Text(
                                                t['hasVivaCredentials'] == true
                                                    ? 'Viva συνδεδεμένη (${t['vivaDemo'] == true ? "demo" : "live"})'
                                                    : 'Λείπουν Viva credentials',
                                                style: const TextStyle(fontSize: 11.5)),
                                          ]),
                                          const SizedBox(height: 8),
                                          // ── Κουμπί αντιγραφής webhook URL — έτοιμο με
                                          // το σωστό tenantId, για να το επικολλήσεις
                                          // απευθείας στο Viva dashboard του πελάτη.
                                          InkWell(
                                            onTap: () => _copyWebhookUrl(t['tenantId'] as String),
                                            borderRadius: BorderRadius.circular(8),
                                            child: Container(
                                              padding: const EdgeInsets.symmetric(
                                                  horizontal: 10, vertical: 7),
                                              decoration: BoxDecoration(
                                                color: Colors.blue.shade50,
                                                borderRadius: BorderRadius.circular(8),
                                                border: Border.all(color: Colors.blue.shade200),
                                              ),
                                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                                Icon(Icons.copy_rounded,
                                                    size: 14, color: Colors.blue.shade700),
                                                const SizedBox(width: 6),
                                                Text('Αντιγραφή Webhook URL',
                                                    style: TextStyle(
                                                        fontSize: 11.5,
                                                        fontWeight: FontWeight.w600,
                                                        color: Colors.blue.shade700)),
                                              ]),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Switch(
                                          value: active,
                                          activeThumbColor: const Color(0xFF1E8E3E),
                                          onChanged: (v) => _toggleActive(
                                              t['tenantId'] as String, v),
                                        ),
                                        Text(active ? 'Ενεργός' : 'Κλειδωμένος',
                                            style: TextStyle(
                                                fontSize: 10.5,
                                                color: active
                                                    ? const Color(0xFF1E8E3E)
                                                    : Colors.red)),
                                      ],
                                    ),
                                  ]),
                                ),
                              );
                            },
                          ),
                  ),
      ),
      floatingActionButton: _isSuperAdmin
          ? FloatingActionButton.extended(
              onPressed: _openCreateDialog,
              icon: const Icon(Icons.add_business_rounded),
              label: const Text('Νέος Πελάτης'),
            )
          : null,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Dialog δημιουργίας νέου tenant
// ─────────────────────────────────────────────────────────────────────────
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
                  const Text('Νέος Πελάτης (Tenant)',
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
                        labelText: 'Αναγνωριστικό (tenantId) *',
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
