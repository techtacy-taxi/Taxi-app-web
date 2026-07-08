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
  bool _backfilling = false;
  bool _fixingCase = false;

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

  // ── Εφάπαξ «γέμισμα» tenantId:'default' σε ό,τι δεν το έχει ──────────────
  Future<void> _runBackfillPrompt() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Επισκευή ζωνών/δουλειών'),
        content: const Text(
          'Αυτό γράφει tenantId:"default" σε κάθε δικό σου δεδομένο (ζώνες, '
          'διαδρομές, δουλειές, αποθηκευμένες, πελάτες, πηγές, χρεώσεις) που '
          'δεν το έχει ήδη — π.χ. αν οι Ζώνες & Τιμές σου εμφανίζονται άδειες. '
          'Ασφαλές να το τρέξεις, δεν διαγράφει/αλλάζει τίποτα άλλο.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: const Text('Άκυρο'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child: const Text('Εκτέλεση'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _backfilling = true);
    try {
      final callable = FirebaseFunctions.instance.httpsCallable(
        'backfillDefaultTenantId',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 120)),
      );
      final res = await callable.call();
      final results = Map<String, dynamic>.from(res.data['results'] ?? {});
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dctx) => AlertDialog(
          title: const Text('Ολοκληρώθηκε'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: results.entries.map((e) {
                final v = Map<String, dynamic>.from(e.value as Map);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Text('${e.key}: ${v['updated']} / ${v['total']} ενημερώθηκαν'),
                );
              }).toList(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dctx).pop(),
              child: const Text('ΟΚ'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Σφάλμα: $e'), backgroundColor: Colors.red.shade700));
      }
    } finally {
      if (mounted) setState(() => _backfilling = false);
    }
  }

  Future<void> _runFixCapitalizationPrompt() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Διόρθωση Κεφαλαίο/πεζά'),
        content: const Text(
          'Διορθώνει το Όνομα/Επίθετο/Μοντέλο σε κάθε ήδη εγγεγραμμένο χρήστη '
          '(π.χ. "ΓΙΩΡΓΟΣ" → "Γιώργος"). Ασφαλές να το τρέξεις, δεν αλλάζει '
          'τίποτα άλλο.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: const Text('Άκυρο'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child: const Text('Εκτέλεση'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _fixingCase = true);
    try {
      final callable = FirebaseFunctions.instance.httpsCallable(
        'fixCapitalization',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 120)),
      );
      final res = await callable.call();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'Διορθώθηκαν ${res.data['updated']} από ${res.data['total']} χρήστες.'),
        backgroundColor: const Color(0xFF1E8E3E),
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Σφάλμα: $e'), backgroundColor: Colors.red.shade700));
      }
    } finally {
      if (mounted) setState(() => _fixingCase = false);
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

  // Αντιγράφει ΜΟΝΟ την τιμή του eformId (π.χ. "rhodes_taxi") — έτοιμη να
  // επικολληθεί απευθείας στη γραμμή `const EFORM_ID = "...";` μέσα στο
  // booking2.html (ή EL/booking2.html) του συγκεκριμένου πελάτη.
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

  // Ενεργοποίηση/απενεργοποίηση χάρτη ή Places σε μια Online Φόρμα.
  // field: 'mapEnabled' ή 'placesEnabled'.
  Future<void> _toggleFeatureFlag(String tenantId, String field, bool newValue) async {
    setState(() {
      final i = _tenants.indexWhere((t) => t['tenantId'] == tenantId);
      if (i != -1) _tenants[i][field] = newValue;
    });
    try {
      final callable = FirebaseFunctions.instance.httpsCallable('updateTenantFeatureFlags');
      await callable.call({'tenantId': tenantId, field: newValue});
    } catch (e) {
      setState(() {
        final i = _tenants.indexWhere((t) => t['tenantId'] == tenantId);
        if (i != -1) _tenants[i][field] = !newValue;
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
        appBar: AppBar(
          backgroundColor: Colors.indigo,
          foregroundColor: Colors.white,
          title: const Text('Online Φόρμα'),
        ),
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
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        title: const Text('Online Φόρμα'),
        actions: [
          IconButton(
            icon: _backfilling
                ? const SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.build_circle_rounded),
            onPressed: _backfilling ? null : _runBackfillPrompt,
            tooltip: 'Επισκευή ζωνών/δουλειών (backfill tenantId)',
          ),
          IconButton(
            icon: _fixingCase
                ? const SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.text_fields_rounded),
            onPressed: _fixingCase ? null : _runFixCapitalizationPrompt,
            tooltip: 'Διόρθωση Κεφαλαίο/πεζά (Όνομα/Επίθετο/Μοντέλο)',
          ),
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
                              final mapEnabled = t['mapEnabled'] != false;
                              final placesEnabled = t['placesEnabled'] != false;
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
                                          Text('eformId: ${t['tenantId']}',
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
                                          // ── Κουμπιά αντιγραφής — webhook URL (έτοιμο για
                                          // Viva dashboard) και eformId (έτοιμο για να το
                                          // βάλεις στη γραμμή EFORM_ID του booking2.html).
                                          // Row με Expanded (ΟΧΙ Wrap) ώστε να έχουν ΙΣΟ
                                          // πλάτος 50/50 — αλλιώς το κοντύτερο κείμενο
                                          // «EformID» έκανε το κουμπί ασύμμετρα μικρότερο.
                                          Row(children: [
                                            Expanded(
                                              child: InkWell(
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
                                                  child: Row(
                                                    mainAxisAlignment: MainAxisAlignment.center,
                                                    mainAxisSize: MainAxisSize.max,
                                                    children: [
                                                      Icon(Icons.copy_rounded,
                                                          size: 14, color: Colors.blue.shade700),
                                                      const SizedBox(width: 6),
                                                      Flexible(
                                                        child: Text('Αντιγραφή Webhook URL',
                                                            textAlign: TextAlign.center,
                                                            overflow: TextOverflow.ellipsis,
                                                            style: TextStyle(
                                                                fontSize: 11.5,
                                                                fontWeight: FontWeight.w600,
                                                                color: Colors.blue.shade700)),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: InkWell(
                                                onTap: () => _copyEformId(t['tenantId'] as String),
                                                borderRadius: BorderRadius.circular(8),
                                                child: Container(
                                                  padding: const EdgeInsets.symmetric(
                                                      horizontal: 10, vertical: 7),
                                                  decoration: BoxDecoration(
                                                    color: Colors.indigo.shade50,
                                                    borderRadius: BorderRadius.circular(8),
                                                    border: Border.all(color: Colors.indigo.shade200),
                                                  ),
                                                  child: Row(
                                                    mainAxisAlignment: MainAxisAlignment.center,
                                                    mainAxisSize: MainAxisSize.max,
                                                    children: [
                                                      Icon(Icons.badge_rounded,
                                                          size: 14, color: Colors.indigo.shade700),
                                                      const SizedBox(width: 6),
                                                      Flexible(
                                                        child: Text('Αντιγραφή EformID',
                                                            textAlign: TextAlign.center,
                                                            overflow: TextOverflow.ellipsis,
                                                            style: TextStyle(
                                                                fontSize: 11.5,
                                                                fontWeight: FontWeight.w600,
                                                                color: Colors.indigo.shade700)),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ]),
                                          const SizedBox(height: 8),
                                          // ── Οδηγίες «πού το βάζεις» — μέσα στην ίδια την
                                          // εφαρμογή, ώστε να μη χρειάζεται να θυμάσαι/ψάχνεις.
                                          Container(
                                            width: double.infinity,
                                            padding: const EdgeInsets.all(8),
                                            decoration: BoxDecoration(
                                              color: Colors.grey.shade50,
                                              borderRadius: BorderRadius.circular(8),
                                              border: Border.all(color: Colors.grey.shade200),
                                            ),
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                _WhereToPutRow(
                                                  color: Colors.blue.shade700,
                                                  label: 'Webhook URL:',
                                                  text: 'στο Viva dashboard του πελάτη → '
                                                      'Ειδοποίηση πληρωμής → νέο webhook, '
                                                      'Event «Νέα Πληρωμή».',
                                                ),
                                                const SizedBox(height: 6),
                                                _WhereToPutRow(
                                                  color: Colors.indigo.shade700,
                                                  label: 'EformID:',
                                                  text: 'στη γραμμή const EFORM_ID = "..."; '
                                                      'μέσα στο booking2.html (ή '
                                                      'EL/booking2.html) — αντικατέστησε το '
                                                      '"CHANGE_ME_EFORM_ID" με ό,τι μόλις '
                                                      'αντέγραψες.',
                                                ),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(height: 10),
                                          // ── Έλεγχος master: κόψε/ξανάβαλε χάρτη ή Places
                                          // στη δημόσια φόρμα αυτού του πελάτη, όποτε θες.
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 10, vertical: 6),
                                            decoration: BoxDecoration(
                                              color: Colors.grey.shade50,
                                              borderRadius: BorderRadius.circular(8),
                                              border: Border.all(color: Colors.grey.shade200),
                                            ),
                                            child: Row(children: [
                                              Expanded(
                                                child: Row(mainAxisSize: MainAxisSize.min, children: [
                                                  Icon(Icons.map_rounded,
                                                      size: 15,
                                                      color: mapEnabled ? Colors.teal : Colors.grey),
                                                  const SizedBox(width: 4),
                                                  const Text('Χάρτης', style: TextStyle(fontSize: 11.5)),
                                                  Switch(
                                                    value: mapEnabled,
                                                    activeThumbColor: Colors.teal,
                                                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                                    onChanged: (v) => _toggleFeatureFlag(
                                                        t['tenantId'] as String, 'mapEnabled', v),
                                                  ),
                                                ]),
                                              ),
                                              Expanded(
                                                child: Row(mainAxisSize: MainAxisSize.min, children: [
                                                  Icon(Icons.location_on_rounded,
                                                      size: 15,
                                                      color: placesEnabled ? Colors.teal : Colors.grey),
                                                  const SizedBox(width: 4),
                                                  const Text('Places', style: TextStyle(fontSize: 11.5)),
                                                  Switch(
                                                    value: placesEnabled,
                                                    activeThumbColor: Colors.teal,
                                                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                                    onChanged: (v) => _toggleFeatureFlag(
                                                        t['tenantId'] as String, 'placesEnabled', v),
                                                  ),
                                                ]),
                                              ),
                                            ]),
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
              backgroundColor: Colors.indigo,
              foregroundColor: Colors.white,
              onPressed: _openCreateDialog,
              icon: const Icon(Icons.add_business_rounded),
              label: const Text('Νέα Online Φόρμα'),
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

// ─── Μία γραμμή οδηγιών «πού το βάζεις» — «Ετικέτα: κείμενο» ─────────────────
class _WhereToPutRow extends StatelessWidget {
  final Color color;
  final String label;
  final String text;
  const _WhereToPutRow({
    required this.color,
    required this.label,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return RichText(
      text: TextSpan(
        style: TextStyle(fontSize: 10.5, color: Colors.grey[700], height: 1.35),
        children: [
          TextSpan(
            text: 'Πού το βάζεις — $label ',
            style: TextStyle(fontWeight: FontWeight.bold, color: color),
          ),
          TextSpan(text: text),
        ],
      ),
    );
  }
}
