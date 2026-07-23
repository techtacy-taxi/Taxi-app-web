// lib/jobs/billing_settlement_page.dart
//
// «Εκκαθαρίσεις» — επαγγελματική όψη του ποιος χρωστάει τι, τι έχει πληρωθεί
// και τι εκκρεμεί, πάνω από το ledger (billing_tx + settlements).
//   • Master: σύνοψη (εκκρεμή/εξοφλημένα), εκκρεμείς προωθήσεις με μπάρα
//     προόδου, σε ποιον οφείλονται (ανά πηγή/collector), τι μαζεύει ο κάθε
//     collector, και ιστορικό εκκαθαρίσεων.
//   • Admin: «Τι πρέπει να προωθήσω», «Τι έχω να μαζέψω», «Τι μου οφείλεται»
//     + το δικό του ιστορικό.
//
// Το «Προώθησα» καταγράφει settlement (collector → recipient) ώστε το
// εκκρεμές να κατεβαίνει. Δεν πειράζει την υπάρχουσα BillingPage.
// SafeArea παντού — τίποτα δεν κρύβεται πίσω από τη μπάρα πλοήγησης Android.

import 'package:flutter/material.dart';

import '../app_theme.dart';

import 'job_model.dart';
import 'job_service.dart';
import 'job_shared_widgets.dart';

