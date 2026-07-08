// lib/viva_settings_page.dart
//
// Ρυθμίσεις Viva — αυτοεξυπηρέτηση:
//   • Tenant-owner: βάζει τα ΔΙΚΑ ΤΟΥ Viva credentials (Client ID/Secret/
//     Merchant ID/API Key/Source Code) για τον ΔΙΚΟ ΤΟΥ tenant.
//   • Master (εσύ, tenant "default"): το ίδιο για τον ΔΙΚΟ ΣΟΥ λογαριασμό.
//     Πλέον διαβάζεται ΖΩΝΤΑΝΑ (readSecret στο backend) — ΔΕΝ χρειάζεται
//     πια `firebase deploy --only functions` μετά την αλλαγή.
//
// Demo/Live διακόπτης: ΠΑΝΤΑ με διπλή επιβεβαίωση (dialog), ώστε να μην
// αλλάξει κατά λάθος κανείς από demo σε live (ή αντίστροφα).
//
// Δουλεύει ΚΑΙ στο Android app ΚΑΙ στο web app (ίδιο Flutter codebase).

import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

// ── Χρώμα «φυστικί» — ίδιο με το φόντο του μενού (βλ. εικόνα μενού) ────────
const Color kPistachio       = Color(0xFFF3ECD9); // φόντο πάνω μπάρα προειδοποίησης
const Color kPistachioAccent = Colors.teal; // κουμπί Αποθήκευση + διακόπτης — ίδιο με την πάνω μπάρα
const Color kPistachioText   = Color(0xFF6B5A2E); // σκούρο κείμενο πάνω σε φυστικί

class VivaSettingsPage extends StatefulWidget {
  const VivaSettingsPage({super.key});

  @override
  State<VivaSettingsPage> createState() => _VivaSettingsPageState();
}

class _VivaSettingsPageState extends State<VivaSettingsPage> {
  String _tenantId = 'default';
  String _tenantName = 'Ο δικός μου λογαριασμός';
  bool _tenantResolved = false;

  bool get _isDefault => _tenantId == 'default';
  bool get _isSuperAdmin =>
      FirebaseAuth.instance.currentUser?.email == 'techtacy@gmail.com';

  // Dropdown επιλογής tenant — ΜΟΝΟ για σένα (super-admin), ώστε να μπορείς
  // να συμπληρώνεις τις ρυθμίσεις για λογαριασμό κάποιου πελάτη.
  List<Map<String, dynamic>> _allTenants = [];
  bool _loadingTenants = false;

  final _clientIdCtrl     = TextEditingController();
  final _clientSecretCtrl = TextEditingController();
  final _merchantIdCtrl   = TextEditingController();
  final _apiKeyCtrl       = TextEditingController();
  final _sourceCodeCtrl   = TextEditingController();
  final _sourceCodeEnCtrl = TextEditingController();

  // ── Στοιχεία επιχείρησης (μόνο για tenants, όχι για το δικό σου default)
  final _businessNameCtrl   = TextEditingController();
  final _contactPhoneCtrl   = TextEditingController();
  final _contactEmailCtrl   = TextEditingController();
  final _whatsappNumberCtrl = TextEditingController();
  final _logoUrlCtrl        = TextEditingController();
  final _mapsApiKeyCtrl     = TextEditingController();

  bool _demo = true;
  bool _loading = true;
  bool _saving = false;
  bool _fillingSharedDemo = false;
  String? _error;

  // Μόνο για tenants (όχι "default") — masked προεπισκόπηση ήδη αποθηκευμένων.
  String? _maskedClientId, _maskedClientSecret, _maskedMerchantId, _maskedApiKey;
  bool _hasCredentials = false;

  @override
  void initState() {
    super.initState();
    _resolveTenantThenLoad();
    if (_isSuperAdmin) _loadAllTenants();
  }

  Future<void> _loadAllTenants() async {
    setState(() => _loadingTenants = true);
    try {
      final callable = FirebaseFunctions.instance.httpsCallable('listTenants');
      final res = await callable.call();
      final list = (res.data['tenants'] as List?) ?? [];
      setState(() {
        _allTenants = list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      });
    } catch (_) {
      // Μη κρίσιμο — απλά δεν εμφανίζεται η λίστα, ο master συνεχίζει με «default».
    } finally {
      if (mounted) setState(() => _loadingTenants = false);
    }
  }

