// lib/masters/masters_admin_page.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../models.dart';
import '../jobs/job_service.dart';
import '../jobs/job_shared_widgets.dart';

class MastersAdminPage extends StatefulWidget {
  final String masterUid;
  const MastersAdminPage({super.key, required this.masterUid});

  @override
  State<MastersAdminPage> createState() => _MastersAdminPageState();
}

class _MastersAdminPageState extends State<MastersAdminPage> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F8F8),
      appBar: AppBar(
        title: const Row(children: [
          Icon(Icons.admin_panel_settings_rounded,
              color: Colors.white, size: 22),
          SizedBox(width: 10),
          Text('Διαχειριστές',
              style: TextStyle(fontWeight: FontWeight.bold)),
        ]),
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_rounded),
            tooltip: 'Ρυθμίσεις χρεώσεων',
            onPressed: () => _showSettingsDialog(context),
          ),
        ],
      ),
      body: Column(children: [
        // ── Μπάρα αναζήτησης οδηγών ───────────────────────────────────────
        Container(
          color: Colors.deepPurple,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          child: TextField(
            controller: _searchCtrl,
            onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Αναζήτηση οδηγού (όνομα ή τηλέφωνο)',
              hintStyle: TextStyle(color: Colors.grey.shade500, fontSize: 14),
              prefixIcon: const Icon(Icons.search_rounded,
                  color: Colors.deepPurple),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear_rounded,
                          color: Colors.grey),
                      onPressed: () {
                        _searchCtrl.clear();
                        setState(() => _query = '');
                      },
                    ),
              filled: true,
              fillColor: Colors.white,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance
                .collection('presence')
                .snapshots(),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(
                    child:
                        CircularProgressIndicator(color: Colors.deepPurple));
              }
              final docs = snap.data?.docs ?? [];
              // Φιλτράρισμα βάσει αναζήτησης (όνομα ή τηλέφωνο)
              final filtered = _query.isEmpty
                  ? docs
                  : docs.where((d) {
                      final m = d.data();
                      final name =
                          '${m['displayName'] ?? ''} ${m['lastName'] ?? ''}'
                              .toLowerCase();
                      final phone =
                          (m['phone'] as String? ?? '').toLowerCase();
                      return name.contains(_query) ||
                          phone.contains(_query);
                    }).toList();

              // Ταξινόμηση: μη-εγκεκριμένοι πρώτα, μετά master, admin, οδηγοί
              final sorted = [...filtered]..sort((a, b) {
                final aAppr = a.data()['isApproved'] == true;
                final bAppr = b.data()['isApproved'] == true;
                // Εκκρεμείς (μη εγκεκριμένοι) στην κορυφή
                if (!aAppr && bAppr) return -1;
                if (aAppr && !bAppr) return 1;
                final aM = a.data()['master'] == true;
                final bM = b.data()['master'] == true;
                final aA = a.data()['admin']  == true;
                final bA = b.data()['admin']  == true;
                if (aM && !bM) return -1;
                if (!aM && bM) return 1;
                if (aA && !bA) return -1;
                if (!aA && bA) return 1;
                return 0;
              });

              if (sorted.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.search_off_rounded,
                          size: 48, color: Colors.grey.shade400),
                      const SizedBox(height: 10),
                      Text(
                        _query.isEmpty
                            ? 'Δεν υπάρχουν χρήστες'
                            : 'Κανένα αποτέλεσμα για «${_searchCtrl.text}»',
                        style: TextStyle(color: Colors.grey.shade600),
                      ),
                    ],
                  ),
                );
              }

              return ListView.separated(
                padding: EdgeInsets.fromLTRB(
                    16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
                itemCount: sorted.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (ctx, i) {
                  final doc  = sorted[i];
                  final data = doc.data();
                  return _AdminDriverCard(
                    docId:     doc.id,
                    data:      data,
                    masterUid: widget.masterUid,
                    isSelf:    doc.id == widget.masterUid,
                  );
                },
              );
            },
          ),
        ),
      ]),
    );
  }

  // ─── Dialog ρυθμίσεων ─────────────────────────────────────────────────────
  Future<void> _showSettingsDialog(BuildContext context) async {
    // Σιγουρέψου ότι υπάρχει η πηγή Standard Rate
    await JobService.ensureStandardRate();
    final settings = await JobService.getAppSettings();

    if (!context.mounted) return;

    final appCtrl = TextEditingController(
        text: (settings['appCommission'] ?? 1.50).toStringAsFixed(2));
    final subCtrl = TextEditingController(
        text: (settings['subscription'] ?? 5.00).toStringAsFixed(2));
    final calCtrl = TextEditingController(
        text: (settings['calendarSubscription'] ?? 0.00).toStringAsFixed(2));

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(children: [
          Icon(Icons.settings_rounded, color: Colors.deepPurple),
          SizedBox(width: 10),
          Text('Ρυθμίσεις'),
        ]),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
            // Προμήθεια App
            TextField(
              controller: appCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText:  'Προμήθεια App (€)',
                helperText: 'Εφαρμόζεται σε ΟΛΕΣ τις πηγές',
                prefixIcon: Icon(Icons.phone_iphone_rounded,
                    color: Colors.blue),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 18),
            // Συνδρομή
            TextField(
              controller: subCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText:  'Μηνιαία Συνδρομή App (€)',
                helperText: 'Χρεώνεται σε κάθε οδηγό την 1η του μήνα',
                prefixIcon: Icon(Icons.calendar_month_rounded,
                    color: Colors.deepOrange),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 18),
            // Συνδρομή Ημερολογίου
            TextField(
              controller: calCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText:  'Συνδρομή Ημερολογίου (€)',
                helperText: 'Έξτρα χρέωση 1η μήνα — μόνο σε όσους έχουν '
                    'ενεργό ημερολόγιο. 0 = ανενεργή.',
                prefixIcon: Icon(Icons.event_repeat_rounded,
                    color: Colors.deepPurple),
                border: OutlineInputBorder(),
              ),
            ),
          ]),
        ),
        actions: [
          AppButtonTonal(label: 'Άκυρο', onPressed: () => Navigator.pop(ctx)),
          AppButton(
            label: 'Αποθήκευση',
            color: Colors.deepPurple,
            onPressed: () async {
              final appV = double.tryParse(
                  appCtrl.text.trim().replaceAll(',', '.'));
              final subV = double.tryParse(
                  subCtrl.text.trim().replaceAll(',', '.'));
              final calV = double.tryParse(
                  calCtrl.text.trim().replaceAll(',', '.'));
              Navigator.pop(ctx);
              if (appV != null) {
                await JobService.setGlobalAppCommission(appV);
              }
              if (subV != null) {
                await JobService.setSubscription(subV);
              }
              if (calV != null) {
                await JobService.setCalendarSubscription(calV);
              }
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Οι ρυθμίσεις αποθηκεύτηκαν'),
                    backgroundColor: Colors.green,
                  ),
                );
              }
            },
          ),
        ],
        ),
      ),
    );
  }
}

