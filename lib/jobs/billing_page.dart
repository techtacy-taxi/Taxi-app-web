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
      backgroundColor: const Color(0xFFF6F6F8),
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
        actions: [
          if (isMaster)
            IconButton(
              tooltip: 'Μηνιαία Αναφορά PDF',
              icon: const Icon(Icons.picture_as_pdf_rounded),
              onPressed: () => _showReportDialog(context),
            ),
          if (isMaster)
            IconButton(
              tooltip: 'Καθαρισμός παλιών δεδομένων',
              icon: const Icon(Icons.cleaning_services_rounded),
              onPressed: () => _showPurgeDialog(context),
            ),
          if (isMaster || isAdmin)
            IconButton(
              tooltip: 'Εκκαθαρίσεις',
              icon: const Icon(Icons.account_tree_rounded),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => BillingSettlementPage(
                    uid:      uid,
                    userName: userName,
                    isMaster: isMaster,
                  ),
                ),
              ),
            ),
        ],
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

  void _showReportDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => SimpleDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
        title: const Row(children: [
          Icon(Icons.picture_as_pdf_rounded, color: _purple),
          SizedBox(width: 8),
          Text('Αναφορά μήνα', style: TextStyle(fontSize: 17)),
        ]),
        children: [
          for (int back = 1; back <= 3; back++)
            SimpleDialogOption(
              onPressed: () {
                Navigator.pop(ctx);
                _generateReport(context, _monthKeyAgo(back));
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(_monthLabelOf(_monthKeyAgo(back)),
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ),
          SimpleDialogOption(
            onPressed: () {
              Navigator.pop(ctx);
              _generateReport(context, _monthKeyAgo(0));
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                  '${_monthLabelOf(_monthKeyAgo(0))} (τρέχων — μέχρι σήμερα)',
                  style: TextStyle(
                      fontSize: 14, color: Colors.grey.shade700)),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 8, 24, 4),
            child: Text(
                'Τα PDF στο Google Drive διατηρούνται για πάντα. Τα δεδομένα '
                'του Firebase (ιστορικό δουλειών) διαγράφονται μετά τους 3 '
                'μήνες — εκτός αν κάποιος χρωστάει.',
                style: TextStyle(fontSize: 11.5, color: Colors.grey)),
          ),
        ],
      ),
    );
  }

  Future<void> _generateReport(BuildContext context, String monthKey) async {
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
  Future<void> _showPurgeDialog(BuildContext context) async {
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
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16)),
          title: const Text('Καθαρισμός δεδομένων'),
          content: const Text(
              'Δεν υπάρχουν παλιά δεδομένα (>3 μήνες) προς διαγραφή.'),
          actions: [
            AppButton(label: 'Εντάξει',
                onPressed: () => Navigator.pop(ctx)),
          ],
        ),
      );
      return;
    }

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
        title: const Row(children: [
          Icon(Icons.cleaning_services_rounded, color: _purple),
          SizedBox(width: 8),
          Expanded(child: Text('Καθαρισμός δεδομένων', style: TextStyle(fontSize: 17))),
        ]),
        content: Text(blocked
            ? 'Υπάρχουν $purgeable παλιές δουλειές (>3 μήνες), αλλά κάποιος '
                'χρωστάει. Πρέπει πρώτα να ξεχρεώσουν όλοι — μετά μπορείς να '
                'τις διαγράψεις.\n\nΤα PDF στο Drive μένουν για πάντα.'
            : 'Θα διαγραφούν οριστικά $purgeable παλιές δουλειές (>3 μήνες) '
                'μαζί με τις οικονομικές τους εγγραφές, και θα μειωθεί '
                'αναλόγως ο τζίρος των οδηγών.\n\nΤα PDF στο Drive μένουν για '
                'πάντα. Η ενέργεια δεν αναιρείται.')
        ,
        actions: blocked
            ? [
                AppButton(label: 'Κατάλαβα',
                    onPressed: () => Navigator.pop(ctx)),
              ]
            : [
                AppButtonTonal(label: 'Άκυρο',
                    onPressed: () => Navigator.pop(ctx)),
                AppButton(
                  label: 'Διαγραφή',
                  color: Colors.red,
                  onPressed: () {
                    Navigator.pop(ctx);
                    _runPurge(context);
                  },
                ),
              ],
      ),
    );
  }

  Future<void> _runPurge(BuildContext context) async {
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

        double grandOwed = 0, grandTurnover = 0;
        int    grandJobs = 0;
        for (final e in entries) {
          grandOwed += (e.value['charges'] as double) -
              (e.value['payments'] as double);
          grandTurnover += e.value['turnover'] as double;
          grandJobs += (e.value['turnoverJobs'] as int? ?? 0);
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
              _SmallStat(
                label:  widget.isMaster
                    ? 'Τζίρος (όλες οι ομάδες)' : 'Τζίρος ομάδων',
                amount: grandTurnover,
                color:  Colors.blueGrey.shade600,
                count:  grandJobs,
              ),
              const SizedBox(height: 10),
              _BigStat(
                label:  widget.isMaster
                    ? 'Χρεώσεις — Σύνολο (όλες οι ομάδες)'
                    : 'Χρεώσεις — Σύνολο',
                amount: grandOwed,
                color:  _debtColor(grandOwed),
              ),
              const SizedBox(height: 16),
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
                return Card(
                  elevation: 0,
                  margin: const EdgeInsets.only(bottom: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(color: Colors.grey.shade200),
                  ),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: _purple.withValues(alpha: 0.1),
                      child: const Icon(Icons.groups_rounded,
                          color: _purple),
                    ),
                    title: Text(data['name'] as String,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold)),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${drivers.length} οδηγοί  •  '
                            'Τζίρος ${turnover.toStringAsFixed(2)}€  •  '
                            '$tJobs ${tJobs == 1 ? "δουλειά" : "δουλειές"}'),
                        // «Πληρώθηκαν Χ από Υ του μήνα» — ίδια λογική με οδηγό
                        if (mCharges > 0.01) ...[
                          const SizedBox(height: 6),
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
                          const SizedBox(height: 3),
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
                    trailing: Text('${owed.toStringAsFixed(2)}€',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 15,
                            color: _debtColor(owed))),
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
                  ),
                );
              }),
              if (entries.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(40),
                  child: Center(child: Text('Δεν υπάρχουν ομάδες',
                      style: TextStyle(color: Colors.grey))),
                ),
            ],
          ),
        );
      },
    );
  }
}

