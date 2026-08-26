// ==========================================
// FILE: ./lib/jobs/flight_delay_badge.dart
// ==========================================
//
// Κοινό widget για όλα τα σημεία που δείχνουμε ότι η ώρα ραντεβού άλλαξε
// λόγω καθυστέρησης πτήσης (κάρτα δουλειάς, αναλυτική καρτέλα, ημερολόγιο,
// ανοιχτές δουλειές, αποθηκευμένες). Ίδιο amber ύφος με τα υπόλοιπα badges.

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../app_theme.dart';
import 'job_model.dart';

/// true αν η δουλειά έχει αλλάξει ώρα λόγω πτήσης (originalScheduledAt
/// γεμάτο + καθυστέρηση > 0).
bool jobHasFlightDelay(Job job) =>
    job.originalScheduledAt != null &&
    (job.flightDelayMinutes ?? 0) > 0;

/// Μικρό badge "Άλλαξε" — για συμπαγείς λίστες (ανοιχτές δουλειές,
/// αποθηκευμένες, ημερολόγιο). Μια γραμμή, δεν καταλαμβάνει πολύ χώρο.
class FlightDelayBadge extends StatelessWidget {
  final Job job;
  const FlightDelayBadge({super.key, required this.job});

  @override
  Widget build(BuildContext context) {
    if (!jobHasFlightDelay(job)) return const SizedBox.shrink();
    final c = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: c.amberSoft,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.schedule_rounded, size: 12, color: c.amberDeep),
          const SizedBox(width: 3),
          Text('Άλλαξε',
              style: TextStyle(
                  fontSize: 11, color: c.amberDeep, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// Γραμμή λεπτομέρειας — "Αρχικά 14:00 · πτήση A3 889 καθυστέρησε 25'".
/// Για κάρτα δουλειάς / αναλυτική καρτέλα / αποθηκευμένες.
class FlightDelaySubline extends StatelessWidget {
  final Job job;
  const FlightDelaySubline({super.key, required this.job});

  @override
  Widget build(BuildContext context) {
    if (!jobHasFlightDelay(job)) return const SizedBox.shrink();
    final c = AppColors.of(context);
    final fmt = DateFormat('HH:mm');
    final oldTime = fmt.format(job.originalScheduledAt!);
    final flight = (job.flightOrShip ?? '').trim();
    final delay = job.flightDelayMinutes ?? 0;
    final text = flight.isNotEmpty
        ? 'Αρχικά $oldTime · πτήση $flight καθυστέρησε $delay\''
        : 'Αρχικά $oldTime · καθυστέρηση $delay\' λόγω πτήσης';
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: c.textFaint),
      ),
    );
  }
}

/// Πλήρες block για την αναλυτική καρτέλα δουλειάς — ώρα με διαγράμμιση
/// στην παλιά, νέα ώρα δίπλα, chip με τη διαφορά σε λεπτά.
class FlightDelayTimeBlock extends StatelessWidget {
  final Job job;
  const FlightDelayTimeBlock({super.key, required this.job});

  @override
  Widget build(BuildContext context) {
    if (!jobHasFlightDelay(job)) return const SizedBox.shrink();
    final c = AppColors.of(context);
    final fmt = DateFormat('HH:mm');
    final delay = job.flightDelayMinutes ?? 0;
    return Container(
      margin: const EdgeInsets.only(top: 8, bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: c.divider,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text('Ήταν', style: TextStyle(fontSize: 11, color: c.textFaint)),
              Text(fmt.format(job.originalScheduledAt!),
                  style: TextStyle(
                      fontSize: 15,
                      color: c.textFaint,
                      decoration: TextDecoration.lineThrough)),
            ],
          ),
          const SizedBox(width: 10),
          Icon(Icons.arrow_forward_rounded, size: 16, color: c.textFaint),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text('Τώρα', style: TextStyle(fontSize: 11, color: c.amberDeep)),
              Text(job.scheduledAt != null ? fmt.format(job.scheduledAt!) : '—',
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: c.amberDeep)),
            ],
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: c.amberSoft,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text('+$delay\'',
                style: TextStyle(
                    fontSize: 12, color: c.amberDeep, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}