  // Ο master επιλέγει άλλον tenant από το dropdown — αλλάζει το «πλαίσιο»
  // της σελίδας και ξαναφορτώνει τα δικά ΤΟΥ δεδομένα.
  Future<void> _switchToTenant(String tenantId, String tenantName) async {
    setState(() {
      _tenantId = tenantId;
      _tenantName = tenantName;
      _tenantResolved = false;
    });
    // Καθάρισε πεδία πριν φορτώσεις τα νέα, ώστε να μη μείνει κατά λάθος
    // παλιό κείμενο από τον προηγούμενο tenant.
    _clientIdCtrl.clear();
    _clientSecretCtrl.clear();
    _merchantIdCtrl.clear();
    _apiKeyCtrl.clear();
    _sourceCodeCtrl.clear();
    _sourceCodeEnCtrl.clear();
    _businessNameCtrl.clear();
    _contactPhoneCtrl.clear();
    _contactEmailCtrl.clear();
    _whatsappNumberCtrl.clear();
    _logoUrlCtrl.clear();
    _mapsApiKeyCtrl.clear();
    if (mounted) setState(() => _tenantResolved = true);
    await _load();
  }

  Future<void> _resolveTenantThenLoad() async {
    final email = FirebaseAuth.instance.currentUser?.email;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (email == 'techtacy@gmail.com') {
      _tenantId = 'default';
      _tenantName = 'Ο δικός μου λογαριασμός';
    } else if (uid != null) {
      try {
        final doc = await FirebaseFirestore.instance.collection('presence').doc(uid).get();
        final data = doc.data();
        _tenantId = (data?['tenantId'] as String?) ?? 'default';
        // Το όνομα της Online Φόρμας (business name) — προαιρετική ωραιοποίηση,
        // αν αποτύχει απλά δείχνει το tenantId.
        if (_tenantId != 'default') {
          try {
            final tDoc = await FirebaseFirestore.instance
                .collection('tenants').doc(_tenantId).get();
            _tenantName = (tDoc.data()?['businessName'] as String?) ?? _tenantId;
          } catch (_) {
            _tenantName = _tenantId;
          }
        }
      } catch (_) {
        _tenantId = 'default';
      }
    }
    if (mounted) setState(() => _tenantResolved = true);
    await _load();
  }

