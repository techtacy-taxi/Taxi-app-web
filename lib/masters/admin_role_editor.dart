// lib/masters/admin_role_editor.dart
//
// Ανάθεση ρόλου (Οδηγός / Διαχειριστής / Master), Ομάδα, Εγκεκριμένος,
// Διαγραφή — εγκεκριμένο mockup. Ανοίγει από το μολυβάκι της AdminCard
// στο global_settings_page.dart.
//
// Πάνω σε την ίδια λογική που ήδη υπήρχε στο masters_admin_page.dart
// (_showEditDialog / _deleteUser / toggle isApproved) — μόνο νέο UI.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../jobs/job_service.dart';

class AdminRoleEditorPage extends StatefulWidget {
  final String docId;
  final Map<String, dynamic> data;

  const AdminRoleEditorPage({
    super.key,
    required this.docId,
    required this.data,
  });

  @override
  State<AdminRoleEditorPage> createState() => _AdminRoleEditorPageState();
}

enum _Role { driver, admin, master }

class _AdminRoleEditorPageState extends State<AdminRoleEditorPage> {
  late _Role _role;
  late bool  _isApproved;
  String?    _selectedGroupId;
  String?    _selectedGroupName;
  bool _groupsLoading = true;
  List<Map<String, String>> _groups = [];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final d = widget.data;
    _role = d['master'] == true
        ? _Role.master
        : (d['admin'] == true ? _Role.admin : _Role.driver);
    _isApproved = d['isApproved'] == true;
    _selectedGroupId   = d['managedGroupId']   as String?;
    _selectedGroupName = d['managedGroupName'] as String?;
    _loadGroups();
  }

  Future<void> _loadGroups() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('groups')
          .orderBy('name')
          .get();
      if (!mounted) return;
      setState(() {
        _groups = snap.docs
            .map((d) => {'id': d.id, 'name': (d.data()['name'] ?? '') as String})
            .toList();
        _groupsLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _groupsLoading = false);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await FirebaseFirestore.instance
          .collection('presence')
          .doc(widget.docId)
          .set({
        'admin':  _role == _Role.admin  || _role == _Role.master,
        'master': _role == _Role.master,
        'isApproved': _isApproved,
        'managedGroupId':   _selectedGroupId,
        'managedGroupName': _selectedGroupName,
      }, SetOptions(merge: true));
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _confirmDelete() async {
    final c = AppColors.of(context);
    final name = '${widget.data['displayName'] ?? ''} ${widget.data['lastName'] ?? ''}'.trim();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.scaffold,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Διαγραφή χρήστη'),
        content: Text(
          'Θα διαγραφεί οριστικά ο/η "$name" από την εφαρμογή. '
          'Αυτή η ενέργεια δεν αναιρείται.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Άκυρο')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Διαγραφή'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await JobService.deleteUserCompletely(widget.docId);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final name = '${widget.data['displayName'] ?? ''} ${widget.data['lastName'] ?? ''}'.trim();

    return Scaffold(
      backgroundColor: c.scaffold,
      appBar: AppBar(
        title: Text(name.isEmpty ? 'Ρόλος χρήστη' : name),
        backgroundColor: c.scaffold,
        foregroundColor: c.textMain,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Ρόλος χρήστη',
                style: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600, color: c.textMain)),
            const SizedBox(height: 10),

            _roleTile(c,
                role: _Role.driver,
                icon: Icons.local_taxi_rounded,
                title: 'Οδηγός',
                subtitle: 'Βλέπει μόνο τις δικές του δουλειές'),
            const SizedBox(height: 7),
            _roleTile(c,
                role: _Role.admin,
                icon: Icons.admin_panel_settings_rounded,
                title: 'Διαχειριστής',
                subtitle: 'Βλέπει και διαχειρίζεται μια ομάδα οδηγών'),
            const SizedBox(height: 7),
            _roleTile(c,
                role: _Role.master,
                icon: Icons.stars_rounded,
                title: 'Master',
                subtitle: 'Πρόσβαση σε όλη την πλατφόρμα'),

            if (_role != _Role.master) ...[
              const SizedBox(height: 16),
              Text('Ομάδα',
                  style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600, color: c.textFaint)),
              const SizedBox(height: 7),
              _groupsLoading
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Center(
                          child: SizedBox(
                              width: 20, height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2))),
                    )
                  : Container(
                      decoration: BoxDecoration(
                        color:        c.card,
                        borderRadius: BorderRadius.circular(14),
                        border:       Border.all(color: c.cardBorder, width: 0.8),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String?>(
                          isExpanded: true,
                          value: _selectedGroupId,
                          hint: Text('Όλες οι ομάδες',
                              style: TextStyle(fontSize: 13, color: c.textFaint)),
                          dropdownColor: c.card,
                          items: [
                            DropdownMenuItem<String?>(
                              value: null,
                              child: Text('Όλες οι ομάδες',
                                  style: TextStyle(fontSize: 13, color: c.textMain)),
                            ),
                            ..._groups.map((g) => DropdownMenuItem<String?>(
                                  value: g['id'],
                                  child: Text(g['name'] ?? '',
                                      style: TextStyle(fontSize: 13, color: c.textMain)),
                                )),
                          ],
                          onChanged: (v) => setState(() {
                            _selectedGroupId = v;
                            _selectedGroupName =
                                v == null ? null : _groups.firstWhere((g) => g['id'] == v)['name'];
                          }),
                        ),
                      ),
                    ),
              const SizedBox(height: 6),
              Text('Αν δεν επιλέξεις ομάδα, ο διαχειριστής βλέπει όλες τις ομάδες',
                  style: TextStyle(fontSize: 10.5, color: c.textFaint)),
            ],

            const SizedBox(height: 16),
            Container(
              decoration: BoxDecoration(
                color:        c.greenPale,
                borderRadius: BorderRadius.circular(14),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(children: [
                Icon(Icons.check_circle_outline_rounded, size: 17, color: c.greenDeep),
                const SizedBox(width: 9),
                Expanded(
                  child: Text('Εγκεκριμένος οδηγός',
                      style: TextStyle(fontSize: 12.5, color: c.greenDeep)),
                ),
                Switch(
                  value: _isApproved,
                  onChanged: (v) => setState(() => _isApproved = v),
                  activeThumbColor: Colors.white,
                  activeTrackColor: c.green,
                ),
              ]),
            ),

            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Αποθήκευση'),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _saving ? null : _confirmDelete,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red,
                  side: const BorderSide(color: Color(0xFFF09595)),
                ),
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                label: const Text('Διαγραφή χρήστη'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _roleTile(AppColors c, {
    required _Role role,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final selected = _role == role;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => setState(() => _role = role),
      child: Container(
        decoration: BoxDecoration(
          color:        selected ? c.amberSoft : c.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? c.amber : c.cardBorder,
            width: selected ? 1.5 : 0.8,
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(children: [
          Icon(icon, size: 18, color: selected ? c.amberDeep : c.textFaint),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected ? c.amberDeep : c.textMain)),
              Text(subtitle,
                  style: TextStyle(fontSize: 10.5, color: c.textFaint)),
            ]),
          ),
          if (selected)
            Container(
              width: 20, height: 20,
              decoration: BoxDecoration(color: c.amber, shape: BoxShape.circle),
              child: const Icon(Icons.check_rounded, size: 13, color: Colors.white),
            )
          else
            Container(
              width: 20, height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: c.cardBorder, width: 1.5),
              ),
            ),
        ]),
      ),
    );
  }
}
