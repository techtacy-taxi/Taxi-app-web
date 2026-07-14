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

  // ── Stripe — δεύτερος διαθέσιμος πάροχος πληρωμών. Ο tenant/master
  // μπορεί να αποθηκεύσει credentials και για τους δύο παρόχους, και να
  // διαλέξει ελεύθερα ποιος είναι ενεργός τώρα (_paymentProvider).
  final _stripeSecretKeyCtrl      = TextEditingController();
  final _stripePublishableKeyCtrl = TextEditingController();
  final _stripeWebhookSecretCtrl  = TextEditingController();
  String _paymentProvider = 'viva'; // 'viva' | 'stripe' — ποιος είναι ενεργός ΤΩΡΑ
  String? _maskedStripeSecretKey, _maskedStripePublishableKey, _maskedStripeWebhookSecret;
  bool _hasStripeCredentials = false;
  bool _savingProvider = false;

  // ── Στοιχεία επιχείρησης (μόνο για tenants, όχι για το δικό σου default)
  final _businessNameCtrl   = TextEditingController();
  final _contactPhoneCtrl   = TextEditingController();
  final _contactEmailCtrl   = TextEditingController();
  final _whatsappNumberCtrl = TextEditingController();
  final _logoUrlCtrl        = TextEditingController();
  final _mapsApiKeyCtrl     = TextEditingController();
  final _resendKeyCtrl      = TextEditingController();
  bool _hasOwnResendKey = false;
  bool _emailsEnabled = true;
  bool _savingResendKey = false;

  // ── Απόδειξη/Τιμολόγιο — φορολογικά στοιχεία + πάροχος ηλεκτρονικής
  // τιμολόγησης, ανά tenant. Προαιρετικό: αν δεν οριστεί πάροχος, απλά δεν
  // εκδίδεται αυτόματα παραστατικό (μένει μόνο το email επιβεβαίωσης).
  final _afmCtrl          = TextEditingController();
  final _doyCtrl          = TextEditingController();
  final _taxAddressCtrl   = TextEditingController();
  final _kadCtrl          = TextEditingController();
  final _invoiceApiKeyCtrl = TextEditingController(); // Epsilon: Subscription Key
  final _epsilonEmailCtrl = TextEditingController();
  final _epsilonPasswordCtrl = TextEditingController();
  final _epsilonItemCodeCtrl = TextEditingController();
  bool _hasEpsilonPassword = false;
  final _mydataSubKeyCtrl  = TextEditingController();
  final _mydataUsernameCtrl = TextEditingController();
  // ── Oxygen Pelatologio — μοιράζεται το _invoiceApiKeyCtrl (invoice-api-key
  // secret) με το Epsilon, ίδιο μοτίβο. Branch/numbering-sequence/payment-
  // method IDs δεν είναι μυστικά — απλά πεδία tenant config.
  final _oxygenBranchIdCtrl = TextEditingController();
  final _oxygenNumberingSequenceIdCtrl = TextEditingController();
  // Ξεχωριστή σειρά αρίθμησης ΓΙΑ ΠΙΣΤΩΤΙΚΑ — χωρίς αυτήν το αυτόματο
  // πιστωτικό σε ακύρωση παραλείπεται (μένει χειροκίνητη ειδοποίηση).
  final _oxygenCreditNumberingSequenceIdCtrl = TextEditingController();
  final _oxygenPaymentMethodIdCtrl = TextEditingController();
  bool _oxygenSandbox = true;
  String _invoiceProvider = 'none'; // 'none' | 'epsilon' | 'mydata' | 'oxygen'
  // ── Φορολογικές παράμετροι myDATA — ΡΩΤΑ ΤΟΝ ΛΟΓΙΣΤΗ ΣΟΥ αν δεν είσαι
  // σίγουρος. Προεπιλογές: 11.2 = Απόδειξη Παροχής Υπηρεσιών (B2C, ο πιο
  // συνηθισμένος τύπος για μεμονωμένους πελάτες), ΦΠΑ 24%.
  String _mydataInvoiceType = '11.2';
  String _mydataVatCategory = '2'; // 1=24%, 2=13%, 3=6%, 7=0% (εξαίρεση) — 13% επιβεβαιωμένο για μεταφορά ΤΑΞΙ (Ν.5116/2024, άρθρο 61, μόνιμο)
  // ── Demo/Live ΤΗΣ myDATA — ΞΕΧΩΡΙΣΤΟ από το Demo/Live της Viva! Το ένα
  // αφορά πληρωμές, το άλλο φορολογικά παραστατικά — δεν πρέπει να είναι
  // δεμένα μεταξύ τους (π.χ. μπορεί να θες Live Viva αλλά ακόμα δοκιμαστικό
  // myDATA μέχρι να βεβαιωθείς ότι δουλεύει σωστά). Προεπιλογή: sandbox.
  bool _mydataDemo = true;
  bool _hasInvoiceApiKey = false;
  bool _hasMydataSubKey = false;
  // ── Ρητός διακόπτης — ΠΑΝΤΑ κλειστός εξ ορισμού. Ακόμα κι αν κάποιος
  // συμπληρώσει πάροχο/κλειδιά, ΔΕΝ εκδίδεται τίποτα μέχρι να το ανοίξει ο
  // ίδιος ρητά — καμία περίπτωση αυτόματης έκδοσης χωρίς συνειδητή επιλογή.
  bool _invoiceEnabled = false;
  final _invoiceSeriesCtrl = TextEditingController();
  bool _savingReceipt = false;

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
    _resendKeyCtrl.dispose();
    _afmCtrl.dispose();
    _doyCtrl.dispose();
    _taxAddressCtrl.dispose();
    _kadCtrl.dispose();
    _invoiceApiKeyCtrl.dispose();
    _epsilonEmailCtrl.dispose();
    _epsilonPasswordCtrl.dispose();
    _epsilonItemCodeCtrl.dispose();
    _mydataSubKeyCtrl.dispose();
    _mydataUsernameCtrl.dispose();
    _oxygenBranchIdCtrl.dispose();
    _oxygenNumberingSequenceIdCtrl.dispose();
    _oxygenCreditNumberingSequenceIdCtrl.dispose();
    _oxygenPaymentMethodIdCtrl.dispose();
    _invoiceSeriesCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      // ── Stripe: φορτώνεται ΠΑΝΤΑ (default ΚΑΙ tenants), ανεξάρτητα από
      // τη Viva λογική — ίδιο endpoint επιστρέφει και το ενεργό paymentProvider.
      try {
        final stripeCallable =
            FirebaseFunctions.instance.httpsCallable('getTenantStripeCredentialsForOwner');
        final stripeRes = await stripeCallable.call({'tenantId': _tenantId});
        final stripeData = Map<String, dynamic>.from(stripeRes.data);
        setState(() {
          _maskedStripeSecretKey      = stripeData['stripeSecretKeyMasked'] as String?;
          _maskedStripePublishableKey = stripeData['stripePublishableKeyMasked'] as String?;
          _maskedStripeWebhookSecret  = stripeData['stripeWebhookSecretMasked'] as String?;
          _hasStripeCredentials       = stripeData['hasStripeCredentials'] == true;
          _paymentProvider            = stripeData['paymentProvider'] as String? ?? 'viva';
        });
      } catch (e) {
        // Μη κρίσιμο — η σελίδα δουλεύει κανονικά με Viva ακόμα κι αν αυτό αποτύχει.
      }

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
              _hasOwnResendKey         = bi['hasOwnResendKey'] as bool? ?? false;
              _emailsEnabled           = bi['emailsEnabled'] as bool? ?? true;
              _afmCtrl.text            = bi['afm'] as String? ?? '';
              _doyCtrl.text            = bi['doy'] as String? ?? '';
              _taxAddressCtrl.text     = bi['taxAddress'] as String? ?? '';
              _kadCtrl.text            = bi['kad'] as String? ?? '';
              _invoiceProvider         = bi['invoiceProvider'] as String? ?? 'none';
              _hasInvoiceApiKey        = bi['hasInvoiceApiKey'] as bool? ?? false;
              _epsilonEmailCtrl.text   = bi['epsilonEmail'] as String? ?? '';
              _epsilonItemCodeCtrl.text = bi['epsilonItemCode'] as String? ?? '';
              _hasEpsilonPassword      = bi['hasEpsilonPassword'] as bool? ?? false;
              _mydataUsernameCtrl.text = bi['mydataUsername'] as String? ?? '';
              _hasMydataSubKey         = bi['hasMydataSubKey'] as bool? ?? false;
              _invoiceEnabled          = bi['invoiceEnabled'] as bool? ?? false;
              _invoiceSeriesCtrl.text  = bi['invoiceSeries'] as String? ?? '';
              _mydataInvoiceType       = bi['mydataInvoiceType'] as String? ?? '11.2';
              _mydataVatCategory       = bi['mydataVatCategory'] as String? ?? '2';
              _mydataDemo              = bi['mydataDemo'] as bool? ?? true;
              _oxygenBranchIdCtrl.text = bi['oxygenBranchId'] as String? ?? '';
              _oxygenNumberingSequenceIdCtrl.text = bi['oxygenNumberingSequenceId'] as String? ?? '';
              _oxygenCreditNumberingSequenceIdCtrl.text = bi['oxygenCreditNumberingSequenceId'] as String? ?? '';
              _oxygenPaymentMethodIdCtrl.text = bi['oxygenPaymentMethodId'] as String? ?? '';
              _oxygenSandbox           = bi['oxygenSandbox'] as bool? ?? true;
            });
          }
          // ── Αυτόματη προσυμπλήρωση (ΜΟΝΟ αν είναι ακόμα κενά, ώστε να μην
          // πειράξουμε ό,τι έχει ήδη σώσει ο tenant): το κινητό του από το
          // presence, και το email με το οποίο έχει κάνει login. Ο tenant
          // μπορεί μετά να τα αλλάξει ελεύθερα.
          if (_contactPhoneCtrl.text.trim().isEmpty ||
              _whatsappNumberCtrl.text.trim().isEmpty ||
              _contactEmailCtrl.text.trim().isEmpty) {
            try {
              final uid = FirebaseAuth.instance.currentUser?.uid;
              String myPhone = '';
              if (uid != null) {
                final pDoc = await FirebaseFirestore.instance
                    .collection('presence').doc(uid).get();
                myPhone = (pDoc.data()?['phone'] as String?) ?? '';
              }
              final myEmail = FirebaseAuth.instance.currentUser?.email ?? '';
              setState(() {
                if (_contactPhoneCtrl.text.trim().isEmpty && myPhone.isNotEmpty) {
                  _contactPhoneCtrl.text = myPhone;
                }
                if (_whatsappNumberCtrl.text.trim().isEmpty && myPhone.isNotEmpty) {
                  _whatsappNumberCtrl.text = myPhone;
                }
                if (_contactEmailCtrl.text.trim().isEmpty && myEmail.isNotEmpty) {
                  _contactEmailCtrl.text = myEmail;
                }
              });
            } catch (_) {
              // Μη κρίσιμο — ο tenant τα συμπληρώνει χειροκίνητα αν αποτύχει.
            }
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

  Future<void> _switchProvider(String provider) async {
    if (provider == _paymentProvider) return;
    setState(() { _savingProvider = true; _error = null; });
    try {
      final callable =
          FirebaseFunctions.instance.httpsCallable('updateTenantPaymentProvider');
      await callable.call({'tenantId': _tenantId, 'paymentProvider': provider});
      setState(() => _paymentProvider = provider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(provider == 'stripe'
              ? 'Ενεργός πάροχος: Stripe'
              : 'Ενεργός πάροχος: Viva'),
          backgroundColor: kPistachioAccent,
        ));
      }
    } catch (e) {
      setState(() => _error = 'Σφάλμα αλλαγής παρόχου: $e');
    } finally {
      if (mounted) setState(() => _savingProvider = false);
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
      // ── Stripe credentials: αποθηκεύονται ΠΑΝΤΑ (ίδιο callable για default
      // ΚΑΙ tenants — το ίδιο endpoint χειρίζεται και τα δύο). ΔΕΝ εξαρτάται
      // από το ποιος πάροχος είναι ενεργός τώρα, ώστε να μπορεί κάποιος να
      // προετοιμάσει τα Stripe κλειδιά του πριν αλλάξει τον διακόπτη.
      if (_stripeSecretKeyCtrl.text.trim().isNotEmpty ||
          _stripePublishableKeyCtrl.text.trim().isNotEmpty ||
          _stripeWebhookSecretCtrl.text.trim().isNotEmpty) {
        try {
          final stripeCallable =
              FirebaseFunctions.instance.httpsCallable('updateTenantStripeCredentials');
          await stripeCallable.call({
            'tenantId': _tenantId,
            if (_stripeSecretKeyCtrl.text.trim().isNotEmpty)
              'stripeSecretKey': _stripeSecretKeyCtrl.text.trim(),
            if (_stripePublishableKeyCtrl.text.trim().isNotEmpty)
              'stripePublishableKey': _stripePublishableKeyCtrl.text.trim(),
            if (_stripeWebhookSecretCtrl.text.trim().isNotEmpty)
              'stripeWebhookSecret': _stripeWebhookSecretCtrl.text.trim(),
          });
        } catch (e) {
          setState(() => _error = 'Σφάλμα αποθήκευσης Stripe: $e');
        }
      }

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
        // Στοιχεία επιχείρησης — τώρα δουλεύει και για τον δικό σου (default)
        // λογαριασμό, όχι μόνο για τους tenants.
        final biCallable =
            FirebaseFunctions.instance.httpsCallable('updateTenantBusinessInfo');
        await biCallable.call({
          'tenantId': 'default',
          'businessName': _businessNameCtrl.text.trim(),
          'contactPhone': _contactPhoneCtrl.text.trim(),
          'contactEmail': _contactEmailCtrl.text.trim(),
          'whatsappNumber': _whatsappNumberCtrl.text.trim(),
          'logoUrl': _logoUrlCtrl.text.trim(),
        });
        if (_businessNameCtrl.text.trim().isNotEmpty) {
          _tenantName = _businessNameCtrl.text.trim();
        }
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
        // ── Μόλις βάλει ο tenant ΔΙΚΑ ΤΟΥ credentials (έστω και ένα πεδίο),
        // κλείνουμε αυτόματα το Demo — αν μπαίνει σε πραγματικά κλειδιά,
        // σημαίνει ότι πάει για Live, όχι δοκιμή με το κοινό demo λογαριασμό.
        final enteringOwnKeys = _clientIdCtrl.text.trim().isNotEmpty ||
            _clientSecretCtrl.text.trim().isNotEmpty ||
            _merchantIdCtrl.text.trim().isNotEmpty ||
            _apiKeyCtrl.text.trim().isNotEmpty;
        if (enteringOwnKeys && _demo) {
          setState(() => _demo = false);
        }

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
    final tabCount = _isDefault ? 4 : 5;
    return DefaultTabController(
      length: tabCount,
      child: Scaffold(
        appBar: AppBar(
          foregroundColor: Colors.white,
          elevation: 0,
          flexibleSpace: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF00695C), Color(0xFF26A69A)],
              ),
            ),
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Ρυθμίσεις Online Φόρμας',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
              Text(_tenantName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.normal, color: Colors.white70)),
            ],
          ),
          bottom: TabBar(
            indicatorColor: Colors.amberAccent,
            indicatorWeight: 3,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white60,
            labelStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold),
            isScrollable: true,
            tabs: [
              const Tab(icon: Icon(Icons.account_balance_rounded, size: 20), text: 'Bank'),
              const Tab(icon: Icon(Icons.cloud_rounded, size: 20), text: 'Google Cloud'),
              const Tab(icon: Icon(Icons.storefront_rounded, size: 20), text: 'Επιχείρηση'),
              if (!_isDefault)
                const Tab(icon: Icon(Icons.mail_rounded, size: 20), text: 'Email'),
              const Tab(icon: Icon(Icons.receipt_long_rounded, size: 20), text: 'Απόδειξη'),
            ],
          ),
        ),
        backgroundColor: const Color(0xFFF3F5F7),
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
                    if (!_isDefault) _buildEmailTab(),
                    _buildReceiptTab(),
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
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: kPistachioAccent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                      textStyle: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox(
                            width: 20, height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.save_rounded),
                    label: const Text('Αποθήκευση (όλα τα tabs)'),
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
  // ── Κομψό περιτύλιγμα tab: απαλό φόντο + λευκή στρογγυλεμένη κάρτα με
  // διακριτική σκιά. Ένα σημείο αλλαγής για ΟΛΑ τα tabs.
  Widget _tabWrap({required Widget child}) {
    return Container(
      color: const Color(0xFFF3F5F7),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(14, 14, 14,
            14 + MediaQuery.of(context).viewPadding.bottom),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.grey.shade200),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 14,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }

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
    return _tabWrap(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Επιλογή ενεργού παρόχου πληρωμών ──────────────────────────────
          const Text('Πάροχος πληρωμών',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 4),
          const Text(
            'Μπορείς να αποθηκεύσεις credentials και για τους δύο παρόχους '
            'και να διαλέξεις ελεύθερα ποιος είναι ενεργός στη φόρμα.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 10),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'viva', label: Text('Viva'), icon: Icon(Icons.payment_rounded)),
              ButtonSegment(value: 'stripe', label: Text('Stripe'), icon: Icon(Icons.credit_card_rounded)),
            ],
            selected: {_paymentProvider},
            onSelectionChanged: _savingProvider
                ? null
                : (sel) => _switchProvider(sel.first),
            style: SegmentedButton.styleFrom(
              selectedBackgroundColor: kPistachioAccent,
              selectedForegroundColor: Colors.white,
            ),
          ),
          if (_savingProvider) ...[
            const SizedBox(height: 8),
            const LinearProgressIndicator(minHeight: 2),
          ],
          const SizedBox(height: 20),
          const Divider(),
          const SizedBox(height: 12),

          if (_paymentProvider == 'stripe') ...[
            _buildStripeFields(),
          ] else ...[
            _buildVivaFields(),
          ],
        ],
      ),
    );
  }

  Widget _buildStripeFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          margin: const EdgeInsets.only(bottom: 16),
          decoration: BoxDecoration(
            color: Colors.blue.shade50,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.blue.shade200),
          ),
          child: const Text(
            'Βρες τα κλειδιά σου στο Stripe Dashboard → Developers → API keys. '
            'Το Webhook Signing Secret δημιουργείται όταν προσθέσεις το endpoint '
            'στο Developers → Webhooks (βλ. οδηγίες παρακάτω).',
            style: TextStyle(fontSize: 12.5),
          ),
        ),
        if (_hasStripeCredentials) ...[
          const Text('Ήδη αποθηκευμένα (κρυμμένα)',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          const SizedBox(height: 6),
          _maskedRow('Secret Key', _maskedStripeSecretKey),
          _maskedRow('Publishable Key', _maskedStripePublishableKey),
          _maskedRow('Webhook Secret', _maskedStripeWebhookSecret),
          const SizedBox(height: 16),
          const Divider(),
          const SizedBox(height: 8),
        ],
        Text(
          _hasStripeCredentials
              ? 'Συμπλήρωσε ΜΟΝΟ ό,τι θες να αλλάξεις:'
              : 'Συμπλήρωσε τα στοιχεία σου:',
          style: const TextStyle(fontSize: 12.5, color: Colors.grey),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _stripeSecretKeyCtrl,
          obscureText: true,
          decoration: const InputDecoration(
              labelText: 'Stripe Secret Key (sk_...)',
              border: OutlineInputBorder()),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _stripePublishableKeyCtrl,
          decoration: const InputDecoration(
              labelText: 'Stripe Publishable Key (pk_...)',
              border: OutlineInputBorder()),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _stripeWebhookSecretCtrl,
          obscureText: true,
          decoration: const InputDecoration(
              labelText: 'Stripe Webhook Signing Secret (whsec_...)',
              helperText: 'Δημιουργείται όταν προσθέσεις το webhook endpoint στο Stripe dashboard.',
              border: OutlineInputBorder()),
        ),
        const SizedBox(height: 16),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: kPistachio,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: kPistachioAccent),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Οδηγίες ρύθμισης Stripe',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              const SizedBox(height: 6),
              Text(
                '1. Σύνδεση στο dashboard.stripe.com → Developers → API keys\n'
                '2. Αντέγραψε το Secret Key και το Publishable Key εδώ\n'
                '3. Πήγαινε στο Developers → Webhooks → Add endpoint\n'
                '4. URL: https://us-central1-my-taxi-app-bbc7c.cloudfunctions.net/stripeWebhook?tenantId=$_tenantId\n'
                '5. Event: checkout.session.completed\n'
                '6. Αντέγραψε το Signing Secret (whsec_...) εδώ και πάτησε Αποθήκευση',
                style: const TextStyle(fontSize: 12.5, color: kPistachioText),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildVivaFields() {
    return Column(
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
      );
  }

  // ─── Tab 2: Google Cloud ──────────────────────────────────────────────────
  Widget _buildGoogleCloudTab() {
    return _tabWrap(
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
    return _tabWrap(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.storefront_rounded, size: 18, color: Colors.indigo[700]),
            const SizedBox(width: 6),
            const Text('Στοιχεία Επιχείρησης',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          ]),
          const SizedBox(height: 4),
          Text(
            _isDefault
                ? 'Εμφανίζονται αυτόματα στη δική σου φόρμα κράτησης (booking.html) '
                  'και στο email επιβεβαίωσης προς τον πελάτη — δεν χρειάζεται να '
                  'επεξεργαστείς κώδικα.'
                : 'Εμφανίζονται αυτόματα στη δική σου φόρμα κράτησης (booking2.html) '
                  'και στο email επιβεβαίωσης προς τον πελάτη — δεν χρειάζεται να '
                  'επεξεργαστείς κώδικα.',
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
                    'και επικόλλησε εδώ το link της εικόνας — εμφανίζεται και '
                    'στην κορυφή/υποσέλιδο του email επιβεβαίωσης.',
                border: OutlineInputBorder()),
          ),
        ],
      ),
    );
  }

  // ─── Tab 4: Email (Resend) — μόνο για tenants, όχι για default ──────────
  Future<void> _saveResendKey() async {
    setState(() => _savingResendKey = true);
    try {
      final callable = FirebaseFunctions.instance.httpsCallable('updateTenantResendKey');
      final res = await callable.call({
        'tenantId': _tenantId,
        'resendApiKey': _resendKeyCtrl.text.trim(),
      });
      setState(() {
        _hasOwnResendKey = res.data['hasOwnResendKey'] == true;
        if (_hasOwnResendKey) _emailsEnabled = true;
        _resendKeyCtrl.clear();
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(_hasOwnResendKey
              ? 'Αποθηκεύτηκε — τα email θα στέλνονται πλέον από τον δικό σου Resend λογαριασμό.'
              : 'Αφαιρέθηκε — τα email θα στέλνονται ξανά από το κοινό μας σύστημα.'),
          backgroundColor: const Color(0xFF1E8E3E),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Σφάλμα: $e'), backgroundColor: Colors.red.shade700));
      }
    } finally {
      if (mounted) setState(() => _savingResendKey = false);
    }
  }

  Widget _buildEmailTab() {
    return _tabWrap(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.mail_rounded, size: 18, color: Colors.indigo[700]),
            const SizedBox(width: 6),
            const Text('Email επιβεβαίωσης πελάτη',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          ]),
          const SizedBox(height: 8),
          Text(
            'Αυτή τη στιγμή τα email επιβεβαίωσης στέλνονται μέσω του κοινού '
            'μας συστήματος (Resend). Αν έχεις δικό σου λογαριασμό Resend με '
            'δικό σου επαληθευμένο domain, βάλε εδώ το API key σου ώστε τα '
            'email να φαίνονται 100% δικά σου.',
            style: TextStyle(fontSize: 12.5, color: Colors.grey[700]),
          ),
          const SizedBox(height: 16),

          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _hasOwnResendKey ? Colors.green.shade50 : Colors.grey.shade100,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: _hasOwnResendKey ? Colors.green.shade300 : Colors.grey.shade300),
            ),
            child: Row(children: [
              Icon(
                  _hasOwnResendKey ? Icons.check_circle_rounded : Icons.info_outline_rounded,
                  color: _hasOwnResendKey ? Colors.green.shade700 : Colors.grey.shade600,
                  size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _hasOwnResendKey
                      ? 'Χρησιμοποιείς το δικό σου Resend key.'
                      : 'Χρησιμοποιείς το κοινό μας σύστημα email (προεπιλογή).',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: _hasOwnResendKey ? Colors.green.shade900 : Colors.grey.shade800),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 16),

          TextField(
            controller: _resendKeyCtrl,
            obscureText: true,
            decoration: InputDecoration(
                isDense: true,
                labelText: 'Resend API Key',
                hintText: _hasOwnResendKey ? '•••••••••••• (ήδη αποθηκευμένο)' : 're_xxxxxxxxxxxx',
                helperText: 'Άδειασέ το και πάτα Αποθήκευση για να αφαιρέσεις το δικό σου '
                    'key και να γυρίσεις στο κοινό μας σύστημα.',
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _savingResendKey ? null : _saveResendKey,
              icon: _savingResendKey
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.save_rounded),
              label: Text(_savingResendKey ? 'Αποθήκευση…' : 'Αποθήκευση Resend key'),
            ),
          ),

          const SizedBox(height: 20),
          const Divider(),
          const SizedBox(height: 12),
          Row(children: [
            Icon(Icons.power_settings_new_rounded, size: 18,
                color: _emailsEnabled ? Colors.green[700] : Colors.red[700]),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _emailsEnabled
                    ? 'Τα αυτόματα email είναι ενεργά.'
                    : 'Ο master έχει απενεργοποιήσει τα αυτόματα email για σένα.',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
          ]),
          if (!_emailsEnabled) ...[
            const SizedBox(height: 6),
            Text(
              'Βάλε το δικό σου Resend key παραπάνω για να ενεργοποιηθούν '
              'ξανά αυτόματα.',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ],

          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => launchUrl(Uri.parse('https://resend.com/api-keys'),
                  mode: LaunchMode.externalApplication),
              icon: const Icon(Icons.open_in_new_rounded),
              label: const Text('Άνοιγμα Resend — Δημιουργία API Key'),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Tab: Απόδειξη — φορολογικά στοιχεία + πάροχος τιμολόγησης ──────────
  Future<void> _saveReceiptInfo() async {
    setState(() => _savingReceipt = true);
    try {
      final callable = FirebaseFunctions.instance.httpsCallable('updateTenantReceiptInfo');
      final res = await callable.call({
        'tenantId': _tenantId,
        'afm': _afmCtrl.text.trim(),
        'doy': _doyCtrl.text.trim(),
        'taxAddress': _taxAddressCtrl.text.trim(),
        'kad': _kadCtrl.text.trim(),
        'invoiceProvider': _invoiceProvider,
        'invoiceEnabled': _invoiceEnabled,
        'invoiceSeries': _invoiceSeriesCtrl.text.trim(),
        'mydataInvoiceType': _mydataInvoiceType,
        'mydataVatCategory': _mydataVatCategory,
        'mydataDemo': _mydataDemo,
        'mydataUsername': _mydataUsernameCtrl.text.trim(),
        'invoiceApiKey': _invoiceApiKeyCtrl.text.trim(),
        'epsilonEmail': _epsilonEmailCtrl.text.trim(),
        'epsilonPassword': _epsilonPasswordCtrl.text.trim(),
        'epsilonItemCode': _epsilonItemCodeCtrl.text.trim(),
        'mydataSubKey': _mydataSubKeyCtrl.text.trim(),
        'oxygenBranchId': _oxygenBranchIdCtrl.text.trim(),
        'oxygenNumberingSequenceId': _oxygenNumberingSequenceIdCtrl.text.trim(),
        'oxygenCreditNumberingSequenceId': _oxygenCreditNumberingSequenceIdCtrl.text.trim(),
        'oxygenPaymentMethodId': _oxygenPaymentMethodIdCtrl.text.trim(),
        'oxygenSandbox': _oxygenSandbox,
      });
      if (res.data['ok'] == true) {
        setState(() {
          if (_invoiceApiKeyCtrl.text.trim().isNotEmpty) _hasInvoiceApiKey = true;
          if (_epsilonPasswordCtrl.text.trim().isNotEmpty) _hasEpsilonPassword = true;
          if (_mydataSubKeyCtrl.text.trim().isNotEmpty) _hasMydataSubKey = true;
          _invoiceApiKeyCtrl.clear();
          _epsilonPasswordCtrl.clear();
          _mydataSubKeyCtrl.clear();
        });
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Αποθηκεύτηκαν τα στοιχεία απόδειξης.'),
          backgroundColor: Color(0xFF1E8E3E),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Σφάλμα: $e'), backgroundColor: Colors.red.shade700));
      }
    } finally {
      if (mounted) setState(() => _savingReceipt = false);
    }
  }

  Widget _mydataStep(String number, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 18, height: 18,
            margin: const EdgeInsets.only(top: 1),
            decoration: BoxDecoration(color: Colors.green.shade700, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: Text(number, style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(fontSize: 11.5, color: Colors.green.shade900))),
        ],
      ),
    );
  }

  Widget _epsilonStep(String number, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 18, height: 18,
            margin: const EdgeInsets.only(top: 1),
            decoration: BoxDecoration(color: Colors.blue.shade700, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: Text(number, style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(fontSize: 11.5, color: Colors.blue.shade900))),
        ],
      ),
    );
  }

  Widget _buildReceiptTab() {
    return _tabWrap(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.receipt_long_rounded, size: 18, color: Colors.indigo[700]),
            const SizedBox(width: 6),
            const Text('Απόδειξη / Τιμολόγιο',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          ]),
          const SizedBox(height: 6),
          Text(
            'Αν βάλεις πάροχο ηλεκτρονικής τιμολόγησης, θα εκδίδεται αυτόματα '
            'νόμιμο παραστατικό μόλις ολοκληρωθεί μια πληρωμή, με ΜΑΡΚ από το myDATA. '
            'Προαιρετικό — αν το αφήσεις σε «Κανένα», συνεχίζει να στέλνεται μόνο '
            'το email επιβεβαίωσης, χωρίς παραστατικό.',
            style: TextStyle(fontSize: 11.5, color: Colors.grey[600]),
          ),
          const SizedBox(height: 16),

          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _invoiceEnabled ? Colors.green.shade50 : Colors.grey.shade100,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: _invoiceEnabled ? Colors.green.shade300 : Colors.grey.shade300),
            ),
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Αυτόματη έκδοση παραστατικού',
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.bold,
                      color: _invoiceEnabled ? Colors.green.shade900 : Colors.grey.shade800)),
              subtitle: Text(
                  _invoiceEnabled
                      ? 'Ενεργό — εκδίδεται αυτόματα με ΤΑ ΔΙΚΑ ΣΟΥ στοιχεία/κλειδιά.'
                      : 'Κλειστό εξ ορισμού — ΔΕΝ εκδίδεται τίποτα μέχρι να το ανοίξεις '
                        'ρητά εσύ, αφού έχεις συμπληρώσει τα στοιχεία σου παρακάτω.',
                  style: const TextStyle(fontSize: 11)),
              value: _invoiceEnabled,
              onChanged: (v) => setState(() => _invoiceEnabled = v),
            ),
          ),
          const SizedBox(height: 16),

          const Text('Φορολογικά στοιχεία', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5)),
          const SizedBox(height: 8),
          TextField(
            controller: _afmCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(isDense: true, labelText: 'ΑΦΜ', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _doyCtrl,
            decoration: const InputDecoration(isDense: true, labelText: 'ΔΟΥ', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _taxAddressCtrl,
            decoration: const InputDecoration(
                isDense: true, labelText: 'Διεύθυνση επιχείρησης', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _kadCtrl,
            decoration: const InputDecoration(
                isDense: true, labelText: 'ΚΑΔ (κωδικός δραστηριότητας)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _invoiceSeriesCtrl,
            decoration: const InputDecoration(
                isDense: true,
                labelText: 'Σειρά παραστατικών (προαιρετικό)',
                hintText: 'π.χ. "Ταξί" ή "Β"',
                helperText: 'Αν κόβεις ήδη παραστατικά αλλού (π.χ. Epsilon για άλλα), '
                    'όρισε εδώ ΞΕΧΩΡΙΣΤΗ σειρά ώστε να μη συγκρούονται οι αριθμοί — '
                    'ρώτα τον λογιστή σου αν δεν είσαι σίγουρος.',
                border: OutlineInputBorder()),
          ),

          const SizedBox(height: 20),
          const Divider(),
          const SizedBox(height: 8),
          const Text('Πάροχος ηλεκτρονικής τιμολόγησης',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5)),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: _invoiceProvider,
            decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
            items: const [
              DropdownMenuItem(value: 'none', child: Text('Κανένα (μόνο email επιβεβαίωσης)')),
              DropdownMenuItem(value: 'epsilon', child: Text('Epsilon Smart (πληρωμένος πάροχος)')),
              DropdownMenuItem(value: 'mydata', child: Text('Απευθείας myDATA API (δωρεάν, της ΑΑΔΕ)')),
              DropdownMenuItem(value: 'oxygen', child: Text('Oxygen Pelatologio (πληρωμένος πάροχος)')),
            ],
            onChanged: (v) => setState(() => _invoiceProvider = v ?? 'none'),
          ),
          const SizedBox(height: 12),

          if (_invoiceProvider == 'epsilon') ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.blue.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Βήματα πριν συμπληρώσεις τα παρακάτω:',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5, color: Colors.blue.shade900)),
                  const SizedBox(height: 6),
                  _epsilonStep('1', 'Κάνε συνδρομή στο Epsilon Smart (epsilonnet.gr), αν δεν έχεις ήδη.'),
                  _epsilonStep('2', 'Μπες στο myaccount.epsilonnet.gr → βρες τη συνδρομή σου → '
                      'πάτησε το κουμπί που δείχνει το «Subscription Key» και αντέγραψέ το.'),
                  _epsilonStep('3', '(Συνιστάται) Από το ίδιο σημείο, «Ενέργειες» → «Δημιουργία χρήστη API» — '
                      'θα πάρεις ξεχωριστό email/κωδικό ειδικά για τη σύνδεση, χωρίς να εκθέσεις τον προσωπικό σου.'),
                  _epsilonStep('4', 'Μέσα στο Epsilon Smart, φτιάξε μία «Υπηρεσία» (π.χ. «Μεταφορά Ταξί») — '
                      'Είδη/Υπηρεσίες → Νέο. Κράτα τον κωδικό της.'),
                  _epsilonStep('5', 'Συμπλήρωσε τα 4 πεδία παρακάτω με ό,τι πήρες στα βήματα 2-4, και πάτησε Αποθήκευση.'),
                  _epsilonStep('6', 'Άνοιξε τον διακόπτη «Αυτόματη έκδοση παραστατικού» πιο πάνω μόνο αφού '
                      'δοκιμάσεις με μία πραγματική κράτηση και δεις ότι βγήκε σωστά το παραστατικό.'),
                ],
              ),
            ),
            Text(_hasInvoiceApiKey && _hasEpsilonPassword
                ? 'Έχουν ήδη αποθηκευτεί τα στοιχεία σύνδεσης.'
                : 'Λείπουν ακόμα στοιχεία σύνδεσης.',
                style: TextStyle(fontSize: 11.5, color: Colors.grey[600])),
            const SizedBox(height: 8),
            TextField(
              controller: _invoiceApiKeyCtrl,
              obscureText: true,
              decoration: InputDecoration(
                  isDense: true,
                  labelText: 'Subscription Key',
                  hintText: _hasInvoiceApiKey ? '•••••••••• (ήδη αποθηκευμένο)' : null,
                  helperText: 'Από τη σελίδα προβολής της συνδρομής σου στο myaccount.epsilonnet.gr',
                  border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _epsilonEmailCtrl,
              decoration: const InputDecoration(
                  isDense: true, labelText: 'Email σύνδεσης Epsilon Smart', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _epsilonPasswordCtrl,
              obscureText: true,
              decoration: InputDecoration(
                  isDense: true,
                  labelText: 'Κωδικός πρόσβασης',
                  hintText: _hasEpsilonPassword ? '•••••••••• (ήδη αποθηκευμένο)' : null,
                  helperText: 'Συνιστάται να φτιάξεις ξεχωριστό «Χρήστη API» (myaccount.epsilonnet.gr → '
                      'Συνδρομή → Ενέργειες → Δημιουργία χρήστη API) αντί για τον προσωπικό σου κωδικό.',
                  border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _epsilonItemCodeCtrl,
              decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Κωδικός υπηρεσίας στο Epsilon Smart',
                  helperText: 'Πρέπει να έχεις ήδη δημιουργήσει μία «Υπηρεσία» (π.χ. «Μεταφορά Ταξί») '
                      'στο Epsilon Smart και να βάλεις εδώ τον κωδικό της.',
                  border: OutlineInputBorder()),
            ),
          ],

          if (_invoiceProvider == 'oxygen') ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.blue.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Βήματα πριν συμπληρώσεις τα παρακάτω:',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5, color: Colors.blue.shade900)),
                  const SizedBox(height: 6),
                  _epsilonStep('1', 'Κάνε λογαριασμό στο pelatologio.gr (Oxygen Pelatologio), αν δεν έχεις ήδη.'),
                  _epsilonStep('2', 'Μπες στο docs.oxygen.gr → πάτησε «Authorize» πάνω δεξιά → βάλε το '
                      'API key σου (Bearer token) — το βρίσκεις στις ρυθμίσεις του λογαριασμού σου στο pelatologio.gr.'),
                  _epsilonStep('3', 'Στο ίδιο docs.oxygen.gr, άνοιξε «GET /branches» → «Try it out» → «Execute» — '
                      'αντέγραψε το «id» του υποκαταστήματός σου από την απάντηση.'),
                  _epsilonStep('4', 'Άνοιξε «GET /numbering-sequences» → «Try it out» → «Execute» — '
                      'αντέγραψε το «id» της σειράς αρίθμησης που θες να χρησιμοποιείς. '
                      'Φτιάξε στο Oxygen και ΔΕΥΤΕΡΗ σειρά, μόνο για πιστωτικά, και κράτα και το δικό της «id» — '
                      'χρειάζεται για το αυτόματο πιστωτικό όταν ακυρώνεται κράτηση.'),
                  _epsilonStep('5', '(Προαιρετικό) Άνοιξε «GET /payment-methods» ομοίως, αν θες να ορίσεις '
                      'συγκεκριμένο τρόπο πληρωμής στα παραστατικά.'),
                  _epsilonStep('6', 'Συμπλήρωσε τα πεδία παρακάτω με ό,τι πήρες, και πάτησε Αποθήκευση.'),
                  _epsilonStep('7', 'Άφησε ενεργό το «Δοκιμαστικό περιβάλλον (sandbox)» μέχρι να δοκιμάσεις '
                      'με μία πραγματική κράτηση και να δεις ότι βγήκε σωστά το παραστατικό.'),
                ],
              ),
            ),
            Text(_hasInvoiceApiKey
                ? 'Έχει ήδη αποθηκευτεί API key.'
                : 'Δεν έχει μπει ακόμα API key.',
                style: TextStyle(fontSize: 11.5, color: Colors.grey[600])),
            const SizedBox(height: 6),
            TextField(
              controller: _invoiceApiKeyCtrl,
              obscureText: true,
              decoration: InputDecoration(
                  isDense: true,
                  labelText: 'API Key Oxygen Pelatologio',
                  hintText: _hasInvoiceApiKey ? '•••••••••• (ήδη αποθηκευμένο)' : null,
                  helperText: 'Βρίσκεται στο pelatologio.gr, μετά από εγγραφή: '
                      'Ρυθμίσεις → API → Δημιουργία κλειδιού (Oxygen MDP).',
                  border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _oxygenBranchIdCtrl,
              decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Branch ID',
                  helperText: 'Από docs.oxygen.gr → GET /branches → πεδίο «id».',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _oxygenNumberingSequenceIdCtrl,
              decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Numbering Sequence ID',
                  helperText: 'Από docs.oxygen.gr → GET /numbering-sequences → πεδίο «id».',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _oxygenCreditNumberingSequenceIdCtrl,
              decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Numbering Sequence ID Πιστωτικών',
                  helperText: 'Φτιάξε στο Oxygen ΞΕΧΩΡΙΣΤΗ σειρά για πιστωτικά και βάλε εδώ το «id» της '
                      '(GET /numbering-sequences). Χωρίς αυτήν ΔΕΝ εκδίδεται αυτόματο πιστωτικό σε ακύρωση.',
                  helperMaxLines: 3,
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _oxygenPaymentMethodIdCtrl,
              decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Payment Method ID (προαιρετικό)',
                  helperText: 'Από docs.oxygen.gr → GET /payment-methods → πεδίο «id». '
                      'Άφησέ το κενό αν δεν χρειάζεσαι συγκεκριμένο τρόπο πληρωμής.',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Δοκιμαστικό περιβάλλον (sandbox)', style: TextStyle(fontSize: 13)),
              subtitle: const Text('Άφησέ το ενεργό μέχρι να επιβεβαιώσεις ότι δουλεύει σωστά.',
                  style: TextStyle(fontSize: 11.5)),
              value: _oxygenSandbox,
              onChanged: (v) => setState(() => _oxygenSandbox = v),
            ),
          ],

          if (_invoiceProvider == 'mydata') ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.green.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.green.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Βήματα πριν συμπληρώσεις τα παρακάτω:',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5, color: Colors.green.shade900)),
                  const SizedBox(height: 6),
                  _mydataStep('1', 'Μπες στο aade.gr/mydata με τους κωδικούς Taxisnet της επιχείρησης.'),
                  _mydataStep('2', 'Βρες τη «Φόρμα εγγραφής στο myDATA REST API» και συμπλήρωσέ τη — '
                      'είναι εντελώς δωρεάν.'),
                  _mydataStep('3', 'Θα πάρεις ένα Username και ένα Subscription Key (κλειδί συνδρομητή) — '
                      'κράτα τα και τα δύο.'),
                  _mydataStep('4', 'Συμπλήρωσε τα Username/Subscription Key παρακάτω και πάτησε Αποθήκευση.'),
                  _mydataStep('5', 'Άφησε το Demo/Sandbox ενεργό (μπλε) όσο δοκιμάζεις — δεν μετράει σαν '
                      'πραγματικό παραστατικό.'),
                  _mydataStep('6', 'Κάνε μία δοκιμαστική κράτηση/πληρωμή και έλεγξε στα Firebase logs τη γραμμή '
                      '«mydata receipt issued, MARK:» — αν εμφανιστεί, δούλεψε σωστά.'),
                  _mydataStep('7', 'Μόνο τότε γύρνα το διακόπτη πιο κάτω σε Live, ΚΑΙ άνοιξε τον διακόπτη '
                      '«Αυτόματη έκδοση παραστατικού» πιο πάνω.'),
                ],
              ),
            ),
            Text(_hasMydataSubKey
                ? 'Έχει ήδη αποθηκευτεί κλειδί συνδρομητή myDATA.'
                : 'Δεν έχει μπει ακόμα κλειδί συνδρομητή myDATA.',
                style: TextStyle(fontSize: 11.5, color: Colors.grey[600])),
            const SizedBox(height: 8),
            TextField(
              controller: _mydataUsernameCtrl,
              decoration: const InputDecoration(
                  isDense: true, labelText: 'Username myDATA (εγγραφής REST API)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _mydataSubKeyCtrl,
              obscureText: true,
              decoration: InputDecoration(
                  isDense: true,
                  labelText: 'Subscription Key myDATA',
                  hintText: _hasMydataSubKey ? '•••••••••• (ήδη αποθηκευμένο)' : null,
                  border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: _mydataDemo ? Colors.blue.shade50 : Colors.red.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _mydataDemo ? Colors.blue.shade200 : Colors.red.shade300),
              ),
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_mydataDemo ? 'Δοκιμαστικό (Sandbox)' : 'Πραγματικό (Live)',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold,
                        color: _mydataDemo ? Colors.blue.shade900 : Colors.red.shade900)),
                subtitle: Text(
                    _mydataDemo
                        ? 'Ασφαλές — τα παραστατικά ΔΕΝ μετράνε πραγματικά, μόνο δοκιμή σύνδεσης. '
                          'Ανεξάρτητο από το Demo/Live της Viva.'
                        : '⚠️ Εκδίδονται ΠΡΑΓΜΑΤΙΚΑ, νόμιμα παραστατικά. Άλλαξε το μόνο αφού έχεις '
                          'δοκιμάσει με επιτυχία στο sandbox.',
                    style: const TextStyle(fontSize: 10.5)),
                value: !_mydataDemo,
                onChanged: (v) => setState(() => _mydataDemo = !v),
              ),
            ),
            const SizedBox(height: 12),
            Text('Ο χαρακτηρισμός εσόδων μπαίνει αυτόματα σωστά (E3_561_003/E3_561_001). '
                'Το ΦΠΑ 13% είναι προεπιλεγμένο — επιβεβαιωμένο για μεταφορά ΤΑΞΙ (Ν.5116/2024). '
                'Άλλαξέ το μόνο αν η δραστηριότητά σου διαφέρει:',
                style: TextStyle(fontSize: 11, color: Colors.grey[600])),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _mydataInvoiceType,
              decoration: const InputDecoration(
                  isDense: true, labelText: 'Τύπος παραστατικού', border: OutlineInputBorder()),
              items: const [
                DropdownMenuItem(value: '11.2', child: Text('11.2 — Απόδειξη Παροχής Υπηρεσιών (B2C)')),
                DropdownMenuItem(value: '2.1', child: Text('2.1 — Τιμολόγιο Παροχής Υπηρεσιών (B2B)')),
              ],
              onChanged: (v) => setState(() => _mydataInvoiceType = v ?? '11.2'),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _mydataVatCategory,
              decoration: const InputDecoration(
                  isDense: true, labelText: 'Κατηγορία ΦΠΑ', border: OutlineInputBorder()),
              items: const [
                DropdownMenuItem(value: '1', child: Text('24%')),
                DropdownMenuItem(value: '2', child: Text('13%')),
                DropdownMenuItem(value: '3', child: Text('6%')),
                DropdownMenuItem(value: '7', child: Text('Χωρίς ΦΠΑ / εξαίρεση')),
              ],
              onChanged: (v) => setState(() => _mydataVatCategory = v ?? '2'),
            ),
          ],

          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _savingReceipt ? null : _saveReceiptInfo,
              icon: _savingReceipt
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.save_rounded),
              label: Text(_savingReceipt ? 'Αποθήκευση…' : 'Αποθήκευση'),
            ),
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
              child: Text('1. Viva Client ID / Client Secret / API Key',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
            ),
            const SizedBox(height: 4),
            const Text(
              'Στο Viva dashboard: πλαϊνό μενού → «Ρυθμίσεις» → «Διαπιστευτήρια '
              'πρόσβασης API» (API Access Credentials). Εκεί θα βρεις το Client '
              'ID και το Client Secret (Smart Checkout), και πιο κάτω το API '
              'Key (Basic Authentication) — αντέγραψε ό,τι από τα δύο σου '
              'ζητάει η κάρτα σου.',
              style: TextStyle(fontSize: 12),
            ),

            const SizedBox(height: 12),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('2. Viva Merchant ID',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
            ),
            const SizedBox(height: 4),
            const Text(
              'Ίδια σελίδα («Ρυθμίσεις» → «Διαπιστευτήρια πρόσβασης API») — '
              'το Merchant ID εμφανίζεται συνήθως πάνω-πάνω στην ίδια σελίδα, '
              'ή στο «Προφίλ λογαριασμού» πάνω δεξιά.',
              style: TextStyle(fontSize: 12),
            ),

            const SizedBox(height: 12),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('3. Webhook (Ειδοποίηση πληρωμής)',
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
              child: Text('4. Source Code (Κωδικός)',
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
