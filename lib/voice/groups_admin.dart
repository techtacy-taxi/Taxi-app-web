// lib/voice/groups_admin.dart

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

import '../jobs/job_service.dart';
import '../jobs/job_shared_widgets.dart';
import 'voice_models.dart';
import 'voice_service.dart';

class GroupsAdminPage extends StatefulWidget {
  final String uid;

  const GroupsAdminPage({super.key, required this.uid});

  @override
  State<GroupsAdminPage> createState() => _GroupsAdminPageState();
}

class _GroupsAdminPageState extends State<GroupsAdminPage> {
  List<VoiceGroup> _groups = [];
  List<Map<String, dynamic>> _drivers = [];
  bool _isLoading = true;
  bool _isAdmin = false;
  bool _isMaster = false;
  String _mainSearchQuery = '';

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _adminSub;

  @override
  void initState() {
    super.initState();
    _listenAdmin();
    _loadData();
  }

  void _listenAdmin() {
    _adminSub = FirebaseFirestore.instance
        .collection('presence')
        .doc(widget.uid)
        .snapshots()
        .listen((doc) {
      if (doc.exists && mounted) {
        final admin  = doc.data()?['admin']  ?? false;
        final master = doc.data()?['master'] ?? false;
        if (admin != _isAdmin || master != _isMaster) {
          setState(() {
            _isAdmin  = admin || master;  // master είναι και admin
            _isMaster = master;
          });
        }
      }
    });
  }

  /// Έλεγχος αν ο τρέχων χρήστης μπορεί να διαχειριστεί τη συγκεκριμένη ομάδα.
  bool _canManageGroup(VoiceGroup g) {
    if (_isMaster) return true;
    if (!_isAdmin) return false;
    // Συμβατότητα με παλιά: αν δεν υπάρχει adminUids, χρησιμοποίησε createdBy
    if (g.adminUids.isNotEmpty) return g.adminUids.contains(widget.uid);
    return g.createdBy == widget.uid;
  }

  /// Οι ομάδες που "βλέπει" ο τρέχων χρήστης.
  List<VoiceGroup> get _visibleGroups {
    if (_isMaster) return _groups;
    if (!_isAdmin) return _groups; // οδηγός βλέπει όλες (read-only)
    // admin: μόνο όσες διαχειρίζεται
    return _groups.where(_canManageGroup).toList();
  }

  /// UIDs μελών που βρίσκονται σε ομάδες που διαχειρίζεται ο τρέχων admin.
  Set<String> get _membersInMyGroups {
    final s = <String>{};
    for (final g in _groups.where(_canManageGroup)) {
      s.addAll(g.memberUids);
    }
    return s;
  }

  @override
  void dispose() {
    _adminSub?.cancel();
    super.dispose();
  }

  Future<void> _loadData() async {
    final fs = FirebaseFirestore.instance;
    final snaps = await Future.wait([
      fs.collection('groups').get(),
      fs.collection('presence').get(),
    ]);

    if (!mounted) return;
    setState(() {
      _groups = snaps[0].docs.map((d) => VoiceGroup.fromDoc(d)).toList();
      _drivers = snaps[1].docs.map((d) {
        final data = d.data();
        data['uid'] = d.id;
        return data;
      }).toList();
      _isLoading = false;
    });
  }

