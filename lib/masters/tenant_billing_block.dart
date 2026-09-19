// lib/masters/tenant_billing_block.dart
//
// «ΧΡΗΣΗ & ΚΟΣΤΟΣ» — μέσα στις Καθολικές ρυθμίσεις (μόνο super-admin).
// Δουλεύει ΑΚΡΙΒΩΣ ίδια σε Android και web (καθαρό Flutter + Firestore).
//
//  • Πίνακας tenants για τον επιλεγμένο μήνα: κόστος μας, χρέωση, κέρδος,
//    υπόλοιπο. Βέλη για προηγούμενους μήνες.
//  • Πάτημα σε tenant → οθόνη με: ανάλυση μήνα ανά υπηρεσία, υπόλοιπο &
//    πληρωμές/πίστωση (χειροκίνητα), ρυθμίσεις χρέωσης (billingMode, συνδρομή,
//    markup ανά υπηρεσία, δικά του κλειδιά, όρια).
//  • «Τιμές υπηρεσιών» → platform/pricing.rates (χωρίς deploy).
//
// Firestore (γράφεται από εδώ, κανόνες: μόνο masterEmail):
//   tenants/{id}/billing/settings , tenants/{id}/billing/account , platform/pricing
// Διαβάζει (γράφονται από usage.js):
//   usage/{id} , usage/{id}/monthly/{YYYY-MM}
//
// Υπόλοιπο = creditGrantedEur + paidEur − chargeTotalEur − feeChargedEur
// (δεν μηδενίζεται ποτέ· αρνητικό = ο tenant ΟΦΕΙΛΕΙ σε σένα).
// Η μηνιαία συνδρομή προστίθεται αυτόματα από το accrueTenantSubscriptions.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../app_theme.dart';

// Ομάδες υπηρεσιών (markup / δικά του κλειδιά) — ίδιες με το usage.js
const _groups = ['claude', 'google', 'resend', 'aerodatabox', 'sms', 'whatsapp'];
const _groupLabels = {
  'claude': 'Claude AI',
  'google': 'Google (Places/Routes/Geocoding)',
  'resend': 'Email (Resend)',
  'aerodatabox': 'Πτήσεις (AeroDataBox)',
  'sms': 'SMS',
  'whatsapp': 'WhatsApp',
};
const _serviceLabels = {
  'claude': 'Claude AI',
  'resend': 'Email (Resend)',
  'places_autocomplete': 'Places · αναζήτηση',
  'places_details': 'Places · λεπτομέρειες',
  'routes': 'Διαδρομές (Routes)',
  'geocode': 'Geocoding',
  'aerodatabox': 'Πτήσεις (AeroDataBox)',
  'sms': 'SMS',
  'whatsapp': 'WhatsApp',
};

// Προεπιλεγμένες τιμές (EUR ανά κλήση) — τιμές καταλόγου Google/Resend σε USD
// × 0.92, χωρίς δωρεάν όρια. Ίδιες με το usage.js. Άλλαξέ τες από το κουμπί
// «Τιμές υπηρεσιών» (π.χ. AeroDataBox από το πλάνο σου στο RapidAPI).
const _defaultUnitRates = {
  'resend': 0.000368,             // Resend Pro: $20 / 50.000 emails
  'places_autocomplete': 0.0,     // εντός session: δωρεάν
  'places_details': 0.01564,      // Place Details Pro $17/1000
  'routes': 0.0092,               // Compute Routes Pro $10/1000
  'geocode': 0.0046,              // Geocoding $5/1000
  'aerodatabox': 0.0092,          // ⚠️ από το πλάνο σου
  'sms': 0.046,                   // ⚠️ ενδεικτικό
  'whatsapp': 0.0,
};

// ── Βοηθητικά ────────────────────────────────────────────────────────────
double _d(dynamic v) => v is num ? v.toDouble() : 0.0;

double _p(String s) => double.tryParse(s.trim().replaceAll(',', '.')) ?? 0.0;

String _eur(num v) {
  final neg = v < 0;
  final a = v.abs();
  final s = (a != 0 && a < 1) ? a.toStringAsFixed(3) : a.toStringAsFixed(2);
  return '${neg ? '−' : ''}€$s';
}

String _mk(int y, int m) => '$y-${m.toString().padLeft(2, '0')}';

