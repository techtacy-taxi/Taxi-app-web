// ==========================================
// FILE: ./lib/jobs/saved_jobs_tab.dart
// ==========================================
//
// ΚΑΡΤΕΛΑ «ΑΠΟΘΗΚΕΥΜΕΝΕΣ»
//
// • admin  → βλέπει μόνο τις δικές του αποθηκευμένες δουλειές
// • master → βλέπει όλες, με φίλτρα (ποιος έφτιαξε / μόνο δικές του)
//
// Λειτουργίες:
//   • Edit / Διαγραφή κάθε αποθηκευμένης
//   • Picker πολλαπλής επιλογής → «Αποστολή»
//       - 1 επιλεγμένη → στέλνεται κατευθείαν (παραλήπτης από pop-up)
//       - >1 επιλεγμένες → pop-up επιλογής παραλήπτη (Όλοι/Ομάδα/Οδηγός)
//         που ΥΠΕΡΙΣΧΥΕΙ ό,τι είχε η φόρμα.
//   • Αν παραλήπτης = 1 συγκεκριμένος οδηγός → αποκλειστική ομαδική αποστολή
//     (κοινό batchId → ο οδηγός βλέπει λίστα με «Αποδοχή όλων»).
//   • Αλλιώς → κάθε δουλειά βγαίνει ξεχωριστά, μία-μία (κανονική διαδικασία).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../voice/recipient_picker.dart';
import '../voice/voice_models.dart';
import '../voice/share_service.dart';
import '../calendar/converted_events_store.dart';
import 'job_form.dart';
import 'job_service.dart';
import 'job_details_sheet.dart';
import 'job_shared_widgets.dart';
import 'saved_job_service.dart';

class SavedJobsTab extends StatefulWidget {
  final String adminUid;
  final String adminName;
  final bool   isMaster;

  const SavedJobsTab({
    super.key,
    required this.adminUid,
    this.adminName = '',
    this.isMaster  = false,
  });

  @override
  State<SavedJobsTab> createState() => _SavedJobsTabState();
}

class _SavedJobsTabState extends State<SavedJobsTab> {
  // Επιλεγμένες (για ομαδική αποστολή)
  final Set<String> _selected = {};
  bool _sending = false;

  // Φίλτρα master
  bool   _onlyMine = false;            // μόνο δικές μου
  String _ownerFilter = '__all__';     // __all__ ή ownerUid

  // ── Αναζήτηση — Booking ID, όνομα πελάτη, τηλέφωνο, διαδρομή, δημιουργός.
  String _searchQuery = '';
  bool _matchesSearch(SavedJob s) {
    final q = _searchQuery.trim().toLowerCase();
    if (q.isEmpty) return true;
    final j = s.job;
    return (s.bookingNumber != null && s.bookingNumber.toString().contains(q)) ||
        (j.clientName?.toLowerCase().contains(q) ?? false) ||
        (j.clientPhone?.toLowerCase().contains(q) ?? false) ||
        j.from.toLowerCase().contains(q) ||
        j.to.toLowerCase().contains(q) ||
        s.ownerName.toLowerCase().contains(q) ||
        (j.note?.toLowerCase().contains(q) ?? false);
  }

  // Κοινή πρόσβαση: ownerUid -> επίπεδο που έχω εγώ πάνω του
  Map<String, ShareLevel> _shared = const {};
  StreamSubscription<Map<String, ShareLevel>>? _shareSub;

  // ── Multi-tenant ──────────────────────────────────────────────────────
  // Ο master (εσύ, super-admin) βλέπει τα πάντα χωρίς φίλτρο (όπως πριν).
  // Κάθε άλλος (admin/tenant-owner) χρειάζεται το ΔΙΚΟ ΤΟΥ tenantId ώστε το
  // query να φιλτράρεται σωστά — αλλιώς, μόλις υπάρξουν docs άλλου tenant
  // στο ίδιο collection, το ΑΦΙΛΤΡΑΡΙΣΤΟ query θα απέτυχε εντελώς (Firestore
  // απορρίπτει ολόκληρο το query αν έστω ένα doc αποτυγχάνει τους κανόνες).
  String? _myTenantId;
  bool _tenantLoaded = false;

  Future<void> _loadMyTenantId() async {
    if (widget.isMaster) {
      // Ο master δεν χρειάζεται φίλτρο — βλέπει τα πάντα, όπως πάντα.
      if (mounted) setState(() => _tenantLoaded = true);
      return;
    }
    try {
      final doc = await FirebaseFirestore.instance
          .collection('presence').doc(widget.adminUid).get();
      final tid = (doc.data()?['tenantId'] as String?) ?? 'default';
      if (mounted) setState(() { _myTenantId = tid; _tenantLoaded = true; });
    } catch (_) {
      if (mounted) setState(() { _myTenantId = 'default'; _tenantLoaded = true; });
    }
  }

  @override
  void initState() {
    super.initState();
    _loadMyTenantId();
    // Ο master βλέπει ούτως ή άλλως τα πάντα — δεν χρειάζεται shares.
    if (!widget.isMaster) {
      _shareSub = ShareService.sharedOwnersStream(widget.adminUid).listen((m) {
        if (mounted) setState(() => _shared = m);
      });
    }
  }

  @override
  void dispose() {
    _shareSub?.cancel();
    super.dispose();
  }

  /// Επίπεδο πρόσβασης που έχω σε μια συγκεκριμένη αποθηκευμένη.
  ShareLevel _levelFor(SavedJob s) {
    if (widget.isMaster) return ShareLevel.full;
    if (s.ownerUid == widget.adminUid) return ShareLevel.full;
    return _shared[s.ownerUid] ?? ShareLevel.none;
  }