  @override
  void dispose() {
    _clientIdCtrl.dispose();
    _clientSecretCtrl.dispose();
    _merchantIdCtrl.dispose();
    _apiKeyCtrl.dispose();
    _sourceCodeCtrl.dispose();
    _sourceCodeEnCtrl.dispose();
    _businessNameCtrl.dispose();
    _contactPhoneCtrl.dispose();
    _contactEmailCtrl.dispose();
    _whatsappNumberCtrl.dispose();
    _logoUrlCtrl.dispose();
    _mapsApiKeyCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      if (_isDefault) {
        // Οι δικές σου ρυθμίσεις — απλά δείχνουμε το πεδίο Demo (αν είναι
        // γνωστό) και αφήνουμε τα υπόλοιπα κενά (τα βάζεις μόνο αν αλλάζεις).
        _demo = true; // προεπιλογή ασφαλής· ο master ξέρει την τρέχουσα κατάσταση
      } else {
        final callable =
            FirebaseFunctions.instance.httpsCallable('getTenantVivaCredentialsForOwner');
        final res = await callable.call({'tenantId': _tenantId});
        final data = Map<String, dynamic>.from(res.data);
        setState(() {
          _maskedClientId     = data['vivaClientIdMasked'] as String?;
          _maskedClientSecret = data['vivaClientSecretMasked'] as String?;
          _maskedMerchantId   = data['vivaMerchantIdMasked'] as String?;
          _maskedApiKey       = data['vivaApiKeyMasked'] as String?;
          _sourceCodeCtrl.text = data['vivaSourceCode'] as String? ?? '';
          _sourceCodeEnCtrl.text = data['vivaSourceCodeEn'] as String? ?? '';
          _demo = data['vivaDemo'] != false;
          _hasCredentials = data['hasVivaCredentials'] == true;
        });
        // Στοιχεία επιχείρησης (τηλέφωνο/email/λογότυπο/WhatsApp) — δημόσιο
        // endpoint, απλά ξαναφορτώνουμε ό,τι υπάρχει ήδη αποθηκευμένο.
        try {
          final biRes = await http.post(
            Uri.parse('https://us-central1-my-taxi-app-bbc7c.cloudfunctions.net/getTenantBusinessInfo'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'tenantId': _tenantId}),
          );
          final bi = jsonDecode(biRes.body) as Map<String, dynamic>;
          if (bi['ok'] == true) {
            setState(() {
              _businessNameCtrl.text  = bi['businessName'] as String? ?? _tenantName;
              _contactPhoneCtrl.text   = bi['contactPhone'] as String? ?? '';
              _contactEmailCtrl.text   = bi['contactEmail'] as String? ?? '';
              _whatsappNumberCtrl.text = bi['whatsappNumber'] as String? ?? '';
              _logoUrlCtrl.text        = bi['logoUrl'] as String? ?? '';
              _mapsApiKeyCtrl.text     = bi['mapsApiKey'] as String? ?? '';
            });
          }
        } catch (_) {
          // Μη κρίσιμο — απλά δεν προσυμπληρώνονται, ο tenant τα ξαναγράφει.
        }
      }
    } catch (e) {
      setState(() => _error = 'Σφάλμα φόρτωσης: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _useSharedDemo() async {
    setState(() { _fillingSharedDemo = true; _error = null; });
    try {
      final callable =
          FirebaseFunctions.instance.httpsCallable('getSharedDemoVivaCredentials');
      final res = await callable.call();
      final data = Map<String, dynamic>.from(res.data);
      setState(() {
        _clientIdCtrl.text     = data['vivaClientId'] as String? ?? '';
        _clientSecretCtrl.text = data['vivaClientSecret'] as String? ?? '';
        _merchantIdCtrl.text   = data['vivaMerchantId'] as String? ?? '';
        _apiKeyCtrl.text       = data['vivaApiKey'] as String? ?? '';
        _demo = true;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Γέμισαν τα demo στοιχεία — μπορείς να δοκιμάσεις πληρωμή.'),
          backgroundColor: Color(0xFF1E8E3E),
        ));
      }
    } catch (e) {
      setState(() => _error = 'Δεν ήταν δυνατή η φόρτωση demo στοιχείων: $e');
    } finally {
      if (mounted) setState(() => _fillingSharedDemo = false);
    }
  }

  Future<bool> _confirmDemoLiveChange(bool newDemo) async {
    final confirmed1 = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Row(children: [
          Icon(Icons.warning_amber_rounded,
              color: newDemo ? Colors.orange : Colors.red),
          const SizedBox(width: 8),
          Expanded(child: Text(
              newDemo ? 'Αλλαγή σε DEMO' : 'Αλλαγή σε LIVE (πραγματικές πληρωμές)')),
        ]),
        content: Text(newDemo
            ? 'Θα σταματήσουν να γίνονται πραγματικές χρεώσεις πελατών — μόνο δοκιμαστικές.'
            : 'Από εδώ και πέρα ΘΑ γίνονται ΠΡΑΓΜΑΤΙΚΕΣ χρεώσεις σε πραγματικές κάρτες πελατών.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dctx).pop(false), child: const Text('Άκυρο')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: newDemo ? Colors.orange : Colors.red),
            onPressed: () => Navigator.of(dctx).pop(true),
            child: const Text('Συνέχεια'),
          ),
        ],
      ),
    );
    if (confirmed1 != true) return false;

    // Διπλή επιβεβαίωση — σκόπιμα δεύτερο, ξεχωριστό dialog.
    final confirmed2 = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Είσαι σίγουρος/η;'),
        content: Text(newDemo
            ? 'Επιβεβαίωση: μετάβαση σε DEMO mode.'
            : 'ΤΕΛΙΚΗ ΕΠΙΒΕΒΑΙΩΣΗ: μετάβαση σε LIVE — πραγματικά χρήματα.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dctx).pop(false), child: const Text('Άκυρο')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: newDemo ? Colors.orange : Colors.red),
            onPressed: () => Navigator.of(dctx).pop(true),
            child: Text(newDemo ? 'Ναι, DEMO' : 'Ναι, LIVE'),
          ),
        ],
      ),
    );
    return confirmed2 == true;
  }

  Future<void> _save() async {
    setState(() { _saving = true; _error = null; });
    try {
      if (_isDefault) {
        final callable =
            FirebaseFunctions.instance.httpsCallable('updateDefaultVivaCredentials');
        final res = await callable.call({
          if (_clientIdCtrl.text.trim().isNotEmpty) 'vivaClientId': _clientIdCtrl.text.trim(),
          if (_clientSecretCtrl.text.trim().isNotEmpty) 'vivaClientSecret': _clientSecretCtrl.text.trim(),
          if (_merchantIdCtrl.text.trim().isNotEmpty) 'vivaMerchantId': _merchantIdCtrl.text.trim(),
          if (_apiKeyCtrl.text.trim().isNotEmpty) 'vivaApiKey': _apiKeyCtrl.text.trim(),
          'vivaDemo': _demo,
        });
        final data = Map<String, dynamic>.from(res.data);
        if (mounted) {
          await showDialog<void>(
            context: context,
            builder: (dctx) => AlertDialog(
              title: const Text('Αποθηκεύτηκε'),
              content: Text(data['message'] as String? ??
                  'Αποθηκεύτηκε και ισχύει ήδη.'),
              actions: [
                FilledButton(
                  onPressed: () => Navigator.of(dctx).pop(),
                  child: const Text('Κατάλαβα'),
                ),
              ],
            ),
          );
        }
      } else {
        final callable =
            FirebaseFunctions.instance.httpsCallable('updateTenantVivaCredentials');
        await callable.call({
          'tenantId': _tenantId,
          if (_clientIdCtrl.text.trim().isNotEmpty) 'vivaClientId': _clientIdCtrl.text.trim(),
          if (_clientSecretCtrl.text.trim().isNotEmpty) 'vivaClientSecret': _clientSecretCtrl.text.trim(),
          if (_merchantIdCtrl.text.trim().isNotEmpty) 'vivaMerchantId': _merchantIdCtrl.text.trim(),
          if (_apiKeyCtrl.text.trim().isNotEmpty) 'vivaApiKey': _apiKeyCtrl.text.trim(),
          'vivaSourceCode': _sourceCodeCtrl.text.trim(),
          'vivaSourceCodeEn': _sourceCodeEnCtrl.text.trim(),
          'vivaDemo': _demo,
        });
        // Στοιχεία επιχείρησης — τηλέφωνο/email/λογότυπο/WhatsApp. Αυτά ΔΕΝ
        // είναι μυστικά, γι' αυτό ξεχωριστό, απλό callable (χωρίς Secret Manager).
        final biCallable =
            FirebaseFunctions.instance.httpsCallable('updateTenantBusinessInfo');
        await biCallable.call({
          'tenantId': _tenantId,
          'businessName': _businessNameCtrl.text.trim(),
          'contactPhone': _contactPhoneCtrl.text.trim(),
          'contactEmail': _contactEmailCtrl.text.trim(),
          'whatsappNumber': _whatsappNumberCtrl.text.trim(),
          'logoUrl': _logoUrlCtrl.text.trim(),
          'mapsApiKey': _mapsApiKeyCtrl.text.trim(),
        });
        // Αν μόλις μπήκε ΔΙΚΟ ΤΟΥ Google Maps κλειδί, ο διακόπτης «Χάρτης/
        // Places» (που αφορά ΜΟΝΟ το δικό ΜΑΣ κλειδί) δεν έχει πια νόημα να
        // είναι ενεργός — τον σβήνουμε αυτόματα, ώστε η λίστα «Online
        // Φόρμες» να δείχνει σωστά ότι δεν χρησιμοποιείται πια το δικό μας.
        if (_mapsApiKeyCtrl.text.trim().isNotEmpty) {
          try {
            final flagsCallable =
                FirebaseFunctions.instance.httpsCallable('updateTenantFeatureFlags');
            await flagsCallable.call({
              'tenantId': _tenantId,
              'mapEnabled': false,
              'placesEnabled': false,
            });
          } catch (_) {
            // Μη κρίσιμο — δεν μπλοκάρει την υπόλοιπη αποθήκευση.
          }
        }
        if (_businessNameCtrl.text.trim().isNotEmpty) {
          _tenantName = _businessNameCtrl.text.trim();
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Αποθηκεύτηκε.'),
            backgroundColor: Color(0xFF1E8E3E),
          ));
        }
        _clientIdCtrl.clear();
        _clientSecretCtrl.clear();
        _merchantIdCtrl.clear();
        _apiKeyCtrl.clear();
        await _load();
      }
    } catch (e) {
      setState(() => _error = 'Σφάλμα αποθήκευσης: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // Το ακριβές webhook URL — με ?tenantId=... για κάθε Online Φόρμα εκτός
  // από τη δική σου (default, που δεν χρειάζεται τίποτα στο URL).
  String get _webhookUrl {
    const base = 'https://us-central1-my-taxi-app-bbc7c.cloudfunctions.net/vivaWebhook';
    return _isDefault ? base : '$base?tenantId=$_tenantId';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading || !_tenantResolved) {
      return Scaffold(
        appBar: AppBar(backgroundColor: Colors.teal, foregroundColor: Colors.white,
            title: const Text('Ρυθμίσεις (Viva, Google Cloud)')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.teal,
          foregroundColor: Colors.white,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Ρυθμίσεις (Viva, Google Cloud)',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
              Text(_tenantName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.normal, color: Colors.white70)),
            ],
          ),
          bottom: const TabBar(
            indicatorColor: Colors.white,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            tabs: [
              Tab(icon: Icon(Icons.payment_rounded, size: 20), text: 'Viva'),
              Tab(icon: Icon(Icons.cloud_rounded, size: 20), text: 'Google Cloud'),
              Tab(icon: Icon(Icons.storefront_rounded, size: 20), text: 'Επιχείρηση'),
            ],
          ),
        ),
        body: SafeArea(
          child: Column(
            children: [
              if (_isSuperAdmin) _buildTenantSwitcher(),
              Expanded(
                child: TabBarView(
                  children: [
                    _buildVivaTab(),
                    _buildGoogleCloudTab(),
                    _buildBusinessTab(),
                  ],
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(_error!, style: const TextStyle(color: Colors.red)),
                ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: kPistachioAccent,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox(
                            width: 20, height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Text('Αποθήκευση (όλα τα tabs)'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Tab 1: Viva ──────────────────────────────────────────────────────────
  // ── Dropdown επιλογής tenant — ΜΟΝΟ για σένα (super-admin). Σου επιτρέπει
  // να συμπληρώνεις τις ρυθμίσεις Viva/Google Cloud/Στοιχεία Επιχείρησης για
  // λογαριασμό οποιουδήποτε πελάτη, χωρίς να χρειάζεται να συνδεθείς ως αυτός.
  Widget _buildTenantSwitcher() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      color: Colors.teal.withValues(alpha: 0.06),
      child: Row(children: [
        Icon(Icons.swap_horiz_rounded, size: 18, color: Colors.teal[700]),
        const SizedBox(width: 8),
        const Text('Προβολή για:', style: TextStyle(fontSize: 12.5)),
        const SizedBox(width: 8),
        Expanded(
          child: _loadingTenants
              ? const LinearProgressIndicator(minHeight: 2)
              : DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: _tenantId,
                    items: [
                      const DropdownMenuItem(
                        value: 'default',
                        child: Text('Ο δικός μου λογαριασμός',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                      ),
                      ..._allTenants.map((t) => DropdownMenuItem<String>(
                            value: t['tenantId'] as String,
                            child: Text(
                                (t['businessName'] as String?) ?? t['tenantId'] as String,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13)),
                          )),
                    ],
                    onChanged: (v) {
                      if (v == null || v == _tenantId) return;
                      if (v == 'default') {
                        _switchToTenant('default', 'Ο δικός μου λογαριασμός');
                      } else {
                        final t = _allTenants.firstWhere((x) => x['tenantId'] == v);
                        _switchToTenant(v, (t['businessName'] as String?) ?? v);
                      }
                    },
                  ),
                ),
        ),
      ]),
    );
  }

  Widget _buildVivaTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_isDefault)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: kPistachio,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: kPistachioAccent),
              ),
              child: const Text(
                '⚠️ Αυτά είναι ΤΑ ΔΙΚΑ ΣΟΥ credentials (default λογαριασμός). '
                'Ισχύουν αμέσως μόλις πατήσεις Αποθήκευση — καμία ανάγκη για deploy.',
                style: TextStyle(fontSize: 12.5, color: kPistachioText),
              ),
            ),

          if (!_isDefault && _hasCredentials) ...[
            const Text('Ήδη αποθηκευμένα (κρυμμένα)',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            const SizedBox(height: 6),
            _maskedRow('Client ID', _maskedClientId),
            _maskedRow('Client Secret', _maskedClientSecret),
            _maskedRow('Merchant ID', _maskedMerchantId),
            _maskedRow('API Key', _maskedApiKey),
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),
          ],

          Text(
            _hasCredentials || _isDefault
                ? 'Συμπλήρωσε ΜΟΝΟ ό,τι θες να αλλάξεις:'
                : 'Συμπλήρωσε τα στοιχεία σου:',
            style: const TextStyle(fontSize: 12.5, color: Colors.grey),
          ),
          const SizedBox(height: 8),

          TextField(
            controller: _clientIdCtrl,
            decoration: const InputDecoration(
                labelText: 'Viva Client ID', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _clientSecretCtrl,
            obscureText: true,
            decoration: const InputDecoration(
                labelText: 'Viva Client Secret', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _merchantIdCtrl,
            decoration: const InputDecoration(
                labelText: 'Viva Merchant ID', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _apiKeyCtrl,
            obscureText: true,
            decoration: const InputDecoration(
                labelText: 'Viva API Key', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _sourceCodeCtrl,
            decoration: const InputDecoration(
                labelText: 'Viva Source Code — Ελληνικά (4ψήφιο)',
                helperText: 'Το Source στο Viva dashboard πρέπει να έχει Success/Failure URL '
                    'προς τη ΔΙΚΙΑ ΣΟΥ ελληνική σελίδα (π.χ. el/booking2.html)',
                border: OutlineInputBorder()),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _sourceCodeEnCtrl,
            decoration: const InputDecoration(
                labelText: 'Viva Source Code — Αγγλικά (4ψήφιο, προαιρετικό)',
                helperText: 'Χρειάζεται ΔΕΥΤΕΡΟ, ξεχωριστό Source στο Viva dashboard, με '
                    'Success/Failure URL προς την αγγλική σελίδα (index.html) — αλλιώς ο '
                    'πελάτης της αγγλικής φόρμας γυρνάει σε ελληνική σελίδα μετά την πληρωμή. '
                    'Αν το αφήσεις κενό, χρησιμοποιείται το ελληνικό Source και για τα δύο.',
                border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),

          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Demo λογαριασμός'),
            subtitle: Text(_fillingSharedDemo
                ? 'Συμπλήρωση δοκιμαστικών στοιχείων...'
                : (_demo
                    ? 'Δοκιμαστικός — καμία πραγματική χρέωση'
                    : 'LIVE — πραγματικές χρεώσεις!')),
            value: _demo,
            activeThumbColor: kPistachioAccent,
            onChanged: (v) async {
              if (v == _demo) return;
              final ok = await _confirmDemoLiveChange(v);
              if (!ok) return;
              setState(() => _demo = v);
              // Αν ενεργοποιείται DEMO και δεν υπάρχουν ήδη δικά του/αποθηκευμένα
              // Viva credentials, γεμίζουμε αυτόματα τα κοινόχρηστα demo στοιχεία
              // ώστε ο διακόπτης να «κάνει τη δουλειά» χωρίς ξεχωριστό κουμπί.
              if (v == true && !_isDefault && !_hasCredentials &&
                  _clientIdCtrl.text.trim().isEmpty) {
                await _useSharedDemo();
              }
            },
          ),

          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.blue.shade200),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Κάρτες δοκιμής (demo)',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(height: 6),
                _CopyableCardNumber(
                  label: '✅ Επιτυχής πληρωμή:',
                  number: '5239 2907 0000 0101',
                ),
                const SizedBox(height: 4),
                _CopyableCardNumber(
                  label: '❌ Αποτυχημένη πληρωμή:',
                  number: '5188 3400 0000 0060',
                ),
                const SizedBox(height: 4),
                const Text('Λήξη: 01/31 · CVC: 123 (και για τις δύο)',
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
              ],
            ),
          ),

          const SizedBox(height: 16),
          _buildSetupInstructions(),
        ],
      ),
    );
  }

  // ─── Tab 2: Google Cloud ──────────────────────────────────────────────────
  Widget _buildGoogleCloudTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Column(children: [
              Container(
                width: 64, height: 64,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Image.network(
                  'https://developers.google.com/identity/images/g-logo.png',
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) =>
                      Icon(Icons.cloud_rounded, size: 38, color: Colors.blue[700]),
                ),
              ),
              const SizedBox(height: 8),
              const Text('Google Cloud Console',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            ]),
          ),
          const SizedBox(height: 16),
          if (!_isDefault) ...[
            const Text(
              'Εδώ βάζεις το δικό σου Google Maps API key, ώστε το κόστος '
              'Places/Maps να πηγαίνει σε σένα, όχι στο δικό μας κλειδί.',
              style: TextStyle(fontSize: 12.5, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _mapsApiKeyCtrl,
              decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Google Maps API Key (προαιρετικό)',
                  helperText: 'Χωρίς αυτό, χρησιμοποιείται προσωρινά το δικό '
                      'μας κλειδί — αλλά τότε το κόστος Google Places/Maps '
                      'επιβαρύνει εμάς.',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            _buildMapsKeyInstructions(),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => launchUrl(
                    Uri.parse('https://console.cloud.google.com/apis/credentials'),
                    mode: LaunchMode.externalApplication),
                icon: const Icon(Icons.open_in_new_rounded),
                label: const Text('Άνοιγμα Google Cloud Console'),
              ),
            ),
          ] else
            const Text(
              'Δεν εφαρμόζεται για τον δικό σου (default) λογαριασμό — το '
              'δικό σου Google Maps κλειδί ρυθμίζεται ήδη απευθείας στον κώδικα.',
              style: TextStyle(fontSize: 12.5, color: Colors.grey),
            ),
        ],
      ),
    );
  }

  // ─── Tab 3: Στοιχεία Επιχείρησης ─────────────────────────────────────────
  Widget _buildBusinessTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!_isDefault) ...[
            Row(children: [
              Icon(Icons.storefront_rounded, size: 18, color: Colors.indigo[700]),
              const SizedBox(width: 6),
              const Text('Στοιχεία Επιχείρησης',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            ]),
            const SizedBox(height: 4),
            Text(
              'Εμφανίζονται αυτόματα στη δική σου φόρμα κράτησης '
              '(booking2.html) — δεν χρειάζεται να επεξεργαστείς κώδικα.',
              style: TextStyle(fontSize: 11, color: Colors.grey[600]),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _businessNameCtrl,
              decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Όνομα επιχείρησης',
                  helperText: 'Εμφανίζεται στη φόρμα κράτησης (footer) — μπορείς να το διορθώσεις όποτε θες',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _contactPhoneCtrl,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Τηλέφωνο επικοινωνίας',
                  hintText: '+30 6900000000',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _contactEmailCtrl,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Email επικοινωνίας',
                  hintText: 'info@τοδικοσουdomain.com',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _whatsappNumberCtrl,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Αριθμός WhatsApp',
                  helperText: 'Μόνο αριθμοί, με κωδικό χώρας — π.χ. 306900000000 (χωρίς +)',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _logoUrlCtrl,
              decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Link λογότυπου (εικόνα)',
                  helperText: 'Ανέβασε το λογότυπό σου κάπου (π.χ. imgur.com) '
                      'και επικόλλησε εδώ το link της εικόνας',
                  border: OutlineInputBorder()),
            ),
          ] else
            const Text(
              'Δεν εφαρμόζεται για τον δικό σου (default) λογαριασμό.',
              style: TextStyle(fontSize: 12.5, color: Colors.grey),
            ),
        ],
      ),
    );
  }

  // ── Οδηγίες: πού βρίσκει ο καθένας το webhook URL και πώς φτιάχνει το
  // Source Code (Κωδικό) στο δικό του Viva dashboard. ─────────────────────
  Widget _buildSetupInstructions() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Theme(
        // Αφαιρούμε τις προεπιλεγμένες γραμμές διαχωρισμού του ExpansionTile
        // ώστε να ταιριάζει οπτικά με το υπόλοιπο κουτί.
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          leading: Icon(Icons.info_outline_rounded, size: 16, color: Colors.grey[700]),
          title: const Text('Πώς ρυθμίζεις το Webhook & το Source Code',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5)),
          children: [
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('1. Webhook (Ειδοποίηση πληρωμής)',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
            ),
            const SizedBox(height: 4),
            const Text(
              'Στο Viva dashboard: πάνω μενού → «Ειδοποίηση πληρωμής» → '
              'πρόσθεσε νέο webhook, Event: «Νέα Πληρωμή» (Transaction Payment '
              'Created), και βάλε ακριβώς αυτό το URL:',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 6),
            _CopyableCode(text: _webhookUrl),

            const SizedBox(height: 12),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('2. Source Code (Κωδικός)',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
            ),
            const SizedBox(height: 4),
            const Text(
              'Πλαϊνό μενού → «Λογαριασμοί» → βρες την ενότητα «Websites / '
              'Apps» → πάτα «Προσθήκη Website/App» → δώσε ένα όνομα (π.χ. το '
              'όνομα της επιχείρησης). Μόλις δημιουργηθεί, εμφανίζεται ένας '
              '4ψήφιος «Κωδικός» στη λίστα — αυτό είναι το Source Code που '
              'βάζεις παραπάνω.',
              style: TextStyle(fontSize: 12),
            ),

            if (_isDefault) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.amber.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'Αν το κάνεις εσύ για λογαριασμό κάποιου tenant, ακολούθησε τα '
                  'ίδια 2 βήματα μέσα στο δικό ΤΟΥ Viva dashboard (όχι στο δικό '
                  'σου) — το webhook URL του θα έχει το δικό του tenantId.',
                  style: TextStyle(fontSize: 11.5),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── Οδηγίες: πώς φτιάχνεις ΑΣΦΑΛΕΣ Google Maps API Key — βήμα-βήμα. ──────
  Widget _buildMapsKeyInstructions() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.blue.shade200),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          leading: Icon(Icons.map_rounded, size: 16, color: Colors.blue[700]),
          title: Text('Πώς φτιάχνεις ασφαλές Google Maps κλειδί',
              style: TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 12.5, color: Colors.blue[900])),
          children: [
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('1. Ενεργοποίηση APIs',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
            ),
            const SizedBox(height: 4),
            const Text(
              'Πήγαινε στο console.cloud.google.com → φτιάξε ΝΕΟ project (ή '
              'χρησιμοποίησε υπάρχον δικό σου) → «APIs & Services» → «Library» → '
              'ενεργοποίησε ΟΛΑ τα παρακάτω:',
              style: TextStyle(fontSize: 12),
            ),
            const Padding(
              padding: EdgeInsets.only(left: 10, top: 4),
              child: Text(
                '•  Places API (New) — για τις προτάσεις διευθύνσεων\n'
                '•  Maps JavaScript API — για τον χάρτη της διαδρομής\n'
                '•  Geocoding API — ΜΟΝΟ αν θες υποστήριξη Plus Codes '
                '(π.χ. "8FW4V75V+8Q"). Χωρίς αυτό, η φόρμα δουλεύει κανονικά, '
                'απλά δεν αναγνωρίζει Plus Codes.',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(children: [
                Icon(Icons.my_location_rounded, size: 14, color: Colors.grey[700]),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Το κουμπί «Η τοποθεσία μου» (GPS) ΔΕΝ χρειάζεται τίποτα από '
                    'τα παραπάνω — είναι λειτουργία του ίδιου του browser, '
                    'δωρεάν, χωρίς Google API key. Μην μπερδεύεις με το '
                    'ξεχωριστό (και εδώ άχρηστο) προϊόν "Geolocation API" της '
                    'Google — δεν χρειάζεται καθόλου για τη φόρμα.',
                    style: TextStyle(fontSize: 11, color: Colors.grey[700]),
                  ),
                ),
              ]),
            ),

            const SizedBox(height: 12),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('2. Δημιουργία κλειδιού',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
            ),
            const SizedBox(height: 4),
            const Text(
              '«APIs & Services» → «Credentials» → «+ Create Credentials» → '
              '«API key». Θα εμφανιστεί αμέσως ένας κωδικός (κάτι σαν '
              '«AIzaSy...») — αυτόν θα βάλεις παραπάνω.',
              style: TextStyle(fontSize: 12),
            ),

            const SizedBox(height: 12),
            Row(children: [
              Icon(Icons.lock_rounded, size: 14, color: Colors.red[700]),
              const SizedBox(width: 4),
              Text('3. ΠΡΟΣΤΑΣΙΑ — υποχρεωτικό βήμα!',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 12, color: Colors.red[700])),
            ]),
            const SizedBox(height: 4),
            const Text(
              'Χωρίς αυτό το βήμα, ΟΠΟΙΟΣΔΗΠΟΤΕ μπορεί να «κλέψει» το κλειδί σου '
              'από τον πηγαίο κώδικα της σελίδας και να το χρησιμοποιήσει αλλού '
              'με δικά σου έξοδα. Πάτα πάνω στο κλειδί που μόλις έφτιαξες →',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 6),
            const Padding(
              padding: EdgeInsets.only(left: 10),
              child: Text(
                '«Application restrictions» → επίλεξε «Websites» → πρόσθεσε:',
                style: TextStyle(fontSize: 12),
              ),
            ),
            const SizedBox(height: 6),
            const _CopyableCode(text: 'https://ΤοDomainΣου.pages.dev/*'),
            const SizedBox(height: 6),
            const Padding(
              padding: EdgeInsets.only(left: 10),
              child: Text(
                'Αν έχεις και preview URLs (Cloudflare Pages), πρόσθεσε ΚΑΙ:',
                style: TextStyle(fontSize: 12),
              ),
            ),
            const SizedBox(height: 6),
            const _CopyableCode(text: 'https://*.ΤοDomainΣου.pages.dev/*'),
            const SizedBox(height: 6),
            const Text(
              'Στην ενότητα «API restrictions» παρακάτω, επίλεξε «Restrict key» '
              'και τσέκαρε ΜΟΝΟ τα APIs που ενεργοποίησες στο βήμα 1 — έτσι το '
              'κλειδί δεν μπορεί να χρησιμοποιηθεί για τίποτα άλλο ακόμα κι αν '
              'διαρρεύσει.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 4),
            Text('Πάτα Save. Χρειάζεται συνήθως 5 λεπτά για να ενεργοποιηθεί.',
                style: TextStyle(fontSize: 11, color: Colors.grey[600])),
          ],
        ),
      ),
    );
  }

  Widget _maskedRow(String label, String? value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          SizedBox(width: 110, child: Text(label, style: const TextStyle(fontSize: 12.5))),
          Text(value?.isNotEmpty == true ? value! : '—',
              style: const TextStyle(fontSize: 12.5, fontFamily: 'monospace')),
        ]),
      );
}

