// lib/alert_gate.dart
//
// Συντονιστής προτεραιότητας ανάμεσα σε:
//   • Διεκδικήσεις δουλειάς (job_badge → showJobPopup) — ΥΨΗΛΗ προτεραιότητα
//   • Owner ειδοποιήσεις (owner_alerts) — ΧΑΜΗΛΗ προτεραιότητα
//
// Στόχος: ποτέ δύο dialogs ταυτόχρονα. Όταν εμφανίζεται διεκδίκηση, οι owner
// ειδοποιήσεις περιμένουν. Όταν έρθει νέα διεκδίκηση ενώ παίζει owner dialog,
// το owner dialog κλείνει και η ειδοποίησή του επιστρέφει στην ουρά.

import 'package:flutter/foundation.dart';

class AlertGate {
  AlertGate._();
  static final AlertGate instance = AlertGate._();

  // True όσο εμφανίζεται popup διεκδίκησης (υψηλή προτεραιότητα).
  final ValueNotifier<bool> claimActive = ValueNotifier<bool>(false);

  // Callback που ζητά από το owner_alerts να κλείσει ΤΩΡΑ το dialog του και να
  // επαναφέρει την ειδοποίηση στην ουρά (όταν προκύπτει διεκδίκηση).
  VoidCallback? onClaimPreempt;

  /// Καλείται από το job_badge όταν ανοίγει popup διεκδίκησης.
  void claimOpened() {
    claimActive.value = true;
    // Διώξε τυχόν ανοιχτό owner dialog για να περάσει η διεκδίκηση μπροστά.
    onClaimPreempt?.call();
  }

  /// Καλείται από το job_badge όταν κλείνει το popup διεκδίκησης.
  void claimClosed() {
    claimActive.value = false;
  }
}
