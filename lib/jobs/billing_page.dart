// lib/jobs/billing_page.dart
//
// Σελίδα χρεώσεων με μηνιαία ανάλυση.
//  • Οδηγός → δικές του μηνιαίες χρεώσεις (ανά πηγή, συνδρομή, app).
//  • Admin  → ομάδες του → οδηγοί ομάδας → καρτέλα καθενός.
//  • Master → όλες οι ομάδες → οδηγοί → καρτέλα + καταγραφή πληρωμών.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'billing_settlement_page.dart';
import '../app_theme.dart';
import 'job_details_sheet.dart';
import 'job_model.dart';
import 'job_service.dart';
import 'job_shared_widgets.dart';

const _purple = Color(0xFF5E35B1);
// Μπλε = ο διαχειριστής χρωστάει στον οδηγό (αρνητική οφειλή).
const _oweDriverBlue = Color(0xFF1565C0);

// Χρώμα ανάλογα με την οφειλή:
//   owed > 0  → κόκκινο (ο οδηγός χρωστάει)
//   owed < 0  → μπλε   (ο διαχειριστής χρωστάει στον οδηγό)
//   owed == 0 → πράσινο (εξοφλημένος)
Color _debtColor(double owed) {
  if (owed > 0.0001)  return Colors.red.shade700;
  if (owed < -0.0001) return _oweDriverBlue;
  return Colors.green;
}

// Σύντομο κείμενο κατάστασης οφειλής.
String _debtText(double owed) {
  if (owed > 0.0001)  return 'Χρωστάει ${owed.toStringAsFixed(2)}€';
  if (owed < -0.0001) return 'Του χρωστάς ${owed.abs().toStringAsFixed(2)}€';
  return 'Εξοφλημένος';
}


class BillingPage extends StatelessWidget {
  final String       uid;
  final String       userName;
  final bool         isMaster;
  final bool         isAdmin;
  final List<String> managedGroupIds;

