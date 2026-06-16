// ==========================================
// FILE: ./lib/jobs/batch_accept_sheet.dart
// ==========================================
//
// ΛΙΣΤΑ ΟΜΑΔΙΚΗΣ ΑΝΑΘΕΣΗΣ (batch) ΣΤΟΝ ΟΔΗΓΟ
//
// Όταν ένας admin/master στείλει ΠΟΛΛΕΣ δουλειές μαζί, αποκλειστικά σε ΕΝΑΝ
// οδηγό (κοινό batchId), ο οδηγός δεν βλέπει popups μία-μία· βλέπει αυτή τη
// λίστα με:  α/α · ώρα · από → προς · τιμή,  και «Σύνολο τζίρου» στο τέλος.
//
// Κουμπί «Αποδοχή όλων» → παίρνει ΟΛΕΣ τις δουλειές, αλλά κάθε μία γράφεται
// ΞΕΧΩΡΙΣΤΑ (takeJob ανά δουλειά), σαν να τις πήρε μία-μία → σωστό billing.
//
// Επιστρέφει: πλήθος δουλειών που πάρθηκαν επιτυχώς (0 αν άκυρο/καμία).

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'job_model.dart';
import 'job_service.dart';
import 'job_shared_widgets.dart';

Future<int> showBatchAcceptSheet({
  required BuildContext context,
  required List<Job>    jobs,
  required String       uid,
  required String       driverName,
}) async {
  final result = await showModalBottomSheet<int>(
    context:            context,
    isScrollControlled: true,
    isDismissible:      false,
    enableDrag:         false,
    backgroundColor:    Colors.transparent,
    builder: (_) => _BatchAcceptSheet(
      jobs:       jobs,
      uid:        uid,
      driverName: driverName,
    ),
  );
  return result ?? 0;
}

class _BatchAcceptSheet extends StatefulWidget {
  final List<Job> jobs;
  final String    uid;
  final String    driverName;

  const _BatchAcceptSheet({
    required this.jobs,
    required this.uid,
    required this.driverName,
  });

  @override
  State<_BatchAcceptSheet> createState() => _BatchAcceptSheetState();
}

class _BatchAcceptSheetState extends State<_BatchAcceptSheet> {
  bool _taking = false;

  // Ταξινόμηση: ραντεβού κατά ώρα, άμεσες στο τέλος
  List<Job> get _sorted {
    final list = [...widget.jobs];
    list.sort((a, b) {
      final aHas = a.scheduledAt != null;
      final bHas = b.scheduledAt != null;
      if (aHas && bHas) return a.scheduledAt!.compareTo(b.scheduledAt!);
      if (aHas) return -1;
      if (bHas) return 1;
      return 0;
    });
    return list;
  }

  double get _totalTurnover =>
      widget.jobs.fold(0.0, (sum, j) => sum + j.price);

  Future<void> _acceptAll() async {
    setState(() => _taking = true);
    int taken = 0;
    for (final j in _sorted) {
      try {
        final ok = await JobService.takeJob(
          jobId: j.id, uid: widget.uid, name: widget.driverName);
        if (ok) taken++;
      } catch (_) {/* αγνόησε — συνέχισε με τις υπόλοιπες */}
    }
    if (mounted) Navigator.of(context).pop(taken);
  }

  @override
  Widget build(BuildContext context) {
    final jobs = _sorted;

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: EdgeInsets.fromLTRB(
          0, 12, 0, 16 + MediaQuery.of(context).padding.bottom),
      constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.88),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        // Drag handle
        const SheetHandle(bottomMargin: 12),

        // Header
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(children: [
            const Icon(Icons.playlist_add_check_rounded,
                color: Color(0xFF1E8E3E), size: 26),
            const SizedBox(width: 10),
            const Expanded(
              child: Text('Πρόγραμμα δουλειών για σένα',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF1E8E3E),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text('${jobs.length}',
                  style: const TextStyle(color: Colors.white,
                      fontSize: 14, fontWeight: FontWeight.bold)),
            ),
          ]),
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
                'Στάλθηκαν αποκλειστικά σε σένα — αποδέξου όλες μαζί.',
                style: TextStyle(fontSize: 12.5, color: Colors.grey[600])),
          ),
        ),
        const SizedBox(height: 8),
        const Divider(height: 1),

        // ── Λίστα (συμπαγής, να χωράνε πολλές) ──
        Flexible(
          child: ListView.separated(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            itemCount: jobs.length,
            separatorBuilder: (_, _) => Divider(
                height: 1, color: Colors.grey.shade200),
            itemBuilder: (_, i) => _row(jobs[i], i + 1),
          ),
        ),

        const Divider(height: 1),
        // ── Σύνολο τζίρου ──
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
          child: Row(children: [
            const Icon(Icons.summarize_rounded, color: Color(0xFF1E8E3E)),
            const SizedBox(width: 8),
            const Text('Σύνολο τζίρου',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const Spacer(),
            Text('${_totalTurnover.toStringAsFixed(2)}€',
                style: const TextStyle(
                    fontSize: 20, fontWeight: FontWeight.bold,
                    color: Color(0xFF1E8E3E))),
          ]),
        ),

        // ── Κουμπιά ──
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Expanded(
              flex: 2,
              child: OutlinedButton(
                onPressed: _taking ? null : () => Navigator.of(context).pop(0),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: BorderSide(color: Colors.grey.shade300),
                  foregroundColor: Colors.grey[700],
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: const Text('Όχι τώρα',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 3,
              child: FilledButton.icon(
                onPressed: _taking ? null : _acceptAll,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF1E8E3E),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                icon: _taking
                    ? const SizedBox(width: 18, height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.done_all_rounded),
                label: Text(_taking ? 'Αποδοχή...' : 'Αποδοχή όλων',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),
          ]),
        ),
      ]),
    );
  }

  // Μία γραμμή: α/α · ώρα · από → προς · τιμή
  Widget _row(Job job, int n) {
    final timeLabel = job.scheduledAt != null
        ? DateFormat('dd/MM HH:mm').format(job.scheduledAt!)
        : 'Άμεση';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // α/α
        Container(
          width: 24, height: 24,
          margin: const EdgeInsets.only(top: 2),
          decoration: const BoxDecoration(
              color: Color(0xFF1E8E3E), shape: BoxShape.circle),
          alignment: Alignment.center,
          child: Text('$n',
              style: const TextStyle(color: Colors.white,
                  fontSize: 12, fontWeight: FontWeight.bold)),
        ),
        const SizedBox(width: 10),
        // ώρα + διαδρομή
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(
                job.scheduledAt != null
                    ? Icons.alarm_rounded
                    : Icons.flash_on_rounded,
                size: 13,
                color: job.scheduledAt != null
                    ? Colors.blue.shade700
                    : const Color(0xFF1E8E3E),
              ),
              const SizedBox(width: 4),
              Text(timeLabel,
                  style: TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.bold,
                      color: job.scheduledAt != null
                          ? Colors.blue.shade800
                          : const Color(0xFF1E8E3E))),
            ]),
            const SizedBox(height: 3),
            Text('${job.from}  →  ${job.to}',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                maxLines: 2, overflow: TextOverflow.ellipsis),
          ]),
        ),
        const SizedBox(width: 8),
        // τιμή
        Text('${job.price.toStringAsFixed(2)}€',
            style: const TextStyle(
                fontSize: 15, fontWeight: FontWeight.bold,
                color: Color(0xFF1E8E3E))),
      ]),
    );
  }
}