// ─── _AdminDriverCard ─────────────────────────────────────────────────────────

class _AdminDriverCard extends StatelessWidget {
  final String                 docId;
  final Map<String, dynamic>   data;
  final String                 masterUid;
  final bool                   isSelf;

  const _AdminDriverCard({
    required this.docId,
    required this.data,
    required this.masterUid,
    required this.isSelf,
  });

  @override
  Widget build(BuildContext context) {
    final name   = '${data['displayName'] ?? ''} ${data['lastName'] ?? ''}'.trim();
    final phone  = data['phone']  as String? ?? '';
    final isMaster = data['master'] == true;
    final isAdmin  = data['admin']  == true;
    final isApproved = data['isApproved'] == true;
    final calendarEnabled = data['calendarEnabled'] == true;
    final managedGroupIds = List<String>.from(data['managedGroupIds'] ?? []);

    Color roleColor;
    String roleLabel;
    IconData roleIcon;

    if (isMaster) {
      roleColor = Colors.deepPurple;
      roleLabel = 'Master';
      roleIcon  = Icons.stars_rounded;
    } else if (isAdmin) {
      roleColor = Colors.amber.shade800;
      roleLabel = 'Διαχειριστής';
      roleIcon  = Icons.admin_panel_settings_rounded;
    } else {
      roleColor = Colors.grey.shade500;
      roleLabel = 'Οδηγός';
      roleIcon  = Icons.local_taxi_rounded;
    }

    return Card(
      elevation: 0,
      color:     Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: isMaster
              ? Colors.deepPurple.shade200
              : (isAdmin ? Colors.amber.shade300 : Colors.grey.shade200),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: όνομα + role badge + edit button
            Row(children: [
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name.isEmpty ? '(χωρίς όνομα)' : name,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.bold)),
                  if (phone.isNotEmpty)
                    Text(phone,
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey[500])),
                ],
              )),
              // Role badge
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: roleColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                      color: roleColor.withValues(alpha: 0.4)),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(roleIcon, size: 14, color: roleColor),
                  const SizedBox(width: 4),
                  Text(roleLabel,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: roleColor)),
                ]),
              ),
              const SizedBox(width: 8),
              // Επεξεργασία (δεν μπορεί να αλλάξει τον εαυτό του)
              if (!isSelf)
                IconButton(
                  icon: const Icon(Icons.edit_rounded,
                      size: 20, color: Colors.deepPurple),
                  onPressed: () => _showEditDialog(context,
                      isAdmin: isAdmin,
                      isMaster: isMaster,
                      calendarEnabled: calendarEnabled,
                      managedGroupIds: managedGroupIds),
                ),
            ]),

            // ── Λεπτομέρειες οδηγού (όχημα, πινακίδα, κ.λπ.) ───────────────
            // Εμφανίζονται έντονα για εκκρεμείς (μη εγκεκριμένους) ώστε ο
            // master να καταλαβαίνει ΠΟΙΟΣ είναι πριν δώσει άδεια.
            _DriverDetails(data: data, highlight: !isApproved && !isSelf),

            // Managed groups
            if (isAdmin && managedGroupIds.isNotEmpty) ...[
              const SizedBox(height: 8),
              _ManagedGroupsRow(groupIds: managedGroupIds),
            ] else if (isAdmin && managedGroupIds.isEmpty) ...[
              const SizedBox(height: 6),
              Text('Βλέπει όλες τις ομάδες',
                  style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey[500],
                      fontStyle: FontStyle.italic)),
            ],

            // ── Άδεια πρόσβασης (approval) ──────────────────────────────
            if (!isSelf) ...[
              const SizedBox(height: 10),
              const Divider(height: 1),
              const SizedBox(height: 6),
              Row(children: [
                Icon(
                  isApproved
                      ? Icons.verified_user_rounded
                      : Icons.gpp_bad_rounded,
                  size: 18,
                  color: isApproved ? Colors.green : Colors.red,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(
                  isApproved
                      ? 'Έχει άδεια πρόσβασης'
                      : 'ΧΩΡΙΣ άδεια — δεν έχει πρόσβαση',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: isApproved
                          ? Colors.green.shade700
                          : Colors.red.shade700),
                )),
                Switch(
                  value: isApproved,
                  activeThumbColor: Colors.green,
                  onChanged: (v) => _toggleApproval(context, v),
                ),
              ]),
            ],

            // ── Πλήρης διαγραφή χρήστη (μόνο master, όχι ο εαυτός του) ──────
            if (!isSelf) ...[
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: AppButton(
                  label: 'Διαγραφή χρήστη',
                  icon: Icons.delete_forever_rounded,
                  color: Colors.red,
                  onPressed: () => _deleteUser(context, name),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _deleteUser(BuildContext context, String name) async {
    final shown = name.trim().isEmpty ? '(χωρίς όνομα)' : name.trim();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(children: [
          Icon(Icons.warning_amber_rounded, color: Colors.red.shade700),
          const SizedBox(width: 10),
          const Expanded(child: Text('Διαγραφή χρήστη;')),
        ]),
        content: Text(
          'Είσαι σίγουρος; Ο χρήστης «$shown» θα αφαιρεθεί ΟΡΙΣΤΙΚΑ από '
          'παντού:\n\n'
          '• τις ομάδες (μέλη & διαχείριση)\n'
          '• τις χρεώσεις του\n'
          '• την πρόσβαση στην εφαρμογή\n\n'
          'Η ενέργεια δεν αναιρείται.',
          style: const TextStyle(fontSize: 13.5),
        ),
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

    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await JobService.deleteUserCompletely(docId);
      messenger?.showSnackBar(
        SnackBar(content: Text('Ο χρήστης «$shown» διαγράφηκε.')),
      );
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Σφάλμα διαγραφής: $e')),
      );
    }
  }

  Future<void> _toggleApproval(BuildContext context, bool approve) async {
    if (!approve) {
      // Επιβεβαίωση πριν την αφαίρεση άδειας
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20)),
          title: const Text('Αφαίρεση άδειας;'),
          content: const Text(
              'Ο οδηγός δεν θα μπορεί πλέον να χρησιμοποιεί την εφαρμογή. '
              'Συνέχεια;'),
          actions: [
            AppButtonTonal(label: 'Άκυρο', onPressed: () => Navigator.pop(ctx, false)),
            AppButton(label: 'Αφαίρεση', color: Colors.red, onPressed: () => Navigator.pop(ctx, true)),
          ],
        ),
      );
      if (ok != true) return;
    }
    await FirebaseFirestore.instance
        .collection('presence')
        .doc(docId)
        .update({'isApproved': approve});
  }

  Future<void> _showEditDialog(
    BuildContext context, {
    required bool         isAdmin,
    required bool         isMaster,
    required bool         calendarEnabled,
    required List<String> managedGroupIds,
  }) async {
    // Φόρτωσε ομάδες
    final groupsSnap = await FirebaseFirestore.instance
        .collection('groups')
        .orderBy('name')
        .get();
    final allGroups = groupsSnap.docs
        .map((d) => _GroupOption(id: d.id, name: d.data()['name'] ?? ''))
        .toList();

    if (!context.mounted) return;

    // Τοπική κατάσταση για το dialog
    bool   selAdmin  = isAdmin;
    bool   selMaster = isMaster;
    bool   selCalendar = calendarEnabled;
    final  selGroupIds = <String>{...managedGroupIds};

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20)),
          title: Row(children: [
            const Icon(Icons.manage_accounts_rounded,
                color: Colors.deepPurple),
            const SizedBox(width: 10),
            Expanded(child: Text(
              '${data['displayName'] ?? ''} ${data['lastName'] ?? ''}'.trim(),
              style: const TextStyle(fontWeight: FontWeight.bold,
                  fontSize: 15),
            )),
          ]),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Ρόλος ──────────────────────────────────────────
                const Text('Ρόλος',
                    style: TextStyle(fontWeight: FontWeight.bold,
                        fontSize: 13)),
                const SizedBox(height: 6),

                // Οδηγός
                _roleOption(
                  ctx: ctx, setS: setS,
                  icon: Icons.local_taxi_rounded,
                  label: 'Οδηγός',
                  subtitle: 'Βλέπει μόνο τις δουλειές του',
                  color: Colors.grey,
                  selected: !selAdmin && !selMaster,
                  onTap: () => setS(() {
                    selAdmin  = false;
                    selMaster = false;
                    selGroupIds.clear();
                  }),
                ),
                const SizedBox(height: 6),

                // Διαχειριστής
                _roleOption(
                  ctx: ctx, setS: setS,
                  icon: Icons.admin_panel_settings_rounded,
                  label: 'Διαχειριστής',
                  subtitle: 'Διαχειρίζεται δουλειές ομάδων',
                  color: Colors.amber.shade800,
                  selected: selAdmin && !selMaster,
                  onTap: () => setS(() {
                    selAdmin  = true;
                    selMaster = false;
                  }),
                ),
                const SizedBox(height: 6),

                // Master
                _roleOption(
                  ctx: ctx, setS: setS,
                  icon: Icons.stars_rounded,
                  label: 'Master',
                  subtitle: 'Πλήρης πρόσβαση + ορισμός διαχειριστών',
                  color: Colors.deepPurple,
                  selected: selMaster,
                  onTap: () => setS(() {
                    selAdmin  = true;
                    selMaster = true;
                    selGroupIds.clear();
                  }),
                ),

                // ── Ομάδες (μόνο αν admin, όχι master) ───────────
                if (selAdmin && !selMaster && allGroups.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Text('Ομάδες Διαχείρισης',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 13)),
                  Text(
                    'Αν δεν επιλεχθεί καμία → βλέπει όλες',
                    style: TextStyle(
                        fontSize: 11, color: Colors.grey[500]),
                  ),
                  const SizedBox(height: 8),
                  ...allGroups.map((g) => CheckboxListTile(
                    dense:          true,
                    activeColor:    Colors.amber.shade800,
                    title:          Text(g.name,
                        style: const TextStyle(fontSize: 13)),
                    value:          selGroupIds.contains(g.id),
                    onChanged:      (v) => setS(() {
                      if (v == true) {
                        selGroupIds.add(g.id);
                      } else {
                        selGroupIds.remove(g.id);
                      }
                    }),
                    controlAffinity: ListTileControlAffinity.leading,
                  )),
                ],

                // ── Πρόσβαση στο Ημερολόγιο (admin ή master) ─────
                if (selAdmin || selMaster) ...[
                  const SizedBox(height: 16),
                  const Divider(height: 1),
                  const SizedBox(height: 8),
                  Container(
                    decoration: BoxDecoration(
                      color: selCalendar
                          ? Colors.deepPurple.withValues(alpha: 0.08)
                          : Colors.grey.shade50,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: selCalendar
                            ? Colors.deepPurple.withValues(alpha: 0.4)
                            : Colors.grey.shade200,
                      ),
                    ),
                    child: SwitchListTile(
                      dense: true,
                      activeThumbColor: Colors.deepPurple,
                      secondary: Icon(Icons.calendar_month_rounded,
                          color: selCalendar
                              ? Colors.deepPurple
                              : Colors.grey),
                      title: const Text('Πρόσβαση στο Ημερολόγιο',
                          style: TextStyle(
                              fontSize: 13, fontWeight: FontWeight.bold)),
                      subtitle: Text(
                        'Σύνδεση Google Calendar & μετατροπή ραντεβού',
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey[600]),
                      ),
                      value: selCalendar,
                      onChanged: (v) => setS(() => selCalendar = v),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            AppButtonTonal(label: 'Άκυρο', onPressed: () => Navigator.pop(ctx)),
            AppButton(
              label: 'Αποθήκευση',
              color: Colors.deepPurple,
              onPressed: () async {
                Navigator.pop(ctx);
                await _saveRole(
                  isAdmin:         selAdmin,
                  isMaster:        selMaster,
                  calendarEnabled: selCalendar,
                  managedGroupIds: selGroupIds.toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _roleOption({
    required BuildContext ctx,
    required StateSetter  setS,
    required IconData     icon,
    required String       label,
    required String       subtitle,
    required Color        color,
    required bool         selected,
    required VoidCallback onTap,
  }) =>
      GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? color.withValues(alpha: 0.1)
                : Colors.grey.shade50,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected
                  ? color.withValues(alpha: 0.6)
                  : Colors.grey.shade200,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(children: [
            Icon(icon, color: selected ? color : Colors.grey, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: selected ? color : Colors.black87)),
                Text(subtitle,
                    style: TextStyle(
                        fontSize: 11, color: Colors.grey[500])),
              ],
            )),
            if (selected)
              Icon(Icons.check_circle_rounded, color: color, size: 18),
          ]),
        ),
      );

  Future<void> _saveRole({
    required bool         isAdmin,
    required bool         isMaster,
    required bool         calendarEnabled,
    required List<String> managedGroupIds,
  }) async {
    final fs = FirebaseFirestore.instance;

    // 1. Ενημέρωσε presence
    await fs.collection('presence').doc(docId).update({
      'admin':           isAdmin,
      'master':          isMaster,
      'calendarEnabled': calendarEnabled,
      'managedGroupIds': managedGroupIds,
    });

    // 2. Συγχρόνισε adminUids σε όλες τις ομάδες
    //    Αν ο χρήστης είναι admin για κάποια ομάδα → προσθήκη.
    //    Αν δεν είναι πια admin για κάποια ομάδα → αφαίρεση.
    final allGroups = await fs.collection('groups').get();
    final batch     = fs.batch();
    bool hasWrites  = false;

    for (final g in allGroups.docs) {
      final admins = List<String>.from(g.data()['adminUids'] ?? []);
      final shouldBeAdmin = isAdmin && managedGroupIds.contains(g.id);
      final isCurrently   = admins.contains(docId);

      if (shouldBeAdmin && !isCurrently) {
        admins.add(docId);
        batch.update(g.reference, {'adminUids': admins});
        hasWrites = true;
      } else if (!shouldBeAdmin && isCurrently) {
        admins.remove(docId);
        batch.update(g.reference, {'adminUids': admins});
        hasWrites = true;
      }
    }

    if (hasWrites) await batch.commit();
  }
}