  const BillingPage({
    super.key,
    required this.uid,
    this.userName        = '',
    this.isMaster        = false,
    this.isAdmin         = false,
    this.managedGroupIds = const [],
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final Widget body;
    if (isMaster) {
      body = _GroupListView(
          masterUid: uid, selfName: userName, isMaster: true);
    } else if (isAdmin) {
      body = _GroupListView(
          masterUid: uid, selfName: userName, isMaster: false,
          onlyGroupIds: managedGroupIds);
    } else {
      body = _DriverBillingView(
          uid: uid, userName: userName, masterUid: uid, canManage: false);
    }

    return Scaffold(
      backgroundColor: c.scaffold,
      appBar: AppBar(
        backgroundColor: _purple,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Row(children: [
          const Icon(Icons.account_balance_wallet_rounded, size: 22),
          const SizedBox(width: 10),
          Text(isMaster || isAdmin ? 'Χρεώσεις' : 'Το Χρέος μου',
              style: const TextStyle(fontWeight: FontWeight.bold)),
        ]),
        // ── Εργαλεία master/admin: μετακινήθηκαν σε ξεχωριστή σελίδα
        //    «Ρυθμίσεις» (πάνω δεξιά, γρανάζι) — πριν ήταν κολλημένα κάτω και
        //    έκρυβαν τη μισή οθόνη. Ίδια ακριβώς δικαιώματα με πριν.
        actions: (isMaster || isAdmin)
            ? [
                IconButton(
                  tooltip: 'Ρυθμίσεις Χρεώσεων',
                  icon: const Icon(Icons.settings_rounded),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => _BillingSettingsPage(
                        uid: uid, userName: userName, isMaster: isMaster,
                      ),
                    ),
                  ),
                ),
              ]
            : null,
      ),
      body: body,
    );
  }


  // ─── Μηνιαία αναφορά PDF (χειροκίνητη παραγωγή — μόνο master) ─────────────

  /// Κλειδί "YYYY-MM" του μήνα που είναι [back] μήνες πριν από τον τρέχοντα.
  static String _monthKeyAgo(int back) {
    final now = DateTime.now();
    final d   = DateTime(now.year, now.month - back, 1);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}';
  }

  static String _monthLabelOf(String key) {
    const months = ['', 'Ιανουάριος', 'Φεβρουάριος', 'Μάρτιος', 'Απρίλιος',
      'Μάιος', 'Ιούνιος', 'Ιούλιος', 'Αύγουστος', 'Σεπτέμβριος',
      'Οκτώβριος', 'Νοέμβριος', 'Δεκέμβριος'];
    final p = key.split('-');
    return '${months[int.parse(p[1])]} ${p[0]}';
  }

  // ─── Χρεώσεις Home Owners — λίστα με ό,τι χρωστάει ο καθένας ─────────────
  static Future<void> _showHomeOwnersBillingDialog(BuildContext context) async {
    final c = AppColors.of(context);
    const indigo = Color(0xFF3F51B5);
    await showDialog<void>(
      context: context,
      builder: (dctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: c.card,
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480, maxHeight: 640),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                color: indigo.withValues(alpha: 0.12),
                child: Row(children: [
                  const Icon(Icons.home_work_rounded, color: indigo, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text('Χρεώσεις Home Owners',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.bold, color: indigo)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: indigo),
                    onPressed: () => Navigator.of(dctx).pop(),
                  ),
                ]),
              ),
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Τι χρωστάει κάθε ιδιοκτήτης καταλύματος (βάσει της '
                        'περιόδου χρέωσης που έχεις ορίσει στο «Διαχειριστές»).',
                        style: TextStyle(fontSize: 11.5, color: c.textFaint),
                      ),
                      const SizedBox(height: 12),
                      Flexible(
                        child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                          stream: FirebaseFirestore.instance
                              .collection('presence')
                              .where('homeOwner', isEqualTo: true)
                              .snapshots(),
                          builder: (context, snap) {
                            if (!snap.hasData) {
                              return const Center(
                                  child: Padding(
                                      padding: EdgeInsets.all(20),
                                      child: CircularProgressIndicator()));
                            }
                            final owners = snap.data!.docs;
                            if (owners.isEmpty) {
                              return const Padding(
                                padding: EdgeInsets.all(20),
                                child: Text('Δεν υπάρχει ακόμα κανένας Home Owner.'),
                              );
                            }
                            double totalMonthly = 0, totalYearly = 0;
                            for (final o in owners) {
                              final d = o.data();
                              final amt = (d['homeOwnerBillingAmount'] as num?)?.toDouble() ?? 0;
                              final period = (d['homeOwnerBillingPeriod'] as String?) ?? 'month';
                              if (period == 'year') {
                                totalYearly += amt;
                              } else {
                                totalMonthly += amt;
                              }
                            }
                            return ListView(
                              shrinkWrap: true,
                              children: [
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(12),
                                  margin: const EdgeInsets.only(bottom: 10),
                                  decoration: BoxDecoration(
                                    color: indigo.withValues(alpha: 0.08),
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: Text(
                                    'Σύνολο μηνιαίων: ${totalMonthly.toStringAsFixed(2)}€\n'
                                    'Σύνολο ετήσιων: ${totalYearly.toStringAsFixed(2)}€',
                                    style: const TextStyle(
                                        fontSize: 12.5, fontWeight: FontWeight.w600,
                                        color: indigo),
                                  ),
                                ),
                                for (final o in owners)
                                  Builder(builder: (context) {
                                    final d = o.data();
                                    final name = [d['displayName'], d['lastName']]
                                        .where((s) => (s as String?)?.isNotEmpty == true)
                                        .join(' ');
                                    final client = d['ownerOfClientName'] as String? ?? '—';
                                    final amt = (d['homeOwnerBillingAmount'] as num?)?.toDouble() ?? 0;
                                    final period = (d['homeOwnerBillingPeriod'] as String?) ?? 'month';
                                    return Container(
                                      margin: const EdgeInsets.only(bottom: 8),
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 12, vertical: 10),
                                      decoration: BoxDecoration(
                                        color: c.card,
                                        borderRadius: BorderRadius.circular(14),
                                        border: Border.all(color: c.cardBorder),
                                      ),
                                      child: Row(children: [
                                        Icon(Icons.home_work_rounded,
                                            size: 18, color: indigo),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(name.isEmpty ? '(χωρίς όνομα)' : name,
                                                  style: const TextStyle(
                                                      fontWeight: FontWeight.bold, fontSize: 13.5)),
                                              Text('Κατάλυμα: $client',
                                                  style: TextStyle(
                                                      fontSize: 11.5, color: c.textFaint)),
                                            ],
                                          ),
                                        ),
                                        Text(
                                          '${amt.toStringAsFixed(2)}€ / '
                                          '${period == 'year' ? 'έτος' : 'μήνα'}',
                                          style: const TextStyle(
                                              fontWeight: FontWeight.bold, fontSize: 13, color: indigo),
                                        ),
                                      ]),
                                    );
                                  }),
                              ],
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Άνοιγμα φακέλου Drive (χωρίς νέο PDF) — μόνο master ──────────────────
  static Future<void> _openReportsFolder(BuildContext context) async {
    final c = AppColors.of(context);
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(
      duration: Duration(seconds: 20),
      content: Row(children: [
        SizedBox(width: 18, height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
        SizedBox(width: 12),
        Expanded(child: Text('Άνοιγμα φακέλου Google Drive…')),
      ]),
    ));
    try {
      final callable = FirebaseFunctions.instance
          .httpsCallable('getReportsFolderLink',
              options: HttpsCallableOptions(timeout: const Duration(seconds: 30)));
      final res  = await callable.call<Map<String, dynamic>>();
      final data = Map<String, dynamic>.from(res.data);
      final link = (data['link'] ?? '') as String;
      messenger.hideCurrentSnackBar();
      if (link.isEmpty) {
        messenger.showSnackBar(SnackBar(
          backgroundColor: Colors.red.shade700,
          content: const Text('Δεν βρέθηκε φάκελος αναφορών.'),
        ));
        return;
      }
      await launchUrl(Uri.parse(link), mode: LaunchMode.externalApplication);
    } on FirebaseFunctionsException catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.red.shade700,
        content: Text('Σφάλμα: ${e.message ?? e.code}'),
      ));
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.red.shade700,
        content: Text('Σφάλμα: $e'),
      ));
    }
  }

  static void _showReportDialog(BuildContext context) {
    final c = AppColors.of(context);
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: c.card,
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              color: _purple.withValues(alpha: 0.12),
              child: Row(children: [
                const Icon(Icons.picture_as_pdf_rounded, color: _purple, size: 20),
                const SizedBox(width: 8),
                const Text('Αναφορά μήνα',
                    style: TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15, color: _purple)),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (int back = 1; back <= 3; back++)
                    InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () {
                        Navigator.pop(ctx);
                        _generateReport(context, _monthKeyAgo(back));
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 12),
                        child: Row(children: [
                          Icon(Icons.calendar_month_rounded,
                              size: 17, color: c.textFaint),
                          const SizedBox(width: 10),
                          Text(_monthLabelOf(_monthKeyAgo(back)),
                              style: const TextStyle(
                                  fontSize: 14.5, fontWeight: FontWeight.w600)),
                        ]),
                      ),
                    ),
                  InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () {
                      Navigator.pop(ctx);
                      _generateReport(context, _monthKeyAgo(0));
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 12),
                      child: Row(children: [
                        Icon(Icons.calendar_today_rounded,
                            size: 17, color: c.textFaint),
                        const SizedBox(width: 10),
                        Text(
                            '${_monthLabelOf(_monthKeyAgo(0))} '
                            '(τρέχων — μέχρι σήμερα)',
                            style: TextStyle(
                                fontSize: 13.5, color: c.textFaint)),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: c.scaffold,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                        'Τα PDF στο Google Drive διατηρούνται για πάντα. Τα '
                        'δεδομένα του Firebase (ιστορικό δουλειών) διαγράφονται '
                        'μετά τους 3 μήνες — εκτός αν κάποιος χρωστάει.',
                        style: TextStyle(fontSize: 11, color: c.textFaint)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Future<void> _generateReport(BuildContext context, String monthKey) async {
    final c = AppColors.of(context);
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(
      duration: const Duration(seconds: 60),
      content: Row(children: [
        const SizedBox(width: 18, height: 18,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: Colors.white)),
        const SizedBox(width: 12),
        Expanded(child: Text(
            'Δημιουργία αναφοράς ${_monthLabelOf(monthKey)}…')),
      ]),
    ));

    try {
      final callable = FirebaseFunctions.instance
          .httpsCallable('generateMonthlyReport',
              options: HttpsCallableOptions(
                  timeout: const Duration(minutes: 5)));
      final res  = await callable.call<Map<String, dynamic>>(
          {'monthKey': monthKey});
      final data = Map<String, dynamic>.from(res.data);
      final link  = (data['link'] ?? '') as String;
      final where = (data['where'] ?? '') as String;

      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(
        backgroundColor: const Color(0xFF1E8E3E),
        duration: const Duration(seconds: 10),
        content: Text('Η αναφορά ${_monthLabelOf(monthKey)} '
            'αποθηκεύτηκε στο $where ✓'),
        action: link.isNotEmpty
            ? SnackBarAction(
                label: 'ΑΝΟΙΓΜΑ',
                textColor: Colors.white,
                onPressed: () => launchUrl(Uri.parse(link),
                    mode: LaunchMode.externalApplication),
              )
            : null,
      ));
    } on FirebaseFunctionsException catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.red.shade700,
        content: Text('Σφάλμα αναφοράς: ${e.message ?? e.code}'),
      ));
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.red.shade700,
        content: Text('Σφάλμα αναφοράς: $e'),
      ));
    }
  }

  // ─── Καθαρισμός παλιών δεδομένων (>3 μήνες) — μόνο master ────────────────
  static Future<void> _showPurgeDialog(BuildContext context) async {
    final c = AppColors.of(context);
    final messenger = ScaffoldMessenger.of(context);
    // Πρώτα ρώτα το backend πόσα εκκρεμούν & αν μπλοκάρει χρέος.
    int purgeable = 0;
    bool blocked = false;
    try {
      final res = await FirebaseFunctions.instance
          .httpsCallable('purgeStatus')
          .call<Map<String, dynamic>>();
      final data = Map<String, dynamic>.from(res.data);
      purgeable = (data['purgeableJobs'] as num?)?.toInt() ?? 0;
      blocked   = data['blockedByDebt'] == true;
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.red.shade700,
        content: Text('Σφάλμα ελέγχου: $e'),
      ));
      return;
    }
    if (!context.mounted) return;

    if (purgeable == 0) {
      showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          backgroundColor: c.card,
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                color: _purple.withValues(alpha: 0.12),
                child: const Row(children: [
                  Icon(Icons.cleaning_services_rounded, color: _purple, size: 20),
                  SizedBox(width: 8),
                  Text('Καθαρισμός δεδομένων',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15, color: _purple)),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Δεν υπάρχουν παλιά δεδομένα (>3 μήνες) προς διαγραφή.',
                        style: TextStyle(fontSize: 13.5)),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      height: 46,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: _purple,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Εντάξει'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
      return;
    }

    const warnRed = Color(0xFFC0392B);
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: c.card,
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              color: warnRed.withValues(alpha: 0.12),
              child: const Row(children: [
                Icon(Icons.warning_amber_rounded, color: warnRed, size: 20),
                SizedBox(width: 8),
                Expanded(
                  child: Text('Καθαρισμός δεδομένων',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15, color: warnRed)),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(blocked
                      ? 'Υπάρχουν $purgeable παλιές δουλειές (>3 μήνες), αλλά '
                          'κάποιος χρωστάει. Πρέπει πρώτα να ξεχρεώσουν όλοι — '
                          'μετά μπορείς να τις διαγράψεις.'
                      : 'Θα διαγραφούν οριστικά $purgeable παλιές δουλειές '
                          '(>3 μήνες) μαζί με τις οικονομικές τους εγγραφές. '
                          'Η ενέργεια δεν αναιρείται.',
                      style: const TextStyle(fontSize: 13.5)),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E8E3E).withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(children: [
                      const Icon(Icons.shield_moon_rounded,
                          size: 16, color: Color(0xFF1E8E3E)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                            'Τα PDF στο Drive μένουν για πάντα. Ο τζίρος «από '
                            'πάντα» ΔΕΝ επηρεάζεται — είναι κλειδωμένος ανά μήνα.',
                            style: TextStyle(
                                fontSize: 11.5, color: Colors.green.shade800,
                                fontWeight: FontWeight.w600)),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 16),
                  if (blocked)
                    SizedBox(
                      width: double.infinity,
                      height: 46,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: _purple,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Κατάλαβα'),
                      ),
                    )
                  else
                    Row(children: [
                      Expanded(
                        child: SizedBox(
                          height: 46,
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(ctx),
                            style: OutlinedButton.styleFrom(
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12)),
                            ),
                            child: const Text('Άκυρο'),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: SizedBox(
                          height: 46,
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: warnRed,
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12)),
                            ),
                            onPressed: () {
                              Navigator.pop(ctx);
                              _runPurge(context);
                            },
                            child: const Text('Διαγραφή'),
                          ),
                        ),
                      ),
                    ]),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Future<void> _runPurge(BuildContext context) async {
    final c = AppColors.of(context);
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(
      duration: Duration(seconds: 60),
      content: Row(children: [
        SizedBox(width: 18, height: 18,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: Colors.white)),
        SizedBox(width: 12),
        Text('Διαγραφή παλιών δεδομένων…'),
      ]),
    ));
    try {
      final res = await FirebaseFunctions.instance
          .httpsCallable('purgeOldDataNow',
              options: HttpsCallableOptions(
                  timeout: const Duration(minutes: 5)))
          .call<Map<String, dynamic>>();
      final data = Map<String, dynamic>.from(res.data);
      final deleted = (data['deleted'] as num?)?.toInt() ?? 0;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(
        backgroundColor: const Color(0xFF1E8E3E),
        content: Text('Διαγράφηκαν $deleted παλιές δουλειές ✓'),
      ));
    } on FirebaseFunctionsException catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.red.shade700,
        content: Text(e.message ?? e.code),
      ));
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.red.shade700,
        content: Text('Σφάλμα: $e'),
      ));
    }
  }
}

// ═══ Ρυθμίσεις Χρεώσεων (ξεχωριστή σελίδα — γρανάζι πάνω δεξιά) ═════════════
// Πριν, αυτά τα εργαλεία ήταν μια μπάρα κολλημένη στο κάτω μέρος της κύριας
// σελίδας Χρεώσεων και έκρυβαν τη μισή οθόνη. Τώρα ζουν εδώ, σε δική τους
// σελίδα, ανοίγοντας από το γρανάζι πάνω δεξιά.
class _BillingSettingsPage extends StatelessWidget {
  final String uid;
  final String userName;
  final bool   isMaster;

