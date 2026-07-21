// lib/map/home_top_overlay.dart
//
// Νέο compact overlay για την κύρια οθόνη (εγκεκριμένα mockups):
//   • Πάνω μπάρα: badge ρόλου + όνομα + διακόπτης Διαθέσιμος/Μη διαθέσιμος
//   • Admin/Master: μπλοκ 3 στατιστικών ΜΟΝΟ των ΔΙΚΩΝ ΤΟΥ δουλειών
//     (createdBy == uid) ΚΑΙ ΜΟΝΟ ΣΗΜΕΡΙΝΩΝ — Ανοιχτές / Χωρίς οδηγό / Τζίρος
//   • Δύο floating chips πάνω στον χάρτη: «Δουλειές» (μόνο ΣΗΜΕΡΙΝΕΣ
//     αναλήψεις + άθροισμα αμοιβής) και «Μηνύματα» (νέα voice messages)
//   • Μπάρα countdown επόμενου ραντεβού — ίδια λογική/χρώματα/behavior με
//     το υπάρχον MyJobsBottomBar (πράσινο >30' / πορτοκαλί <30' / κόκκινο
//     <10' ή καθυστέρηση, flashing στα τελευταία λεπτά). Όταν δεν υπάρχει
//     ραντεβού, δεν καταλαμβάνει ΚΑΘΟΛΟΥ χώρο — τα chips από πάνω κατεβαίνουν
//     αυτόματα στη θέση της (Column, όχι Stack/Positioned σταθερό).
//
// ΔΕΝ αγγίζει τη λογική δουλειών/δικαιωμάτων — μόνο διαβάζει από
// JobService.allJobs() και VoiceService, με client-side φιλτράρισμα.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../jobs/job_model.dart';
import '../jobs/job_service.dart';

bool _isToday(DateTime d) {
  final now = DateTime.now();
  return d.year == now.year && d.month == now.month && d.day == now.day;
}

/// Η "ημερομηνία αναφοράς" μιας δουλειάς για το φίλτρο "σήμερα":
/// ραντεβού → scheduledAt, άμεση → takenAt (πότε αναλήφθηκε) ή createdAt.
DateTime? _referenceDate(Job j) {
  if (j.scheduledAt != null) return j.scheduledAt;
  return j.takenAt ?? j.createdAt;
}

// ─────────────────────────────────────────────────────────────────
// Πάνω status bar: badge ρόλου + όνομα + διαθεσιμότητα
// ─────────────────────────────────────────────────────────────────
class HomeStatusBar extends StatelessWidget {
  final bool   isMaster;
  final bool   isAdmin;
  final String displayName;
  final bool   isAvailable;
  final VoidCallback onToggleAvailable;
  final VoidCallback onTapAvatar;