// ─── Λεπτομέρειες οδηγού ───────────────────────────────────────────────────────

class _DriverDetails extends StatelessWidget {
  final Map<String, dynamic> data;
  final bool                 highlight;
  const _DriverDetails({required this.data, required this.highlight});

  @override
  Widget build(BuildContext context) {
    final vehicleModel = (data['vehicleModel'] as String? ?? '').trim();
    final plateNumber  = (data['plateNumber']  as String? ?? '').trim();
    final referredBy   = (data['referredBy']   as String? ?? '').trim();
    final isVan        = (data['vehicleType']  as String?) == VehicleType.van.name;
    final vehicleLabel = isVan ? 'Van' : 'Taxi';

    final rows = <Widget>[
      if (vehicleModel.isNotEmpty)
        _detailRow(Icons.directions_car_rounded, 'Όχημα', vehicleModel),
      if (plateNumber.isNotEmpty)
        _detailRow(Icons.confirmation_number_rounded, 'Πινακίδα', plateNumber),
      _detailRow(
        isVan ? Icons.airport_shuttle_rounded : Icons.local_taxi_rounded,
        'Τύπος',
        vehicleLabel,
      ),
      if (referredBy.isNotEmpty)
        _detailRow(Icons.person_add_alt_1_rounded, 'Πρόταση από', referredBy),
    ];

    if (rows.isEmpty) return const SizedBox.shrink();

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: rows,
    );

