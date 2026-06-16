// lib/jobs/history_job_card.dart

import 'package:flutter/material.dart';
import 'job_model.dart';
import 'job_service.dart';
import 'job_shared_widgets.dart';
import 'job_details_sheet.dart';

class HistoryJobCard extends StatelessWidget {
  final Job          job;
  final bool         isAdmin;
  final bool         isMaster;        // ο master μπορεί να διορθώσει χρεώσεις
  final List<String> viewerGroupIds; // ομάδες του θεατή — για σήμα "εκτός ομάδας"
  final VoidCallback? onChanged;      // καλείται μετά από ακύρωση/διόρθωση

  const HistoryJobCard({
    super.key,
    required this.job,
    this.isAdmin        = true,
    this.isMaster       = false,
    this.viewerGroupIds = const [],
    this.onChanged,
  });

  // Η δουλειά ανήκε σε άλλη ομάδα ή βγήκε σε όλους
  bool get _outOfGroup {
    if (viewerGroupIds.isEmpty) return false;
    final g = job.groupId;
    if (g == null || g.isEmpty) return true;       // βγήκε σε όλους
    return !viewerGroupIds.contains(g);            // ομάδα άλλου admin
  }

  @override
  Widget build(BuildContext context) {
    final isCancelled = job.status == JobStatus.cancelled;
    final totalComm   = isCancelled ? 0.0 : (job.commission + job.appCommission);
    final dateLabel   = job.cancelledAt ?? job.doneAt ?? job.takenAt;

    return GestureDetector(
      onTap: () => _openDetails(context),
      child: Card(
      margin:    const EdgeInsets.only(bottom: 10),
      elevation: 0,
      color:     Colors.white,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
              color: isCancelled
                  ? Colors.red.shade200
                  : Colors.grey.shade200)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

          // ── Banner ΑΚΥΡΩΜΕΝΗ ─────────────────────────────────────────
          if (isCancelled)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color:        Colors.red.shade50,
                borderRadius: BorderRadius.circular(8),
                border:       Border.all(color: Colors.red.shade300),
              ),
              child: Row(children: [
                Icon(Icons.cancel_rounded, size: 14, color: Colors.red.shade700),
                const SizedBox(width: 6),
                Text('ΑΚΥΡΩΜΕΝΗ', style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.bold,
                    color: Colors.red.shade700, letterSpacing: 1.2)),
                if (job.takenByName != null) ...[
                  const SizedBox(width: 6),
                  Text('(${job.takenByName})',
                      style: TextStyle(fontSize: 11, color: Colors.red.shade500)),
                ],
              ]),
            ),

          // ── Banner ΕΚΤΟΣ ΟΜΑΔΑΣ ──────────────────────────────────────
          if (_outOfGroup && !isCancelled)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color:        Colors.deepPurple.shade50,
                borderRadius: BorderRadius.circular(8),
                border:       Border.all(color: Colors.deepPurple.shade300),
              ),
              child: Row(children: [
                Icon(Icons.swap_horiz_rounded, size: 16,
                    color: Colors.deepPurple.shade700),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('ΕΚΤΟΣ ΟΜΑΔΑΣ', style: TextStyle(
                          fontSize: 11, fontWeight: FontWeight.bold,
                          color: Colors.deepPurple.shade700,
                          letterSpacing: 1)),
                      if (job.createdByName.isNotEmpty)
                        Text(
                          'Τα έσοδα ανήκουν στον/στην: '
                          '${job.createdByName}',
                          style: TextStyle(
                              fontSize: 11,
                              color: Colors.deepPurple.shade600,
                              fontWeight: FontWeight.w600),
                        ),
                    ],
                  ),
                ),
              ]),
            ),

          // ── Route + date + cancel button ─────────────────────────────
          Row(children: [
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.trip_origin_rounded,
                      size: 12, color: Colors.amber),
                  const SizedBox(width: 6),
                  Expanded(child: Text(job.from,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600),
                      maxLines: 1, overflow: TextOverflow.ellipsis)),
                ]),
                const SizedBox(height: 3),
                Row(children: [
                  const Icon(Icons.place_rounded, size: 12, color: Colors.red),
                  const SizedBox(width: 6),
                  Expanded(child: Text(job.to,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600),
                      maxLines: 1, overflow: TextOverflow.ellipsis)),
                ]),
              ],
            )),
            if (dateLabel != null)
              Text(
                '${dateLabel.day}/${dateLabel.month}\n'
                '${dateLabel.hour.toString().padLeft(2, '0')}:'
                '${dateLabel.minute.toString().padLeft(2, '0')}',
                style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                textAlign: TextAlign.center,
              ),
            // Διόρθωση χρεώσεων — ΜΟΝΟ master, σε ολοκληρωμένη δουλειά
            if (isMaster && job.status == JobStatus.done) ...[
              const SizedBox(width: 4),
              IconButton(
                icon:        const Icon(Icons.edit_rounded,
                    size: 18, color: Colors.deepPurple),
                tooltip:     'Διόρθωση χρεώσεων',
                padding:     EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed:   () => _showEditChargesDialog(context),
              ),
            ],
            // Ολική διαγραφή — ΜΟΝΟ master, για ΚΑΘΕ δουλειά του ιστορικού
            if (isMaster) ...[
              const SizedBox(width: 4),
              IconButton(
                icon:        const Icon(Icons.delete_forever_rounded,
                    size: 19, color: Colors.red),
                tooltip:     'Ολική διαγραφή',
                padding:     EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed:   () => _showPurgeDialog(context),
              ),
            ],
            // Ακύρωση — μόνο admin + done
            if (isAdmin && job.status == JobStatus.done) ...[
              const SizedBox(width: 4),
              IconButton(
                icon:        const Icon(Icons.cancel_rounded,
                    size: 18, color: Colors.red),
                tooltip:     'Ακύρωση',
                padding:     EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed:   () async {
                  final changed = await showCancelDialog(context,
                      from: job.from, to: job.to, jobId: job.id,
                      takenByName: job.takenByName);
                  if (changed) onChanged?.call();
                },
              ),
            ],
          ]),
          const SizedBox(height: 8),

          // ── Οικονομικά: ΙΣΑ συμμετρικά κελιά (ίδιο πλάτος/ύψος,
          //    ανεξάρτητα από το μέγεθος του ποσού) ─────────────────────
          if (!isCancelled)
            Row(children: [
              _moneyCell('Τζίρος',
                  '${job.price.toStringAsFixed(2)}€',
                  Icons.euro_rounded, const Color(0xFF1E8E3E)),
              if (job.commission > 0) ...[
                const SizedBox(width: 6),
                _moneyCell('Γιαούρτι',
                    '-${job.commission.toStringAsFixed(2)}€',
                    Icons.handshake_rounded, Colors.orange.shade800),
              ],
              if (job.appCommission > 0) ...[
                const SizedBox(width: 6),
                _moneyCell('App',
                    '-${job.appCommission.toStringAsFixed(2)}€',
                    Icons.phone_iphone_rounded, Colors.blue.shade700),
              ],
              const SizedBox(width: 6),
              _moneyCell('Κέρδος',
                  '${job.driverEarning.toStringAsFixed(2)}€',
                  Icons.account_balance_wallet_rounded, Colors.purple),
            ]),
          if (isCancelled)
            Row(children: [
              _moneyCell('Τζίρος',
                  '${job.price.toStringAsFixed(2)}€',
                  Icons.euro_rounded, Colors.grey),
            ]),
          const SizedBox(height: 6),

          // ── Λοιπά chips (οδηγός, πελάτης, πτήση, δημιουργός) ─────────
          Wrap(spacing: 6, runSpacing: 4, children: [
            jobChip(Icons.person_rounded,
                job.takenByName ?? 'Άγνωστος', Colors.blue),
            if (!isCancelled &&
                job.commission > 0 && job.sourceName != null)
              jobChip(Icons.source_rounded, job.sourceName!, Colors.orange),
            if (job.clientName != null && job.clientName!.isNotEmpty)
              jobChip(Icons.badge_rounded, job.clientName!, Colors.teal),
            if (job.flightOrShip != null && job.flightOrShip!.isNotEmpty)
              jobChip(Icons.flight_rounded, job.flightOrShip!, Colors.indigo),
            if (job.createdByName.isNotEmpty)
              jobChip(Icons.manage_accounts_rounded,
                  'Από: ${job.createdByName}',
                  Colors.grey.shade600),
          ]),

          // ── Banner Οφείλεται ─────────────────────────────────────────
          if (!isCancelled && totalComm > 0) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color:        Colors.red.shade50,
                borderRadius: BorderRadius.circular(8),
                border:       Border.all(color: Colors.red.shade200),
              ),
              child: Row(children: [
                Icon(Icons.payment_rounded, size: 14, color: Colors.red.shade700),
                const SizedBox(width: 6),
                Text('Οφείλεται: ${totalComm.toStringAsFixed(2)}€',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold,
                        color: Colors.red.shade700)),
                if (job.commission > 0 && job.appCommission > 0) ...[
                  const Spacer(),
                  Text(
                    'Γιαούρτι ${job.commission.toStringAsFixed(2)}€'
                    '  +  App ${job.appCommission.toStringAsFixed(2)}€',
                    style: TextStyle(fontSize: 10, color: Colors.red.shade500),
                  ),
                ],
              ]),
            ),
          ],
        ]),
      ),
    ));
  }

  // Συμμετρικό οικονομικό κελί: όλα ΙΔΙΟΥ πλάτους (Expanded) & ύψους,
  // με μικρή ετικέτα πάνω και ποσό κάτω — το ποσό δεν αλλάζει το μέγεθος.
  Widget _moneyCell(String label, String value, IconData icon, Color color) {
    return Expanded(
      child: Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        decoration: BoxDecoration(
          color:        color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border:       Border.all(color: color.withValues(alpha: 0.30)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon, size: 11, color: color),
              const SizedBox(width: 3),
              Flexible(child: Text(label,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 9.5, color: color,
                      fontWeight: FontWeight.w600))),
            ]),
            const SizedBox(height: 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(value,
                  maxLines: 1,
                  style: TextStyle(fontSize: 13.5,
                      fontWeight: FontWeight.bold, color: color)),
            ),
          ],
        ),
      ),
    );
  }

  void _openDetails(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => JobDetailsSheet(
        job: job,
        parentContext: context,
        hideComplete: true,
        historyMode: true,
      ),
    );
  }

  // ── Dialog διόρθωσης χρεώσεων — μόνο για master ─────────────────────────
  Future<void> _showEditChargesDialog(BuildContext context) async {
    String fmt(double v) =>
        v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

    final priceCtrl = TextEditingController(text: fmt(job.price));
    final commCtrl  = TextEditingController(text: fmt(job.commission));
    final appCtrl   = TextEditingController(text: fmt(job.appCommission));

    // Επιλεγμένη έτοιμη πηγή (αν διαλέξει ο master) + το όνομά της για αποθήκευση.
    JobSource? pickedSource;
    String?    pickedSourceName = job.sourceName;
    String?    pickedSourceId   = job.sourceId;

    // Φόρτωσε τις διαθέσιμες πηγές (ο master βλέπει όλες).
    List<JobSource> sources = const [];
    try {
      sources = await JobService.sources(createdBy: null).first;
    } catch (_) {}

    Widget field(String label, TextEditingController c, IconData icon,
            Color color, {bool signed = false}) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextField(
            controller: c,
            keyboardType: TextInputType.numberWithOptions(
                decimal: true, signed: signed),
            decoration: InputDecoration(
              labelText: label,
              prefixIcon: Icon(icon, color: color, size: 20),
              suffixText: '€',
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
        );

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
        title: const Row(children: [
          Icon(Icons.edit_rounded, color: Colors.deepPurple, size: 22),
          SizedBox(width: 10),
          Expanded(
            child: Text('Διόρθωση Χρεώσεων',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ]),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('${job.from} → ${job.to}',
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 13)),
            if (job.takenByName != null)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 8),
                child: Text('Οδηγός: ${job.takenByName}',
                    style: TextStyle(
                        fontSize: 12, color: Colors.grey[600])),
              ),
            const SizedBox(height: 8),
            field('Ποσό δουλειάς (τζίρος)', priceCtrl,
                Icons.euro_rounded, const Color(0xFF1E8E3E)),
            // ── Επιλογή έτοιμης πηγής ──
            if (sources.isNotEmpty) ...[
              DropdownButtonFormField<JobSource?>(
                initialValue: pickedSource,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: 'Έτοιμη πηγή (π.χ. Standard Rate)',
                  prefixIcon: const Icon(Icons.handshake_rounded,
                      color: Colors.orange, size: 20),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  const DropdownMenuItem<JobSource?>(
                    value: null,
                    child: Text('— Χειροκίνητα —',
                        overflow: TextOverflow.ellipsis),
                  ),
                  ...sources.map((s) => DropdownMenuItem<JobSource?>(
                    value: s,
                    child: Text(s.name, overflow: TextOverflow.ellipsis),
                  )),
                ],
                onChanged: (s) => setS(() {
                  pickedSource = s;
                  if (s != null) {
                    // Γέμισε αυτόματα γιαούρτι + App από την πηγή.
                    // Λαμβάνει υπόψη το βραδινό ωράριο της δουλειάς.
                    final price = double.tryParse(
                        priceCtrl.text.trim().replaceAll(',', '.')) ?? job.price;
                    final ref = job.scheduledAt ?? job.doneAt ?? job.createdAt;
                    final night = isNightYogurt(ref);
                    final c  = s.calculateFor(price, night);
                    final ac = s.calculateApp(price);
                    commCtrl.text = c  != 0 ? c.toStringAsFixed(2)  : '0';
                    appCtrl.text  = ac != 0 ? ac.toStringAsFixed(2) : '0';
                    pickedSourceName = s.name;
                    pickedSourceId   = s.id;
                  }
                }),
              ),
              const SizedBox(height: 12),
            ],
            field('Γιαούρτι (προμήθεια πηγής)', commCtrl,
                Icons.handshake_rounded, Colors.orange, signed: true),
            field('Προμήθεια App', appCtrl,
                Icons.phone_iphone_rounded, Colors.blue.shade700),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.amber.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(children: [
                Icon(Icons.info_outline_rounded,
                    size: 14, color: Colors.amber.shade800),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Οι αλλαγές ενημερώνουν αυτόματα τον τζίρο, '
                    'το χρέος του οδηγού και το μενού «Χρεώσεις». '
                    'Αρνητικό γιαούρτι = χρωστάς στον οδηγό.',
                    style: TextStyle(
                        fontSize: 10.5, color: Colors.amber.shade900),
                  ),
                ),
              ]),
            ),
          ]),
        ),
        actions: [
          AppButtonTonal(label: 'Άκυρο', onPressed: () => Navigator.pop(ctx, false)),
          AppButton(label: 'Αποθήκευση', color: Colors.deepPurple, onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
      ),
    );

    if (saved != true) return;

    final newPrice = double.tryParse(
        priceCtrl.text.trim().replaceAll(',', '.')) ?? job.price;
    // Το γιαούρτι ΕΠΙΤΡΕΠΕΤΑΙ αρνητικό (χρωστάς στον οδηγό) → χωρίς clamp.
    final newComm  = double.tryParse(
        commCtrl.text.trim().replaceAll(',', '.')) ?? job.commission;
    final newApp   = double.tryParse(
        appCtrl.text.trim().replaceAll(',', '.')) ?? job.appCommission;

    await JobService.editJobCharges(
      jobId:            job.id,
      newPrice:         newPrice < 0 ? 0 : newPrice,
      newCommission:    newComm,
      newAppCommission: newApp < 0 ? 0 : newApp,
      newSourceId:      pickedSource != null ? pickedSourceId : null,
      newSourceName:    pickedSource != null ? pickedSourceName : null,
    );

    onChanged?.call();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Οι χρεώσεις ενημερώθηκαν'),
          backgroundColor: Colors.deepPurple,
        ),
      );
    }
  }

  // ── Dialog ολικής διαγραφής — μόνο για master ──────────────────────────
  Future<void> _showPurgeDialog(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
        title: const Row(children: [
          Icon(Icons.delete_forever_rounded, color: Colors.red, size: 24),
          SizedBox(width: 10),
          Expanded(
            child: Text('Ολική Διαγραφή',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ]),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('${job.from} → ${job.to}',
              style: const TextStyle(
                  fontWeight: FontWeight.w600, fontSize: 13)),
          if (job.takenByName != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Οδηγός: ${job.takenByName}',
                  style: TextStyle(
                      fontSize: 12, color: Colors.grey[600])),
            ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.red.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.red.shade200),
            ),
            child: Row(children: [
              Icon(Icons.warning_amber_rounded,
                  size: 16, color: Colors.red.shade700),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  job.takenByName != null
                      ? 'Η δουλειά θα διαγραφεί ΟΡΙΣΤΙΚΑ. '
                          'Ο τζίρος και το χρέος του '
                          '${job.takenByName} θα αναιρεθούν '
                          'ανεξάρτητα από την τρέχουσα κατάσταση.'
                      : 'Η δουλειά θα διαγραφεί ΟΡΙΣΤΙΚΑ και θα '
                          'φύγει εντελώς από το ιστορικό.',
                  style: TextStyle(
                      fontSize: 11.5, color: Colors.red.shade900),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 10),
          const Text('Η ενέργεια δεν αναιρείται.',
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
        actions: [
          AppButtonTonal(label: 'Άκυρο', onPressed: () => Navigator.pop(ctx, false)),
          AppButton(
            label: 'Διαγραφή',
            icon: Icons.delete_forever_rounded,
            color: Colors.red,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );

    if (ok != true) return;

    await JobService.purgeJob(job.id);

    onChanged?.call();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Η δουλειά διαγράφηκε οριστικά'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
}