  const _BillingSettingsPage({
    required this.uid,
    required this.userName,
    required this.isMaster,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Scaffold(
      backgroundColor: c.scaffold,
      appBar: AppBar(
        backgroundColor: _purple,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('Ρυθμίσεις Χρεώσεων',
            style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: _BillingToolsBar(
        isMaster: isMaster,
        onHomeOwners: () =>
            BillingPage._showHomeOwnersBillingDialog(context),
        onDriveFolder: () => BillingPage._openReportsFolder(context),
        onMonthlyReport: () => BillingPage._showReportDialog(context),
        onPurge: () => BillingPage._showPurgeDialog(context),
        onSettlements: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => BillingSettlementPage(
              uid:      uid,
              userName: userName,
              isMaster: isMaster,
            ),
          ),
        ),
      ),
    );
  }
}

// ═══ Εργαλεία Χρεώσεων (κάτω μέρος σελίδας — μόνο master/admin) ═════════════
// Πριν ήταν γυμνά εικονίδια πάνω δεξιά στο AppBar χωρίς καμία εξήγηση.
// Τώρα κάθε εργαλείο έχει τίτλο + περιγραφή, ώστε να ξέρεις τι κάνει το
// καθένα με μια ματιά. Ίδια ΑΚΡΙΒΩΣ δικαιώματα με πριν:
//   • Home Owners / Google Drive / Μηνιαία Αναφορά / Καθαρισμός → μόνο master
//   • Εκκαθαρίσεις → master ΚΑΙ admin
class _BillingToolsBar extends StatelessWidget {
  final bool         isMaster;
  final VoidCallback onHomeOwners;
  final VoidCallback onDriveFolder;
  final VoidCallback onMonthlyReport;
  final VoidCallback onPurge;
  final VoidCallback onSettlements;

  const _BillingToolsBar({
    required this.isMaster,
    required this.onHomeOwners,
    required this.onDriveFolder,
    required this.onMonthlyReport,
    required this.onPurge,
    required this.onSettlements,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: c.scaffold,
        border: Border(top: BorderSide(color: c.cardBorder)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isMaster) ...[
              _toolRow(c,
                icon: Icons.home_work_rounded,
                title: 'Χρεώσεις Home Owners',
                subtitle: 'Τι οφείλεται από ιδιοκτήτες καταλυμάτων',
                onTap: onHomeOwners,
              ),
              _divider(c),
              _toolRow(c,
                icon: Icons.folder_open_rounded,
                title: 'Φάκελος Google Drive',
                subtitle: 'Οι αποθηκευμένες μηνιαίες αναφορές PDF',
                onTap: onDriveFolder,
              ),
              _divider(c),
              _toolRow(c,
                icon: Icons.picture_as_pdf_rounded,
                title: 'Μηνιαία Αναφορά PDF',
                subtitle: 'Παραγωγή αναφοράς για συγκεκριμένο μήνα',
                onTap: onMonthlyReport,
              ),
              _divider(c),
              _toolRow(c,
                icon: Icons.cleaning_services_rounded,
                title: 'Καθαρισμός παλιών δεδομένων',
                subtitle: 'Διαγραφή παλιών, εξοφλημένων εγγραφών',
                onTap: onPurge,
              ),
              _divider(c),
            ],
            _toolRow(c,
              icon: Icons.account_tree_rounded,
              title: 'Εκκαθαρίσεις',
              subtitle: 'Καταγραφή πληρωμών μεταξύ οδηγών/διαχειριστών',
              onTap: onSettlements,
            ),
          ],
        ),
      ),
    );
  }

  Widget _divider(AppColors c) =>
      Divider(height: 1, indent: 56, color: c.cardBorder);

  Widget _toolRow(AppColors c, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(children: [
          CircleAvatar(
            radius: 17,
            backgroundColor: _purple.withValues(alpha: 0.1),
            child: Icon(icon, size: 18, color: _purple),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 14,
                        color: c.textMain)),
                Text(subtitle,
                    style: TextStyle(fontSize: 11.5, color: c.textFaint)),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, size: 18, color: c.textFaint),
        ]),
      ),
    );
  }
}

// ═══ Λίστα Ομάδων (master / admin) ═══════════════════════════════════════════

class _GroupListView extends StatefulWidget {
  final String        masterUid;
  final String        selfName;
  final bool          isMaster;
  final List<String>? onlyGroupIds;

  const _GroupListView({
    required this.masterUid,
    required this.isMaster,
    this.selfName = '',
    this.onlyGroupIds,
  });

  @override
  State<_GroupListView> createState() => _GroupListViewState();
}

class _GroupListViewState extends State<_GroupListView> {
  late Stream<Map<String, Map<String, dynamic>>> _stream;
  // Κρατάμε το τελευταίο αποτέλεσμα ώστε το pull-to-refresh να μην «αδειάζει»
  // την οθόνη και ώστε να μη δείχνουμε spinner σε κάθε live ανανέωση.
  Map<String, Map<String, dynamic>>? _last;

  @override
  void initState() {
    super.initState();
    _stream = JobService.groupBillingTotalsStream();
  }