  @override
  Widget build(BuildContext context) {
    if (!_tenantLoaded) {
      return const Center(child: CircularProgressIndicator());
    }
    // master → όλες· admin → δικές του + όσων του έχουν δώσει πρόσβαση
    final Stream<List<SavedJob>> stream;
    if (widget.isMaster) {
      stream = SavedJobService.stream(ownerUid: null);
    } else {
      final owners = <String>{widget.adminUid, ..._shared.keys};
      stream = SavedJobService.streamForOwners(owners, tenantId: _myTenantId);
    }

    return StreamBuilder<List<SavedJob>>(
      stream: stream,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(child: Text('Σφάλμα: ${snap.error}'));
        }

        var items = snap.data ?? const <SavedJob>[];

        // ── Κρύψε ό,τι έχει απορροφηθεί σε ενωμένο Shuttle — φαίνεται μόνο
        // μέσα στο container, όχι σαν ξεχωριστή κάρτα εδώ.
        items = items.where((s) => !s.isMergedAway).toList();

        // ── Φίλτρα master ──
        if (widget.isMaster) {
          if (_onlyMine) {
            items = items.where((s) => s.ownerUid == widget.adminUid).toList();
          } else if (_ownerFilter != '__all__') {
            items = items.where((s) => s.ownerUid == _ownerFilter).toList();
          }
        }

        // ── Αναζήτηση ──
        items = items.where(_matchesSearch).toList();

        // ── Ταξινόμηση: πιο κοντινό ραντεβού πάνω, πιο μακρινό κάτω.
        //    Άμεσες (χωρίς ραντεβού) = «τώρα» → πρώτες. Ισοπαλία → σειρά
        //    δημιουργίας (όποια φτιάχτηκε πρώτη, πάνω).
        items = [...items]..sort((a, b) {
          final aSc = a.job.scheduledAt;
          final bSc = b.job.scheduledAt;
          if (aSc != null && bSc != null) {
            final c = aSc.compareTo(bSc);
            if (c != 0) return c;
            return a.savedAt.compareTo(b.savedAt);
          }
          if (aSc == null && bSc != null) return -1;
          if (aSc != null && bSc == null) return 1;
          return a.savedAt.compareTo(b.savedAt);
        });

        // Καθάρισε επιλογές που δεν υπάρχουν πλέον
        final liveIds = items.map((e) => e.id).toSet();
        _selected.removeWhere((id) => !liveIds.contains(id));

        return Column(
          children: [
            // ── Αναζήτηση ──
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              child: TextField(
                decoration: InputDecoration(
                  hintText:   'Αναζήτηση: Booking ID, όνομα, τηλέφωνο, διαδρομή...',
                  prefixIcon: const Icon(Icons.search_rounded),
                  filled:     true,
                  fillColor:  Colors.white,
                  isDense:    true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.grey.shade300),
                  ),
                ),
                onChanged: (v) => setState(() => _searchQuery = v),
              ),
            ),

            // ── Φίλτρα (μόνο master) ──
            if (widget.isMaster) _buildMasterFilters(snap.data ?? const []),

            // ── Μπάρα επιλογής/αποστολής ──
            if (items.isNotEmpty) _buildSelectionBar(items),