  const HomeStatusBar({
    super.key,
    required this.isMaster,
    required this.isAdmin,
    required this.displayName,
    required this.isAvailable,
    required this.onToggleAvailable,
    required this.onTapAvatar,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color:        c.card.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(14),
        border:       Border.all(color: c.cardBorder, width: 0.8),
      ),
      child: Row(children: [
        GestureDetector(
          onTap: onTapAvatar,
          child: isMaster || isAdmin
              ? Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: isMaster ? c.textMain : c.blue,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text(isMaster ? 'MASTER' : 'ADMIN',
                      style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: Colors.white)),
                )
              : Container(
                  width: 28, height: 28,
                  decoration: BoxDecoration(color: c.amberSoft, shape: BoxShape.circle),
                  child: Icon(Icons.local_taxi_rounded, size: 14, color: c.amberDeep),
                ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(displayName,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: c.textMain)),
        ),
        Text(isAvailable ? 'Διαθέσιμος' : 'Μη διαθέσιμος',
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: isAvailable ? const Color(0xFF3B6D11) : c.textFaint)),
        const SizedBox(width: 6),
        GestureDetector(
          onTap: onToggleAvailable,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 32, height: 19,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: isAvailable ? c.green : c.cardBorder,
              borderRadius: BorderRadius.circular(10),
            ),
            child: AnimatedAlign(
              duration: const Duration(milliseconds: 200),
              alignment: isAvailable ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                width: 13, height: 13,
                decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// Μπλοκ στατιστικών — ΜΟΝΟ admin/master, ΜΟΝΟ δικές τους + σήμερα
// ─────────────────────────────────────────────────────────────────
class OwnJobsTodayStats extends StatelessWidget {
  final String uid;
  const OwnJobsTodayStats({super.key, required this.uid});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return StreamBuilder<List<Job>>(
      stream: JobService.allJobs(limit: 150),
      builder: (context, snap) {
        final all = snap.data ?? const <Job>[];
        // ΜΟΝΟ δικές του (createdBy == uid) + ΜΟΝΟ σήμερα.
        final mine = all.where((j) {
          if (j.createdBy != uid) return false;
          final ref = _referenceDate(j);
          if (ref == null || !_isToday(ref)) return false;
          return j.isOpen || j.isTaken || j.isBoarded;
        }).toList();

        final openCount       = mine.where((j) => j.isOpen).length;
        final unassignedCount = mine.where((j) => j.isOpen && (j.takenBy == null || j.takenBy!.isEmpty)).length;
        final revenue = mine
            .where((j) => j.isTaken || j.isBoarded)
            .fold<double>(0, (sum, j) => sum + j.price);

        return Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          decoration: BoxDecoration(
            color:        c.card.withValues(alpha: 0.95),
            borderRadius: BorderRadius.circular(14),
            border:       Border.all(color: c.cardBorder, width: 0.8),
          ),
          child: Column(children: [
            Text('ΟΙ ΔΙΚΕΣ ΜΟΥ ΔΟΥΛΕΙΕΣ · ΣΗΜΕΡΑ',
                style: TextStyle(fontSize: 9, color: c.textFaint, letterSpacing: 0.3)),
            const SizedBox(height: 5),
            Row(children: [
              _stat(c, '$openCount', 'Ανοιχτές', c.textMain),
              _divider(c),
              _stat(c, '$unassignedCount', 'Χωρίς οδηγό',
                  unassignedCount > 0 ? const Color(0xFFA66A00) : c.textMain),
              _divider(c),
              _stat(c, '${revenue.toStringAsFixed(0)}€', 'Τζίρος', const Color(0xFF27500A)),
            ]),
          ]),
        );
      },
    );
  }

  Widget _divider(AppColors c) => Container(width: 0.8, height: 26, color: c.divider);