  void _showGroupDialog({VoiceGroup? group}) {
    final nameController = TextEditingController(text: group?.name ?? '');
    Color selectedColor = group?.color ?? const Color(0xFF1565C0);
    Set<String> selectedUids = Set.from(group?.memberUids ?? []);
    String dialogSearchQuery = '';

    // Κοινή πρόσβαση δουλειών (επεξεργάσιμο αντίγραφο):
    // { ownerUid: { viewerUid: 'view'|'send'|'full' } }
    final Map<String, Map<String, String>> shares = {
      for (final e in (group?.savedJobShares ?? {}).entries)
        e.key: Map<String, String>.from(e.value),
    };
    // Ποιον admin ρυθμίζει ο master αυτή τη στιγμή (όψη master).
    // Για admin: πάντα ο εαυτός του.
    String shareOwner = widget.uid;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final filteredDialogDrivers = _drivers.where((d) {
              final fullName = '${d['displayName'] ?? ''} ${d['lastName'] ?? ''}'.toLowerCase();
              return fullName.contains(dialogSearchQuery.toLowerCase());
            }).toList();

            return AlertDialog(
              titlePadding: EdgeInsets.zero,
              title: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                decoration: const BoxDecoration(
                  color: Colors.amber,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
                ),
                child: Row(children: [
                  Icon(group == null
                      ? Icons.group_add_rounded
                      : Icons.edit_rounded,
                      color: Colors.black87, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                        group == null ? 'Νέα Ομάδα' : 'Επεξεργασία Ομάδας',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                            color: Colors.black87)),
                  ),
                ]),
              ),
              content: SizedBox(
                width: double.maxFinite,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        controller: nameController,
                        decoration: const InputDecoration(
                          labelText: 'Όνομα Ομάδας *',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 20),
                      const Text('Επιλογή Χρώματος', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      ColorPicker(
                        pickerColor: selectedColor,
                        onColorChanged: (Color color) {
                          setDialogState(() => selectedColor = color);
                        },
                        colorPickerWidth: 260,
                        pickerAreaHeightPercent: 0.6,
                        enableAlpha: false,
                        displayThumbColor: true,
                        paletteType: PaletteType.hsvWithHue,
                        labelTypes: const [],
                        pickerAreaBorderRadius: const BorderRadius.all(Radius.circular(12)),
                      ),
                      const SizedBox(height: 20),
                      const Divider(),
                      const Text('Επιλογή Μελών', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      TextField(
                        decoration: InputDecoration(
                          hintText: 'Αναζήτηση οδηγού...',
                          prefixIcon: const Icon(Icons.search, size: 20),
                          filled: true,
                          fillColor: Colors.grey[100],
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                          contentPadding: EdgeInsets.zero,
                        ),
                        onChanged: (val) {
                          setDialogState(() => dialogSearchQuery = val);
                        },
                      ),
                      const SizedBox(height: 10),
                      Container(
                        height: 200,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade300),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: filteredDialogDrivers.isEmpty
                            ? const Center(child: Text('Κανένας οδηγός'))
                            : ListView.builder(
                          shrinkWrap: true,
                          itemCount: filteredDialogDrivers.length,
                          itemBuilder: (context, index) {
                            final d = filteredDialogDrivers[index];
                            final uid = d['uid'] as String;
                            final name = '${d['displayName'] ?? ''} ${d['lastName'] ?? ''}'.trim();
                            return CheckboxListTile(
                              title: Text(name, style: const TextStyle(fontSize: 14)),
                              value: selectedUids.contains(uid),
                              activeColor: selectedColor,
                              onChanged: (val) {
                                setDialogState(() {
                                  if (val == true) {
                                    selectedUids.add(uid);
                                  } else {
                                    selectedUids.remove(uid);
                                  }
                                });
                              },
                            );
                          },
                        ),
                      ),

                      // ── Κοινή θέα αποθηκευμένων/ανοιχτών δουλειών ──────────
                      ..._buildSharingSection(
                        group: group,
                        shares: shares,
                        shareOwner: shareOwner,
                        setDialogState: setDialogState,
                        onOwnerChange: (v) =>
                            setDialogState(() => shareOwner = v),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                AppButtonTonal(label: 'Ακύρωση', onPressed: () => Navigator.pop(ctx)),
                AppButton(
                  label: 'Αποθήκευση',
                  color: Colors.amber,
                  onPressed: () async {
                    if (nameController.text.trim().isEmpty) return;
                    Navigator.pop(ctx);
                    setState(() => _isLoading = true);

                    final data = <String, dynamic>{
                      'name':       nameController.text.trim(),
                      'colorHex':   VoiceGroup.colorToHex(selectedColor),
                      'memberUids': selectedUids.toList(),
                    };
                    // Καθάρισμα κενών εγγραφών και αποθήκευση κοινής πρόσβασης
                    final cleanShares = <String, Map<String, String>>{};
                    shares.forEach((owner, m) {
                      final mm = <String, String>{};
                      m.forEach((v, lvl) {
                        if (lvl == 'view' || lvl == 'send' || lvl == 'full') {
                          mm[v] = lvl;
                        }
                      });
                      if (mm.isNotEmpty) cleanShares[owner] = mm;
                    });
                    data['savedJobShares'] = cleanShares;

                    if (group == null) {
                      // Νέα ομάδα: createdBy + adminUids = αυτός που τη φτιάχνει
                      data['createdBy'] = widget.uid;
                      data['adminUids'] = [widget.uid];
                      final ref = await FirebaseFirestore.instance
                          .collection('groups').add(data);
                      // Σπιτική ομάδα: κλειδώνεται 1η φορά για κάθε μέλος
                      for (final m in selectedUids) {
                        await JobService.ensureHomeGroup(m, ref.id);
                      }
                    } else {
                      // Edit: δεν αλλάζουμε adminUids εδώ (μόνο master το αλλάζει)
                      await FirebaseFirestore.instance
                          .collection('groups').doc(group.id).update(data);
                      for (final m in selectedUids) {
                        await JobService.ensureHomeGroup(m, group.id);
                      }
                    }
                    _loadData();
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }

  // Όνομα admin/οδηγού από το presence cache (_drivers).
  String _nameOfUid(String uid) {
    final d = _drivers.firstWhere(
      (e) => e['uid'] == uid,
      orElse: () => const {},
    );
    final n = '${d['displayName'] ?? ''} ${d['lastName'] ?? ''}'.trim();
    return n.isEmpty ? uid : n;
  }

  String _initialsOfUid(String uid) {
    final n = _nameOfUid(uid).trim();
    if (n.isEmpty || n == uid) return '?';
    final parts = n.split(RegExp(r'\s+'));
    if (parts.length == 1) {
      return parts.first.substring(0, 1).toUpperCase();
    }
    return (parts.first.substring(0, 1) + parts[1].substring(0, 1))
        .toUpperCase();
  }

  /// Είναι ο συγκεκριμένος uid master; (ο master βλέπει/χειρίζεται τα πάντα
  /// ούτως ή άλλως — δεν έχει νόημα να ορίζεται κοινή πρόσβαση γι' αυτόν.)
  bool _isUidMaster(String uid) {
    final d = _drivers.firstWhere(
      (e) => e['uid'] == uid,
      orElse: () => const {},
    );
    return d['master'] == true;
  }

  /// Τμήμα «Κοινή θέα» μέσα στο dialog ομάδας.
  /// Εμφανίζεται μόνο όταν η (υπάρχουσα) ομάδα έχει 2+ admins (χωρίς master).
  List<Widget> _buildSharingSection({
    required VoiceGroup? group,
    required Map<String, Map<String, String>> shares,
    required String shareOwner,
    required StateSetter setDialogState,
    required ValueChanged<String> onOwnerChange,
  }) {
    if (group == null) return const []; // νέα ομάδα: αποθήκευσε πρώτα
    // Ο master εξαιρείται εντελώς — βλέπει/επεξεργάζεται/διαγράφει τα πάντα.
    final admins = group.adminUids.where((u) => !_isUidMaster(u)).toList();
    if (admins.length < 2) return const [];

    // Ποιον ρυθμίζουμε: master → επιλέξιμο, admin → πάντα ο εαυτός του.
    final owner = _isMaster ? shareOwner : widget.uid;
    if (!admins.contains(owner) && admins.isNotEmpty) {
      // ασφάλεια: αν ο owner δεν είναι (μη-master) admin εδώ, διάλεξε τον πρώτο
      onOwnerChange(admins.first);
    }
    final others = admins.where((u) => u != owner).toList();
    final ownerMap = shares[owner] ?? const {};

    return [
      const SizedBox(height: 20),
      const Divider(),
      Row(children: const [
        Icon(Icons.visibility_rounded, size: 18, color: Color(0xFF534AB7)),
        SizedBox(width: 6),
        Expanded(
          child: Text('Κοινή θέα δουλειών',
              style: TextStyle(fontWeight: FontWeight.bold)),
        ),
      ]),
      const SizedBox(height: 8),
      if (_isMaster) ...[
        // Επιλογή «ποιον admin ρυθμίζω» — πλαίσιο που μεγαλώνει σε 2 σειρές.
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFFFFF7E6),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFF0D89B)),
          ),
          child: Row(children: [
            const Text('Ρυθμίζω: ',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF854F0B))),
            Expanded(
              child: DropdownButton<String>(
                isExpanded: true,
                value: owner,
                underline: const SizedBox.shrink(),
                isDense: false,
                items: admins
                    .map((u) => DropdownMenuItem(
                          value: u,
                          child: Text(_nameOfUid(u),
                              softWrap: true,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600, fontSize: 13.5)),
                        ))
                    .toList(),
                selectedItemBuilder: (_) => admins
                    .map((u) => Text(_nameOfUid(u),
                        maxLines: 2,
                        softWrap: true,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 13.5)))
                    .toList(),
                onChanged: (v) {
                  if (v != null) onOwnerChange(v);
                },
              ),
            ),
          ]),
        ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
              'Τι μπορούν οι άλλοι admin να κάνουν με τις δουλειές του «${_nameOfUid(owner)}».',
              style: const TextStyle(fontSize: 12, color: Colors.black45)),
        ),
      ] else
        const Padding(
          padding: EdgeInsets.only(bottom: 4),
          child: Text(
              'Διάλεξε τι μπορεί κάθε admin να κάνει με τις δικές σου δουλειές.',
              style: TextStyle(fontSize: 12, color: Colors.black45)),
        ),
      ...others.map((viewer) {
        final current = shareLevelFromString(ownerMap[viewer]);
        // αμοιβαίο: ο viewer έχει δώσει κι αυτός στον owner
        final reverse = shareLevelFromString(shares[viewer]?[owner]);
        final isBoth = current != ShareLevel.none && reverse != ShareLevel.none;
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: current == ShareLevel.none
                ? Colors.grey.shade50
                : const Color(0xFFF6F4FE),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: current == ShareLevel.none
                    ? Colors.grey.shade200
                    : const Color(0xFFD9D2F5)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: Colors.amber.shade100,
                  child: Text(_initialsOfUid(viewer),
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Colors.amber.shade800)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_nameOfUid(viewer),
                          maxLines: 2,
                          softWrap: true,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w500)),
                      Text(
                        current == ShareLevel.none
                            ? 'δεν έχει πρόσβαση'
                            : (isBoth ? 'αμοιβαίο ✓' : 'μονόδρομο'),
                        style: TextStyle(
                            fontSize: 11,
                            color: current == ShareLevel.none
                                ? Colors.black38
                                : (isBoth
                                    ? const Color(0xFF0F6E56)
                                    : const Color(0xFF1565C0)),
                            fontWeight:
                                isBoth ? FontWeight.w600 : FontWeight.normal),
                      ),
                    ],
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              // Dropdown επιπέδου — πλήρες πλάτος, μεγάλη ετικέτα.
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: current == ShareLevel.none
                          ? Colors.grey.shade300
                          : const Color(0xFF534AB7)),
                ),
                child: DropdownButton<ShareLevel>(
                  value: current,
                  isExpanded: true,
                  underline: const SizedBox.shrink(),
                  icon: const Icon(Icons.keyboard_arrow_down_rounded),
                  items: ShareLevel.values
                      .map((lv) => DropdownMenuItem(
                            value: lv,
                            child: Text(_levelLabel(lv),
                                softWrap: true,
                                style: const TextStyle(fontSize: 13)),
                          ))
                      .toList(),
                  onChanged: (lv) {
                    if (lv == null) return;
                    setDialogState(() {
                      final m = shares.putIfAbsent(owner, () => {});
                      if (lv == ShareLevel.none) {
                        m.remove(viewer);
                        if (m.isEmpty) shares.remove(owner);
                      } else {
                        m[viewer] = lv.wire;
                      }
                    });
                  },
                ),
              ),
            ],
          ),
        );
      }),
    ];
  }

  String _levelLabel(ShareLevel lv) {
    switch (lv) {
      case ShareLevel.none: return 'Κλειστό';
      case ShareLevel.view: return 'Εμφάνιση';
      case ShareLevel.send: return 'Εμφάνιση + αποστολή/επεξεργασία';
      case ShareLevel.full: return 'Εμφάνιση + όλα + διαγραφή';
    }
  }

  void _deleteGroup(VoiceGroup group) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Διαγραφή Ομάδας'),
        content: Text('Θέλετε να διαγράψετε την ομάδα "${group.name}";'),
        actions: [
          AppButtonTonal(label: 'Ακύρωση', onPressed: () => Navigator.pop(ctx, false)),
          AppButton(label: 'Διαγραφή', color: Colors.red, onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
    );

    if (confirm == true) {
      setState(() => _isLoading = true);
      await FirebaseFirestore.instance.collection('groups').doc(group.id).delete();
      _loadData();
    }
  }

  /// ── Μόνο για master: διόρθωση tenantId ενός admin/οδηγού.
  /// Κρίσιμο όταν πελάτες/διαδρομές που δημιουργεί ένας admin δεν
  /// εμφανίζονται στη δημόσια φόρμα — συνήθως γιατί το tenantId του
  /// admin δεν είναι "default" (ή λείπει και κάπου αλλού υπολογίζεται
  /// διαφορετικά). Αυτό ΔΕΝ μετακινεί ήδη υπάρχοντες πελάτες· αλλάζει
  /// μόνο το presence του admin, ώστε ΝΕΟΙ πελάτες που θα φτιάξει από
  /// εδώ και πέρα να αποθηκευτούν με το σωστό tenantId.
  void _showEditTenantIdDialog(String uid, String name, String currentTenantId) {
    final ctrl = TextEditingController(text: currentTenantId);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('tenantId — ${name.isEmpty ? 'Άγνωστος' : name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Οι πελάτες/διαδρομές που δημιουργεί αυτός ο admin αποθηκεύονται '
              'με ΑΥΤΟ το tenantId. Άφησέ το κενό ή γράψε "default" αν θέλεις '
              'να ανήκει στον ίδιο (δικό σου) λογαριασμό με εσένα.',
              style: TextStyle(fontSize: 12.5, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              decoration: const InputDecoration(
                labelText: 'tenantId',
                hintText: 'default',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          AppButtonTonal(label: 'Ακύρωση', onPressed: () => Navigator.pop(ctx)),
          AppButton(
            label: 'Αποθήκευση',
            onPressed: () async {
              final newValue = ctrl.text.trim().isEmpty ? 'default' : ctrl.text.trim();
              Navigator.pop(ctx);
              await FirebaseFirestore.instance
                  .collection('presence')
                  .doc(uid)
                  .set({'tenantId': newValue}, SetOptions(merge: true));
              _loadData();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text('tenantId ενημερώθηκε σε "$newValue"'),
                  backgroundColor: Colors.green,
                ));
              }
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filteredDrivers = _drivers.where((d) {
      final name = '${d['displayName'] ?? ''} ${d['lastName'] ?? ''}'.toLowerCase();
      return name.contains(_mainSearchQuery.toLowerCase());
    }).toList();

    return Scaffold(
      backgroundColor: const Color(0xFFF8F8F8),
      appBar: AppBar(
        title: const Text('Ομάδες & Οδηγοί', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.amber,
        foregroundColor: Colors.black,
      ),
      floatingActionButton: _isMaster
          ? FloatingActionButton.extended(
        onPressed: () => _showGroupDialog(),
        backgroundColor: Colors.amber,
        icon: const Icon(Icons.group_add_rounded),
        label: const Text('Νέα Ομάδα', style: TextStyle(fontWeight: FontWeight.bold)),
      )
          : null,
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.amber))
          : ListView(
        padding: const EdgeInsets.only(bottom: 100),
        children: [
          _SectionTitle(label: _isMaster ? 'Όλες οι Ομάδες' : 'Οι Ομάδες μου'),
          if (_visibleGroups.isEmpty)
            const Padding(padding: EdgeInsets.all(16.0),
                child: Text('Δεν υπάρχουν ομάδες.')),
          ..._visibleGroups.map((group) {
            final count    = group.memberUids.length;
            final canEdit  = _canManageGroup(group);
            final canDelete = _isMaster;
            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: group.color,
                  child: Icon(Icons.folder_rounded,
                      color: group.color.computeLuminance() > 0.5
                          ? Colors.black : Colors.white),
                ),
                title: Text(group.name,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text('$count μέλη'),
                trailing: (canEdit || canDelete)
                    ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (canEdit)
                      IconButton(
                        icon: const Icon(Icons.edit, color: Colors.blue),
                        onPressed: () => _showGroupDialog(group: group),
                      ),
                    if (canDelete)
                      IconButton(
                        icon: const Icon(Icons.delete, color: Colors.red),
                        onPressed: () => _deleteGroup(group),
                      ),
                  ],
                )
                    : null,
              ),
            );
          }),

          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Αναζήτηση οδηγού στη λίστα...',
                prefixIcon: const Icon(Icons.search),
                filled: true, fillColor: Colors.white,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
              onChanged: (val) => setState(() => _mainSearchQuery = val),
            ),
          ),

          const SizedBox(height: 16),
          const _SectionTitle(label: 'Όλοι οι Οδηγοί'),
          ...filteredDrivers.map((d) {
            final dUid = d['uid'] as String;
            final name = '${d['displayName'] ?? ''} ${d['lastName'] ?? ''}'.trim();
            final plate = d['plateNumber'] ?? '';
            final vehicle = d['vehicleType'] ?? 'taxi';
            final canSend = d['canSend'] ?? true;
            final email = d['email'] ?? 'Χωρίς email';
            final isMe = dUid == widget.uid;

            final dGroups = _groups.where((g) => g.memberUids.contains(dUid)).toList();

            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: Colors.amber.shade100,
                      child: Text(name.isNotEmpty ? name[0] : '?', style: TextStyle(color: Colors.amber.shade800, fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(name.isEmpty ? 'Άγνωστος' : name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                            const SizedBox(height: 2),
                            Row(children: [
                              Icon(vehicle == 'van' ? Icons.airport_shuttle_rounded : Icons.local_taxi_rounded, size: 12, color: Colors.grey[400]),
                              const SizedBox(width: 4),
                              Text(plate.isNotEmpty ? plate : vehicle, style: TextStyle(fontSize: 11, color: Colors.grey[500])),
                            ]),
                            const SizedBox(height: 2),
                            Text(email, style: TextStyle(fontSize: 10, color: Colors.blueGrey[400])),
                            // ── Μόνο για master: δείχνει το tenantId του
                            // χρήστη — κρίσιμο γιατί οι πελάτες/διαδρομές
                            // που δημιουργεί κάθε admin αποθηκεύονται με ΤΟ
                            // ΔΙΚΟ ΤΟΥ tenantId. Αν διαφέρει από "default"
                            // (ή είναι κενό), οι πελάτες του ΔΕΝ εμφανίζονται
                            // ποτέ στη δημόσια φόρμα (που πάντα ζητά "default"),
                            // ακόμα κι αν το «μάτι» hideOthers είναι ανοιχτό.
                            if (_isMaster) ...[
                              const SizedBox(height: 4),
                              InkWell(
                                onTap: () => _showEditTenantIdDialog(dUid, name, (d['tenantId'] as String?) ?? ''),
                                borderRadius: BorderRadius.circular(6),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: ((d['tenantId'] as String?) ?? '').isEmpty || (d['tenantId'] as String?) == 'default'
                                        ? Colors.green.shade50
                                        : Colors.orange.shade50,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: ((d['tenantId'] as String?) ?? '').isEmpty || (d['tenantId'] as String?) == 'default'
                                          ? Colors.green.shade200
                                          : Colors.orange.shade300,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.storefront_rounded, size: 11,
                                          color: ((d['tenantId'] as String?) ?? '').isEmpty || (d['tenantId'] as String?) == 'default'
                                              ? Colors.green.shade700 : Colors.orange.shade800),
                                      const SizedBox(width: 3),
                                      Text(
                                        'tenantId: ${((d['tenantId'] as String?)?.isNotEmpty ?? false) ? d['tenantId'] : '(κενό → default)'}',
                                        style: TextStyle(
                                          fontSize: 10, fontWeight: FontWeight.w600,
                                          color: ((d['tenantId'] as String?) ?? '').isEmpty || (d['tenantId'] as String?) == 'default'
                                              ? Colors.green.shade800 : Colors.orange.shade900,
                                        ),
                                      ),
                                      const SizedBox(width: 3),
                                      Icon(Icons.edit, size: 10, color: Colors.grey.shade500),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                            if (dGroups.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 4, runSpacing: 4,
                                children: dGroups.map((g) => GroupBadge(name: g.name, color: g.color)).toList(),
                              ),
                            ],
                          ],
                        )
                    ),
                    if (_isAdmin && !isMe && (_isMaster || _membersInMyGroups.contains(dUid)))
                      Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.mic_rounded, size: 16, color: canSend ? Colors.green : Colors.grey[300]),
                            const SizedBox(width: 4),
                            Switch(
                                value: canSend,
                                activeThumbColor: Colors.amber,
                                onChanged: (v) {
                                  setState(() {
                                    final index = _drivers.indexWhere((doc) => doc['uid'] == dUid);
                                    if (index != -1) {
                                      final updatedMap = Map<String, dynamic>.from(_drivers[index]);
                                      updatedMap['canSend'] = v;
                                      _drivers[index] = updatedMap;
                                    }
                                  });
                                  VoiceService.toggleCanSend(dUid, v);
                                }
                            ),
                          ]
                      )
                    else if (!canSend)
                      Icon(Icons.mic_off_rounded, size: 18, color: Colors.grey[400]),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String label;
  const _SectionTitle({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Text(
          label.toUpperCase(),
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.grey[600], letterSpacing: 1.2)
      ),
    );
  }
}

class GroupBadge extends StatelessWidget {
  final String name;
  final Color color;

  const GroupBadge({super.key, required this.name, required this.color});

  @override
  Widget build(BuildContext context) {
    final textColor = color.computeLuminance() > 0.5 ? Colors.black : Colors.white;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        name.toUpperCase(),
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: textColor),
      ),
    );
  }
}