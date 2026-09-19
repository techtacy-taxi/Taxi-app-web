// lib/jobs/platform_billing_card.dart
//
// «Χρέωση πλατφόρμας» — ό,τι πληρώνει ο tenant-owner στην πλατφόρμα.
// Μπαίνει στις «Ρυθμίσεις Χρεώσεων». Καλεί το callable getMyBillingSummary,
// που ελέγχει στο server ότι ο χρήστης είναι tenantOwner/master και
// επιστρέφει ΜΟΝΟ τα ποσά χρέωσης (ποτέ το κόστος μας ή το markup).
//
// Αυτοκρύβεται όταν: δεν έχεις δικαίωμα (απλός admin), ο tenant είναι χωρίς
// χρέωση (billingMode = none, π.χ. ο δικός μας), ή υπάρχει σφάλμα.

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../app_theme.dart';

const _purple = Color(0xFF5E35B1);

const _serviceLabels = {
  'claude': 'Claude AI',
  'resend': 'Email',
  'places_autocomplete': 'Αναζήτηση διευθύνσεων',
  'places_details': 'Λεπτομέρειες διευθύνσεων',
  'routes': 'Υπολογισμός διαδρομών',
  'geocode': 'Διευθύνσεις χάρτη',
  'aerodatabox': 'Πληροφορίες πτήσεων',
  'sms': 'SMS',
  'whatsapp': 'WhatsApp',
};

String _eur(num v) {
  final neg = v < 0;
  final a = v.abs();
  final s = (a != 0 && a < 1) ? a.toStringAsFixed(3) : a.toStringAsFixed(2);
  return '${neg ? '−' : ''}€$s';
}

double _d(dynamic v) => v is num ? v.toDouble() : 0.0;

class PlatformBillingCard extends StatefulWidget {
  const PlatformBillingCard({super.key});

  @override
  State<PlatformBillingCard> createState() => _PlatformBillingCardState();
}

class _PlatformBillingCardState extends State<PlatformBillingCard> {
  bool _loading = true;
  Map<String, dynamic>? _data; // null → κρυμμένη κάρτα

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await FirebaseFunctions.instance
          .httpsCallable('getMyBillingSummary')
          .call();
      final m = Map<String, dynamic>.from(res.data as Map);
      if (!mounted) return;
      setState(() {
        _data = m['billingMode'] == 'none' ? null : m;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() { _data = null; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading || _data == null) return const SizedBox.shrink();
    final c = AppColors.of(context);
    final d = _data!;
    final services = Map<String, dynamic>.from((d['services'] as Map?) ?? {});
    final keys = services.keys.toList()..sort();
    final balance = _d(d['balanceEur']);
    final fee = _d(d['monthlyFeeEur']);

    return Container(
      margin: const EdgeInsets.fromLTRB(14, 14, 14, 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.cardBorder),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const CircleAvatar(
            radius: 17,
            backgroundColor: Color(0x1A5E35B1),
            child: Icon(Icons.receipt_long_rounded, size: 18, color: _purple),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text('Χρέωση πλατφόρμας',
                style: TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 15, color: c.textMain)),
          ),
          Text('${d['month'] ?? ''}',
              style: TextStyle(fontSize: 12, color: c.textFaint)),
        ]),
        const SizedBox(height: 10),
        if (fee > 0) _line(c, 'Μηνιαία συνδρομή', _eur(fee)),
        _line(c, 'Χρήση αυτού του μήνα', _eur(_d(d['monthChargeEur']))),
        if (keys.isNotEmpty) ...[
          const SizedBox(height: 4),
          ...keys.map((k) => Padding(
                padding: const EdgeInsets.only(left: 10, top: 2),
                child: Row(children: [
                  Expanded(
                    child: Text(_serviceLabels[k] ?? k,
                        style: TextStyle(fontSize: 12, color: c.textFaint)),
                  ),
                  Text(_eur(_d(services[k])),
                      style: TextStyle(fontSize: 12, color: c.textFaint)),
                ]),
              )),
        ],
        Divider(color: c.divider, height: 18),
        Text(
          balance >= 0
              ? 'Πίστωση που απομένει ${_eur(balance)}'
              : 'Υπόλοιπο προς πληρωμή ${_eur(balance.abs())}',
          style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: balance >= 0 ? c.greenDeep : Colors.red.shade700),
        ),
        const SizedBox(height: 4),
        Text(
          'Το υπόλοιπο αφορά τη χρήση υπηρεσιών (χωρίς τη μηνιαία συνδρομή).',
          style: TextStyle(fontSize: 11, color: c.textFaint),
        ),
      ]),
    );
  }

  Widget _line(AppColors c, String l, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Expanded(child: Text(l, style: TextStyle(fontSize: 13, color: c.textMain))),
          Text(v,
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: c.textMain)),
        ]),
      );
}