  Widget _stat(AppColors c, String value, String label, Color valueColor) {
    return Expanded(
      child: Column(children: [
        Text(value,
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: valueColor)),
        Text(label, style: TextStyle(fontSize: 8.5, color: c.textFaint)),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// Floating chips: Δουλειές (σημερινές + αμοιβή) / Μηνύματα (νέα)
// ─────────────────────────────────────────────────────────────────
class HomeFloatingChips extends StatelessWidget {
  final String uid;
  final VoidCallback onTapJobs;
  final VoidCallback onTapMessages;

  const HomeFloatingChips({
    super.key,
    required this.uid,
    required this.onTapJobs,
    required this.onTapMessages,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Row(children: [
      Expanded(
        child: StreamBuilder<List<Job>>(
          stream: JobService.allJobs(limit: 150),
          builder: (context, snap) {
            final all = snap.data ?? const <Job>[];
            final mine = all.where((j) {
              if (j.takenBy != uid) return false;
              if (!(j.isTaken || j.isBoarded)) return false;
              final ref = _referenceDate(j);
              return ref != null && _isToday(ref);
            }).toList();
            final total = mine.fold<double>(0, (s, j) => s + j.driverEarning);

            return _chip(context, c,
                icon: Icons.work_rounded,
                iconColor: c.amberDeep,
                label: mine.isEmpty
                    ? '0 σήμερα'
                    : '${mine.length} σήμερα · ${total.toStringAsFixed(0)}€',
                onTap: onTapJobs);
          },
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection('messages')
              .where('visibleTo', arrayContains: uid)
              .snapshots(),
          builder: (context, snap) {
            final docs = snap.data?.docs ?? [];
            final unread = docs.where((d) {
              final readBy = List<String>.from(d.data()['readBy'] ?? []);
              return !readBy.contains(uid) && d.data()['fromUid'] != uid;
            }).length;

            return _chip(context, c,
                icon: Icons.mic_rounded,
                iconColor: const Color(0xFF534AB7),
                label: unread == 0 ? 'Μηνύματα' : '$unread νέα',
                onTap: onTapMessages);
          },
        ),
      ),
    ]);
  }

  Widget _chip(BuildContext context, AppColors c, {
    required IconData icon,
    required Color    iconColor,
    required String   label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color:        c.card.withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(14),
          border:       Border.all(color: c.cardBorder, width: 0.8),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 15, color: iconColor),
          const SizedBox(width: 6),
          Flexible(
            child: Text(label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: c.textMain)),
          ),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// Μπάρα countdown επόμενου ραντεβού — ίδια λογική με MyJobsBottomBar:
// πράσινο >30' / πορτοκαλί <30' / κόκκινο <10' ή καθυστέρηση, με flash
// (opacity pulse) στα τελευταία λεπτά. ΔΕΝ καταλαμβάνει χώρο όταν δεν
// υπάρχει επόμενο ραντεβού — γονικό Column απλά τη χάνει.
// ─────────────────────────────────────────────────────────────────
class AppointmentCountdownBar extends StatefulWidget {
  final String uid;
  const AppointmentCountdownBar({super.key, required this.uid});

  @override
  State<AppointmentCountdownBar> createState() => _AppointmentCountdownBarState();
}

class _AppointmentCountdownBarState extends State<AppointmentCountdownBar>
    with SingleTickerProviderStateMixin {
  Timer? _ticker;
  late final AnimationController _flashCtrl;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _flashCtrl = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _flashCtrl.dispose();
    super.dispose();
  }

  Job? _nextScheduled(List<Job> jobs) {
    final scheduled = jobs
        .where((j) => j.scheduledAt != null && j.isTaken && j.takenBy == widget.uid)
        .toList()
      ..sort((a, b) => a.scheduledAt!.compareTo(b.scheduledAt!));
    if (scheduled.isEmpty) return null;
    final now = DateTime.now();
    for (final j in scheduled) {
      if (j.scheduledAt!.isAfter(now.subtract(const Duration(hours: 1)))) {
        return j;
      }
    }
    return scheduled.last;
  }

  String _fmtRemaining(Duration d) {
    final abs = d.isNegative ? -d : d;
    final h = abs.inHours;
    final m = abs.inMinutes % 60;
    final s = abs.inSeconds % 60;
    if (h > 0) return '$h:${m.toString().padLeft(2, "0")}:${s.toString().padLeft(2, "0")}';
    return '$m:${s.toString().padLeft(2, "0")}';
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Job>>(
      stream: JobService.allJobs(limit: 150),
      builder: (context, snap) {
        final all  = snap.data ?? const <Job>[];
        final next = _nextScheduled(all);

        // ΚΑΝΕΝΑ ραντεβού → μηδενικό ύψος, καμία θέση δεσμευμένη.
        if (next == null) return const SizedBox.shrink();

        final remaining = next.scheduledAt!.difference(DateTime.now());
        final mins      = remaining.inMinutes;
        final overdue   = remaining.isNegative;

        Color bg;
        IconData icon;
        String   label;
        bool     shouldFlash;

        if (overdue) {
          bg = const Color(0xFFC0392B);
          icon = Icons.alarm_rounded;
          label = 'Καθυστέρηση';
          shouldFlash = true;
        } else if (mins < 10) {
          bg = const Color(0xFFC0392B);
          icon = Icons.alarm_rounded;
          label = 'Ραντεβού σε';
          shouldFlash = true;
        } else if (mins < 30) {
          bg = const Color(0xFFD9822B);
          icon = Icons.access_time_rounded;
          label = 'Ραντεβού σε';
          shouldFlash = false;
        } else {
          bg = const Color(0xFF1E8E3E);
          icon = Icons.alarm_rounded;
          label = 'Ραντεβού σε';
          shouldFlash = false;
        }

        final content = Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 15, color: Colors.white),
            const SizedBox(width: 7),
            Text(label,
                style: TextStyle(fontSize: 11.5, color: Colors.white.withValues(alpha: 0.9))),
            const SizedBox(width: 6),
            Text(_fmtRemaining(remaining),
                style: const TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w700, color: Colors.white)),
          ]),
        );

        if (!shouldFlash) return content;

        return AnimatedBuilder(
          animation: _flashCtrl,
          builder: (_, child) => Opacity(
            opacity: 0.55 + 0.45 * _flashCtrl.value,
            child: child,
          ),
          child: content,
        );
      },
    );
  }
}