String _fmtNum(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

String _fmtDate(Timestamp? t) {
  if (t == null) return '';
  final d = t.toDate();
  return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
}

Widget _numField(TextEditingController ctrl, String label, {String? suffix}) {
  return TextField(
    controller: ctrl,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    decoration: InputDecoration(
      labelText: label,
      suffixText: suffix,
      isDense: true,
      border: const OutlineInputBorder(),
    ),
  );
}

class _Summary {
  final double monthCost, monthCharge, monthFee, chargeTotal, balance;
  final String mode;
  const _Summary({
    required this.monthCost,
    required this.monthCharge,
    required this.monthFee,
    required this.chargeTotal,
    required this.balance,
    required this.mode,
  });
}

// ════════════════════════════════════════════════════════════════════════════
//  ΚΑΡΤΑ ΣΤΙΣ ΚΑΘΟΛΙΚΕΣ ΡΥΘΜΙΣΕΙΣ
// ════════════════════════════════════════════════════════════════════════════
class TenantBillingBlock extends StatefulWidget {
  /// Η λίστα από το listTenants (κάθε στοιχείο: tenantId, businessName).
  final List<Map<String, dynamic>> tenants;
  const TenantBillingBlock({super.key, required this.tenants});

  @override
  State<TenantBillingBlock> createState() => _TenantBillingBlockState();
}

class _TenantBillingBlockState extends State<TenantBillingBlock> {
  late int _year;
  late int _month;
  bool _loading = true;
  final Map<String, _Summary> _sum = {};

  // Ο tenant «default» (δικός σου) δεν έχει createdAt → δεν έρχεται από το
  // listTenants. Τον προσθέτουμε πάντα πρώτο.
  List<Map<String, dynamic>> get _list {
    final l = widget.tenants
        .where((t) => (t['tenantId'] as String?)?.isNotEmpty == true)
        .toList();
    if (!l.any((t) => t['tenantId'] == 'default')) {
      l.insert(0, {'tenantId': 'default', 'businessName': 'Δικός μου (default)'});
    }
    return l;
  }

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _year = now.year;
    _month = now.month;
    _load();
  }

  @override
  void didUpdateWidget(covariant TenantBillingBlock old) {
    super.didUpdateWidget(old);
    if (old.tenants.length != widget.tenants.length) _load();
  }

  void _shiftMonth(int delta) {
    var m = _month + delta;
    var y = _year;
    while (m < 1) { m += 12; y--; }
    while (m > 12) { m -= 12; y++; }
    setState(() { _month = m; _year = y; });
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final db = FirebaseFirestore.instance;
    final out = <String, _Summary>{};
    try {
      await Future.wait(_list.map((t) async {
        final id = t['tenantId'] as String;
        final r = await Future.wait([
          db.collection('usage').doc(id).get(),
          db.collection('usage').doc(id).collection('monthly').doc(_mk(_year, _month)).get(),
          db.collection('tenants').doc(id).collection('billing').doc('account').get(),
          db.collection('tenants').doc(id).collection('billing').doc('settings').get(),
        ]);
        final root = r[0].data() ?? {};
        final mon = r[1].data() ?? {};
        final acc = r[2].data() ?? {};
        final st = r[3].data() ?? {};
        final chargeTotal = _d(root['chargeTotalEur']);
        final fees = (acc['feeByMonth'] as Map?) ?? {};
        out[id] = _Summary(
          monthCost: _d(mon['totalCostEur']),
          monthCharge: _d(mon['totalChargeEur']),
          monthFee: _d(fees[_mk(_year, _month)]),
          chargeTotal: chargeTotal,
          balance: _d(acc['creditGrantedEur']) +
              _d(acc['paidEur']) -
              chargeTotal -
              _d(acc['feeChargedEur']),
          mode: (st['billingMode'] as String?) ?? 'markup',
        );
      }));
    } catch (_) {/* δείχνουμε ό,τι φορτώθηκε */}
    if (!mounted) return;
    setState(() {
      _sum
        ..clear()
        ..addAll(out);
      _loading = false;
    });
  }

  Future<void> _open(Map<String, dynamic> t) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _TenantBillingPage(
        tenantId: t['tenantId'] as String,
        name: ((t['businessName'] as String?) ?? '').trim(),
        year: _year,
        month: _month,
      ),
    ));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final list = _list;
    double totCost = 0, totCharge = 0, totProfit = 0, totOwed = 0;
    for (final t in list) {
      final s = _sum[t['tenantId']];
      if (s == null) continue;
      totCost += s.monthCost;
      totCharge += s.monthCharge + s.monthFee;
      if (s.mode != 'none') {
        totProfit += s.monthCharge + s.monthFee - s.monthCost;
      }
      if (s.balance < 0) totOwed += -s.balance;
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.chevron_left, color: c.textMain),
              onPressed: () => _shiftMonth(-1),
            ),
            Expanded(
              child: Center(
                child: Text(_mk(_year, _month),
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700, color: c.textMain)),
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.chevron_right, color: c.textMain),
              onPressed: () => _shiftMonth(1),
            ),
          ]),
          const SizedBox(height: 6),
          Wrap(spacing: 14, runSpacing: 4, children: [
            Text('Κόστος μας ${_eur(totCost)}',
                style: TextStyle(fontSize: 13, color: c.textMain)),
            Text('Χρεώσεις μήνα ${_eur(totCharge)}',
                style: TextStyle(fontSize: 13, color: c.textMain)),
            Text('Κέρδος ${_eur(totProfit)}',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: totProfit >= 0 ? c.greenDeep : Colors.red.shade700)),
            Text('Σου χρωστούν ${_eur(totOwed)}',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: totOwed > 0 ? Colors.red.shade700 : c.textMain)),
          ]),
          const SizedBox(height: 10),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else
            ...list.map((t) => _row(c, t)),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.tune, size: 18),
              label: const Text('Τιμές υπηρεσιών'),
              onPressed: () => showDialog(
                context: context,
                builder: (_) => const _RatesDialog(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(AppColors c, Map<String, dynamic> t) {
    final id = t['tenantId'] as String;
    final name = ((t['businessName'] as String?) ?? '').trim();
    final s = _sum[id];
    final bal = s?.balance ?? 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _open(t),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            border: Border.all(color: c.divider),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name.isEmpty ? id : name,
                    style: TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600, color: c.textMain)),
                const SizedBox(height: 2),
                Text(
                  s == null
                      ? '—'
                      : s.mode == 'none'
                          ? 'Κόστος ${_eur(s.monthCost)} · χωρίς χρέωση'
                          : 'Κόστος ${_eur(s.monthCost)} · Συνδρομή ${_eur(s.monthFee)}'
                              ' · Χρήση ${_eur(s.monthCharge)}'
                              ' · Σύνολο ${_eur(s.monthFee + s.monthCharge)}',
                  style: TextStyle(fontSize: 12, color: c.textFaint),
                ),
              ]),
            ),
            if (s != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: (bal >= 0 ? c.green : Colors.red.shade700).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  bal >= 0 ? 'Πίστωση ${_eur(bal)}' : 'Οφείλει ${_eur(bal.abs())}',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: bal >= 0 ? c.greenDeep : Colors.red.shade700),
                ),
              ),
            Icon(Icons.chevron_right, color: c.textFaint),
          ]),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