/// Γραμμή «ετικέτα + αριθμός κάρτας + κουμπί αντιγραφής» — για τις demo
/// κάρτες δοκιμής (χωρίς τα κενά, έτοιμη να επικολληθεί στο πεδίο κάρτας).
class _CopyableCardNumber extends StatelessWidget {
  final String label;
  final String number;
  const _CopyableCardNumber({required this.label, required this.number});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text('$label $number', style: const TextStyle(fontSize: 12.5)),
        ),
        InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () {
            Clipboard.setData(ClipboardData(text: number.replaceAll(' ', '')));
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Αντιγράφηκε ο αριθμός κάρτας'),
              duration: Duration(seconds: 1),
            ));
          },
          child: const Padding(
            padding: EdgeInsets.all(4),
            child: Icon(Icons.copy_rounded, size: 15),
          ),
        ),
      ],
    );
  }
}

/// Κουτί με κείμενο + κουμπί αντιγραφής — για το webhook URL.
class _CopyableCode extends StatelessWidget {
  final String text;
  const _CopyableCode({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Row(children: [
        Expanded(
          child: Text(text,
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
        ),
        IconButton(
          icon: const Icon(Icons.copy_rounded, size: 16),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: text));
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Αντιγράφηκε'),
              duration: Duration(seconds: 1),
            ));
          },
        ),
      ]),
    );
  }
}