  // Το stream ανανεώνεται μόνο του· το pull-to-refresh απλώς δίνει στον χρήστη
  // την αίσθηση χειροκίνητης ανανέωσης (επανασύνδεση στο stream).
  Future<void> _refresh() async {
    setState(() {
      _stream = JobService.groupBillingTotalsStream();
    });
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return StreamBuilder<Map<String, Map<String, dynamic>>>(
      stream: _stream,
      builder: (context, snap) {
        if (snap.hasData) _last = snap.data;
        final all = _last;
        if (all == null) {
          return const Center(
              child: CircularProgressIndicator(color: _purple));
        }
        final entries = all.entries
            .where((e) => widget.onlyGroupIds == null ||
                widget.onlyGroupIds!.contains(e.key))
            .toList();

        double grandOwed = 0, grandTurnover = 0, grandMonthTurnover = 0;
        int    grandJobs = 0, grandMonthJobs = 0;
        for (final e in entries) {
          grandOwed += (e.value['charges'] as double) -
              (e.value['payments'] as double);
          grandTurnover += e.value['turnover'] as double;
          grandJobs += (e.value['turnoverJobs'] as int? ?? 0);
          grandMonthTurnover += e.value['monthTurnover'] as double? ?? 0;
          grandMonthJobs += (e.value['monthTurnoverJobs'] as int? ?? 0);
        }

        return RefreshIndicator(
          color: _purple,
          onRefresh: _refresh,
          child: ListView(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
            children: [
              // ── Τα δικά μου χρέη/τζίρος (ο admin/master παίρνει κι αυτός
              //    δουλειές, από άλλον ή από τον εαυτό του) ──
              _SelfBillingCard(
                uid:       widget.masterUid,
                userName:  widget.selfName,
                masterUid: widget.masterUid,
                isMaster:  widget.isMaster,
              ),
              const SizedBox(height: 16),
              _TurnoverCard(
                label: widget.isMaster ? 'Τζίρος όλων των ομάδων' : 'Τζίρος ομάδων',
                lifetimeTurnover: grandTurnover,
                lifetimeJobs:     grandJobs,
                monthTurnover:    grandMonthTurnover,
                monthJobs:        grandMonthJobs,
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: _debtColor(grandOwed).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                      color: _debtColor(grandOwed).withValues(alpha: 0.35)),
                ),
                child: Column(children: [
                  Text(
                    '${widget.isMaster
                            ? 'Χρεώσεις — Σύνολο (όλες οι ομάδες)'
                            : 'Χρεώσεις — Σύνολο'}  ·  από πάντα',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: _debtColor(grandOwed)),
                  ),
                  const SizedBox(height: 4),
                  Text('${grandOwed.toStringAsFixed(2)}€',
                      style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          color: _debtColor(grandOwed))),
                ]),
              ),
              const SizedBox(height: 16),
              if (entries.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(bottom: 8, left: 2),
                  child: Text('Ομάδες',
                      style: TextStyle(fontSize: 12, color: c.textFaint)),
                ),
              ...entries.map((e) {
                final data     = e.value;
                final owed     = (data['charges'] as double) -
                    (data['payments'] as double);
                final turnover = data['turnover'] as double;
                final tJobs    = data['turnoverJobs'] as int? ?? 0;
                final drivers  = data['drivers']
                    as Map<String, Map<String, dynamic>>;
                final mCharges  = data['monthCharges']  as double? ?? 0;
                final mPayments = data['monthPayments'] as double? ?? 0;
                final mPaid = mPayments > mCharges ? mCharges : mPayments;
                final mLeft = (mCharges - mPaid).clamp(0, double.infinity);
                final gColor = mCharges <= 0.01
                    ? Colors.grey
                    : (mLeft <= 0.01
                        ? const Color(0xFF1E8E3E)
                        : (mPaid > 0.01
                            ? const Color(0xFFD9822B)
                            : const Color(0xFFC0392B)));
                final barColor = _debtColor(owed);
                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: c.card,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: c.cardBorder),
                  ),
                  child: InkWell(
                    onTap: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => _GroupDriversView(
                            groupName: data['name'] as String,
                            groupData: data,
                            masterUid: widget.masterUid,
                            // Admin μπορεί πλέον να διαχειρίζεται (μόνο τα δικά
                            // του γιαούρτια — φιλτράρεται μέσω isMaster=false).
                            canManage: true,
                            isMaster:  widget.isMaster,
                          ),
                        ),
                      );
                      // Επιστροφή από την καρτέλα οδηγών → ανανέωση συνόλων
                      if (mounted) _refresh();
                    },
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 11),
                          color: barColor.withValues(alpha: 0.14),
                          child: Row(children: [
                            Icon(Icons.groups_rounded,
                                size: 19, color: barColor),
                            const SizedBox(width: 7),
                            Expanded(
                              child: Text(data['name'] as String,
                                  style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 15,
                                      color: barColor)),
                            ),
                            Text('${owed.toStringAsFixed(2)}€',
                                style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                    color: barColor)),
                          ]),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                Icon(Icons.people_alt_rounded,
                                    size: 18, color: c.textFaint),
                                const SizedBox(width: 4),
                                Text('${drivers.length}',
                                    style: const TextStyle(fontSize: 13.5)),
                                const SizedBox(width: 14),
                                Icon(Icons.trending_up_rounded,
                                    size: 18, color: c.textFaint),
                                const SizedBox(width: 4),
                                Text(
                                    '${turnover.toStringAsFixed(0)}€ · '
                                    '$tJobs ${tJobs == 1 ? "δουλειά" : "δουλειές"}',
                                    style: const TextStyle(fontSize: 13.5)),
                              ]),
                              if (mCharges > 0.01) ...[
                                const SizedBox(height: 10),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: LinearProgressIndicator(
                                    value: (mPaid / mCharges).clamp(0.0, 1.0),
                                    minHeight: 6,
                                    backgroundColor:
                                        gColor.withValues(alpha: 0.18),
                                    valueColor: AlwaysStoppedAnimation(gColor),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Πληρώθηκαν ${mPaid.toStringAsFixed(2)}€ από τα '
                                  '${mCharges.toStringAsFixed(2)}€ του μήνα'
                                  '${mLeft > 0.01 ? " · μένουν ${mLeft.toStringAsFixed(2)}€" : ""}',
                                  style: TextStyle(fontSize: 11, color: gColor,
                                      fontWeight: FontWeight.w600),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
              if (entries.isEmpty)
                Padding(
                  padding: EdgeInsets.all(40),
                  child: Center(child: Text('Δεν υπάρχουν ομάδες',
                      style: TextStyle(color: c.textFaint))),
                ),
              // ── Δουλειές «εκτός ομάδας»: δουλειά που δημιούργησε ο admin/
              //    master αλλά την ανέλαβε οδηγός εκτός της δικής του ομάδας.
              _CrossGroupSection(
                viewerUid: widget.masterUid,
                isMaster:  widget.isMaster,
                groupOwnerNames: {
                  for (final e in entries)
                    if ((e.value['ownerUid'] as String? ?? '').isNotEmpty)
                      e.value['ownerUid'] as String: e.value['name'] as String,
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

// ═══ Δουλειές εκτός ομάδας (root σελίδα) ════════════════════════════════════
// Master: ομαδοποιημένα ανά ΠΑΡΑΛΗΠΤΗ («Χρωστάνε σε σένα» / «στον Χ» / ...).
// Admin:  μόνο η δική του λίστα, χωρίς υπο-ενότητες (μόνο σε αυτόν μπορεί να
//         οφείλεται κάτι εκτός ομάδας).
class _CrossGroupSection extends StatelessWidget {
  final String viewerUid;
  final bool   isMaster;
  final Map<String, String> groupOwnerNames; // ownerUid → όνομα ομάδας

  const _CrossGroupSection({
    required this.viewerUid,
    required this.isMaster,
    required this.groupOwnerNames,
  });

  String _recipientLabel(String recipientUid) {
    if (recipientUid == viewerUid) return 'σένα';
    return groupOwnerNames[recipientUid] ?? 'άλλον';
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return StreamBuilder<Map<String, List<Map<String, dynamic>>>>(
      stream: JobService.crossGroupReceivablesStream(),
      builder: (context, snap) {
        final all = snap.data ?? const {};
        // Admin: μόνο οι δικές του οφειλές. Master: όλα.
        final relevant = isMaster
            ? all
            : {
                if (all.containsKey(viewerUid))
                  viewerUid: all[viewerUid]!,
              };
        if (relevant.isEmpty) return const SizedBox.shrink();

        final recipientUids = relevant.keys.toList()
          ..sort((a, b) => a == viewerUid ? -1 : (b == viewerUid ? 1 : 0));

        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.only(bottom: 8, left: 2),
                child: Text('Δουλειές εκτός ομάδας',
                    style: TextStyle(fontSize: 12, color: c.textFaint)),
              ),
              for (final rid in recipientUids) ...[
                if (isMaster)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(2, 4, 2, 6),
                    child: Text('Χρωστάνε ${_recipientLabel(rid)}',
                        style: const TextStyle(
                            fontSize: 12.5, fontWeight: FontWeight.w700)),
                  ),
                ...relevant[rid]!.map((d) => Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: c.card,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                            color: c.cardBorder, style: BorderStyle.solid),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        child: Row(children: [
                          const Icon(Icons.person_off_rounded,
                              size: 18, color: Color(0xFFC0392B)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(d['name'] as String? ?? '—',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 13.5)),
                                Text('Ομάδα «${d['groupName']}»',
                                    style: TextStyle(
                                        fontSize: 11.5,
                                        color: c.textFaint)),
                              ],
                            ),
                          ),
                          Text(
                              '${(d['amount'] as double).toStringAsFixed(2)}€',
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                  color: Color(0xFFC0392B))),
                        ]),
                      ),
                    )),
              ],
            ],
          ),
        );
      },
    );
  }
}
// ═══ Κάρτα «Τα δικά μου» (admin / master) ════════════════════════════════════
// ΝΕΑ ΣΗΜΑΣΙΑ (όχι «σαν οδηγός»):
//  • Τζίρος = ΤΡΕΧΟΝΤΟΣ μήνα, από δουλειές που δημιούργησε ο ίδιος
//    (createdBy == uid) — χειροκίνητα Ή από τη ΔΙΚΗ ΤΟΥ online φόρμα.
//  • Οφειλές = ΟΛΩΝ των εποχών (ΟΧΙ μόνο μήνα) — τι ΤΟΥ οφείλεται συνολικά:
//    προμήθειες πηγής (μέσα ΚΑΙ έξω από ομάδα) + (μόνο master) προμήθειες
//    app/συνδρομές υπηρεσιών.
class _SelfBillingCard extends StatelessWidget {
  final String uid;
  final String userName;
  final String masterUid;
  final bool   isMaster;

  const _SelfBillingCard({
    required this.uid,
    required this.userName,
    required this.masterUid,
    this.isMaster = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return StreamBuilder<({double turnover, int jobs})>(
      stream: JobService.myCreatedTurnoverThisMonth(uid),
      builder: (context, tSnap) {
        final turnover  = tSnap.data?.turnover ?? 0.0;
        final jobsCount = tSnap.data?.jobs ?? 0;
        return StreamBuilder<double>(
          stream: JobService.myReceivablesAllTime(uid, isMaster: isMaster),
          builder: (context, rSnap) {
            final owed = rSnap.data ?? 0.0;
            final color = owed > 0.01
                ? const Color(0xFFD9822B) // σου οφείλουν κάτι ακόμα
                : const Color(0xFF1E8E3E); // όλα εξοφλημένα
            return Container(
              decoration: BoxDecoration(
                color: c.card,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: c.cardBorder),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 11),
                    color: _purple.withValues(alpha: 0.10),
                    child: Row(children: [
                      const Icon(Icons.person_rounded,
                          size: 20, color: _purple),
                      const SizedBox(width: 7),
                      const Text('Τα δικά μου',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                              color: _purple)),
                    ]),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          const Icon(Icons.trending_up_rounded,
                              size: 18, color: Colors.blueGrey),
                          const SizedBox(width: 6),
                          Text(
                            'Τζίρος μήνα: ${turnover.toStringAsFixed(2)}€  '
                            '($jobsCount ${jobsCount == 1 ? "δουλειά" : "δουλειές"})',
                            style: const TextStyle(fontSize: 13),
                          ),
                        ]),
                        const SizedBox(height: 6),
                        Row(children: [
                          Icon(Icons.account_balance_wallet_rounded,
                              size: 18, color: color),
                          const SizedBox(width: 6),
                          Text(
                            owed > 0.01
                                ? 'Σου οφείλουν ${owed.toStringAsFixed(2)}€'
                                : 'Δεν σου οφείλουν τίποτα',
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: color),
                          ),
                        ]),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

// ═══ Οδηγοί μιας Ομάδας ══════════════════════════════════════════════════════

class _GroupDriversView extends StatelessWidget {
  final String               groupName;
  final Map<String, dynamic> groupData;
  final String               masterUid;
  final bool                 canManage;
  final bool                 isMaster;

  const _GroupDriversView({
    required this.groupName,
    required this.groupData,
    required this.masterUid,
    required this.canManage,
    this.isMaster = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final owed     = (groupData['charges'] as double) -
        (groupData['payments'] as double);
    final turnover = groupData['turnover'] as double;
    final tJobs    = groupData['turnoverJobs'] as int? ?? 0;
    final mTurnover = groupData['monthTurnover'] as double? ?? 0;
    final mTJobs    = groupData['monthTurnoverJobs'] as int? ?? 0;
    final drivers  = (groupData['drivers']
            as Map<String, Map<String, dynamic>>)
        .entries
        .toList()
      ..sort((a, b) {
        final da = (a.value['charges'] as double) -
            (a.value['payments'] as double);
        final db = (b.value['charges'] as double) -
            (b.value['payments'] as double);
        return db.compareTo(da);
      });

    return Scaffold(
      backgroundColor: c.scaffold,
      appBar: AppBar(
        backgroundColor: _purple,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(groupName,
            style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 10, left: 2),
            child: Row(children: [
              Icon(Icons.groups_rounded, size: 15, color: c.textFaint),
              const SizedBox(width: 6),
              Text('Ομάδα', style: TextStyle(fontSize: 12.5, color: c.textFaint)),
              const SizedBox(width: 4),
              Text(groupName,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
            ]),
          ),
          _TurnoverCard(
            label: 'Τζίρος ομάδας',
            lifetimeTurnover: turnover,
            lifetimeJobs:     tJobs,
            monthTurnover:    mTurnover,
            monthJobs:        mTJobs,
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _debtColor(owed).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _debtColor(owed).withValues(alpha: 0.35)),
            ),
            child: Column(children: [
              Text('Χρεώσεις — Σύνολο ομάδας',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _debtColor(owed))),
              const SizedBox(height: 4),
              Text('${owed.toStringAsFixed(2)}€',
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: _debtColor(owed))),
            ]),
          ),
          const SizedBox(height: 16),
          if (drivers.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(bottom: 8, left: 2),
              child: Text('Οδηγοί ομάδας', style: TextStyle(fontSize: 12, color: c.textFaint)),
            ),
          ...drivers.map((e) {
            final uid       = e.key;
            final d         = e.value;
            final dOwed     = (d['charges'] as double) -
                (d['payments'] as double);
            final dTurnover = d['turnover'] as double;
            final dJobs     = d['turnoverJobs'] as int? ?? 0;
            final name      = d['name'] as String;
            final barColor  = _debtColor(dOwed);
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: c.card,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: c.cardBorder),
              ),
              child: InkWell(
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      backgroundColor: c.scaffold,
                      appBar: AppBar(
                        backgroundColor: _purple,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        title: Text(name,
                            style: const TextStyle(fontWeight: FontWeight.bold)),
                      ),
                      body: _DriverBillingView(
                        uid:       uid,
                        userName:  name,
                        masterUid: masterUid,
                        canManage: canManage,
                        isMaster:  isMaster,
                      ),
                    ),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      color: barColor.withValues(alpha: 0.14),
                      child: Row(children: [
                        Icon(
                          dOwed > 0.0001
                              ? Icons.error_outline_rounded
                              : dOwed < -0.0001
                                  ? Icons.south_west_rounded
                                  : Icons.check_circle_rounded,
                          size: 18, color: barColor,
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(name,
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14.5, color: barColor)),
                        ),
                        Text('${dOwed.toStringAsFixed(2)}€',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: barColor)),
                        const SizedBox(width: 6),
                        Icon(Icons.chevron_right_rounded, size: 16, color: c.textFaint),
                      ]),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                      child: Row(children: [
                        Icon(Icons.trending_up_rounded, size: 16, color: c.textFaint),
                        const SizedBox(width: 4),
                        Text('${dTurnover.toStringAsFixed(0)}€ · $dJobs ${dJobs == 1 ? "δουλειά" : "δουλειές"}',
                            style: const TextStyle(fontSize: 12.5)),
                        const SizedBox(width: 12),
                        Text(_debtText(dOwed),
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: barColor)),
                      ]),
                    ),
                  ],
                ),
              ),
            );
          }),
          if (drivers.isEmpty)
            Padding(
              padding: EdgeInsets.all(40),
              child: Center(child: Text('Δεν υπάρχουν οδηγοί',
                  style: TextStyle(color: c.textFaint))),
            ),
          // ── Πήραν δουλειά σου εκτός ομάδας: φιλτραρισμένο ΜΟΝΟ για τον
          //    ιδιοκτήτη ΑΥΤΗΣ της ομάδας (ownerUid), όχι για όποιον απλά
          //    την προβάλλει (π.χ. ο master βλέπει την ομάδα του admin Χ).
          _OutsideGroupSection(
            recipientUid: (groupData['ownerUid'] as String?)?.isNotEmpty == true
                ? groupData['ownerUid'] as String
                : masterUid,
          ),
        ],
      ),
    );
  }
}