//  ΟΘΟΝΗ ΕΝΟΣ TENANT
// ════════════════════════════════════════════════════════════════════════════
class _TenantBillingPage extends StatefulWidget {
  final String tenantId;
  final String name;
  final int year;
  final int month;
  const _TenantBillingPage({
    required this.tenantId,
    required this.name,
    required this.year,
    required this.month,
  });

  @override
  State<_TenantBillingPage> createState() => _TenantBillingPageState();
}

class _TenantBillingPageState extends State<_TenantBillingPage> {
  bool _loading = true;
  bool _saving = false;

  // Ανάλυση μήνα + λογαριασμός
  Map<String, dynamic> _services = {};
  double _monthCost = 0, _monthCharge = 0, _chargeTotal = 0;
  double _feeTotal = 0, _feeThisMonth = 0;
  double _credit = 0, _paid = 0;
  List<Map<String, dynamic>> _history = [];

  // Ρυθμίσεις
  String _mode = 'markup';
  final _fee = TextEditingController();
  final _start = TextEditingController();
  final _limit = TextEditingController();
  final _warn = TextEditingController();
  bool _hard = false;
  final Map<String, TextEditingController> _markup = {};
  final Map<String, bool> _own = {};

  DocumentReference<Map<String, dynamic>> get _settingsRef => FirebaseFirestore.instance
      .collection('tenants').doc(widget.tenantId).collection('billing').doc('settings');
  DocumentReference<Map<String, dynamic>> get _accountRef => FirebaseFirestore.instance
      .collection('tenants').doc(widget.tenantId).collection('billing').doc('account');