    if (!highlight) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: content,
      );
    }

    // Εκκρεμής χρήστης → έντονο πλαίσιο για να ξεχωρίζει
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color:        Colors.amber.shade50,
        borderRadius: BorderRadius.circular(10),
        border:       Border.all(color: Colors.amber.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.badge_rounded, size: 15, color: Colors.amber.shade900),
            const SizedBox(width: 6),
            Text('Στοιχεία οδηγού',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.amber.shade900)),
          ]),
          const SizedBox(height: 6),
          content,
        ],
      ),
    );
  }

  Widget _detailRow(IconData icon, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 15, color: Colors.grey.shade600),
          const SizedBox(width: 8),
          Text('$label: ',
              style: TextStyle(
                  fontSize: 12.5,
                  color: Colors.grey.shade600)),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w600)),
          ),
        ]),
      );
}

// ─── Chip ομάδων ──────────────────────────────────────────────────────────────

class _ManagedGroupsRow extends StatelessWidget {
  final List<String> groupIds;
  const _ManagedGroupsRow({required this.groupIds});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<QuerySnapshot<Map<String, dynamic>>>(
      future: FirebaseFirestore.instance.collection('groups').get(),
      builder: (ctx, snap) {
        if (!snap.hasData) return const SizedBox.shrink();
        final names = snap.data!.docs
            .where((d) => groupIds.contains(d.id))
            .map((d) => d.data()['name'] as String? ?? '')
            .where((n) => n.isNotEmpty)
            .toList();

        return Wrap(spacing: 6, runSpacing: 4, children: names.map((n) =>
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color:        Colors.amber.shade50,
              borderRadius: BorderRadius.circular(8),
              border:       Border.all(color: Colors.amber.shade300),
            ),
            child: Text(n,
                style: TextStyle(
                    fontSize: 11,
                    color:      Colors.amber.shade900,
                    fontWeight: FontWeight.w600)),
          ),
        ).toList());
      },
    );
  }
}

// ─── Helper ───────────────────────────────────────────────────────────────────

class _GroupOption {
  final String id;
  final String name;
  const _GroupOption({required this.id, required this.name});
}