// ═══ Κάρτα «Τα δικά μου» (admin / master) ════════════════════════════════════
// Ο admin/master μπορεί να πάρει δουλειά (από άλλον ή από τον εαυτό του), οπότε
// έχει κι αυτός τζίρο & χρέη. Η κάρτα δείχνει σύνοψη και ανοίγει την πλήρη
// προσωπική του καρτέλα.
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
    return StreamBuilder<({double turnover, int jobs})>(
      stream: JobService.turnoverStatsFor(uid),
      builder: (context, tSnap) {
        final turnover  = tSnap.data?.turnover ?? 0.0;
        final jobsCount = tSnap.data?.jobs ?? 0;
        return StreamBuilder<List<MonthlyBilling>>(
          stream: JobService.monthlyBillingFor(uid,
              excludeOwnRecipient: true, isMaster: isMaster),
          builder: (context, mSnap) {
            final months = mSnap.data ?? const <MonthlyBilling>[];
            final owed = months.fold<double>(
                0, (s, m) => s + m.balance);

            return Container(
              decoration: BoxDecoration(
                color: _purple.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: _purple.withValues(alpha: 0.25)),
              ),
              child: ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                leading: CircleAvatar(
                  backgroundColor: _purple.withValues(alpha: 0.15),
                  child: const Icon(Icons.person_rounded, color: _purple),
                ),
                title: const Text('Τα δικά μου',
                    style: TextStyle(
                        fontWeight: FontWeight.bold, color: _purple)),
                subtitle: Text(
                  'Τζίρος ${turnover.toStringAsFixed(2)}€ '
                  '($jobsCount ${jobsCount == 1 ? "δουλειά" : "δουλειές"})  •  '
                  '${owed > 0.0001
                      ? "Χρωστάω ${owed.toStringAsFixed(2)}€"
                      : owed < -0.0001
                          ? "Σου χρωστούν ${owed.abs().toStringAsFixed(2)}€"
                          : "Εξοφλημένος"}',
                  style: TextStyle(
                      fontSize: 12,
                      color: _debtColor(owed)),
                ),
                trailing: const Icon(Icons.chevron_right_rounded,
                    color: _purple),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      backgroundColor: const Color(0xFFF6F6F8),
                      appBar: AppBar(
                        backgroundColor: _purple,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        title: const Text('Τα δικά μου',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                      body: _DriverBillingView(
                        uid:                 uid,
                        userName:            userName,
                        masterUid:           masterUid,
                        canManage:           isMaster,
                        excludeOwnRecipient: true,
                        isMaster:            isMaster,
                      ),
                    ),
                  ),
                ),
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
    final owed     = (groupData['charges'] as double) -
        (groupData['payments'] as double);
    final turnover = groupData['turnover'] as double;
    final tJobs    = groupData['turnoverJobs'] as int? ?? 0;
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
      backgroundColor: const Color(0xFFF6F6F8),
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
          _SmallStat(
            label:  'Τζίρος ομάδας «$groupName»',
            amount: turnover,
            color:  Colors.blueGrey.shade600,
            count:  tJobs,
          ),
          const SizedBox(height: 10),
          _BigStat(
            label:  'Χρεώσεις — Σύνολο ομάδας',
            amount: owed,
            color:  _debtColor(owed),
          ),
          const SizedBox(height: 16),
          ...drivers.map((e) {
            final uid       = e.key;
            final d         = e.value;
            final dOwed     = (d['charges'] as double) -
                (d['payments'] as double);
            final dTurnover = d['turnover'] as double;
            final dJobs     = d['turnoverJobs'] as int? ?? 0;
            final name      = d['name'] as String;
            return Card(
              elevation: 0,
              margin: const EdgeInsets.only(bottom: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: Colors.grey.shade200),
              ),
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: dOwed > 0.0001
                      ? Colors.red.shade50
                      : dOwed < -0.0001
                          ? _oweDriverBlue.withValues(alpha: 0.12)
                          : Colors.green.shade50,
                  child: Icon(
                    dOwed > 0.0001
                        ? Icons.error_outline_rounded
                        : dOwed < -0.0001
                            ? Icons.south_west_rounded
                            : Icons.check_rounded,
                    color: _debtColor(dOwed),
                  ),
                ),
                title: Text(name,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold)),
                subtitle: Text(
                  'Τζίρος ${dTurnover.toStringAsFixed(2)}€ '
                  '($dJobs ${dJobs == 1 ? "δουλειά" : "δουλειές"})  •  '
                  '${_debtText(dOwed)}',
                  style: TextStyle(
                      fontSize: 12,
                      color: _debtColor(dOwed)),
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      backgroundColor: const Color(0xFFF6F6F8),
                      appBar: AppBar(
                        backgroundColor: _purple,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        title: Text(name,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold)),
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
              ),
            );
          }),
          if (drivers.isEmpty)
            const Padding(
              padding: EdgeInsets.all(40),
              child: Center(child: Text('Δεν υπάρχουν οδηγοί',
                  style: TextStyle(color: Colors.grey))),
            ),
        ],
      ),
    );
  }
}

