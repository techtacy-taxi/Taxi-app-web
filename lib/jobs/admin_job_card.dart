// lib/jobs/admin_job_card.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'job_form.dart';
import 'job_model.dart';
import 'job_service.dart';
import 'job_shared_widgets.dart';
import 'job_details_sheet.dart';
import '../voice/voice_models.dart';

class AdminJobCard extends StatelessWidget {
  final Job    job;
  final String adminUid;
  final String adminName;
  final bool   isMaster;
  final bool   isAdmin;
  // Επίπεδο πρόσβασης σε ΞΕΝΗ δουλειά (μέσω κοινής πρόσβασης ομάδας).
  // null/full = δική μου ή master → πλήρη δικαιώματα.
  final ShareLevel shareLevel;
  // Αν η δουλειά ανήκει σε άλλον admin (κοινή πρόσβαση), τα στοιχεία του.
  final bool   isForeign;

  const AdminJobCard({
    super.key,
    required this.job,
    required this.adminUid,
    this.adminName = '',
    this.isMaster = false,
    this.isAdmin  = false,
    this.shareLevel = ShareLevel.full,
    this.isForeign  = false,
  });

  // Μπορεί ο χρήστης να επεξεργαστεί/ακυρώσει/σβήσει δουλειές;
  // Για δικές του/master → ναι. Για ξένες → ανάλογα το επίπεδο.
  bool get _canView   => isMaster || isAdmin;
  bool get _canEdit   => isMaster || (isAdmin && shareLevel.canEdit);
  bool get _canDelete => isMaster || (isAdmin && shareLevel.canDelete);