// ═══ «Πήραν δουλειά σου εκτός ομάδας» (σελίδα μίας ομάδας) ══════════════════
class _OutsideGroupSection extends StatelessWidget {
  final String recipientUid;
  const _OutsideGroupSection({required this.recipientUid});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return StreamBuilder<Map<String, List<Map<String, dynamic>>>>(
      stream: JobService.crossGroupReceivablesStream(),
      builder: (context, snap) {
        final list = snap.data?[recipientUid] ?? const [];
        if (list.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 8, left: 2, top: 4),
                child: Row(children: [
                  Icon(Icons.arrow_forward_rounded, size: 14, color: c.textFaint),
                  const SizedBox(width: 5),
                  Text('Πήραν δουλειά σου εκτός ομάδας',
                      style: TextStyle(fontSize: 12, color: c.textFaint)),
                ]),
              ),
              ...list.map((d) => Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: c.card,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: c.cardBorder),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      child: Row(children: [
                        const Icon(Icons.person_off_rounded, size: 18, color: Color(0xFFC0392B)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(d['name'] as String? ?? '—',
                                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
                              Text('Ομάδα «${d['groupName']}»',
                                  style: TextStyle(fontSize: 11.5, color: c.textFaint)),
                            ],
                          ),
                        ),
                        Text('${(d['amount'] as double).toStringAsFixed(2)}€',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFFC0392B))),
                      ]),
                    ),
                  )),
            ],
          ),
        );
      },
    );
  }
}

// ═══ Καρτέλα Οδηγού — μηνιαία ανάλυση ════════════════════════════════════════

class _DriverBillingView extends StatelessWidget {
  final String uid;
  final String userName;
  final String masterUid;
  final bool   canManage;
  final bool   isMaster;

  const _DriverBillingView({
    required this.uid,
    required this.userName,
    required this.masterUid,
    required this.canManage,
    this.isMaster            = false,
  });