            // ── Λίστα ──
            Expanded(
              child: items.isEmpty
                  ? _emptyState()
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 100),
                      itemCount: items.length,
                      itemBuilder: (_, i) {
                        final lvl = _levelFor(items[i]);
                        final isForeign =
                            !widget.isMaster && items[i].ownerUid != widget.adminUid;
                        if (items[i].isShuttleContainer) {
                          return FadeSlideIn(
                            index: i,
                            child: _ShuttleContainerCard(
                              saved: items[i],
                              onSplit: () => _splitShuttle(items[i]),
                              onTapStop: (stop) => _showStopDetails(stop),
                              onEditPrice: (stop) => _editStopPrice(items[i], stop),
                            ),
                          );
                        }
                        return FadeSlideIn(
                          index: i,
                          child: _SavedJobCard(
                            saved:      items[i],
                            selected:   _selected.contains(items[i].id),
                            showOwner:  widget.isMaster || isForeign,
                            isMaster:   widget.isMaster,
                            canSend:    lvl.canSend,
                            canEdit:    lvl.canEdit,
                            canDelete:  lvl.canDelete,
                            onTap:      () => _openDetails(items[i]),
                            onToggle:   lvl.canSend
                                ? () => setState(() {
                                      if (_selected.contains(items[i].id)) {
                                        _selected.remove(items[i].id);
                                      } else {
                                        _selected.add(items[i].id);
                                      }
                                    })
                                : null,
                            onEdit:   lvl.canEdit ? () => _editSaved(items[i]) : null,
                            onDelete: lvl.canDelete ? () => _deleteSaved(items[i]) : null,
                            onSend:   lvl.canSend ? () => _chooseSendTarget(items[i]) : null,
                            onCopy:   () => _copySaved(items[i]),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  // ─── Empty state ──────────────────────────────────────────────────────────
  Widget _emptyState() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.bookmark_border_rounded,
            size: 64, color: Colors.grey.shade400),
        const SizedBox(height: 12),
        Text('Καμία αποθηκευμένη δουλειά',
            style: TextStyle(
                fontSize: 16, color: Colors.grey.shade600,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Text('Φτιάξε δουλειά και πάτησε «Αποθήκευση»',
            style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
      ],
    ),
  );

  // ─── Φίλτρα master ──────────────────────────────────────────────────────
  Widget _buildMasterFilters(List<SavedJob> all) {
    // Μοναδικοί δημιουργοί + πλήθος ανά δημιουργό
    final owners = <String, String>{};
    final counts = <String, int>{};
    for (final s in all) {
      owners[s.ownerUid] = s.ownerName.isNotEmpty ? s.ownerName : s.ownerUid;
      counts[s.ownerUid] = (counts[s.ownerUid] ?? 0) + 1;
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Row(children: [
        // Μόνο δικές μου
        FilterChip(
          label: const Text('Μόνο δικές μου'),
          selected: _onlyMine,
          onSelected: (v) => setState(() {
            _onlyMine = v;
            if (v) _ownerFilter = '__all__';
          }),
          selectedColor: Colors.amber.shade200,
          checkmarkColor: Colors.black,
        ),
        const SizedBox(width: 10),
        // Ποιος έφτιαξε
        Expanded(
          child: DropdownButtonFormField<String>(
            initialValue: _ownerFilter,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: 'Δημιουργός',
              isDense: true,
              filled: true,
              fillColor: Colors.white,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            items: [
              DropdownMenuItem(
                  value: '__all__',
                  child: Text('Όλοι (${all.length})')),
              ...owners.entries.map((e) => DropdownMenuItem(
                    value: e.key,
                    child: Text('${e.value} (${counts[e.key] ?? 0})',
                        overflow: TextOverflow.ellipsis),
                  )),
            ],
            onChanged: _onlyMine
                ? null
                : (v) => setState(() => _ownerFilter = v ?? '__all__'),
          ),
        ),
      ]),
    );
  }

  // ─── Μπάρα επιλογής / αποστολής ──────────────────────────────────────────
  Widget _buildSelectionBar(List<SavedJob> items) {
    final allSelected = _selected.length == items.length && items.isNotEmpty;
    final count = _selected.length;
    final disabled = count == 0 || _sending;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: count > 0 ? Colors.amber.shade50 : Colors.transparent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Σειρά 1: επιλογή όλων + πλήθος ──────────────────────────────
          Row(children: [
            AppButtonTonal(
              icon: allSelected
                  ? Icons.check_box_rounded
                  : Icons.check_box_outline_blank_rounded,
              label: allSelected ? 'Καμία' : 'Όλες',
              onPressed: () => setState(() {
                if (allSelected) {
                  _selected.clear();
                } else {
                  _selected
                    ..clear()
                    ..addAll(items.map((e) => e.id));
                }
              }),
            ),
            const Spacer(),
            if (count > 0)
              Text('$count επιλεγμένες',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 8),
          // ── Σειρά 2: κουμπιά αποστολής (ίσο πλάτος, πάντα ορατά) ─────────
          Row(children: [
            Expanded(
              child: AppButtonTonal(
                icon: Icons.person_rounded,
                label: 'Σε εμένα',
                fg: const Color(0xFF1E8E3E),
                onPressed: disabled
                    ? null
                    : () => _sendToSelf(
                        items.where((e) => _selected.contains(e.id)).toList()),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: AppButton(
                icon: _sending ? null : Icons.send_rounded,
                label: _sending ? 'Αποστολή…' : 'Αποστολή',
                color: const Color(0xFF1E8E3E),
                onPressed: disabled
                    ? null
                    : () => _sendJobs(
                        items.where((e) => _selected.contains(e.id)).toList()),
              ),
            ),
          ]),
          if (count >= 2) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: AppButtonTonal(
                icon: Icons.directions_bus_filled_rounded,
                label: 'Ένωση σε Shuttle ($count)',
                fg: Colors.amber.shade900,
                onPressed: _sending
                    ? null
                    : () => _openMergeDialog(
                        items.where((e) => _selected.contains(e.id)).toList()),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ─── Split ενωμένου Shuttle πίσω στα αρχικά κομμάτια ──────────────────────
  Future<void> _splitShuttle(SavedJob container) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Διαχωρισμός Shuttle'),
        content: const Text('Θα ξαναφανούν οι αρχικές, ξεχωριστές δουλειές. Σίγουρα;'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dctx).pop(false), child: const Text('Άκυρο')),
          FilledButton(onPressed: () => Navigator.of(dctx).pop(true), child: const Text('Διαχωρισμός')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await SavedJobService.splitShuttle(container);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Διαχωρίστηκε.'),
          backgroundColor: Color(0xFF1E8E3E),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Σφάλμα: $e'), backgroundColor: Colors.red));
      }
    }
  }

  // ─── Επεξεργασία τιμής ενός επιβάτη μέσα σε ήδη ενωμένο Shuttle ──────────
  Future<void> _editStopPrice(SavedJob container, ShuttleStop stop) async {
    final ctrl = TextEditingController(text: stop.price.toStringAsFixed(2));
    final newPrice = await showDialog<double>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text('Τιμή — ${stop.name.isNotEmpty ? stop.name : "(χωρίς όνομα)"}'),
        content: TextField(
          controller: ctrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          autofocus: true,
          decoration: const InputDecoration(suffixText: '€', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dctx).pop(), child: const Text('Άκυρο')),
          FilledButton(
            onPressed: () => Navigator.of(dctx).pop(
                double.tryParse(ctrl.text.replaceAll(',', '.')) ?? stop.price),
            child: const Text('Αποθήκευση'),
          ),
        ],
      ),
    );
    if (newPrice == null) return;
    try {
      await SavedJobService.updateShuttleStopPrice(container, stop.savedJobId, newPrice);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Σφάλμα: $e'), backgroundColor: Colors.red));
      }
    }
  }