  @override
  Widget build(BuildContext context) {
    final Color  statusColor;
    final String statusLabel;
    if (job.isBoarded) {
      statusColor = const Color(0xFF1E8E3E);              // πράσινο
      statusLabel = 'Παρελήφθη από ${job.takenByName ?? ''}';
    } else if (job.isTaken) {
      statusColor = Colors.orange.shade800;               // πορτοκαλί
      statusLabel = 'Ανελήφθη από ${job.takenByName ?? ''}';
    } else {
      statusColor = Colors.red.shade600;                  // κόκκινο — ανοιχτή
      statusLabel = 'Αναμονή...';
    }

    return FadeSlideIn(
      child: GestureDetector(
      onTap: () => _openDetails(context),
      child: Card(
      margin:    const EdgeInsets.only(bottom: 10),
      elevation: 0,
      color:     job.isReturn
          ? const Color(0xFFF3E5F5)
          : statusColor.withValues(alpha: 0.16),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
              color: job.isReturn
                  ? const Color(0xFF7B1FA2)
                  : Colors.grey.shade200,
              width: job.isReturn ? 1.5 : 1)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

          // ── Badge ΕΠΙΣΤΡΟΦΗ (πάνω-πάνω) ─────────────────────────────────
          if (job.isReturn) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color:        const Color(0xFF7B1FA2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Row(mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                Icon(Icons.u_turn_left_rounded, color: Colors.white, size: 16),
                SizedBox(width: 6),
                Text('ΕΠΙΣΤΡΟΦΗ', style: TextStyle(
                    color: Colors.white, fontSize: 13,
                    fontWeight: FontWeight.w900, letterSpacing: 2)),
              ]),
            ),
          ],

          // ── Header ──────────────────────────────────────────────────────
          // Status badge σε δική του γραμμή → το όνομα φαίνεται ΟΛΟΚΛΗΡΟ
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color:        statusColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(20),
              border:       Border.all(color: statusColor.withValues(alpha: 0.4)),
            ),
            child: Row(children: [
              // Ανοιχτή δουλειά (χτυπάει) → παλλόμενη κουκκίδα· αλλιώς στατική
              job.isOpen && !job.stopped
                  ? _PulsingDot(color: statusColor)
                  : Container(width: 7, height: 7,
                      decoration: BoxDecoration(
                          color: statusColor, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(statusLabel,
                    style: TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w600,
                        color: statusColor)),
              ),
            ]),
          ),
          // Κατάσταση διεκδίκησης — μόνο για ανοιχτές δουλειές
          if (!job.isTaken && job.isOpen)
            _ClaimStatusBanner(job: job, canManage: _canView),
          // Ώρα ραντεβού — αν είναι προγραμματισμένη δουλειά
          if (job.scheduledAt != null) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color:        Colors.blue.shade50,
                borderRadius: BorderRadius.circular(10),
                border:       Border.all(color: Colors.blue.shade200),
              ),
              child: Row(children: [
                Icon(Icons.alarm_rounded, size: 16, color: Colors.blue.shade700),
                const SizedBox(width: 8),
                Text('Ραντεβού:',
                    style: TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600,
                        color: Colors.blue.shade700)),
                const SizedBox(width: 6),
                Text(
                  DateFormat('dd/MM/yyyy  HH:mm').format(job.scheduledAt!),
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.bold,
                      color: Colors.blue.shade900),
                ),
              ]),
            ),
          ],
          const SizedBox(height: 8),
          // Τιμή + κουμπιά ενέργειας — σε ξεχωριστή γραμμή, πάντα ορατά
          Row(children: [
            Text('${job.price.toStringAsFixed(2)}€',
                style: const TextStyle(
                    fontSize: 20, fontWeight: FontWeight.bold,
                    color: Color(0xFF1E8E3E))),
            const Spacer(),
            // Edit + Delete για open — κατά επίπεδο πρόσβασης
            if (job.isOpen && (_canEdit || _canDelete)) ...[
              if (_canEdit)
                IconButton(
                  icon:        const Icon(Icons.edit_rounded, size: 20, color: Colors.grey),
                  tooltip:     'Επεξεργασία',
                  onPressed:   () {
                    Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => JobFormPage(
                          adminUid: adminUid,
                          adminName: adminName,
                          editJob: job,
                          isMaster: isMaster,
                          ownerOverrideUid:  isForeign ? job.createdBy : null,
                          ownerOverrideName: isForeign ? job.createdByName : null),
                    ));
                  },
                ),
              if (_canDelete)
                IconButton(
                  icon:        const Icon(Icons.delete_rounded, size: 20, color: Colors.red),
                  tooltip:     'Διαγραφή',
                  onPressed:   () => _confirmDelete(context),
                ),
            ],
            // Ακύρωση για taken — όσοι μπορούν να επεξεργαστούν
            if ((job.isTaken || job.isBoarded) && _canEdit)
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.red.shade50,
                  foregroundColor: Colors.red,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  elevation: 0,
                ),
                icon:  const Icon(Icons.cancel_rounded, size: 18),
                label: const Text('Ακύρωση'),
                onPressed: () => showCancelDialog(context,
                    from: job.from, to: job.to, jobId: job.id,
                    takenByName: job.takenByName),
              ),
          ]),
          const SizedBox(height: 10),

          // ── Διαδρομή ────────────────────────────────────────────────────
          Row(children: [
            const Icon(Icons.trip_origin_rounded, size: 14, color: Colors.amber),
            const SizedBox(width: 6),
            Expanded(child: Text(job.from,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600))),
          ]),
          const SizedBox(height: 4),
          Row(children: [
            const Icon(Icons.place_rounded, size: 14, color: Colors.red),
            const SizedBox(width: 6),
            Expanded(child: Text(job.to,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600))),
          ]),
          const SizedBox(height: 8),

          // ── Chips ────────────────────────────────────────────────────────
          Wrap(spacing: 6, runSpacing: 4, children: [
            jobChip(Icons.person_rounded, '${job.persons} άτομα',
                Colors.grey.shade600),
            if (job.luggage > 0)
              jobChip(Icons.luggage_rounded, '${job.luggage} βαλίτσες',
                  Colors.grey.shade600),
            if (job.childSeat)
              jobChip(Icons.child_care_rounded,
                  job.childSeatCount > 1
                      ? '${job.childSeatCount} παιδικά'
                      : 'Παιδικό κάθισμα',
                  Colors.purple),
            jobChip(
              job.vehicleType == 'van'
                  ? Icons.airport_shuttle_rounded
                  : Icons.local_taxi_rounded,
              job.vehicleLabel, Colors.grey.shade600,
            ),
            if (job.commission > 0)
              jobChip(Icons.handshake_rounded,
                  '-${job.commission.toStringAsFixed(2)}€'
                  '${job.sourceName != null && job.sourceName!.isNotEmpty ? " ${job.sourceName}" : ""}',
                  Colors.red.shade700),
            if (job.appCommission > 0)
              jobChip(Icons.phone_iphone_rounded,
                  'App -${job.appCommission.toStringAsFixed(2)}€',
                  Colors.indigo.shade700),
          ]),

          if (job.note != null && job.note!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(job.note!, style: TextStyle(fontSize: 12, color: Colors.grey[500])),
          ],

          // ── Δημιουργός ──────────────────────────────────────────────────
          if (job.createdByName.isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(children: [
              Icon(Icons.person_outline, size: 13, color: Colors.grey[500]),
              const SizedBox(width: 4),
              Text('από ${job.createdByName}',
                  style: TextStyle(
                      fontSize: 11,
                      fontStyle: FontStyle.italic,
                      color: Colors.grey[600])),
              if (isForeign) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEFE9FB),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text('κοινή',
                      style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF534AB7))),
                ),
              ],
              if (job.isReposted) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.amber.shade100,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text('ξαναστάλθηκε',
                      style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: Colors.orange.shade900)),
                ),
              ],
            ]),
          ],
        ]),
      ),
    )));
  }

  void _openDetails(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => JobDetailsSheet(
        job: job,
        parentContext: context,
        hideComplete: true,   // δεν είναι ενέργεια εδώ — μόνο προβολή
        historyMode: true,    // δείχνει δημιουργό & εκτελεστή
        openJobMode: true,    // banner κατάστασης ανάθεσης/επιβίβασης
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title:   const Text('Διαγραφή δουλειάς'),
        content: Text('Να διαγραφεί η δουλειά ${job.from} → ${job.to};'),
        actions: [
          AppButtonTonal(label: 'Άκυρο', onPressed: () => Navigator.pop(ctx, false)),
          AppButton(label: 'Διαγραφή', color: Colors.red, onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
    );
    if (ok == true) await JobService.deleteJob(job.id);
  }
}

// ─── Live banner: σε ποιους βγαίνει + χρόνος + κουμπί ΣΤΟΠ ───────────────────
class _ClaimStatusBanner extends StatefulWidget {
  final Job  job;
  final bool canManage;
  const _ClaimStatusBanner({required this.job, this.canManage = false});
  @override
  State<_ClaimStatusBanner> createState() => _ClaimStatusBannerState();
}

class _ClaimStatusBannerState extends State<_ClaimStatusBanner> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      // Ο admin βοηθά την κλιμάκωση: αν έληξε στάδιο, προχώρα το.
      if (widget.job.needsStageAdvance) {
        // ignore: unawaited_futures
        JobService.autoAdvanceStageIfNeeded(widget.job);
      } else if (widget.job.isPastDeadline) {
        // Τελευταίο στάδιο & έληξε ο χρόνος → μαρκάρισμα ως expired ώστε ο
        // owner να ειδοποιηθεί (Cloud Function onJobExpired).
        // ignore: unawaited_futures
        JobService.markExpiredIfNeeded(widget.job);
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String _fmt(int secs) {
    final m = secs ~/ 60;
    final s = secs % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  // Σε ποιους χτυπάει το ΤΡΕΧΟΝ στάδιο κλιμάκωσης
  String _audienceLabel(Job job) {
    final st = job.currentStage;
    if (!st.restrictToBase) {
      return st.availableOnly
          ? 'Όλους τους διαθέσιμους οδηγούς'
          : 'Όλους τους οδηγούς της εφαρμογής';
    }
    if (job.hasSpecificDrivers) {
      final names = job.targetNames.isNotEmpty
          ? job.targetNames.join(', ')
          : '${job.targetUids.length} οδηγοί';
      return st.availableOnly
          ? 'Επιλεγμένους (διαθέσιμους): $names'
          : 'Επιλεγμένους οδηγούς: $names';
    }
    return st.availableOnly
        ? 'Διαθέσιμους της ομάδας'
        : 'Όλη την ομάδα (διαθέσιμοι & μη)';
  }

  Future<void> _confirmStop() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18)),
        title: const Text('Διακοπή ειδοποίησης'),
        content: const Text(
            'Η δουλειά θα σταματήσει να χτυπάει σε οδηγούς '
            'και δεν θα στέλνεται σε περισσότερους. '
            'Θα μείνει στις ανοιχτές δουλειές — '
            'μπορείς να την επεξεργαστείς ή να τη διαγράψεις.'),
        actions: [
          AppButtonTonal(label: 'Άκυρο', onPressed: () => Navigator.pop(ctx, false)),
          AppButton(
            label: 'Στοπ',
            icon: Icons.stop_rounded,
            color: Colors.red,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (ok == true) await JobService.stopJob(widget.job.id);
  }

  @override
  Widget build(BuildContext context) {
    final job = widget.job;

    // ── Σταματημένη δουλειά ──────────────────────────────────────────────
    if (job.stopped) {
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.grey.shade400),
        ),
        child: Row(children: [
          Icon(Icons.stop_circle_rounded,
              size: 16, color: Colors.grey.shade700),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
                'Σταματημένη — επεξεργασία & αποστολή για να ξαναχτυπήσει',
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600,
                    color: Colors.grey.shade700)),
          ),
        ]),
      );
    }

    final advancing = job.needsStageAdvance;
    final expired   = job.isPastDeadline;
    final audience  = _audienceLabel(job);

    final color = expired
        ? Colors.grey.shade600
        : (job.isReposted ? Colors.deepOrange : Colors.orange.shade800);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.campaign_rounded, size: 15, color: color),
            const SizedBox(width: 6),
            Expanded(
              child: Text('Βγαίνει σε: $audience',
                  style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600,
                      color: color)),
            ),
            const SizedBox(width: 6),
            // Δείκτης σταδίου κλιμάκωσης
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text('Στάδιο ${job.stageNumber}/${job.totalStages}',
                  style: TextStyle(
                      fontSize: 10, fontWeight: FontWeight.bold,
                      color: color)),
            ),
          ]),
          if (job.sourceName != null && job.sourceName!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 21, top: 3),
              child: Text('Πηγή: ${job.sourceName}',
                  style: TextStyle(
                      fontSize: 11.5, color: Colors.grey.shade700)),
            ),
          const SizedBox(height: 5),
          Row(children: [
            Icon(expired ? Icons.timer_off_rounded : Icons.timer_rounded,
                size: 15, color: color),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                expired
                    ? 'Έληξε ο χρόνος — δεν την πήρε κανείς'
                    : (advancing
                        ? 'Προχωράει στο επόμενο στάδιο…'
                        : 'Απομένουν ${_fmt(job.secondsRemaining)} '
                          'για διεκδίκηση'),
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.bold,
                    color: color)),
            ),
            // ── Κουμπί ΣΤΟΠ (τετράγωνο) ───────────────────────────────────
            if (widget.canManage) ...[
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _confirmStop,
                child: Container(
                  width: 30, height: 30,
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(color: Colors.red.shade300),
                  ),
                  child: const Icon(Icons.stop_rounded,
                      size: 18, color: Colors.red),
                ),
              ),
            ],
          ]),
        ],
      ),
    );
  }
}

// ─── Παλλόμενη κουκκίδα κατάστασης (για ανοιχτές δουλειές που χτυπάνε) ───────
class _PulsingDot extends StatefulWidget {
  final Color color;
  const _PulsingDot({required this.color});

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, _) {
        // Παλμός: η εξωτερική «άλω» μεγαλώνει & σβήνει, η κουκκίδα σταθερή
        final t = _ctrl.value;
        return SizedBox(
          width: 14, height: 14,
          child: Stack(alignment: Alignment.center, children: [
            Container(
              width:  7 + 7 * t,
              height: 7 + 7 * t,
              decoration: BoxDecoration(
                color: widget.color.withValues(alpha: 0.35 * (1 - t)),
                shape: BoxShape.circle,
              ),
            ),
            Container(
              width: 7, height: 7,
              decoration: BoxDecoration(
                  color: widget.color, shape: BoxShape.circle),
            ),
          ]),
        );
      },
    );
  }
}