  // Όταν εξοφλεί admin (όχι master), οι πληρωμές αφορούν ΜΟΝΟ τις χρεώσεις
  // όπου παραλήπτης είναι ο ίδιος (τα δικά του γιαούρτια). Master → null (όλα).
  String? get _recipientFilter => isMaster ? null : masterUid;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return StreamBuilder<({double turnover, int jobs})>(
      stream: JobService.lockedTurnoverThroughLastMonth(uid),
      builder: (context, lockedSnap) {
        final lockedTurnover = lockedSnap.data?.turnover ?? 0.0;
        final lockedJobs     = lockedSnap.data?.jobs ?? 0;
        return StreamBuilder<({double turnover, int jobs})>(
          stream: JobService.monthlyTurnoverStatsFor(uid),
          builder: (context, mSnap) {
        final monthTurnover = mSnap.data?.turnover ?? 0.0;
        final monthJobsN    = mSnap.data?.jobs ?? 0;
        // «Από πάντα» = κλειδωμένο (μέχρι προηγούμενο μήνα) + τρέχων μήνας
        // (ζωντανό — αν ακυρωθεί δουλειά ΤΩΡΑ, αφαιρείται αμέσως εδώ).
        final lifeTurnover = lockedTurnover + monthTurnover;
        final lifeJobs     = lockedJobs + monthJobsN;
        return StreamBuilder<List<MonthlyBilling>>(
          stream: JobService.monthlyBillingFor(uid, isMaster: isMaster),
          builder: (context, snap) {
            if (!snap.hasData) {
              return const Center(
                  child: CircularProgressIndicator(color: _purple));
            }
            final months = snap.data!;
            // Άθροισμα balance ΟΛΩΝ των μηνών — με το πρόσημο.
            // Αρνητικό σύνολο = ο διαχειριστής χρωστάει στον οδηγό (μπλε).
            // ΣΗΜΕΙΩΣΗ: αυτό ΗΔΗ ήταν all-time (όχι μόνο τρέχοντος μήνα) —
            // παλιοί ανεξόφλητοι μήνες παραμένουν ορατοί κανονικά.
            final totalOwed = months.fold<double>(
                0, (s, m) => s + m.balance);

            // Ανάλυση οφειλών ανά πηγή (από τους ΑΠΛΗΡΩΤΟΥΣ μήνες)
            final owedBySource = <String, double>{};
            double owedSub = 0, owedCalSub = 0, owedApp = 0;
            for (final m in months) {
              if (m.paid) continue;
              m.bySource.forEach((k, v) =>
                  owedBySource[k] = (owedBySource[k] ?? 0) + v);
              owedSub += m.subscription;
              owedCalSub += m.calendarSubscription;
              owedApp += m.appCommission;
            }

            return ListView(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
              children: [
                _TurnoverCard(
                  label: 'Τζίρος',
                  lifetimeTurnover: lifeTurnover,
                  lifetimeJobs:     lifeJobs,
                  monthTurnover:    monthTurnover,
                  monthJobs:        monthJobsN,
                ),
                const SizedBox(height: 10),
                // Χρεώσεις — μεγάλο κουτί (all-time, ΟΧΙ μόνο μήνα)
                _BigStat(
                  label:  'Χρεώσεις — Οφειλόμενα  ·  όλων των εποχών',
                  amount: totalOwed,
                  color:  _debtColor(totalOwed),
                ),
                const SizedBox(height: 16),
                // Ανάλυση ανά πηγή — τι να μαζέψουμε
                if (totalOwed.abs() > 0.0001) ...[
                  _OwedBreakdown(
                    bySource:     owedBySource,
                    subscription: owedSub,
                    calendarSubscription: owedCalSub,
                    appCommission: owedApp,
                  ),
                  const SizedBox(height: 16),
                ],
                const Text('Ανά μήνα',
                    style: TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15)),
                const SizedBox(height: 8),
                if (months.isEmpty)
                  Padding(
                    padding: EdgeInsets.all(30),
                    child: Center(child: Text('Δεν υπάρχουν χρεώσεις',
                        style: TextStyle(color: c.textFaint))),
                  ),
                ...months.map((m) => _MonthCard(
                      monthly:   m,
                      canManage: canManage,
                      recipientScope: _recipientFilter,
                      onPay: () => _payMonth(context, m),
                      onPartialPay: () => _payPartial(context, m),
                      onPayDriver: () => _payDriverMonth(context, m),
                      onPartialPayDriver: () => _payDriverPartial(context, m),
                    )),
              ],
            );
          },
        );
          },
        );
      },
    );
  }

  Future<void> _payMonth(BuildContext context, MonthlyBilling m) async {
    final c = AppColors.of(context);
    final bal = _recipientFilter == null
        ? m.balance
        : m.balanceForRecipient(_recipientFilter!);
    final ok = await _confirmStyled(
      context: context,
      icon: Icons.check_circle_rounded,
      color: const Color(0xFF1E8E3E),
      title: 'Εξόφληση — ${m.monthLabel}',
      amountLabel: '${bal.toStringAsFixed(2)}€',
      message: 'Να καταχωρηθεί ως πληρωμένο για τον/την $userName;',
      confirmLabel: 'Εξόφληση',
    );
    if (ok != true) return;
    // Admin → εξοφλεί μόνο τα δικά του· Master → όλα.
    await JobService.recordPayment(
      uid:              uid,
      uidName:          userName,
      amount:           bal,
      masterUid:        masterUid,
      monthKey:         m.monthKey,
      note:             'Εξόφληση μηνός ${m.monthKey}',
      onlyRecipientUid: _recipientFilter,
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${m.monthLabel}: εξοφλήθηκε'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  // ── Μερική πληρωμή: γράφεις π.χ. 7,20 και κατανέμεται FIFO ───────────────
  // (πρώτα η προμήθεια App, μετά οι παλιότερες χρεώσεις).
  Future<void> _payPartial(BuildContext context, MonthlyBilling m) async {
    final c = AppColors.of(context);
    final ctrl = TextEditingController();
    final amount = await showDialog<double>(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: c.card,
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Γεμάτη μπάρα header — ίδιο στυλ με τις κάρτες.
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              color: const Color(0xFFD9822B).withValues(alpha: 0.14),
              child: Row(children: [
                const Icon(Icons.payments_rounded,
                    size: 20, color: Color(0xFFD9822B)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Μερική πληρωμή — $userName',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                          color: Color(0xFFD9822B))),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: c.scaffold,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(children: [
                      Icon(Icons.info_outline_rounded,
                          size: 18, color: c.textFaint),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Οφειλή ${m.monthLabel}: ${m.balance.toStringAsFixed(2)}€\n'
                          'Εξοφλούνται πρώτα η προμήθεια App και μετά οι '
                          'παλιότερες δουλειές (FIFO).',
                          style: TextStyle(
                              fontSize: 12.5, color: c.textFaint),
                        ),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: ctrl,
                    autofocus: true,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    style: const TextStyle(
                        fontSize: 24, fontWeight: FontWeight.bold),
                    decoration: InputDecoration(
                      suffixText: '€',
                      suffixStyle: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.bold),
                      hintText: '0,00',
                      filled: true,
                      fillColor: c.scaffold,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(color: c.cardBorder),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(
                            color: Color(0xFFD9822B), width: 2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(children: [
                    Expanded(
                      child: SizedBox(
                        height: 48,
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(ctx),
                          style: OutlinedButton.styleFrom(
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                          child: const Text('Άκυρο'),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: SizedBox(
                        height: 48,
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF1E8E3E),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                          onPressed: () {
                            // Δεκτά και κόμμα και τελεία ως υποδιαστολή (π.χ. 7,20).
                            final raw =
                                ctrl.text.trim().replaceAll(',', '.');
                            final v = double.tryParse(raw);
                            if (v == null || v <= 0) return;
                            Navigator.pop(ctx, v);
                          },
                          child: const Text('Καταχώρηση'),
                        ),
                      ),
                    ),
                  ]),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (amount == null || amount <= 0) return;

    await JobService.recordPayment(
      uid:       uid,
      uidName:   userName,
      amount:    amount,
      masterUid: masterUid,
      monthKey:  m.monthKey,
      note:      'Μερική πληρωμή',
      onlyRecipientUid: _recipientFilter,
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'Καταχωρήθηκαν ${amount.toStringAsFixed(2)}€ — '
            'κατανεμήθηκαν στις παλιότερες χρεώσεις'),
        backgroundColor: Colors.green,
      ));
    }
  }

  // ── Πλήρης πληρωμή ΠΡΟΣ τον οδηγό (ο διαχειριστής χρωστάει) ──────────────
  Future<void> _payDriverMonth(BuildContext context, MonthlyBilling m) async {
    final c = AppColors.of(context);
    final bal = _recipientFilter == null
        ? m.balance
        : m.balanceForRecipient(_recipientFilter!);
    final owe = bal.abs();
    final ok = await _confirmStyled(
      context: context,
      icon: Icons.arrow_downward_rounded,
      color: const Color(0xFF1565C0),
      title: 'Πληρωμή προς οδηγό — ${m.monthLabel}',
      amountLabel: '${owe.toStringAsFixed(2)}€',
      message: 'Να καταχωρηθεί ότι έδωσες στον/στην $userName;',
      confirmLabel: 'Πλήρωσα',
    );
    if (ok != true) return;
    await JobService.markMonthPaidToDriver(
      uid:       uid,
      uidName:   userName,
      monthKey:  m.monthKey,
      balance:   bal,
      masterUid: masterUid,
      onlyRecipientUid: _recipientFilter,
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${m.monthLabel}: πληρώθηκε ο οδηγός'),
        backgroundColor: const Color(0xFF1565C0),
      ));
    }
  }

  // ── Κοινό, νέο στυλ confirm dialog (γεμάτη έγχρωμη μπάρα header) ─────────
  Future<bool?> _confirmStyled({
    required BuildContext context,
    required IconData icon,
    required Color color,
    required String title,
    required String amountLabel,
    required String message,
    required String confirmLabel,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) {
        final c = AppColors.of(context);
        return Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: c.card,
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              color: color.withValues(alpha: 0.14),
              child: Row(children: [
                Icon(icon, size: 20, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(title,
                      style: TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15, color: color)),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(amountLabel,
                      style: TextStyle(
                          fontSize: 26, fontWeight: FontWeight.w800, color: color)),
                  const SizedBox(height: 6),
                  Text(message,
                      style: TextStyle(fontSize: 13, color: c.textFaint)),
                  const SizedBox(height: 18),
                  Row(children: [
                    Expanded(
                      child: SizedBox(
                        height: 48,
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          style: OutlinedButton.styleFrom(
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                          child: const Text('Άκυρο'),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: SizedBox(
                        height: 48,
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: color,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                          onPressed: () => Navigator.pop(ctx, true),
                          child: Text(confirmLabel),
                        ),
                      ),
                    ),
                  ]),
                ],
              ),
            ),
          ],
        ),
      );
      },
    );
  }

  // ── Μερική πληρωμή ΠΡΟΣ τον οδηγό ───────────────────────────────────────
  Future<void> _payDriverPartial(BuildContext context, MonthlyBilling m) async {
    final c = AppColors.of(context);
    final bal = _recipientFilter == null
        ? m.balance
        : m.balanceForRecipient(_recipientFilter!);
    final owe = bal.abs();
    final ctrl = TextEditingController();
    const blue = Color(0xFF1565C0);
    final amount = await showDialog<double>(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: c.card,
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              color: blue.withValues(alpha: 0.14),
              child: Row(children: [
                const Icon(Icons.arrow_downward_rounded, size: 20, color: blue),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Πληρωμή προς οδηγό — $userName',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15, color: blue)),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: c.scaffold,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(children: [
                      Icon(Icons.info_outline_rounded,
                          size: 18, color: c.textFaint),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Του χρωστάς ${owe.toStringAsFixed(2)}€ για '
                          '${m.monthLabel}. Γράψε πόσα του έδωσες.',
                          style: TextStyle(
                              fontSize: 12.5, color: c.textFaint),
                        ),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: ctrl,
                    autofocus: true,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    style: const TextStyle(
                        fontSize: 24, fontWeight: FontWeight.bold),
                    decoration: InputDecoration(
                      suffixText: '€',
                      suffixStyle: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.bold),
                      hintText: '0,00',
                      filled: true,
                      fillColor: c.scaffold,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(color: c.cardBorder),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: blue, width: 2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(children: [
                    Expanded(
                      child: SizedBox(
                        height: 48,
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(ctx),
                          style: OutlinedButton.styleFrom(
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                          child: const Text('Άκυρο'),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: SizedBox(
                        height: 48,
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: blue,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                          onPressed: () {
                            final raw = ctrl.text.trim().replaceAll(',', '.');
                            final v = double.tryParse(raw);
                            if (v == null || v <= 0) return;
                            Navigator.pop(ctx, v);
                          },
                          child: const Text('Καταχώρηση'),
                        ),
                      ),
                    ),
                  ]),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (amount == null || amount <= 0) return;

    await JobService.recordDriverPayment(
      uid:       uid,
      uidName:   userName,
      amount:    amount,
      masterUid: masterUid,
      monthKey:  m.monthKey,
      note:      'Μερική πληρωμή προς οδηγό',
      onlyRecipientUid: _recipientFilter,
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'Καταχωρήθηκαν ${amount.toStringAsFixed(2)}€ προς τον οδηγό'),
        backgroundColor: const Color(0xFF1565C0),
      ));
    }
  }
}

// ═══ Κάρτα Μήνα — αναπτυσσόμενη ══════════════════════════════════════════════

class _MonthCard extends StatefulWidget {
  final MonthlyBilling monthly;
  final bool           canManage;
  final VoidCallback   onPay;
  final VoidCallback   onPartialPay;
  final VoidCallback   onPayDriver;        // πλήρης πληρωμή ΠΡΟΣ οδηγό
  final VoidCallback   onPartialPayDriver; // μερική πληρωμή ΠΡΟΣ οδηγό
  // Αν != null → admin: τα κουμπιά αφορούν ΜΟΝΟ τις χρεώσεις αυτού του
  // παραλήπτη (τα δικά του γιαούρτια). null → master (όλο το υπόλοιπο).
  final String?        recipientScope;

  const _MonthCard({
    required this.monthly,
    required this.canManage,
    required this.onPay,
    required this.onPartialPay,
    required this.onPayDriver,
    required this.onPartialPayDriver,
    this.recipientScope,
  });

  @override
  State<_MonthCard> createState() => _MonthCardState();
}