const Color _kAmber  = Color(0xFFFFB300);
const Color _kGreen  = Color(0xFF1E8E3E);
const Color _kOrange = Color(0xFFE8710A);
const Color _kBlue   = Color(0xFF1A73E8);
const Color _kInk    = Color(0xFF202124);

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
  static String _date(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final ac = AppColors.of(context);
    return Scaffold(
      backgroundColor: ac.scaffold,
      appBar: AppBar(
        backgroundColor: _kAmber,
        foregroundColor: Colors.black,
        title: Text(isMaster ? 'Εκκαθαρίσεις (Master)' : 'Εκκαθαρίσεις'),
      ),
      body: SafeArea(
        child: StreamBuilder<List<BillingTx>>(
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
                    ? _masterBody(ac, context, txs, sets)
                    : _adminBody(ac, context, txs, sets);
              },
            );
          },
        ),
      ),
    );
  }

  // ─── MASTER ────────────────────────────────────────────────────────────────
  Widget _masterBody(AppColors ac,
      BuildContext context, List<BillingTx> txs, List<Settlement> sets) {
    final recipients = JobService.recipientOutstanding(txs);
    final collectors = JobService.collectorOutstanding(txs);
    final ledger     = JobService.forwardingLedger(txs, sets);

    // Σύνοψη: εκκρεμή προς προώθηση / συνολικά οφειλόμενα / εξοφλημένα (ιστορικό).
    double pendingTotal = 0, owedTotal = 0, settledTotal = 0;
    for (final c in ledger.values) {
      final byRec = c['byRecipient'] as Map<String, Map<String, dynamic>>;
      for (final r in byRec.values) {
        pendingTotal += (r['pending'] as double).clamp(0, double.infinity);
      }
    }
    for (final r in recipients.values) {
      owedTotal += (r['total'] as double).clamp(0, double.infinity);
    }
    for (final s in sets) {
      settledTotal += s.amount;
    }

    final recEntries = recipients.entries.toList()
      ..sort((a, b) =>
          (b.value['total'] as double).compareTo(a.value['total'] as double));
    final colEntries = collectors.entries.toList()
      ..sort((a, b) =>
          (b.value['total'] as double).compareTo(a.value['total'] as double));

    return ListView(
      padding: EdgeInsets.fromLTRB(
          12, 12, 12, 16 + MediaQuery.of(context).padding.bottom),
      children: [
        _summaryBar(ac, pendingTotal, owedTotal, settledTotal),
        const SizedBox(height: 16),
        _sectionHeader(ac, Icons.forward_rounded, 'Εκκρεμείς προωθήσεις',
            'Χρήματα που έχουν εισπραχθεί και πρέπει να παραδοθούν'),
        ..._forwardingCards(ac, context, ledger),
        const SizedBox(height: 20),
        _sectionHeader(ac, Icons.account_balance_wallet_rounded, 'Σε ποιον οφείλονται',
            'Ανεξόφλητα από οδηγούς, ανά δικαιούχο'),
        if (recEntries.every((e) => (e.value['total'] as double) <= 0.01))
          _Empty('Όλα εξοφλημένα ✔', ac)
        else
          for (final e in recEntries)
            if ((e.value['total'] as double) > 0.01)
              _recipientCard(ac, e.key, e.value),
        const SizedBox(height: 20),
        _sectionHeader(ac, Icons.group_rounded, 'Τι μαζεύει ο κάθε εισπράκτορας',
            'Ποσά που κρατούν αυτή τη στιγμή, και για λογαριασμό ποιου'),
        if (colEntries.every((e) => (e.value['total'] as double) <= 0.01))
          _Empty('Κανένα ποσό σε εκκρεμότητα', ac)
        else
          for (final e in colEntries)
            if ((e.value['total'] as double) > 0.01)
              _collectorCard(ac, e.key, e.value),
        const SizedBox(height: 20),
        _sectionHeader(ac, Icons.history_rounded, 'Ιστορικό εκκαθαρίσεων',
            'Οι τελευταίες καταγεγραμμένες παραδόσεις χρημάτων'),
        ..._historyCards(ac, sets),
      ],
    );
  }

  // ─── ADMIN ───────────────────────────────────────────────────────────────
  Widget _adminBody(AppColors ac,
      BuildContext context, List<BillingTx> txs, List<Settlement> sets) {
    final collectors = JobService.collectorOutstanding(txs);
    final recipients = JobService.recipientOutstanding(txs);
    final ledger     = JobService.forwardingLedger(txs, sets);
    final myCollect  = collectors[uid];
    final myReceive  = recipients[uid];
    final myLedger   = ledger[uid];

    double myPending = 0;
    if (myLedger != null) {
      final byRec = myLedger['byRecipient'] as Map<String, Map<String, dynamic>>;
      for (final r in byRec.values) {
        myPending += (r['pending'] as double).clamp(0, double.infinity);
      }
    }
    final myOwed = (myReceive?['total'] as double?) ?? 0;
    double mySettled = 0;
    for (final s in sets) {
      if (s.collectorUid == uid || s.recipientUid == uid) mySettled += s.amount;
    }
    final mySets = sets
        .where((s) => s.collectorUid == uid || s.recipientUid == uid)
        .toList();

    return ListView(
      padding: EdgeInsets.fromLTRB(
          12, 12, 12, 16 + MediaQuery.of(context).padding.bottom),
      children: [
        _summaryBar(ac, myPending, myOwed, mySettled),
        const SizedBox(height: 16),
        _sectionHeader(ac, Icons.forward_rounded, 'Τι πρέπει να προωθήσω',
            'Χρήματα που έχεις εισπράξει για άλλους'),
        if (myLedger == null)
          _Empty('Τίποτα προς προώθηση ✔', ac)
        else
          ..._forwardingCards(ac, context, {uid: myLedger}, hideName: true),
        const SizedBox(height: 20),
        _sectionHeader(ac, Icons.download_rounded, 'Τι έχω να μαζέψω',
            'Ανεξόφλητα από τους οδηγούς σου'),
        if (myCollect == null || (myCollect['total'] as double) <= 0.01)
          _Empty('Τίποτα προς είσπραξη ✔', ac)
        else
          _collectorCard(ac, uid, myCollect, expanded: true),
        const SizedBox(height: 20),
        _sectionHeader(ac, Icons.account_balance_wallet_rounded, 'Τι μου οφείλεται',
            'Ανά πηγή εσόδου'),
        if (myReceive == null || (myReceive['total'] as double) <= 0.01)
          _Empty('Τίποτα ✔', ac)
        else
          _recipientCard(ac, uid, myReceive, expanded: true),
        const SizedBox(height: 20),
        _sectionHeader(ac, Icons.history_rounded, 'Ιστορικό εκκαθαρίσεων',
            'Οι δικές σου παραδόσεις/παραλαβές'),
        ..._historyCards(ac, mySets),
      ],
    );
  }

  // ─── Σύνοψη (3 stats) ──────────────────────────────────────────────────────
  Widget _summaryBar(AppColors ac, double pending, double owed, double settled) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            colors: [Color(0xFFFFC533), _kAmber],
            begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: _kAmber.withValues(alpha: 0.4), blurRadius: 10, offset: const Offset(0, 4)),
        ],
      ),
      child: Row(
        children: [
          _stat(ac, 'Εκκρεμή', _eur(pending), _kOrange, Icons.hourglass_top_rounded),
          _vDiv(),
          _stat(ac, 'Οφειλόμενα', _eur(owed), _kInk, Icons.account_balance_wallet_rounded),
          _vDiv(),
          _stat(ac, 'Εξοφλημένα', _eur(settled), _kGreen, Icons.verified_rounded),
        ],
      ),
    );
  }

  Widget _vDiv() => Container(
      width: 1, height: 42, color: Colors.black.withValues(alpha: 0.15),
      margin: const EdgeInsets.symmetric(horizontal: 10));

  // Σημείωση: αυτή η μπάρα έχει ΠΑΝΤΑ κίτρινο/πορτοκαλί gradient φόντο (brand
  // accent, όχι «surface») — τα εσωτερικά κείμενα δουλεύουν με μαύρο/ημιδιαφανές
  // πάνω σε αυτό ανεξαρτήτως θέματος, οπότε δεν χρειάζονται αλλαγή.
  Widget _stat(AppColors ac, String label, String value, Color color, IconData icon) {
    return Expanded(
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 14, color: Colors.black54),
              const SizedBox(width: 4),
              Flexible(
                child: Text(label,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: Colors.black54, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          FittedBox(
            child: Text(value,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: color)),
          ),
        ],
      ),
    );
  }

  // ─── Επικεφαλίδες ενοτήτων ────────────────────────────────────────────────
  Widget _sectionHeader(AppColors ac, IconData icon, String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: _kAmber.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, size: 18, color: _kAmberDarkText),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w800, color: ac.textMain)),
                Text(subtitle,
                    style: TextStyle(fontSize: 11, color: ac.textFaint)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static const Color _kAmberDarkText = Color(0xFF8A6100);

  // ─── Κάρτες προώθησης (με μπάρα προόδου πληρωμής) ─────────────────────────
  List<Widget> _forwardingCards(AppColors ac,
      BuildContext context, Map<String, Map<String, dynamic>> ledger,
      {bool hideName = false}) {
    final cards = <Widget>[];
    for (final e in ledger.entries) {
      final cName = (e.value['name'] as String?)?.trim() ?? '';
      final byRec = (e.value['byRecipient'] as Map<String, Map<String, dynamic>>)
          .entries
          .where((r) => (r.value['pending'] as double) > 0.01)
          .toList()
        ..sort((a, b) => (b.value['pending'] as double)
            .compareTo(a.value['pending'] as double));
      if (byRec.isEmpty) continue;

      cards.add(_card(
        ac,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!hideName) ...[
              Row(children: [
                const CircleAvatar(radius: 13, backgroundColor: _kAmber,
                    child: Icon(Icons.person, size: 16, color: Colors.black87)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(cName.isEmpty ? 'Εισπράκτορας' : cName,
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14,
                          color: ac.textMain)),
                ),
              ]),
              const SizedBox(height: 8),
            ],
            for (final r in byRec)
              _forwardRow(ac, context, e.key, cName, r.key, r.value),
          ],
        ),
      ));
    }
    if (cards.isEmpty) cards.add(_Empty('Καμία εκκρεμής προώθηση ✔', ac));
    return cards;
  }

  Widget _forwardRow(AppColors ac, BuildContext context, String collectorUid,
      String collectorName, String rid, Map<String, dynamic> r) {
    final isMasterRec = r['isMaster'] == true;
    final name      = (r['name'] as String?)?.trim() ?? '';
    final pending   = r['pending']   as double;
    final collected = r['collected'] as double;
    final forwarded = r['forwarded'] as double;
    final progress  = collected > 0 ? (forwarded / collected).clamp(0.0, 1.0) : 0.0;
    final label = isMasterRec
        ? 'Προς Master (app + συνδρομή)'
        : 'Προς ${name.isEmpty ? 'admin' : name}';

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 5),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _kOrange.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _kOrange.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(label,
                    style: TextStyle(fontWeight: FontWeight.w700, color: ac.textMain)),
              ),
              _chip('ΕΚΚΡΕΜΕΙ ${_eur(pending)}', _kOrange),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 7,
              backgroundColor: _kOrange.withValues(alpha: 0.15),
              valueColor: const AlwaysStoppedAnimation<Color>(_kGreen),
            ),
          ),
          const SizedBox(height: 5),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Εισπράχθηκαν: ${_eur(collected)}',
                  style: TextStyle(fontSize: 11, color: ac.textFaint)),
              Text('Παραδόθηκαν: ${_eur(forwarded)}',
                  style: const TextStyle(fontSize: 11, color: _kGreen, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: AppButton(
              label: 'Προώθησα',
              icon: Icons.check_circle_outline,
              color: _kGreen,
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
    final ac = AppColors.of(context);
    final ctrl = TextEditingController(text: pending.toStringAsFixed(2));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ac.card,
        title: Text('Προώθηση σε $recipientName',
            style: TextStyle(color: ac.textMain)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Εκκρεμεί: ${_eur(pending)}',
                style: TextStyle(color: ac.textFaint)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              style: TextStyle(color: ac.textMain),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
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
          AppButton(label: 'Καταγραφή', color: _kAmber, onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
    );
    if (ok != true) return;
    final amount = double.tryParse(ctrl.text.trim().replaceAll(',', '.')) ?? 0;
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

  // ─── Κάρτα δικαιούχου ─────────────────────────────────────────────────────
  Widget _recipientCard(AppColors ac, String rid, Map<String, dynamic> data,
      {bool expanded = false}) {
    final name  = (data['name'] as String?)?.trim();
    final total = data['total'] as double;
    final bySource = (data['bySource'] as Map<String, double>).entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final byCollector =
        (data['byCollector'] as Map<String, Map<String, dynamic>>).values.toList();
    final title = (name == null || name.isEmpty)
        ? (rid == JobService.kMasterRecipient ? 'Master' : 'Admin')
        : name;

    return _card(
      ac,
      padding: EdgeInsets.zero,
      child: ExpansionTile(
        initiallyExpanded: expanded,
        shape: const Border(),
        backgroundColor: _kBlue.withValues(alpha: 0.06),
        collapsedBackgroundColor: _kBlue.withValues(alpha: 0.06),
        iconColor: _kBlue,
        collapsedIconColor: _kBlue,
        leading: const CircleAvatar(radius: 15, backgroundColor: _kBlue,
            child: Icon(Icons.account_balance_wallet_rounded, size: 16, color: Colors.white)),
        title: Text(title, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14,
            color: ac.textMain)),
        trailing: _chip(_eur(total), _kBlue),
        childrenPadding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        children: [
          if (bySource.isNotEmpty) ...[
            _subLabel(ac, 'Ανά πηγή εσόδου'),
            for (final s in bySource)
              if (s.value > 0.01) _row(ac, s.key, _eur(s.value)),
          ],
          if (byCollector.any((cc) => (cc['total'] as double) > 0.01)) ...[
            const SizedBox(height: 6),
            _subLabel(ac, 'Το κρατούν για λογαριασμό του'),
            for (final cc in byCollector)
              if ((cc['total'] as double) > 0.01)
                _row(
                  ac,
                  (cc['name'] as String?)?.isNotEmpty == true
                      ? cc['name'] as String : 'Εισπράκτορας',
                  _eur(cc['total'] as double),
                ),
          ],
        ],
      ),
    );
  }

  // ─── Κάρτα εισπράκτορα ────────────────────────────────────────────────────
  Widget _collectorCard(AppColors ac, String cid, Map<String, dynamic> data,
      {bool expanded = false}) {
    final name  = (data['name'] as String?)?.trim();
    final total = data['total'] as double;
    final byRecipient =
        (data['byRecipient'] as Map<String, Map<String, dynamic>>)
            .entries.toList()
          ..sort((a, b) => (b.value['total'] as double)
              .compareTo(a.value['total'] as double));
    final title = (name == null || name.isEmpty) ? 'Εισπράκτορας' : name;

    return _card(
      ac,
      padding: EdgeInsets.zero,
      child: ExpansionTile(
        initiallyExpanded: expanded,
        shape: const Border(),
        backgroundColor: _kAmber.withValues(alpha: 0.10),
        collapsedBackgroundColor: _kAmber.withValues(alpha: 0.10),
        iconColor: const Color(0xFF9A7000),
        collapsedIconColor: const Color(0xFF9A7000),
        leading: const CircleAvatar(radius: 15, backgroundColor: _kAmber,
            child: Icon(Icons.person, size: 16, color: Colors.black87)),
        title: Text(title, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14,
            color: ac.textMain)),
        trailing: _chip(_eur(total), _kInk),
        childrenPadding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        children: [
          for (final r in byRecipient)
            if ((r.value['total'] as double) > 0.01)
              _recipientBreakdown(ac, cid, r.key, r.value),
        ],
      ),
    );
  }

  Widget _recipientBreakdown(
      AppColors ac, String collectorUid, String rid, Map<String, dynamic> r) {
    final isMasterRec = r['isMaster'] == true;
    final isOwn       = rid == collectorUid;
    final name        = (r['name'] as String?)?.trim();
    final total       = r['total'] as double;
    final bySource    = (r['bySource'] as Map<String, double>).entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final String label;
    final Color  color;
    if (isOwn) {
      label = 'Κρατά (δικά του)';
      color = _kGreen;
    } else if (isMasterRec) {
      label = 'Προς Master (app + συνδρομή)';
      color = _kBlue;
    } else {
      label = 'Προς ${(name == null || name.isEmpty) ? 'admin' : name}';
      color = _kOrange;
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(label,
                    style: TextStyle(fontWeight: FontWeight.w700, color: color)),
              ),
              Text(_eur(total),
                  style: TextStyle(fontWeight: FontWeight.w800, color: color)),
            ],
          ),
          for (final s in bySource)
            if (s.value > 0.01)
              Padding(
                padding: const EdgeInsets.only(left: 8, top: 2),
                child: _row(ac, s.key, _eur(s.value), small: true),
              ),
        ],
      ),
    );
  }

  // ─── Ιστορικό εκκαθαρίσεων ────────────────────────────────────────────────
  List<Widget> _historyCards(AppColors ac, List<Settlement> sets) {
    if (sets.isEmpty) return [_Empty('Καμία εκκαθάριση ακόμα', ac)];
    final sorted = [...sets]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final show = sorted.take(15).toList();
    return [
      _card(
        ac,
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            for (int i = 0; i < show.length; i++) ...[
              if (i > 0) Divider(height: 1, color: ac.divider),
              ListTile(
                dense: true,
                leading: const CircleAvatar(radius: 13, backgroundColor: _kGreen,
                    child: Icon(Icons.check_rounded, size: 15, color: Colors.white)),
                title: Text(
                  '${show[i].collectorName.isEmpty ? "Εισπράκτορας" : show[i].collectorName}'
                  ' → '
                  '${show[i].recipientName.isEmpty ? "Παραλήπτης" : show[i].recipientName}',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                      color: ac.textMain),
                ),
                subtitle: Text(_date(show[i].createdAt),
                    style: TextStyle(fontSize: 11, color: ac.textFaint)),
                trailing: Text(_eur(show[i].amount),
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, color: _kGreen, fontSize: 14)),
              ),
            ],
            if (sorted.length > show.length)
              Padding(
                padding: const EdgeInsets.all(10),
                child: Text('… και ${sorted.length - show.length} παλαιότερες',
                    style: TextStyle(fontSize: 11, color: ac.textFaint)),
              ),
          ],
        ),
      ),
    ];
  }

  // ─── Μικρά κοινά widgets ──────────────────────────────────────────────────
  Widget _card(AppColors ac, {required Widget child, EdgeInsetsGeometry? padding}) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 5),
      padding: padding ?? const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ac.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ac.cardBorder),
      ),
      child: child,
    );
  }

  Widget _chip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(text,
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: color)),
    );
  }

  Widget _subLabel(AppColors ac, String text) => Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Text(text,
            style: TextStyle(fontSize: 11, color: ac.textFaint,
                fontWeight: FontWeight.w600)),
      ));

  Widget _row(AppColors ac, String left, String right, {bool small = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(child: Text(left,
              style: TextStyle(fontSize: small ? 12 : 14, color: ac.textMain))),
          Text(right, style: TextStyle(fontSize: small ? 12 : 14,
              fontWeight: FontWeight.w600, color: ac.textMain)),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  final String text;
  final AppColors? ac;
  const _Empty(this.text, [this.ac]);
  @override
  Widget build(BuildContext context) {
    final t = ac ?? AppColors.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 5),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: t.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.cardBorder),
      ),
      child: Text(text, style: TextStyle(color: t.textFaint)),
    );
  }
}