// ═══ Καρτέλα Οδηγού — μηνιαία ανάλυση ════════════════════════════════════════

class _DriverBillingView extends StatelessWidget {
  final String uid;
  final String userName;
  final String masterUid;
  final bool   canManage;
  // Προσωπική όψη admin/master: κρύβει αυτο-οφειλές (και App/συνδρομή για master)
  final bool   excludeOwnRecipient;
  final bool   isMaster;

  const _DriverBillingView({
    required this.uid,
    required this.userName,
    required this.masterUid,
    required this.canManage,
    this.excludeOwnRecipient = false,
    this.isMaster            = false,
  });

  // Όταν εξοφλεί admin (όχι master), οι πληρωμές αφορούν ΜΟΝΟ τις χρεώσεις
  // όπου παραλήπτης είναι ο ίδιος (τα δικά του γιαούρτια). Master → null (όλα).
  String? get _recipientFilter => isMaster ? null : masterUid;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<({double turnover, int jobs})>(
      stream: JobService.turnoverStatsFor(uid),
      builder: (context, tSnap) {
        final turnover  = tSnap.data?.turnover ?? 0.0;
        final jobsCount = tSnap.data?.jobs ?? 0;
        return StreamBuilder<List<MonthlyBilling>>(
          stream: JobService.monthlyBillingFor(uid,
              excludeOwnRecipient: excludeOwnRecipient, isMaster: isMaster),
          builder: (context, snap) {
            if (!snap.hasData) {
              return const Center(
                  child: CircularProgressIndicator(color: _purple));
            }
            final months = snap.data!;
            // Άθροισμα balance ΟΛΩΝ των μηνών — με το πρόσημο.
            // Αρνητικό σύνολο = ο διαχειριστής χρωστάει στον οδηγό (μπλε).
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
                // Τζίρος — μικρό κουτάκι πάνω
                _SmallStat(
                  label:  'Τζίρος (σύνολο διαδρομών)',
                  amount: turnover,
                  color:  Colors.blueGrey.shade600,
                  count:  jobsCount,
                ),
                const SizedBox(height: 10),
                // Χρεώσεις — μεγάλο κουτί
                _BigStat(
                  label:  'Χρεώσεις — Οφειλόμενα',
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
                  const Padding(
                    padding: EdgeInsets.all(30),
                    child: Center(child: Text('Δεν υπάρχουν χρεώσεις',
                        style: TextStyle(color: Colors.grey))),
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
  }

  Future<void> _payMonth(BuildContext context, MonthlyBilling m) async {
    final bal = _recipientFilter == null
        ? m.balance
        : m.balanceForRecipient(_recipientFilter!);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
        title: Text('Εξόφληση — ${m.monthLabel}'),
        content: Text(
            'Να καταχωρηθεί ως πληρωμένο το ποσό '
            '${bal.toStringAsFixed(2)}€ για τον/την $userName;'),
        actions: [
          AppButtonTonal(label: 'Άκυρο', onPressed: () => Navigator.pop(ctx, false)),
          AppButton(label: 'Εξόφληση', color: Colors.green, onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
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
    final ctrl = TextEditingController();
    final amount = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
        title: Text('Μερική πληρωμή — $userName'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(
            'Οφειλή ${m.monthLabel}: ${m.balance.toStringAsFixed(2)}€\n'
            'Εξοφλούνται πρώτα η προμήθεια App και μετά οι παλιότερες '
            'δουλειές (FIFO).',
            style: const TextStyle(fontSize: 12.5, color: Colors.grey),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            style: const TextStyle(
                fontSize: 22, fontWeight: FontWeight.bold),
            decoration: InputDecoration(
              suffixText: '€',
              suffixStyle: const TextStyle(
                  fontSize: 20, fontWeight: FontWeight.bold),
              hintText: '0,00',
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ]),
        actions: [
          AppButtonTonal(label: 'Άκυρο',
              onPressed: () => Navigator.pop(ctx)),
          AppButton(
            label: 'Καταχώρηση',
            color: Colors.green,
            onPressed: () {
              // Δεκτά και κόμμα και τελεία ως υποδιαστολή (π.χ. 7,20).
              final raw = ctrl.text.trim().replaceAll(',', '.');
              final v = double.tryParse(raw);
              if (v == null || v <= 0) return;
              Navigator.pop(ctx, v);
            },
          ),
        ],
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
    final bal = _recipientFilter == null
        ? m.balance
        : m.balanceForRecipient(_recipientFilter!);
    final owe = bal.abs();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
        title: Text('Πληρωμή προς οδηγό — ${m.monthLabel}'),
        content: Text(
            'Να καταχωρηθεί ότι έδωσες ${owe.toStringAsFixed(2)}€ '
            'στον/στην $userName;'),
        actions: [
          AppButtonTonal(label: 'Άκυρο', onPressed: () => Navigator.pop(ctx, false)),
          AppButton(label: 'Πλήρωσα', color: const Color(0xFF1565C0),
              onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
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

  // ── Μερική πληρωμή ΠΡΟΣ τον οδηγό ───────────────────────────────────────
  Future<void> _payDriverPartial(BuildContext context, MonthlyBilling m) async {
    final bal = _recipientFilter == null
        ? m.balance
        : m.balanceForRecipient(_recipientFilter!);
    final owe = bal.abs();
    final ctrl = TextEditingController();
    final amount = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
        title: Text('Πληρωμή προς οδηγό — $userName'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(
            'Του χρωστάς ${owe.toStringAsFixed(2)}€ για ${m.monthLabel}.\n'
            'Γράψε πόσα του έδωσες.',
            style: const TextStyle(fontSize: 12.5, color: Colors.grey),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            style: const TextStyle(
                fontSize: 22, fontWeight: FontWeight.bold),
            decoration: InputDecoration(
              suffixText: '€',
              suffixStyle: const TextStyle(
                  fontSize: 20, fontWeight: FontWeight.bold),
              hintText: '0,00',
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ]),
        actions: [
          AppButtonTonal(label: 'Άκυρο',
              onPressed: () => Navigator.pop(ctx)),
          AppButton(
            label: 'Καταχώρηση',
            color: const Color(0xFF1565C0),
            onPressed: () {
              final raw = ctrl.text.trim().replaceAll(',', '.');
              final v = double.tryParse(raw);
              if (v == null || v <= 0) return;
              Navigator.pop(ctx, v);
            },
          ),
        ],
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

    // Χρώματα προόδου: πράσινο πλήρες, πορτοκαλί μερικό, κόκκινο τίποτα.
    final Color pColor = paid
        ? const Color(0xFF1E8E3E)
        : (paidAmt > 0.01 ? const Color(0xFFD9822B) : const Color(0xFFC0392B));
    final Color pBg = paid
        ? const Color(0xFFE7F4EA)
        : (paidAmt > 0.01 ? const Color(0xFFFDF3E3) : const Color(0xFFFBEAEA));

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

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Column(children: [
        // Header
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Row(children: [
                Icon(_expanded
                    ? Icons.expand_less_rounded
                    : Icons.expand_more_rounded,
                    color: Colors.grey),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(m.monthLabel,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15)),
                ),
                if (paid)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.green.shade50,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Row(mainAxisSize: MainAxisSize.min,
                        children: [
                      Icon(Icons.check_circle_rounded,
                          size: 13, color: Colors.green),
                      SizedBox(width: 4),
                      Text('ΕΞΟΦΛΗΜΕΝΟ',
                          style: TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.bold,
                              color: Colors.green)),
                    ]),
                  ),
              ]),
              // ── Κουτί προόδου: «πλήρωσε Χ από Υ του μήνα» ──────────────
              if (m.charges > 0.01) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(11, 8, 11, 9),
                  decoration: BoxDecoration(
                    color: pBg,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: pColor.withValues(alpha: 0.35)),
                  ),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Row(crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                      Text('${paidAmt.toStringAsFixed(2)}€',
                          style: TextStyle(fontSize: 16,
                              fontWeight: FontWeight.bold, color: pColor)),
                      Text(' από τα ',
                          style: TextStyle(fontSize: 12, color: pColor)),
                      Text('${m.charges.toStringAsFixed(2)}€',
                          style: TextStyle(fontSize: 13.5,
                              fontWeight: FontWeight.bold, color: pColor)),
                      Text(' του μήνα',
                          style: TextStyle(fontSize: 12, color: pColor)),
                      const Spacer(),
                      if (!paid)
                        Text('μένουν ${m.balance.toStringAsFixed(2)}€',
                            style: const TextStyle(fontSize: 11.5,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFFC0392B))),
                    ]),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 7,
                        backgroundColor: pColor.withValues(alpha: 0.18),
                        valueColor: AlwaysStoppedAnimation(pColor),
                      ),
                    ),
                  ]),
                ),
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
                _line('Μηνιαία συνδρομή', m.subscription,
                    Icons.calendar_month_rounded),
                _line('Συνδρομή ημερολογίου', m.calendarSubscription,
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
                      _line('  ${e.key}', e.value,
                          Icons.person_rounded)),
                ],
                const Divider(height: 18),
                _line('Σύνολο χρεώσεων', m.charges, Icons.receipt_long_rounded,
                    bold: true),
                if (m.payments > 0)
                  _line('Πληρωμές', m.payments, Icons.payments_rounded,
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
                              borderRadius: BorderRadius.circular(11)),
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
                                borderRadius: BorderRadius.circular(11))),
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
                              borderRadius: BorderRadius.circular(11)),
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
                                borderRadius: BorderRadius.circular(11))),
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

  Widget _line(String label, double amount, IconData icon,
      {bool bold = false, bool green = false}) {
    if (amount == 0 && !bold) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        Icon(icon, size: 15,
            color: green ? Colors.green : Colors.grey[600]),
        const SizedBox(width: 8),
        Expanded(
          child: Text(label,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
        ),
        Text('${green ? '-' : ''}${amount.toStringAsFixed(2)}€',
            style: TextStyle(
                fontSize: 12.5,
                fontWeight: bold ? FontWeight.bold : FontWeight.w500,
                color: green ? Colors.green : Colors.black87)),
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
    final total = widget.charges.fold<double>(0, (s, d) => s + d.amount);
    final paid  = widget.charges.fold<double>(0, (s, d) => s + d.paid);
    final full  = (total - paid) <= 0.01;
    final amtColor = full
        ? const Color(0xFF1E8E3E)
        : (paid > 0.01 ? const Color(0xFF9A6B0F) : const Color(0xFFC0392B));

    return Container(
      margin: const EdgeInsets.only(bottom: 7),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade200),
        borderRadius: BorderRadius.circular(11),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Container(
            color: Colors.grey.shade50,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(children: [
              Icon(_open
                  ? Icons.expand_more_rounded
                  : Icons.chevron_right_rounded,
                  size: 17, color: Colors.grey),
              const SizedBox(width: 5),
              Icon(widget.icon, size: 15, color: widget.color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(widget.title,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13)),
              ),
              Text('${paid.toStringAsFixed(2)}€ / ${total.toStringAsFixed(2)}€',
                  style: TextStyle(fontSize: 12,
                      fontWeight: FontWeight.bold, color: amtColor)),
            ]),
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
            child: Column(children: [
              for (int i = 0; i < widget.charges.length; i++)
                _jobRow(context, widget.charges[i]),
            ]),
          ),
      ]),
    );
  }

  Widget _jobRow(BuildContext context, ChargeDetail d) {
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
        color: Colors.white,
        border: Border.all(color: Colors.grey.shade200),
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
                    child: _routeTimeline(fromTxt, toTxt),
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
            Container(height: 0.5, color: Colors.grey.shade200),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(children: [
                  Icon(Icons.calendar_today_rounded,
                      size: 12, color: Colors.grey.shade500),
                  const SizedBox(width: 4),
                  Text(date,
                      style: TextStyle(
                          fontSize: 11.5, color: Colors.grey.shade600)),
                ]),
                Row(children: [
                  Text('${d.amount.toStringAsFixed(2)}€',
                      style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF263238))),
                  if (tappable) ...[
                    const SizedBox(width: 2),
                    Icon(Icons.chevron_right_rounded,
                        size: 16, color: Colors.grey.shade400),
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
  Widget _routeTimeline(String from, String? to) {
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
              style: const TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w600, height: 1.3)),
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
            Container(width: 1.5, height: 16, color: Colors.grey.shade300),
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
              style: const TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w600, height: 1.3)),
          const SizedBox(height: 6),
          Text(to, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12.5, color: Colors.grey.shade700, height: 1.3)),
        ]),
      ),
    ]);
  }

  // Tap σε δουλειά → άνοιγμα της λεπτομερούς καρτέλας της.
  Future<void> _openJob(BuildContext context, String jobId) async {
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
                color: Colors.white,
                fontSize: compact ? 22 : 40,
                fontWeight: FontWeight.bold)),
      ]),
    );
  }
}

// Μικρό κουτάκι (π.χ. Τζίρος)
class _SmallStat extends StatelessWidget {
  final String    label;
  final double    amount;
  final Color     color;
  final int?      count; // προαιρετικό: πλήθος δουλειών που έβγαλαν τον τζίρο
  final IconData  icon = Icons.trending_up_rounded;

  const _SmallStat({
    required this.label,
    required this.amount,
    required this.color,
    this.count,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Expanded(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: color, fontSize: 11.5,
                      fontWeight: FontWeight.w600)),
            ),
          ]),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text('${amount.toStringAsFixed(2)}€',
                  style: TextStyle(
                      color: color, fontSize: 19,
                      fontWeight: FontWeight.bold)),
              if (count != null) ...[
                const SizedBox(width: 8),
                Text('• από $count ${count == 1 ? "δουλειά" : "δουλειές"}',
                    style: TextStyle(
                        color: color.withValues(alpha: 0.85),
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
              ],
            ],
          ),
        ],
      ),
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
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Τι χρωστάει — ανάλυση οφειλής',
              style: TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 4),
          const Text('Για να ξέρεις τι να μαζέψεις ανά πηγή',
              style: TextStyle(fontSize: 11, color: Colors.grey)),
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