class _MonthCardState extends State<_MonthCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final m    = widget.monthly;
    final paid = m.paid;
    final paidAmt  = m.payments > m.charges ? m.charges : m.payments;
    final progress = m.charges > 0 ? (paidAmt / m.charges).clamp(0.0, 1.0) : 1.0;
    // Ποσό που μπορεί να εξοφλήσει αυτός που βλέπει:
    //  • master (scope == null) → όλο το υπόλοιπο του μήνα
    //  • admin (scope != null)  → μόνο τα δικά του γιαούρτια
    final double actionBalance = widget.recipientScope == null
        ? m.balance
        : m.balanceForRecipient(widget.recipientScope!);

    // Χρώμα προόδου: πράσινο πλήρες, πορτοκαλί μερικό, κόκκινο τίποτα.
    final Color pColor = paid
        ? const Color(0xFF1E8E3E)
        : (paidAmt > 0.01 ? const Color(0xFFD9822B) : const Color(0xFFC0392B));

    // Ανάλυση χρεώσεων: App + ανά πηγή
    final appCharges = m.details
        .where((d) => d.category == 'app_commission')
        .toList();
    final sourceGroups = <String, List<ChargeDetail>>{};
    for (final d in m.details) {
      if (d.category != 'source_commission') continue;
      final s = d.sourceName.isNotEmpty ? d.sourceName : 'Πηγή';
      sourceGroups.putIfAbsent(s, () => []).add(d);
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.cardBorder),
      ),
      child: Column(children: [
        // Header — γεμάτη έγχρωμη μπάρα (ίδιο μοτίβο με τις υπόλοιπες
        // σελίδες), χρώμα ανάλογα με το ποσοστό πληρωμής του μήνα.
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            color: pColor.withValues(alpha: 0.14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Row(children: [
                Icon(_expanded
                    ? Icons.expand_less_rounded
                    : Icons.expand_more_rounded,
                    color: pColor, size: 20),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(m.monthLabel,
                      style: TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15,
                          color: pColor)),
                ),
                if (paid)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min,
                        children: [
                      Icon(Icons.check_circle_rounded,
                          size: 13, color: pColor),
                      const SizedBox(width: 4),
                      Text('ΕΞΟΦΛΗΜΕΝΟ',
                          style: TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.bold,
                              color: pColor)),
                    ]),
                  )
                else
                  Text('${m.charges.toStringAsFixed(2)}€',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15,
                          color: pColor)),
              ]),
              // ── Κουτί προόδου: «πλήρωσε Χ από Υ του μήνα» ──────────────
              if (m.charges > 0.01) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 7,
                    backgroundColor: pColor.withValues(alpha: 0.22),
                    valueColor: AlwaysStoppedAnimation(pColor),
                  ),
                ),
                const SizedBox(height: 5),
                Row(children: [
                  Text(
                      '${paidAmt.toStringAsFixed(2)}€ από τα '
                      '${m.charges.toStringAsFixed(2)}€ του μήνα',
                      style: TextStyle(
                          fontSize: 11.5, fontWeight: FontWeight.w600,
                          color: pColor)),
                  const Spacer(),
                  if (!paid)
                    Text('μένουν ${m.balance.toStringAsFixed(2)}€',
                        style: TextStyle(fontSize: 11.5,
                            fontWeight: FontWeight.bold, color: pColor)),
                ]),
              ],
            ]),
          ),
        ),
        // Ανάλυση
        if (_expanded) ...[
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _line(c, 'Μηνιαία συνδρομή', m.subscription,
                    Icons.calendar_month_rounded),
                _line(c, 'Συνδρομή ημερολογίου', m.calendarSubscription,
                    Icons.event_repeat_rounded),

                // ── Προμήθεια App — «N × 0,60€» + λίστα δουλειών ──────────
                if (appCharges.isNotEmpty)
                  _ChargeGroupTile(
                    icon:  Icons.phone_iphone_rounded,
                    color: Colors.indigo,
                    title: _appTitle(appCharges),
                    charges: appCharges,
                  ),

                // ── Προμήθεια ανά πηγή — expand σε δουλειές ──────────────
                if (sourceGroups.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  const Text('Προμήθεια ανά πηγή:',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 12.5)),
                  const SizedBox(height: 4),
                  ...sourceGroups.entries.map((e) => _ChargeGroupTile(
                        icon:  Icons.handshake_rounded,
                        color: Colors.purple,
                        title: e.key,
                        charges: e.value,
                      )),
                ],

                if (m.byAdmin.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  const Text('Χρωστούμενα ανά διαχειριστή:',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 12.5)),
                  ...m.byAdmin.entries.map((e) =>
                      _line(c, '  ${e.key}', e.value,
                          Icons.person_rounded)),
                ],
                const Divider(height: 18),
                _line(c, 'Σύνολο χρεώσεων', m.charges, Icons.receipt_long_rounded,
                    bold: true),
                if (m.payments > 0)
                  _line(c, 'Πληρωμές', m.payments, Icons.payments_rounded,
                      bold: true, green: true),
                if (widget.canManage && actionBalance > 0.01) ...[
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF1E8E3E),
                          side: const BorderSide(
                              color: Color(0xFF1E8E3E), width: 1.4),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        icon:  const Icon(Icons.euro_rounded, size: 17),
                        label: const Text('Μερική πληρωμή',
                            style: TextStyle(fontWeight: FontWeight.bold,
                                fontSize: 12.5)),
                        onPressed: widget.onPartialPay,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12))),
                        icon:  const Icon(Icons.check_rounded, size: 17),
                        label: Text(
                            'Εξόφληση ${actionBalance.toStringAsFixed(2)}€',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 12.5)),
                        onPressed: widget.onPay,
                      ),
                    ),
                  ]),
                ]
                // ── Ο διαχειριστής χρωστάει στον οδηγό → πληρωμή ΠΡΟΣ οδηγό ──
                else if (widget.canManage && actionBalance < -0.01) ...[
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF1565C0),
                          side: const BorderSide(
                              color: Color(0xFF1565C0), width: 1.4),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        icon:  const Icon(Icons.euro_rounded, size: 17),
                        label: const Text('Μερική πληρωμή',
                            style: TextStyle(fontWeight: FontWeight.bold,
                                fontSize: 12.5)),
                        onPressed: widget.onPartialPayDriver,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF1565C0),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12))),
                        icon:  const Icon(Icons.check_rounded, size: 17),
                        label: Text(
                            'Πλήρωσα ${actionBalance.abs().toStringAsFixed(2)}€',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 12.5)),
                        onPressed: widget.onPayDriver,
                      ),
                    ),
                  ]),
                ],
              ],
            ),
          ),
        ],
      ]),
    );
  }

  // Τίτλος προμήθειας App: «17 × 0,60€» αν όλες ίδιες, αλλιώς «17 δουλειές».
  String _appTitle(List<ChargeDetail> list) {
    final rates = list.map((d) => d.amount.toStringAsFixed(2)).toSet();
    if (rates.length == 1) {
      return 'Προμήθεια App — ${list.length} × ${rates.first}€';
    }
    return 'Προμήθεια App — ${list.length} δουλειές';
  }

  Widget _line(AppColors c, String label, double amount, IconData icon,
      {bool bold = false, bool green = false}) {
    if (amount == 0 && !bold) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        Icon(icon, size: 15,
            color: green ? c.greenDeep : c.textFaint),
        const SizedBox(width: 8),
        Expanded(
          child: Text(label,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: bold ? FontWeight.bold : FontWeight.normal,
                  color: c.textMain)),
        ),
        Text('${green ? '-' : ''}${amount.toStringAsFixed(2)}€',
            style: TextStyle(
                fontSize: 12.5,
                fontWeight: bold ? FontWeight.bold : FontWeight.w500,
                color: green ? c.greenDeep : c.textMain)),
      ]),
    );
  }
}

// ═══ Ομάδα χρεώσεων (πηγή ή App) — expand σε δουλειές ════════════════════════

class _ChargeGroupTile extends StatefulWidget {
  final IconData icon;
  final Color    color;
  final String   title;
  final List<ChargeDetail> charges;
  const _ChargeGroupTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.charges,
  });

  @override
  State<_ChargeGroupTile> createState() => _ChargeGroupTileState();
}