  void _showStopDetails(ShuttleStop stop) {
    showDialog<void>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text(stop.name.isNotEmpty ? stop.name : '(χωρίς όνομα)'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (stop.phone != null && stop.phone!.isNotEmpty)
              Row(children: [
                const Icon(Icons.phone_rounded, size: 16, color: Colors.grey),
                const SizedBox(width: 8),
                Text(stop.phone!),
              ]),
            if (stop.email != null && stop.email!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Row(children: [
                const Icon(Icons.email_rounded, size: 16, color: Colors.grey),
                const SizedBox(width: 8),
                Expanded(child: Text(stop.email!)),
              ]),
            ],
            if (stop.flightOrShip != null && stop.flightOrShip!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Row(children: [
                const Icon(Icons.flight_rounded, size: 16, color: Colors.grey),
                const SizedBox(width: 8),
                Text(stop.flightOrShip!),
              ]),
            ],
            const SizedBox(height: 6),
            Row(children: [
              const Icon(Icons.place_rounded, size: 16, color: Colors.grey),
              const SizedBox(width: 8),
              Expanded(child: Text(stop.address)),
            ]),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dctx).pop(), child: const Text('Κλείσιμο')),
        ],
      ),
    );
  }

  // ─── Ένωση πολλών αποθηκευμένων σε ΜΙΑ δουλειά Shuttle ─────────────────────
  double _haversineKmReal(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371.0;
    final dLat = (lat2 - lat1) * (math.pi / 180);
    final dLng = (lng2 - lng1) * (math.pi / 180);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180) * math.cos(lat2 * math.pi / 180) *
            math.sin(dLng / 2) * math.sin(dLng / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return r * c;
  }

  Future<void> _openMergeDialog(List<SavedJob> items) async {
    // ── Ανίχνευση κοινού σημείου: είτε όλες οι αφετηρίες κοντά (≤400μ) —
    // κοινή παραλαβή, πολλαπλές αφήσεις — είτε όλοι οι προορισμοί κοντά —
    // κοινή άφεση, πολλαπλές παραλαβές.
    bool closeEnough(List<double?> lats, List<double?> lngs) {
      for (var i = 0; i < lats.length; i++) {
        if (lats[i] == null || lngs[i] == null) return false;
      }
      for (var i = 1; i < lats.length; i++) {
        if (_haversineKmReal(lats[0]!, lngs[0]!, lats[i]!, lngs[i]!) > 0.4) return false;
      }
      return true;
    }

    final fromLats = items.map((e) => e.job.fromLat).toList();
    final fromLngs = items.map((e) => e.job.fromLng).toList();
    final toLats = items.map((e) => e.job.toLat).toList();
    final toLngs = items.map((e) => e.job.toLng).toList();

    final fromShared = closeEnough(fromLats, fromLngs);
    final toShared = !fromShared && closeEnough(toLats, toLngs);

    if (!fromShared && !toShared) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Δεν βρέθηκε κοινό σημείο (ούτε παραλαβή ούτε άφεση) — '
              'η ένωση χρειάζεται είτε ίδια αφετηρία είτε ίδιο προορισμό.'),
          backgroundColor: Colors.red,
        ));
      }
      return;
    }

    final sharedIsPickup = fromShared;
    final sharedName = sharedIsPickup ? items.first.job.from : items.first.job.to;
    final sharedLat = sharedIsPickup ? items.first.job.fromLat : items.first.job.toLat;
    final sharedLng = sharedIsPickup ? items.first.job.fromLng : items.first.job.toLng;

    // ── Συμβατότητα ώρας: κάθε πελάτης «χωράει» [ώρα-25, ώρα+15]. Ενωμένη
    // ώρα = οποιαδήποτε μέσα στην τομή όλων αυτών των διαστημάτων.
    final withTime = items.where((e) => e.job.scheduledAt != null).toList();
    DateTime? suggested;
    bool timeCompatible = true;
    if (withTime.length == items.length && items.isNotEmpty) {
      final starts = items.map((e) => e.job.scheduledAt!.subtract(const Duration(minutes: 25))).toList();
      final ends = items.map((e) => e.job.scheduledAt!.add(const Duration(minutes: 15))).toList();
      final maxStart = starts.reduce((a, b) => a.isAfter(b) ? a : b);
      final minEnd = ends.reduce((a, b) => a.isBefore(b) ? a : b);
      timeCompatible = !maxStart.isAfter(minEnd);
      final sortedTimes = items.map((e) => e.job.scheduledAt!).toList()..sort();
      suggested = sortedTimes[sortedTimes.length ~/ 2];
      if (timeCompatible) {
        if (suggested.isBefore(maxStart)) suggested = maxStart;
        if (suggested.isAfter(minEnd)) suggested = minEnd;
      }
    }

    final anyNonShuttle = items.any((e) => e.job.vehicleType != 'shuttle');

    if (!mounted) return;
    final priceOverrides = await showDialog<Map<String, double>>(
      context: context,
      builder: (dctx) => _MergeShuttleDialog(
        items: items,
        sharedIsPickup: sharedIsPickup,
        sharedName: sharedName,
        suggestedTime: suggested,
        timeCompatible: timeCompatible,
        anyNonShuttle: anyNonShuttle,
      ),
    );
    if (priceOverrides == null || suggested == null) return;

    try {
      await SavedJobService.mergeIntoShuttle(
        items: items,
        sharedPointName: sharedName,
        sharedPointLat: sharedLat,
        sharedPointLng: sharedLng,
        sharedIsPickup: sharedIsPickup,
        unifiedScheduledAt: suggested,
        ownerUid: widget.adminUid,
        ownerName: widget.adminName,
        priceOverrides: priceOverrides,
      );
      setState(() => _selected.clear());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Οι δουλειές ενώθηκαν σε ένα Shuttle.'),
          backgroundColor: Color(0xFF1E8E3E),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Σφάλμα ένωσης: $e'), backgroundColor: Colors.red));
      }
    }
  }

  // ─── Άνοιγμα λεπτομερειών (όπως στις ανοιχτές δουλειές) ──────────────────
  void _openDetails(SavedJob s) {
    showModalBottomSheet(
      context:            context,
      isScrollControlled: true,
      backgroundColor:    Colors.transparent,
      builder: (ctx) => JobDetailsSheet(
        job:           s.job,
        parentContext: context,
        hideComplete:  true, // αποθηκευμένη → όχι «Τέλος Διαδρομής»
      ),
    );
  }

  // ─── Αντιγραφή → νέα δουλειά ───────────────────────────────────────────────
  Future<void> _copySaved(SavedJob s) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => JobFormPage(
        adminUid:    widget.adminUid,
        adminName:   widget.adminName,
        isMaster:    widget.isMaster,
        copyFromJob: s.job,
      ),
    ));
  }

  // ─── Edit ────────────────────────────────────────────────────────────────
  Future<void> _editSaved(SavedJob s) async {
    final isForeign =
        !widget.isMaster && s.ownerUid != widget.adminUid;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => JobFormPage(
        adminUid:       widget.adminUid,
        adminName:      widget.adminName,
        isMaster:       widget.isMaster,
        editSavedJob:   s.job,
        editSavedJobId: s.id,
        ownerOverrideUid:  isForeign ? s.ownerUid : null,
        ownerOverrideName: isForeign ? s.ownerName : null,
      ),
    ));
  }

  // ─── Delete ──────────────────────────────────────────────────────────────
  Future<void> _deleteSaved(SavedJob s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Διαγραφή;'),
        content: Text('Διαγραφή της αποθηκευμένης δουλειάς '
            '${s.job.from} → ${s.job.to};'),
        actions: [
          AppButtonTonal(label: 'Άκυρο', onPressed: () => Navigator.pop(ctx, false)),
          AppButton(
            label: 'Διαγραφή',
            icon: Icons.delete_rounded,
            color: Colors.red,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (ok == true) {
      await SavedJobService.delete(s.id);
      if (mounted) setState(() => _selected.remove(s.id));
    }
  }

  // ─── Επιλογή παραλήπτη για ΜΙΑ δουλειά (οδηγοί ή εμένα) ──────────────────
  Future<void> _chooseSendTarget(SavedJob s) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            const SheetHandle(bottomMargin: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text('${s.job.from} → ${s.job.to}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.groups_rounded, color: Color(0xFF1E8E3E)),
              title: const Text('Αποστολή σε οδηγούς'),
              subtitle: const Text('Επιλογή ομάδας / οδηγών'),
              onTap: () => Navigator.pop(ctx, 'drivers'),
            ),
            ListTile(
              leading: const Icon(Icons.person_rounded, color: Color(0xFF1E8E3E)),
              title: const Text('Αποστολή σε εμένα'),
              subtitle: const Text('Μπαίνει στις δικές μου δουλειές'),
              onTap: () => Navigator.pop(ctx, 'self'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == 'drivers') {
      await _sendJobs([s]);
    } else if (choice == 'self') {
      await _sendToSelf([s]);
    }
  }

  // ─── Αποστολή στον ΕΑΥΤΟ μου ────────────────────────────────────────────
  Future<void> _sendToSelf(List<SavedJob> saved) async {
    if (saved.isEmpty) return;
    final jobs = saved.map((s) => s.job.copyWith(bookingNumber: s.bookingNumber)).toList();

    setState(() => _sending = true);
    try {
      // Κοινό batchId → εμφανίζονται μαζί στις δικές μου δουλειές.
      await JobService.createBatchToDriver(
        jobs:       jobs,
        driverUid:  widget.adminUid,
        driverName: widget.adminName,
      );

      for (final s in saved) {
        final evId = s.calendarEventId;
        if (evId != null && evId.isNotEmpty) {
          try { await ConvertedEventsStore.instance.markSent(evId); } catch (_) {}
        }
        try { await SavedJobService.delete(s.id); } catch (_) {}
      }

      if (mounted) {
        setState(() {
          _selected.clear();
          _sending = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Στάλθηκαν ${jobs.length} δουλειές σε εσένα'),
            backgroundColor: const Color(0xFF1E8E3E),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _sending = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Σφάλμα αποστολής: $e'),
              backgroundColor: Colors.red),
        );
      }
    }
  }

  // ─── Αποστολή ──────────────────────────────────────────────────────────
  Future<void> _sendJobs(List<SavedJob> saved) async {
    if (saved.isEmpty) return;
    final jobs = saved.map((s) => s.job.copyWith(bookingNumber: s.bookingNumber)).toList();

    // ── pop-up επιλογής παραλήπτη (ίδιο με φωνητικά/φόρμα) ──
    final sel = await showRecipientPicker(
      context: context,
      fromUid: widget.adminUid,
    );
    if (sel == null || !mounted) return; // ακύρωση

    setState(() => _sending = true);
    try {
      if (sel.toType == ToType.user &&
          sel.toUid != null && sel.toUid!.isNotEmpty) {
        // ── 1 συγκεκριμένος οδηγός → αποκλειστική ομαδική αποστολή ──
        // Όλες με κοινό batchId → ο οδηγός βλέπει λίστα + «Αποδοχή όλων».
        await JobService.createBatchToDriver(
          jobs:       jobs,
          driverUid:  sel.toUid!,
          driverName: sel.toName ?? '',
        );
      } else {
        // ── Ομάδα / Όλοι / πολλοί οδηγοί → μία-μία ξεχωριστά ──
        String? groupId;
        List<String> uids  = const [];
        List<String> names = const [];
        switch (sel.toType) {
          case ToType.group:
            groupId = sel.toGroupId;
            break;
          case ToType.users:
            uids  = sel.toUids ?? const [];
            names = const []; // ονόματα δεν είναι κρίσιμα για πολλαπλούς
            break;
          case ToType.all:
          case ToType.user:
            break; // all → χωρίς φίλτρο
        }
        await JobService.sendDraftsToAudience(
          jobs:        jobs,
          groupId:     groupId,
          targetUids:  uids,
          targetNames: names,
        );
      }

      // Διαγραφή των απεσταλμένων από τις αποθηκευμένες + σήμανση ημερολογίου
      for (final s in saved) {
        // Αν προήλθε από συμβάν ημερολογίου → μαρκάρισέ το «Στάλθηκε».
        final evId = s.calendarEventId;
        if (evId != null && evId.isNotEmpty) {
          try { await ConvertedEventsStore.instance.markSent(evId); } catch (_) {}
        }
        try { await SavedJobService.delete(s.id); } catch (_) {}
      }

      if (mounted) {
        setState(() {
          _selected.clear();
          _sending = false;
        });
        final n = jobs.length;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(sel.toType == ToType.user
                ? '✅ Στάλθηκαν $n δουλειές στον/στην ${sel.toName ?? "οδηγό"}'
                : '✅ Στάλθηκαν $n δουλειές (${sel.toLabel})'),
            backgroundColor: const Color(0xFF1E8E3E),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _sending = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Σφάλμα αποστολής: $e'),
              backgroundColor: Colors.red),
        );
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Κάρτα αποθηκευμένης δουλειάς
// ─────────────────────────────────────────────────────────────────────────────

class _SavedJobCard extends StatelessWidget {
  final SavedJob     saved;
  final bool         selected;
  final bool         showOwner;
  final bool         canSend;
  final bool         canEdit;
  final bool         canDelete;
  final bool         isMaster;
  final VoidCallback  onTap;
  final VoidCallback? onToggle;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onSend;
  final VoidCallback? onCopy;

  const _SavedJobCard({
    required this.saved,
    required this.selected,
    required this.showOwner,
    this.canSend   = true,
    this.canEdit   = true,
    this.canDelete = true,
    this.isMaster  = false,
    required this.onTap,
    this.onToggle,
    this.onEdit,
    this.onDelete,
    this.onSend,
    this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    final job = saved.job;
    final expires = saved.expiresAt;
    final isReturn = job.isReturn;
    final isForm = saved.isFromPublicForm;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 1.5,
      shadowColor: Colors.black26,
      color: selected
          ? Colors.amber.shade50
          : (isForm
              ? const Color(0xFFFFF8E1)
              : (isReturn ? const Color(0xFFF3E5F5) : Colors.white)),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
            color: selected
                ? Colors.amber
                : (isForm
                    ? const Color(0xFFFFB300)
                    : (isReturn ? const Color(0xFF7B1FA2) : Colors.grey.shade400)),
            width: selected ? 2 : ((isForm || isReturn) ? 1.5 : 1.2)),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Badge ΑΠΟ ΦΟΡΜΑ (πάνω-πάνω) — ήρθε από τη δημόσια φόρμα του site
              if (isForm) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFB300),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                    const Icon(Icons.public_rounded,
                        color: Color(0xFF5A3D00), size: 16),
                    const SizedBox(width: 6),
                    Text(
                        saved.bookingNumber != null
                            ? 'ΑΠΟ ΦΟΡΜΑ · #${saved.bookingNumber}'
                            : 'ΑΠΟ ΦΟΡΜΑ',
                        style: const TextStyle(
                            color: Color(0xFF5A3D00), fontSize: 13,
                            fontWeight: FontWeight.w900, letterSpacing: 1.2)),
                  ]),
                ),
              ],
              // Badge ΑΔΙΕΚΔΙΚΗΤΗ (πάνω-πάνω) — γύρισε μόνη της, κανείς οδηγός
              // δεν την πήρε· διαγράφεται αυτόματα 24 ώρες μετά την επιστροφή.
              if (saved.autoReturned) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade700,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Row(mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                    Icon(Icons.undo_rounded, color: Colors.white, size: 16),
                    SizedBox(width: 6),
                    Text('ΑΔΙΕΚΔΙΚΗΤΗ · ΔΙΑΓΡΑΦΗ ΣΕ 24Ω', style: TextStyle(
                        color: Colors.white, fontSize: 12,
                        fontWeight: FontWeight.w900, letterSpacing: 1)),
                  ]),
                ),
              ],
              // Badge ΕΠΙΣΤΡΟΦΗ (πάνω-πάνω)
              if (isReturn) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF7B1FA2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Row(mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                    Icon(Icons.u_turn_left_rounded,
                        color: Colors.white, size: 16),
                    SizedBox(width: 6),
                    Text('ΕΠΙΣΤΡΟΦΗ', style: TextStyle(
                        color: Colors.white, fontSize: 13,
                        fontWeight: FontWeight.w900, letterSpacing: 2)),
                  ]),
                ),
              ],
              // ── Ταινία «ΠΡΟΠΛΗΡΩΜΕΝΗ» — μόνο για πλήρη πληρωμή online.
              if (isMaster && job.fullyPaid) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFD97757),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Icon(Icons.warning_amber_rounded, size: 16, color: Colors.white),
                    const SizedBox(width: 8),
                    Text(
                      'ΠΡΟΠΛΗΡΩΜΕΝΗ · ${job.depositAmount.toStringAsFixed(2)}€${job.vivaOrderCode != null ? " (Viva)" : ""}',
                      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w900,
                          color: Colors.white, letterSpacing: .5),
                    ),
                  ]),
                ),
              ],
              // Badge προκαταβολής μέσω Viva — ΜΟΝΟ ο master το βλέπει.
              if (isMaster && job.depositPaid && !job.fullyPaid) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE8F5E9),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF1E8E3E), width: 1),
                  ),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Icon(Icons.verified_rounded, size: 15, color: Color(0xFF1E8E3E)),
                    const SizedBox(width: 6),
                    Text(
                      'Πληρώθηκε προκαταβολή ${job.depositAmount.toStringAsFixed(2)}€${job.vivaOrderCode != null ? " (Viva)" : ""}',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                          color: Color(0xFF1E8E3E)),
                    ),
                  ]),
                ),
              ],
              // Header: checkbox + τιμή + ενέργειες
              Row(children: [
                // Κουτάκι επιλογής — μόνο αν μπορεί να στείλει (επιλογή = αποστολή)
                if (canSend)
                  InkWell(
                    onTap: onToggle,
                    borderRadius: BorderRadius.circular(20),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        selected
                            ? Icons.check_circle_rounded
                            : Icons.radio_button_unchecked_rounded,
                        color: selected ? Colors.amber.shade800 : Colors.grey,
                        size: 26,
                      ),
                    ),
                  )
                else
                  const SizedBox(width: 8),
                const SizedBox(width: 6),
                Text('${job.price.toStringAsFixed(2)}€',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold,
                        color: Color(0xFF1E8E3E))),
                const Spacer(),
                if (onCopy != null)
                  IconButton(
                    icon: const Icon(Icons.copy_rounded,
                        size: 20, color: Color(0xFF1565C0)),
                    tooltip: 'Αντιγραφή σε νέα',
                    onPressed: onCopy,
                  ),
                if (canSend)
                  IconButton(
                    icon: const Icon(Icons.send_rounded,
                        size: 20, color: Color(0xFF1E8E3E)),
                    tooltip: 'Αποστολή',
                    onPressed: onSend,
                  ),
                if (canEdit)
                  IconButton(
                    icon: const Icon(Icons.edit_rounded,
                        size: 20, color: Colors.grey),
                    tooltip: 'Επεξεργασία',
                    onPressed: onEdit,
                  ),
                if (canDelete)
                  IconButton(
                    icon: const Icon(Icons.delete_rounded,
                        size: 20, color: Colors.red),
                    tooltip: 'Διαγραφή',
                    onPressed: onDelete,
                  ),
              ]),

              // Ραντεβού — μπλε μπάρα πλήρους πλάτους
              if (job.scheduledAt != null) ...[
                const SizedBox(height: 4),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1565C0),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(children: [
                    const Icon(Icons.alarm_rounded,
                        size: 15, color: Colors.white),
                    const SizedBox(width: 8),
                    Text(
                      'Ραντεβού · ${DateFormat('dd/MM/yyyy  HH:mm').format(job.scheduledAt!)}',
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Colors.white),
                    ),
                  ]),
                ),
              ],
              const SizedBox(height: 8),

              // Διαδρομή
              Row(children: [
                const Icon(Icons.trip_origin_rounded, size: 14, color: Colors.amber),
                const SizedBox(width: 6),
                Expanded(child: Text(job.from,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600))),
              ]),
              const SizedBox(height: 4),
              Row(children: [
                const Icon(Icons.place_rounded, size: 14, color: Colors.red),
                const SizedBox(width: 6),
                Expanded(child: Text(job.to,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600))),
              ]),

              const SizedBox(height: 8),
              // Ιδιοκτήτης (master ή ξένη) + λήξη
              Row(children: [
                if (showOwner && saved.ownerName.isNotEmpty) ...[
                  Icon(Icons.person_outline, size: 13, color: Colors.grey[500]),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text('από ${saved.ownerName}',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                  ),
                ] else
                  const Spacer(),
                Icon(Icons.auto_delete_rounded, size: 13, color: Colors.grey[400]),
                const SizedBox(width: 4),
                Text(
                    saved.autoReturned
                        ? 'λήγει ${DateFormat('dd/MM HH:mm').format(expires)}'
                        : 'λήγει ${DateFormat('dd/MM').format(expires)}',
                    style: TextStyle(fontSize: 11, color: Colors.grey[500])),
              ]),
              if (saved.lastEditedByName != null &&
                  saved.lastEditedByName!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Row(children: [
                  Icon(Icons.history_edu_rounded, size: 12, color: Colors.grey[400]),
                  const SizedBox(width: 4),
                  Text('επεξ. ${saved.lastEditedByName}',
                      style: TextStyle(fontSize: 11, color: Colors.grey[500])),
                ]),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Διάλογος επιβεβαίωσης ένωσης σε Shuttle
// ─────────────────────────────────────────────────────────────────────────
class _MergeShuttleDialog extends StatefulWidget {
  final List<SavedJob> items;
  final bool sharedIsPickup;
  final String sharedName;
  final DateTime? suggestedTime;
  final bool timeCompatible;
  final bool anyNonShuttle;

  const _MergeShuttleDialog({
    required this.items,
    required this.sharedIsPickup,
    required this.sharedName,
    required this.suggestedTime,
    required this.timeCompatible,
    required this.anyNonShuttle,
  });

  @override
  State<_MergeShuttleDialog> createState() => _MergeShuttleDialogState();
}

class _MergeShuttleDialogState extends State<_MergeShuttleDialog> {
  bool _confirm1 = false;
  bool _confirm2 = false;
  late final Map<String, TextEditingController> _priceCtrls;

  @override
  void initState() {
    super.initState();
    _priceCtrls = {
      for (final s in widget.items)
        s.id: TextEditingController(text: s.job.price.toStringAsFixed(2)),
    };
  }

  @override
  void dispose() {
    for (final c in _priceCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  double get _total => _priceCtrls.values.fold<double>(
      0, (sum, c) => sum + (double.tryParse(c.text.replaceAll(',', '.')) ?? 0));

  Map<String, double> get _priceOverrides => {
        for (final e in _priceCtrls.entries)
          e.key: double.tryParse(e.value.text.replaceAll(',', '.')) ?? 0,
      };

  @override
  Widget build(BuildContext context) {
    final needsDouble = widget.anyNonShuttle;
    final canProceed = widget.suggestedTime != null &&
        (!needsDouble || (_confirm1 && _confirm2));

    return AlertDialog(
      title: const Text('Ένωση σε Shuttle'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.sharedIsPickup
                    ? 'Κοινή παραλαβή από: ${widget.sharedName}\nΔιαφορετική άφεση για κάθε επιβάτη.'
                    : 'Κοινή άφεση στο: ${widget.sharedName}\nΔιαφορετική παραλαβή για κάθε επιβάτη.',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5),
              ),
              const SizedBox(height: 12),
              const Text('Ποιος πληρώνει τι — μπορείς να αλλάξεις τις τιμές:',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5)),
              const SizedBox(height: 6),
              ...widget.items.map((s) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(children: [
                      const Icon(Icons.person_rounded, size: 16, color: Colors.grey),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              s.job.clientName?.isNotEmpty == true ? s.job.clientName! : '(χωρίς όνομα)',
                              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                            ),
                            Text(widget.sharedIsPickup ? s.job.to : s.job.from,
                                style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                          ],
                        ),
                      ),
                      if (s.job.vehicleType != 'shuttle')
                        Container(
                          margin: const EdgeInsets.only(right: 6),
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.red.shade50,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text('όχι Shuttle',
                              style: TextStyle(fontSize: 9.5, color: Colors.red.shade800, fontWeight: FontWeight.bold)),
                        ),
                      SizedBox(
                        width: 80,
                        child: TextField(
                          controller: _priceCtrls[s.id],
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          textAlign: TextAlign.right,
                          style: const TextStyle(fontSize: 13),
                          decoration: const InputDecoration(
                              isDense: true,
                              suffixText: '€',
                              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                              border: OutlineInputBorder()),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                    ]),
                  )),
              const Divider(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Σύνολο', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  Text('${_total.toStringAsFixed(2)}€',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF1E8E3E))),
                ],
              ),
              const SizedBox(height: 12),
              if (widget.suggestedTime != null)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: widget.timeCompatible ? Colors.green.shade50 : Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: widget.timeCompatible ? Colors.green.shade200 : Colors.orange.shade300),
                  ),
                  child: Text(
                    widget.timeCompatible
                        ? 'Κοινή ώρα: ${DateFormat('HH:mm').format(widget.suggestedTime!)} '
                          '(μέσα στο ανεκτό περιθώριο -25/+15 λεπτών όλων)'
                        : '⚠️ Οι ώρες δεν συμπίπτουν καλά μεταξύ τους (εκτός -25/+15 λεπτών) — '
                          'προτεινόμενη ώρα ${DateFormat('HH:mm').format(widget.suggestedTime!)}, έλεγξε το χειροκίνητα.',
                    style: TextStyle(
                        fontSize: 12,
                        color: widget.timeCompatible ? Colors.green.shade900 : Colors.orange.shade900),
                  ),
                )
              else
                const Text('Δεν βρέθηκε ραντεβού σε όλες τις δουλειές — δεν μπορεί να υπολογιστεί κοινή ώρα.',
                    style: TextStyle(fontSize: 12, color: Colors.red)),
              if (needsDouble) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red.shade300),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Μία ή περισσότερες δουλειές ΔΕΝ είναι Shuttle. Η ένωση '
                        'μη-Shuttle δουλειών είναι ασυνήθιστη — επιβεβαίωσε ρητά:',
                        style: TextStyle(fontSize: 12, color: Colors.red.shade900)),
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: _confirm1,
                      onChanged: (v) => setState(() => _confirm1 = v ?? false),
                      title: const Text('Κατάλαβα ότι δεν είναι όλες Shuttle',
                          style: TextStyle(fontSize: 12)),
                    ),
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: _confirm2,
                      onChanged: (v) => setState(() => _confirm2 = v ?? false),
                      title: const Text('Θέλω σίγουρα να τις ενώσω παρ\' όλα αυτά',
                          style: TextStyle(fontSize: 12)),
                    ),
                  ]),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Άκυρο')),
        FilledButton(
          onPressed: canProceed
              ? () => Navigator.of(context).pop(_priceOverrides)
              : null,
          child: const Text('Ένωση'),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Κάρτα ενωμένης δουλειάς Shuttle — δείχνει το κοινό σημείο + στάσεις
// ─────────────────────────────────────────────────────────────────────────
class _ShuttleContainerCard extends StatelessWidget {
  final SavedJob saved;
  final VoidCallback onSplit;
  final void Function(ShuttleStop) onTapStop;
  final void Function(ShuttleStop) onEditPrice;

  const _ShuttleContainerCard({
    required this.saved,
    required this.onSplit,
    required this.onTapStop,
    required this.onEditPrice,
  });

  @override
  Widget build(BuildContext context) {
    final stops = saved.shuttleStops;
    final sharedLabel = saved.shuttleSharedIsPickup
        ? 'Από ${saved.shuttleSharedPointName ?? "—"} παίρνεις:'
        : 'Παίρνεις από αλλού, πάνε στο ${saved.shuttleSharedPointName ?? "—"}:';

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.amber.shade400, width: 1.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.directions_bus_filled_rounded, color: Colors.amber.shade800, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Ενωμένο Shuttle · ${stops.length} επιβάτες',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              ),
              IconButton(
                icon: const Icon(Icons.call_split_rounded, size: 20),
                tooltip: 'Διαχωρισμός',
                onPressed: onSplit,
              ),
            ]),
            if (saved.job.scheduledAt != null) ...[
              const SizedBox(height: 4),
              Text('Ραντεβού: ${DateFormat('dd/MM HH:mm').format(saved.job.scheduledAt!)}',
                  style: TextStyle(fontSize: 12.5, color: Colors.grey[700])),
            ],
            const SizedBox(height: 10),
            Text(sharedLabel,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5)),
            const SizedBox(height: 6),
            ...stops.map((s) => InkWell(
                  onTap: () => onTapStop(s),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(children: [
                      const Icon(Icons.person_pin_circle_rounded, size: 16, color: Colors.amber),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(s.name.isNotEmpty ? s.name : '(χωρίς όνομα)',
                                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                            Text(
                                (s.isPickupHere ? 'Παραλαβή: ' : 'Άφηση: ') + s.address,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 11.5, color: Colors.grey[600])),
                          ],
                        ),
                      ),
                      InkWell(
                        onTap: () => onEditPrice(s),
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Text('${s.price.toStringAsFixed(2)}€',
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5, color: Color(0xFF1E8E3E))),
                            const SizedBox(width: 3),
                            Icon(Icons.edit_rounded, size: 12, color: Colors.grey[400]),
                          ]),
                        ),
                      ),
                    ]),
                  ),
                )),
            const Divider(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Σύνολο: ${saved.job.persons} άτομα',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                Text('${saved.job.price.toStringAsFixed(2)}€',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF1E8E3E))),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
