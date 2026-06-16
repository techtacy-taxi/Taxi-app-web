// lib/jobs/billing_settlement_page.dart
//
// Όψη «ανά παραλήπτη / ανά collector» + εκκαθαρίσεις, πάνω από το ledger.
//   • Master: τι οφείλεται σε κάθε admin & master (ανά πηγή), τι μαζεύει/
//             προωθεί ο κάθε collector, και ΟΛΕΣ οι εκκρεμείς προωθήσεις.
//   • Admin:  «Τι έχω να μαζέψω», «Τι μου οφείλεται», «Τι πρέπει να προωθήσω».
//
// Το «Προώθησα» καταγράφει settlement (collector → recipient) ώστε το
// εκκρεμές να κατεβαίνει. Δεν πειράζει την υπάρχουσα BillingPage.

import 'package:flutter/material.dart';

import 'job_model.dart';
import 'job_service.dart';
import 'job_shared_widgets.dart';

class BillingSettlementPage extends StatelessWidget {
  final String uid;
  final String userName;
  final bool   isMaster;

  const BillingSettlementPage({
    super.key,
    required this.uid,
    this.userName = '',
    this.isMaster = false,
  });

  static String _eur(double v) => '${v.toStringAsFixed(2)}€';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F6F8),
      appBar: AppBar(
        backgroundColor: Colors.amber,
        foregroundColor: Colors.black,
        title: Text(isMaster ? 'Εκκαθαρίσεις (Master)' : 'Εκκαθαρίσεις'),
      ),
      body: StreamBuilder<List<BillingTx>>(
        stream: JobService.allBillingTx(),
        builder: (context, txSnap) {
          if (!txSnap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final txs = txSnap.data!;
          return StreamBuilder<List<Settlement>>(
            stream: JobService.settlements(),
            builder: (context, setSnap) {
              final sets = setSnap.data ?? const <Settlement>[];
              return isMaster
                  ? _masterBody(context, txs, sets)
                  : _adminBody(context, txs, sets);
            },
          );
        },
      ),
    );
  }

  // ─── MASTER ────────────────────────────────────────────────────────────────
  Widget _masterBody(
      BuildContext context, List<BillingTx> txs, List<Settlement> sets) {
    final recipients = JobService.recipientOutstanding(txs);
    final collectors = JobService.collectorOutstanding(txs);
    final ledger     = JobService.forwardingLedger(txs, sets);

    final recEntries = recipients.entries.toList()
      ..sort((a, b) =>
          (b.value['total'] as double).compareTo(a.value['total'] as double));
    final colEntries = collectors.entries.toList()
      ..sort((a, b) =>
          (b.value['total'] as double).compareTo(a.value['total'] as double));

    return ListView(
      padding: EdgeInsets.fromLTRB(
          12, 12, 12, 12 + MediaQuery.of(context).padding.bottom),
      children: [
        const _Header('ΕΚΚΡΕΜΕΙΣ ΠΡΟΩΘΗΣΕΙΣ'),
        ..._forwardingCards(context, ledger),
        const SizedBox(height: 16),
        const _Header('ΣΕ ΠΟΙΟΝ ΟΦΕΙΛΟΝΤΑΙ (αξεξόφλητα από οδηγούς)'),
        for (final e in recEntries)
          if ((e.value['total'] as double) > 0.01)
            _recipientCard(e.key, e.value),
        const SizedBox(height: 16),
        const _Header('ΤΙ ΜΑΖΕΥΕΙ Ο ΚΑΘΕ COLLECTOR'),
        for (final e in colEntries)
          if ((e.value['total'] as double) > 0.01)
            _collectorCard(e.key, e.value),
        const SizedBox(height: 24),
      ],
    );
  }

  // ─── ADMIN ───────────────────────────────────────────────────────────────
  Widget _adminBody(
      BuildContext context, List<BillingTx> txs, List<Settlement> sets) {
    final collectors = JobService.collectorOutstanding(txs);
    final recipients = JobService.recipientOutstanding(txs);
    final ledger     = JobService.forwardingLedger(txs, sets);
    final myCollect  = collectors[uid];
    final myReceive  = recipients[uid];
    final myLedger   = ledger[uid];

    return ListView(
      padding: EdgeInsets.fromLTRB(
          12, 12, 12, 12 + MediaQuery.of(context).padding.bottom),
      children: [
        const _Header('ΤΙ ΠΡΕΠΕΙ ΝΑ ΠΡΟΩΘΗΣΩ'),
        if (myLedger == null)
          const _Empty('Τίποτα προς προώθηση')
        else
          ..._forwardingCards(context, {uid: myLedger}, hideName: true),
        const SizedBox(height: 16),
        const _Header('ΤΙ ΕΧΩ ΝΑ ΜΑΖΕΨΩ ΑΠΟ ΤΟΥΣ ΟΔΗΓΟΥΣ ΜΟΥ'),
        if (myCollect == null || (myCollect['total'] as double) <= 0.01)
          const _Empty('Τίποτα προς είσπραξη')
        else
          _collectorCard(uid, myCollect, expanded: true),
        const SizedBox(height: 16),
        const _Header('ΤΙ ΜΟΥ ΟΦΕΙΛΕΤΑΙ (ανά πηγή)'),
        if (myReceive == null || (myReceive['total'] as double) <= 0.01)
          const _Empty('Τίποτα')
        else
          _recipientCard(uid, myReceive, expanded: true),
        const SizedBox(height: 24),
      ],
    );
  }

  // ─── Κάρτες προώθησης ───────────────────────────────────────────────────────
  List<Widget> _forwardingCards(
      BuildContext context, Map<String, Map<String, dynamic>> ledger,
      {bool hideName = false}) {
    final cards = <Widget>[];
    final entries = ledger.entries.toList();
    for (final e in entries) {
      final cName = (e.value['name'] as String?)?.trim() ?? '';
      final byRec = (e.value['byRecipient'] as Map<String, Map<String, dynamic>>)
          .entries
          .where((r) => (r.value['pending'] as double) > 0.01)
          .toList()
        ..sort((a, b) => (b.value['pending'] as double)
            .compareTo(a.value['pending'] as double));
      if (byRec.isEmpty) continue;

      cards.add(Card(
        margin: const EdgeInsets.symmetric(vertical: 4),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!hideName)
                Text(cName.isEmpty ? 'Collector' : cName,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              if (!hideName) const SizedBox(height: 6),
              for (final r in byRec)
                _forwardRow(context, e.key, cName, r.key, r.value),
            ],
          ),
        ),
      ));
    }
    if (cards.isEmpty) {
      cards.add(const _Empty('Καμία εκκρεμής προώθηση'));
    }
    return cards;
  }

  Widget _forwardRow(BuildContext context, String collectorUid,
      String collectorName, String rid, Map<String, dynamic> r) {
    final isMasterRec = r['isMaster'] == true;
    final name      = (r['name'] as String?)?.trim() ?? '';
    final pending   = r['pending']   as double;
    final collected = r['collected'] as double;
    final forwarded = r['forwarded'] as double;
    final label = isMasterRec
        ? 'Προς Master (app + συνδρομή)'
        : 'Προς ${name.isEmpty ? 'admin' : name}';

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.deepOrange.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.deepOrange.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(label,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.deepOrange)),
              ),
              Text(_eur(pending),
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, color: Colors.deepOrange)),
            ],
          ),
          const SizedBox(height: 2),
          Text('μαζεμένα ${_eur(collected)} • προωθημένα ${_eur(forwarded)}',
              style: TextStyle(fontSize: 11, color: Colors.grey[600])),
          Align(
            alignment: Alignment.centerRight,
            child: AppButton(
              label: 'Προώθησα',
              icon: Icons.check_circle_outline,
              color: const Color(0xFF1E8E3E),
              onPressed: () => _markForward(
                context, collectorUid, collectorName, rid,
                isMasterRec ? 'Master' : name, pending),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _markForward(
      BuildContext context,
      String collectorUid,
      String collectorName,
      String rid,
      String recipientName,
      double pending) async {
    final ctrl =
        TextEditingController(text: pending.toStringAsFixed(2));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Προώθηση σε $recipientName'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Εκκρεμεί: ${_eur(pending)}',
                style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Ποσό που προώθησες',
                suffixText: '€',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          AppButtonTonal(label: 'Ακύρωση', onPressed: () => Navigator.pop(ctx, false)),
          AppButton(label: 'Καταγραφή', color: Colors.amber, onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
    );
    if (ok != true) return;
    final amount =
        double.tryParse(ctrl.text.trim().replaceAll(',', '.')) ?? 0;
    if (amount <= 0) return;
    await JobService.recordSettlement(
      collectorUid:  collectorUid,
      collectorName: collectorName,
      recipientUid:  rid,
      recipientName: recipientName,
      amount:        amount,
      byUid:         uid,
    );
  }

  // ─── Κάρτα recipient ──────────────────────────────────────────────────────
  Widget _recipientCard(String rid, Map<String, dynamic> data,
      {bool expanded = false}) {
    final name  = (data['name'] as String?)?.trim();
    final total = data['total'] as double;
    final bySource =
        (data['bySource'] as Map<String, double>).entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));
    final byCollector =
        (data['byCollector'] as Map<String, Map<String, dynamic>>)
            .values
            .toList();
    final title = (name == null || name.isEmpty)
        ? (rid == JobService.kMasterRecipient ? 'Master' : 'Admin')
        : name;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ExpansionTile(
        initiallyExpanded: expanded,
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        trailing: Text(_eur(total),
            style: const TextStyle(
                fontWeight: FontWeight.bold, color: Colors.green)),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          if (bySource.isNotEmpty) ...[
            const Align(
                alignment: Alignment.centerLeft,
                child: Text('Ανά πηγή:',
                    style: TextStyle(fontSize: 12, color: Colors.grey))),
            for (final s in bySource)
              if (s.value > 0.01) _row(s.key, _eur(s.value)),
          ],
          if (byCollector.isNotEmpty) ...[
            const SizedBox(height: 6),
            const Align(
                alignment: Alignment.centerLeft,
                child: Text('Το κρατάει για λογαριασμό σου:',
                    style: TextStyle(fontSize: 12, color: Colors.grey))),
            for (final c in byCollector)
              if ((c['total'] as double) > 0.01)
                _row(
                  (c['name'] as String?)?.isNotEmpty == true
                      ? c['name'] as String
                      : 'Collector',
                  _eur(c['total'] as double),
                ),
          ],
        ],
      ),
    );
  }

  // ─── Κάρτα collector ──────────────────────────────────────────────────────
  Widget _collectorCard(String cid, Map<String, dynamic> data,
      {bool expanded = false}) {
    final name  = (data['name'] as String?)?.trim();
    final total = data['total'] as double;
    final byRecipient =
        (data['byRecipient'] as Map<String, Map<String, dynamic>>)
            .entries
            .toList()
          ..sort((a, b) => (b.value['total'] as double)
              .compareTo(a.value['total'] as double));
    final title = (name == null || name.isEmpty) ? 'Collector' : name;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ExpansionTile(
        initiallyExpanded: expanded,
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        trailing: Text(_eur(total),
            style: const TextStyle(fontWeight: FontWeight.bold)),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          for (final r in byRecipient)
            if ((r.value['total'] as double) > 0.01)
              _recipientBreakdown(cid, r.key, r.value),
        ],
      ),
    );
  }

  Widget _recipientBreakdown(
      String collectorUid, String rid, Map<String, dynamic> r) {
    final isMasterRec = r['isMaster'] == true;
    final isOwn       = rid == collectorUid;
    final name        = (r['name'] as String?)?.trim();
    final total       = r['total'] as double;
    final bySource    = (r['bySource'] as Map<String, double>).entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final String label;
    final Color  color;
    if (isOwn) {
      label = 'Κράτα (δικά σου)';
      color = Colors.green;
    } else if (isMasterRec) {
      label = 'Προς Master (app + συνδρομή)';
      color = Colors.blue;
    } else {
      label = 'Προς ${(name == null || name.isEmpty) ? 'admin' : name}';
      color = Colors.deepOrange;
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(label,
                    style:
                        TextStyle(fontWeight: FontWeight.bold, color: color)),
              ),
              Text(_eur(total),
                  style: TextStyle(fontWeight: FontWeight.bold, color: color)),
            ],
          ),
          for (final s in bySource)
            if (s.value > 0.01)
              Padding(
                padding: const EdgeInsets.only(left: 8, top: 2),
                child: _row(s.key, _eur(s.value), small: true),
              ),
        ],
      ),
    );
  }

  Widget _row(String left, String right, {bool small = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
              child:
                  Text(left, style: TextStyle(fontSize: small ? 12 : 14))),
          Text(right, style: TextStyle(fontSize: small ? 12 : 14)),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
        child: Text(text,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.1,
                color: Colors.grey[600])),
      );
}

class _Empty extends StatelessWidget {
  final String text;
  const _Empty(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(16),
        child: Text(text, style: TextStyle(color: Colors.grey[500])),
      );
}