class _ChargeGroupTileState extends State<_ChargeGroupTile> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final total = widget.charges.fold<double>(0, (s, d) => s + d.amount);
    final paid  = widget.charges.fold<double>(0, (s, d) => s + d.paid);
    final full  = (total - paid) <= 0.01;
    final amtColor = full
        ? const Color(0xFF1E8E3E)
        : (paid > 0.01 ? const Color(0xFF9A6B0F) : const Color(0xFFC0392B));

    return Container(
      margin: const EdgeInsets.only(bottom: 7),
      decoration: BoxDecoration(
        border: Border.all(color: c.cardBorder),
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Container(
            color: widget.color.withValues(alpha: 0.12),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(children: [
              Icon(_open
                  ? Icons.expand_more_rounded
                  : Icons.chevron_right_rounded,
                  size: 17, color: widget.color),
              const SizedBox(width: 6),
              Icon(widget.icon, size: 16, color: widget.color),
              const SizedBox(width: 7),
              Expanded(
                child: Text(widget.title,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 13.5,
                        color: widget.color)),
              ),
              Text('${paid.toStringAsFixed(2)}€ / ${total.toStringAsFixed(2)}€',
                  style: TextStyle(fontSize: 12.5,
                      fontWeight: FontWeight.bold, color: amtColor)),
            ]),
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
            child: Column(children: [
              for (int i = 0; i < widget.charges.length; i++)
                _jobRow(context, widget.charges[i]),
            ]),
          ),
      ]),
    );
  }

  Widget _jobRow(BuildContext context, ChargeDetail d) {
    final c = AppColors.of(context);
    final String chip;
    final Color  cFg;
    final Color  cBg;
    if (d.isCredit) {
      // Αρνητική χρέωση = ο διαχειριστής χρωστάει στον οδηγό.
      chip = 'Του χρωστάς ${d.amount.abs().toStringAsFixed(2)}€';
      cFg = const Color(0xFF1565C0); cBg = const Color(0xFFE3F0FB);
    } else if (d.isPaid) {
      chip = '✓ Πληρωμένη';
      cFg = const Color(0xFF1E8E3E); cBg = const Color(0xFFE7F4EA);
    } else if (d.isPartial) {
      chip = '${d.paid.toStringAsFixed(2)}€ από ${d.amount.toStringAsFixed(2)}€';
      cFg = const Color(0xFF9A6B0F); cBg = const Color(0xFFFDF3E3);
    } else {
      chip = 'Οφείλεται';
      cFg = const Color(0xFFC0392B); cBg = const Color(0xFFFBEAEA);
    }
    final dt = d.createdAt;
    final date = '${dt.day.toString().padLeft(2, "0")}/'
        '${dt.month.toString().padLeft(2, "0")}';

    // Το note έρχεται ως «Από → Προς» (server). Σπάμε στα δύο για να δείξουμε
    // route timeline· αν δεν υπάρχει διαχωριστής, δείχνουμε όλη τη γραμμή ως «από».
    final raw = d.note.trim();
    String fromTxt = raw.isNotEmpty ? raw : 'Δουλειά';
    String? toTxt;
    final arrow = raw.indexOf('→');
    if (arrow >= 0) {
      fromTxt = raw.substring(0, arrow).trim();
      final rest = raw.substring(arrow + 1).trim();
      if (rest.isNotEmpty) toTxt = rest;
      if (fromTxt.isEmpty) fromTxt = 'Δουλειά';
    }

    final tappable = d.jobId.isNotEmpty;

    return Container(
      margin: const EdgeInsets.only(bottom: 7),
      decoration: BoxDecoration(
        color: c.card,
        border: Border.all(color: c.cardBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: tappable ? () => _openJob(context, d.jobId) : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(11, 9, 11, 9),
          child: Column(children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Route timeline: από (πορτοκαλί) → προς (κόκκινο) ──
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 2),
                    child: _routeTimeline(c, fromTxt, toTxt),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(
                    color: cBg,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text(chip,
                      style: TextStyle(fontSize: 11,
                          fontWeight: FontWeight.bold, color: cFg)),
                ),
              ],
            ),
            const SizedBox(height: 7),
            Container(height: 0.5, color: c.cardBorder),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(children: [
                  Icon(Icons.calendar_today_rounded,
                      size: 12, color: c.textFaint),
                  const SizedBox(width: 4),
                  Text(date,
                      style: TextStyle(
                          fontSize: 11.5, color: c.textFaint)),
                ]),
                Row(children: [
                  Text('${d.amount.toStringAsFixed(2)}€',
                      style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: c.textMain)),
                  if (tappable) ...[
                    const SizedBox(width: 2),
                    Icon(Icons.chevron_right_rounded,
                        size: 16, color: c.textFaint),
                  ],
                ]),
              ],
            ),
          ]),
        ),
      ),
    );
  }

  // Route timeline: «από» πάνω (πορτοκαλί κουκκίδα) ενωμένο με «προς» κάτω
  // (κόκκινη κουκκίδα) μέσω κάθετης γραμμής. Αν δεν υπάρχει «προς», δείχνει
  // μόνο τη μία γραμμή χωρίς γραμμή σύνδεσης.
  Widget _routeTimeline(AppColors c, String from, String? to) {
    const orange = Color(0xFFEF9F27);
    const red    = Color(0xFFE24B4A);
    if (to == null) {
      return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Container(width: 7, height: 7,
            decoration: const BoxDecoration(
                color: orange, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(from, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w600, height: 1.3,
                  color: c.textMain)),
        ),
      ]);
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Στήλη κουκκίδων + γραμμή
      Padding(
        padding: const EdgeInsets.only(top: 3),
        child: SizedBox(
          width: 7,
          child: Column(children: [
            Container(width: 7, height: 7,
                decoration: const BoxDecoration(
                    color: orange, shape: BoxShape.circle)),
            Container(width: 1.5, height: 16, color: c.cardBorder),
            Container(width: 7, height: 7,
                decoration: const BoxDecoration(
                    color: red, shape: BoxShape.circle)),
          ]),
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(from, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w600, height: 1.3,
                  color: c.textMain)),
          const SizedBox(height: 6),
          Text(to, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12.5, color: c.textFaint, height: 1.3)),
        ]),
      ),
    ]);
  }

  // Tap σε δουλειά → άνοιγμα της λεπτομερούς καρτέλας της.
  Future<void> _openJob(BuildContext context, String jobId) async {
    final c = AppColors.of(context);
    try {
      final doc = await FirebaseFirestore.instance
          .collection('jobs').doc(jobId).get();
      if (!context.mounted) return;
      if (!doc.exists) {
        showCenterToast(context,
            'Η δουλειά δεν υπάρχει πια (έχει διαγραφεί)');
        return;
      }
      final job = Job.fromDoc(doc);
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (ctx) => JobDetailsSheet(job: job, parentContext: context),
      );
    } catch (e) {
      if (context.mounted) {
        showCenterToast(context, 'Σφάλμα: $e');
      }
    }
  }
}

// ═══ Στατιστικό header ═══════════════════════════════════════════════════════

// ═══ Κάρτα Τζίρου — «από πάντα» (μόνιμος μετρητής) + τρέχων μήνας ═══════════
// Το «από πάντα» έρχεται από presence.lifetimeTurnover (server-side, ΔΕΝ
// επηρεάζεται από καθαρισμό παλιών δεδομένων). Το μηνιαίο υπολογίζεται live.
class _TurnoverCard extends StatelessWidget {
  final String label;
  final double lifetimeTurnover;
  final int    lifetimeJobs;
  final double monthTurnover;
  final int    monthJobs;

  const _TurnoverCard({
    required this.label,
    required this.lifetimeTurnover,
    required this.lifetimeJobs,
    required this.monthTurnover,
    required this.monthJobs,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.trending_up_rounded, size: 16, color: Colors.blueGrey),
            const SizedBox(width: 6),
            Text('$label  ·  από πάντα',
                style: const TextStyle(fontSize: 12.5, color: Colors.blueGrey)),
          ]),
          const SizedBox(height: 4),
          Text.rich(TextSpan(children: [
            TextSpan(text: '${lifetimeTurnover.toStringAsFixed(2)}€',
                style: const TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
            TextSpan(
                text: '   από $lifetimeJobs '
                    '${lifetimeJobs == 1 ? "δουλειά" : "δουλειές"}',
                style: TextStyle(fontSize: 13, color: c.textFaint)),
          ])),
          const Divider(height: 18),
          Row(children: [
            Icon(Icons.calendar_today_rounded, size: 14, color: c.textFaint),
            const SizedBox(width: 6),
            Text('Αυτόν τον μήνα',
                style: TextStyle(fontSize: 12, color: c.textFaint)),
            const Spacer(),
            Text('${monthTurnover.toStringAsFixed(2)}€',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            Text('  ·  $monthJobs ${monthJobs == 1 ? "δουλειά" : "δουλειές"}',
                style: TextStyle(fontSize: 12, color: c.textFaint)),
          ]),
        ],
      ),
    );
  }
}

class _BigStat extends StatelessWidget {
  final String label;
  final double amount;
  final Color  color;
  final bool   compact = false;

  const _BigStat({
    required this.label,
    required this.amount,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(vertical: compact ? 16 : 28),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [color, color.withValues(alpha: 0.75)],
          begin: Alignment.topLeft,
          end:   Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.3),
              blurRadius: 12, offset: const Offset(0, 4)),
        ],
      ),
      child: Column(children: [
        Text(label,
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.white70,
                fontWeight: FontWeight.w600,
                fontSize: compact ? 11 : 14)),
        const SizedBox(height: 6),
        Text('${amount.toStringAsFixed(2)}€',
            style: TextStyle(
                color: c.card,
                fontSize: compact ? 22 : 40,
                fontWeight: FontWeight.bold)),
      ]),
    );
  }
}

// Ανάλυση οφειλών ανά πηγή — τι να μαζέψουμε
class _OwedBreakdown extends StatelessWidget {
  final Map<String, double> bySource;
  final double subscription;
  final double calendarSubscription;
  final double appCommission;

  const _OwedBreakdown({
    required this.bySource,
    required this.subscription,
    this.calendarSubscription = 0,
    required this.appCommission,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    Widget row(String label, double amount, IconData icon, Color c) =>
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            Icon(icon, size: 17, color: c),
            const SizedBox(width: 10),
            Expanded(child: Text(label,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w500))),
            Text('${amount.toStringAsFixed(2)}€',
                style: TextStyle(
                    fontSize: 14, fontWeight: FontWeight.bold, color: c)),
          ]),
        );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Τι χρωστάει — ανάλυση οφειλής',
              style: TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 4),
          Text('Για να ξέρεις τι να μαζέψεις ανά πηγή',
              style: TextStyle(fontSize: 11, color: c.textFaint)),
          const Divider(height: 16),
          ...bySource.entries.map((e) => row(
              e.key, e.value, Icons.handshake_rounded, Colors.orange)),
          if (appCommission > 0)
            row('Προμήθεια App', appCommission,
                Icons.phone_iphone_rounded, Colors.blue.shade700),
          if (subscription > 0)
            row('Μηνιαία συνδρομή', subscription,
                Icons.calendar_month_rounded, Colors.teal),
          if (calendarSubscription > 0)
            row('Συνδρομή ημερολογίου', calendarSubscription,
                Icons.event_repeat_rounded, Colors.deepPurple),
        ],
      ),
    );
  }
}