  @override
  void initState() {
    super.initState();
    for (final g in [..._groups, 'default']) {
      _markup[g] = TextEditingController();
    }
    for (final g in _groups) {
      _own[g] = false;
    }
    _load();
  }

  @override
  void dispose() {
    _fee.dispose();
    _start.dispose();
    _limit.dispose();
    _warn.dispose();
    for (final c in _markup.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final db = FirebaseFirestore.instance;
    try {
      final r = await Future.wait([
        _settingsRef.get(),
        _accountRef.get(),
        db.collection('usage').doc(widget.tenantId).get(),
        db.collection('usage').doc(widget.tenantId)
            .collection('monthly').doc(_mk(widget.year, widget.month)).get(),
      ]);
      final st = r[0].data() ?? {};
      final acc = r[1].data() ?? {};
      final root = r[2].data() ?? {};
      final mon = r[3].data() ?? {};
      if (!mounted) return;
      setState(() {
        _mode = (st['billingMode'] as String?) ?? 'markup';
        _fee.text = _fmtNum(_d((st['plan'] as Map?)?['monthlyFeeEur']));
        _start.text = ((st['plan'] as Map?)?['startMonth'] as String?) ?? '';
        final lim = (st['limits'] as Map?) ?? {};
        _limit.text = _fmtNum(_d(lim['monthlyUsageEur']));
        _warn.text = _fmtNum(lim['warnAtPercent'] == null ? 80 : _d(lim['warnAtPercent']));
        _hard = lim['hardStop'] == true;
        final mk = (st['markup'] as Map?) ?? {};
        for (final e in _markup.entries) {
          e.value.text = _fmtNum(_d(mk[e.key]));
        }
        final own = (st['ownKeys'] as Map?) ?? {};
        for (final g in _groups) {
          _own[g] = own[g] == true;
        }
        _credit = _d(acc['creditGrantedEur']);
        _paid = _d(acc['paidEur']);
        _feeTotal = _d(acc['feeChargedEur']);
        _feeThisMonth = _d(((acc['feeByMonth'] as Map?) ?? {})[_mk(widget.year, widget.month)]);
        _history = ((acc['history'] as List?) ?? [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList()
            .reversed
            .take(10)
            .toList();
        _chargeTotal = _d(root['chargeTotalEur']);
        _monthCost = _d(mon['totalCostEur']);
        _monthCharge = _d(mon['totalChargeEur']);
        _services = Map<String, dynamic>.from((mon['services'] as Map?) ?? {});
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack('Σφάλμα φόρτωσης: $e');
    }
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _saveSettings() async {
    setState(() => _saving = true);
    try {
      await _settingsRef.set({
        'billingMode': _mode,
        'plan': {'monthlyFeeEur': _p(_fee.text), 'startMonth': _start.text.trim()},
        'markup': {for (final e in _markup.entries) e.key: _p(e.value.text)},
        'ownKeys': Map<String, bool>.from(_own),
        'limits': {
          'monthlyUsageEur': _p(_limit.text),
          'warnAtPercent': _p(_warn.text),
          'hardStop': _hard,
        },
      }, SetOptions(merge: true));
      if (!mounted) return;
      setState(() => _saving = false);
      _snack('Οι ρυθμίσεις αποθηκεύτηκαν (ισχύουν σε ~1 λεπτό)');
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack('Σφάλμα: $e');
    }
  }

  Future<void> _accrueNow() async {
    try {
      final res = await FirebaseFunctions.instance
          .httpsCallable('accrueTenantSubscriptionsNow')
          .call();
      final n = ((res.data as Map)['accrued'] as num?)?.toInt() ?? 0;
      _snack(n > 0
          ? 'Προστέθηκε συνδρομή σε $n tenant(s)'
          : 'Τίποτα νέο — ο μήνας έχει ήδη χρεωθεί ή δεν ισχύει η έναρξη');
      await _load();
    } catch (e) {
      _snack('Σφάλμα: $e');
    }
  }

  Future<void> _addEntry({required bool isPayment}) async {
    final amountCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isPayment ? 'Καταχώρηση πληρωμής' : 'Πίστωση (πακέτο / δώρο)'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            _numField(amountCtrl, 'Ποσό', suffix: '€'),
            const SizedBox(height: 10),
            TextField(
              controller: noteCtrl,
              decoration: const InputDecoration(
                  labelText: 'Σημείωση (προαιρετικό)',
                  isDense: true,
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            const Text('Για διόρθωση λάθους γράψε αρνητικό ποσό.',
                style: TextStyle(fontSize: 12)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Άκυρο')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Αποθήκευση')),
        ],
      ),
    );
    final amount = _p(amountCtrl.text);
    final note = noteCtrl.text.trim();
    amountCtrl.dispose();
    noteCtrl.dispose();
    if (ok != true || amount == 0) return;
    try {
      await _accountRef.set({
        isPayment ? 'paidEur' : 'creditGrantedEur': FieldValue.increment(amount),
        'history': FieldValue.arrayUnion([
          {
            'ts': Timestamp.now(),
            'type': isPayment ? 'payment' : 'credit',
            'amountEur': amount,
            'note': note,
          }
        ]),
      }, SetOptions(merge: true));
      await _load();
    } catch (e) {
      _snack('Σφάλμα: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final title = widget.name.isEmpty ? widget.tenantId : widget.name;
    return Scaffold(
      backgroundColor: c.scaffold,
      appBar: AppBar(
        title: Text('Χρέωση · $title'),
        backgroundColor: c.scaffold,
        foregroundColor: c.textMain,
        elevation: 0,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              // Κάτω padding: να μην κρύβεται από τη μπάρα πλοήγησης Android.
              padding: EdgeInsets.fromLTRB(
                  14, 8, 14, 30 + MediaQuery.of(context).viewPadding.bottom),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _h(c, 'ΑΝΑΛΥΣΗ ΜΗΝΑ ${_mk(widget.year, widget.month)}'),
                  _monthCard(c),
                  const SizedBox(height: 16),
                  _h(c, 'ΥΠΟΛΟΙΠΟ & ΠΛΗΡΩΜΕΣ'),
                  _balanceCard(c),
                  const SizedBox(height: 16),
                  _h(c, 'ΡΥΘΜΙΣΕΙΣ ΧΡΕΩΣΗΣ'),
                  _settingsCard(c),
                ],
              ),
            ),
    );
  }

  Widget _h(AppColors c, String t) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(t,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: c.blueDeep)),
      );

  Widget _box(AppColors c, Widget child) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: c.cardBorder),
        ),
        child: child,
      );

  Widget _monthCard(AppColors c) {
    final keys = _services.keys.toList()..sort();
    return _box(
      c,
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (keys.isEmpty)
          Text('Καμία χρήση αυτόν τον μήνα.', style: TextStyle(color: c.textFaint)),
        ...keys.map((k) {
          final v = Map<String, dynamic>.from((_services[k] as Map?) ?? {});
          final own = _d(v['ownKeyUnits']).toInt();
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              Expanded(
                flex: 5,
                child: Text(_serviceLabels[k] ?? k,
                    style: TextStyle(fontSize: 13, color: c.textMain)),
              ),
              Expanded(
                flex: 2,
                child: Text('${_d(v['units']).toInt()}×',
                    textAlign: TextAlign.right,
                    style: TextStyle(fontSize: 12, color: c.textFaint)),
              ),
              Expanded(
                flex: 3,
                child: Text(_eur(_d(v['costEur'])),
                    textAlign: TextAlign.right,
                    style: TextStyle(fontSize: 13, color: c.textMain)),
              ),
              Expanded(
                flex: 3,
                child: Text(own > 0 && _d(v['units']) == 0 ? 'δικό του' : _eur(_d(v['chargeEur'])),
                    textAlign: TextAlign.right,
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600, color: c.greenDeep)),
              ),
            ]),
          );
        }),
        Divider(color: c.divider),
        Row(children: [
          Expanded(
              child: Text('Κόστος μας ${_eur(_monthCost)}',
                  style: TextStyle(fontSize: 13, color: c.textMain))),
          Text('Χρήση ${_eur(_monthCharge)}',
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w700, color: c.greenDeep)),
        ]),
        _line(c, 'Μηνιαία συνδρομή', _eur(_feeThisMonth)),
        _line(c, 'Σύνολο μήνα προς είσπραξη', _eur(_feeThisMonth + _monthCharge)),
        const SizedBox(height: 4),
        Text('Στήλες: υπηρεσία · κλήσεις · κόστος μας · χρέωση tenant',
            style: TextStyle(fontSize: 11, color: c.textFaint)),
      ]),
    );
  }

  Widget _balanceCard(AppColors c) {
    final bal = _credit + _paid - _chargeTotal - _feeTotal;
    return _box(
      c,
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _line(c, 'Πίστωση / πακέτο (συνολικά)', _eur(_credit)),
        _line(c, 'Πληρωμές (συνολικά)', _eur(_paid)),
        _line(c, 'Μηνιαίες συνδρομές (συνολικά)', _eur(_feeTotal)),
        _line(c, 'Χρεώσεις χρήσης (συνολικά)', _eur(_chargeTotal)),
        Divider(color: c.divider),
        Text(
          bal >= 0 ? 'Πίστωση που απομένει ${_eur(bal)}' : 'Σου οφείλει ${_eur(bal.abs())}',
          style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: bal >= 0 ? c.greenDeep : Colors.red.shade700),
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 6, children: [
          FilledButton.icon(
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Πληρωμή'),
            onPressed: () => _addEntry(isPayment: true),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.card_giftcard, size: 18),
            label: const Text('Πίστωση'),
            onPressed: () => _addEntry(isPayment: false),
          ),
        ]),
        if (_history.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text('Τελευταίες κινήσεις',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: c.textFaint)),
          ..._history.map((h) {
            final type = h['type'];
            final label = type == 'payment'
                ? 'Πληρωμή'
                : type == 'subscription' ? 'Συνδρομή' : 'Πίστωση';
            final note = (h['note'] as String?) ?? '';
            return Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                '${_fmtDate(h['ts'] as Timestamp?)} · $label '
                '${_eur(_d(h['amountEur']))}${note.isEmpty ? '' : ' · $note'}',
                style: TextStyle(fontSize: 12, color: c.textMain),
              ),
            );
          }),
        ],
      ]),
    );
  }

  Widget _line(AppColors c, String l, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Expanded(child: Text(l, style: TextStyle(fontSize: 13, color: c.textFaint))),
          Text(v, style: TextStyle(fontSize: 13, color: c.textMain)),
        ]),
      );

  Widget _settingsCard(AppColors c) {
    return _box(
      c,
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        DropdownButtonFormField<String>(
          initialValue: _mode,
          decoration: const InputDecoration(
              labelText: 'Τρόπος χρέωσης', isDense: true, border: OutlineInputBorder()),
          items: const [
            DropdownMenuItem(value: 'markup', child: Text('Χρεώνεται (κόστος + markup)')),
            DropdownMenuItem(value: 'none', child: Text('Χωρίς χρέωση (μόνο στατιστικά)')),
          ],
          onChanged: (v) => setState(() => _mode = v ?? 'markup'),
        ),
        const SizedBox(height: 10),
        _numField(_fee, 'Μηνιαία συνδρομή', suffix: '€'),
        const SizedBox(height: 10),
        TextField(
          controller: _start,
          decoration: const InputDecoration(
            labelText: 'Έναρξη συνδρομής (ΕΕΕΕ-ΜΜ, κενό = από τώρα)',
            isDense: true,
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 14),
        Text('Markup ανά υπηρεσία (%) · δικά του κλειδιά',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: c.textFaint)),
        const SizedBox(height: 6),
        ..._groups.map((g) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                Expanded(
                  flex: 5,
                  child: Text(_groupLabels[g] ?? g,
                      style: TextStyle(fontSize: 13, color: c.textMain)),
                ),
                Expanded(flex: 3, child: _numField(_markup[g]!, '%')),
                const SizedBox(width: 6),
                Column(children: [
                  Switch(
                    value: _own[g] ?? false,
                    onChanged: (v) => setState(() => _own[g] = v),
                  ),
                  Text('δικό του', style: TextStyle(fontSize: 10, color: c.textFaint)),
                ]),
              ]),
            )),
        Row(children: [
          Expanded(
            flex: 5,
            child: Text('Προεπιλογή (υπόλοιπες)',
                style: TextStyle(fontSize: 13, color: c.textMain)),
          ),
          Expanded(flex: 3, child: _numField(_markup['default']!, '%')),
          const SizedBox(width: 64),
        ]),
        const SizedBox(height: 14),
        Text('Όρια',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: c.textFaint)),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(child: _numField(_limit, 'Μηνιαίο όριο (0 = χωρίς)', suffix: '€')),
          const SizedBox(width: 8),
          Expanded(child: _numField(_warn, 'Ειδοποίηση στο', suffix: '%')),
        ]),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('Σταμάτημα υπηρεσιών όταν ξεπεραστεί το όριο',
              style: TextStyle(fontSize: 13, color: c.textMain)),
          value: _hard,
          onChanged: (v) => setState(() => _hard = v),
        ),
        const SizedBox(height: 6),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _saving ? null : _saveSettings,
            child: _saving
                ? const SizedBox(
                    height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Αποθήκευση ρυθμίσεων'),
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: _accrueNow,
            child: const Text('Υπολογισμός συνδρομής τώρα'),
          ),
        ),
        const SizedBox(height: 4),
        Text('Η συνδρομή προστίθεται αυτόματα κάθε μέρα στις 03:00 (μία φορά τον μήνα).',
            style: TextStyle(fontSize: 11, color: c.textFaint)),
      ]),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
