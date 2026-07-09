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

        // ── Φίλτρα master ──
        if (widget.isMaster) {
          if (_onlyMine) {
            items = items.where((s) => s.ownerUid == widget.adminUid).toList();
          } else if (_ownerFilter != '__all__') {
            items = items.where((s) => s.ownerUid == _ownerFilter).toList();
          }
        }

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
        ],
      ),
    );
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
    final jobs = saved.map((s) => s.job).toList();

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
    final jobs = saved.map((s) => s.job).toList();

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