//  ΤΙΜΕΣ ΥΠΗΡΕΣΙΩΝ  (platform/pricing → rates)
// ════════════════════════════════════════════════════════════════════════════
class _RatesDialog extends StatefulWidget {
  const _RatesDialog();

  @override
  State<_RatesDialog> createState() => _RatesDialogState();
}

class _RatesDialogState extends State<_RatesDialog> {
  bool _loading = true;
  bool _saving = false;
  final _usd = TextEditingController(text: '0.92');
  final _cIn = TextEditingController(text: '1');
  final _cOut = TextEditingController(text: '5');
  final Map<String, TextEditingController> _unit = {
    for (final e in _defaultUnitRates.entries)
      e.key: TextEditingController(text: e.value.toString()),
  };

  DocumentReference<Map<String, dynamic>> get _ref =>
      FirebaseFirestore.instance.collection('platform').doc('pricing');

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _usd.dispose();
    _cIn.dispose();
    _cOut.dispose();
    for (final c in _unit.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = ((await _ref.get()).data()?['rates'] as Map?) ?? {};
      if (r['usdToEur'] != null) _usd.text = _fmtNum(_d(r['usdToEur']));
      final cl = (r['claude'] as Map?) ?? {};
      if (cl['inUsdPerMTok'] != null) _cIn.text = _fmtNum(_d(cl['inUsdPerMTok']));
      if (cl['outUsdPerMTok'] != null) _cOut.text = _fmtNum(_d(cl['outUsdPerMTok']));
      final u = (r['perUnitEur'] as Map?) ?? {};
      for (final e in _unit.entries) {
        if (u[e.key] != null) e.value.text = _d(u[e.key]).toString();
      }
    } catch (_) {/* μένουν οι προεπιλογές */}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await _ref.set({
        'rates': {
          'usdToEur': _p(_usd.text),
          'claude': {
            'inUsdPerMTok': _p(_cIn.text),
            'outUsdPerMTok': _p(_cOut.text),
          },
          'perUnitEur': {for (final e in _unit.entries) e.key: _p(e.value.text)},
        },
      }, SetOptions(merge: true));
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Οι τιμές αποθηκεύτηκαν (ισχύουν σε ~1 λεπτό)')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Σφάλμα: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Τιμές υπηρεσιών (κόστος μας)'),
      content: _loading
          ? const SizedBox(height: 80, child: Center(child: CircularProgressIndicator()))
          : SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text(
                    'Βάλε τις πραγματικές τιμές από τα πακέτα / τους τιμοκαταλόγους. '
                    'Χωρίς τα δωρεάν όρια — κόστος σαν να μην υπήρχε δώρο.',
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 10),
                  _numField(_usd, 'Ισοτιμία USD → EUR'),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(child: _numField(_cIn, 'Claude input', suffix: '\$/1M tok')),
                    const SizedBox(width: 8),
                    Expanded(child: _numField(_cOut, 'Claude output', suffix: '\$/1M tok')),
                  ]),
                  const SizedBox(height: 12),
                  ..._unit.entries.map((e) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _numField(e.value, _serviceLabels[e.key] ?? e.key,
                            suffix: '€ / κλήση'),
                      )),
                ]),
              ),
            ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Άκυρο')),
        FilledButton(
          onPressed: (_loading || _saving) ? null : _save,
          child: const Text('Αποθήκευση'),
        ),
      ],
    );
  }
}
