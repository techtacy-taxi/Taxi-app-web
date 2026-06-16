// lib/voice/recipient_picker.dart

import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'voice_models.dart';
import '../jobs/job_shared_widgets.dart';

// Key για SharedPreferences — αποθήκευση τελευταίας επιλογής αποδεκτών
const String _kLastRecipientKey = 'voice_last_recipient_v1';

class RecipientSelection {
  final ToType  toType;
  final String? toGroupId;
  final String? toGroupName;
  final String? toUid;
  final String? toName;
  final List<String>? toUids;
  final List<String> visibleTo;

  const RecipientSelection({
    required this.toType,
    this.toGroupId,
    this.toGroupName,
    this.toUid,
    this.toName,
    this.toUids,
    required this.visibleTo,
  });

  String get toLabel {
    switch (toType) {
      case ToType.all:   return 'Όλοι';
      case ToType.group: return toGroupName ?? 'Ομάδα';
      case ToType.user:  return toName      ?? 'Οδηγός';
      case ToType.users: return '${toUids?.length ?? 0} Επιλεγμένοι';
    }
  }
}

Future<RecipientSelection?> showRecipientPicker({
  required BuildContext context,
  required String       fromUid,
}) async {
  return showModalBottomSheet<RecipientSelection>(
    context:            context,
    isScrollControlled: true,
    backgroundColor:    Colors.transparent,
    builder: (_) => _RecipientPickerSheet(fromUid: fromUid),
  );
}

class _RecipientPickerSheet extends StatefulWidget {
  final String fromUid;
  const _RecipientPickerSheet({required this.fromUid});

  @override
  State<_RecipientPickerSheet> createState() => _RecipientPickerSheetState();
}

class _RecipientPickerSheetState extends State<_RecipientPickerSheet> {
  bool _isLoading = true;

  List<VoiceGroup> _groups = [];
  List<Map<String, dynamic>> _drivers = [];

  final Set<String> _selectedUids = {};
  bool _sendToAll = false;

  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadData();
    _restoreLastSelection();
  }

  Future<void> _restoreLastSelection() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw   = prefs.getString(_kLastRecipientKey);
      if (raw == null) return;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _sendToAll = data['sendToAll'] == true;
        if (!_sendToAll) {
          final uids = List<String>.from(data['uids'] ?? []);
          _selectedUids
            ..clear()
            ..addAll(uids);
        }
      });
    } catch (_) {}
  }

  Future<void> _saveLastSelection({
    required bool sendToAll,
    required List<String> uids,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kLastRecipientKey, jsonEncode({
        'sendToAll': sendToAll,
        'uids':      uids,
      }));
    } catch (_) {}
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    final fs = FirebaseFirestore.instance;
    final snaps = await Future.wait([
      fs.collection('groups').get(),
      fs.collection('presence').where('isApproved', isEqualTo: true).get(),
    ]);

    setState(() {
      _groups = snaps[0].docs.map((d) => VoiceGroup.fromDoc(d)).toList();
      _drivers = snaps[1].docs.map((d) {
        final data = d.data();
        data['uid'] = d.id;
        return data;
      }).where((d) => d['uid'] != widget.fromUid).toList();
      _isLoading = false;
    });
  }

  void _confirmSelection() {
    if (_sendToAll) {
      _saveLastSelection(sendToAll: true, uids: []);
      Navigator.of(context).pop(RecipientSelection(
        toType: ToType.all,
        visibleTo: [widget.fromUid],
      ));
      return;
    }

    if (_selectedUids.isEmpty) return;

    _saveLastSelection(sendToAll: false, uids: _selectedUids.toList());

    if (_selectedUids.length == 1) {
      final selectedUid = _selectedUids.first;
      final driver = _drivers.firstWhere((d) => d['uid'] == selectedUid);
      final name = '${driver['displayName'] ?? ''} ${driver['lastName'] ?? ''}'.trim();

      Navigator.of(context).pop(RecipientSelection(
        toType: ToType.user,
        toUid: selectedUid,
        toName: name,
        visibleTo: [widget.fromUid, selectedUid],
      ));
      return;
    }

    Navigator.of(context).pop(RecipientSelection(
      toType: ToType.users,
      toUids: _selectedUids.toList(),
      visibleTo: [widget.fromUid, ..._selectedUids],
    ));
  }

  @override
  Widget build(BuildContext context) {
    final query = _searchQuery.toLowerCase().trim();
    final filteredDrivers = _drivers.where((d) {
      final name = '${d['displayName'] ?? ''} ${d['lastName'] ?? ''}'.toLowerCase();
      return name.contains(query);
    }).toList();

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize:     0.5,
      maxChildSize:     0.95,
      builder: (context, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: SheetHandle(bottomMargin: 0),
              ),
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: Text('Επιλογή Παραληπτών', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ),

              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: 'Αναζήτηση οδηγού...',
                    prefixIcon: const Icon(Icons.search_rounded, color: Colors.grey),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                      icon: const Icon(Icons.clear_rounded, color: Colors.grey),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                    )
                        : null,
                    filled: true,
                    fillColor: Colors.grey[100],
                    contentPadding: const EdgeInsets.symmetric(vertical: 0),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onChanged: (val) {
                    setState(() {
                      _searchQuery = val;
                    });
                  },
                ),
              ),
              const SizedBox(height: 8),
              const Divider(height: 1),

              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator(color: Colors.amber))
                    : ListView(
                  controller: scrollController,
                  children: [
                    if (_searchQuery.isEmpty) ...[
                      CheckboxListTile(
                        title: const Text('Όλοι (Γενική Εκπομπή)', style: TextStyle(fontWeight: FontWeight.bold)),
                        secondary: const Icon(Icons.public_rounded, color: Colors.blue),
                        activeColor: Colors.amber,
                        value: _sendToAll,
                        onChanged: (val) {
                          setState(() {
                            _sendToAll = val ?? false;
                            if (_sendToAll) _selectedUids.clear();
                          });
                        },
                      ),
                      const Divider(),
                    ],

                    if (!_sendToAll) ...[
                      if (_searchQuery.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          child: Text('ΟΜΑΔΕΣ ΦΑΚΕΛΟΙ', style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold)),
                        ),

                      ..._groups.map((group) {
                        final groupMembers = filteredDrivers.where((d) => group.memberUids.contains(d['uid'])).toList();

                        if (groupMembers.isEmpty) return const SizedBox.shrink();

                        final allSelected = groupMembers.every((d) => _selectedUids.contains(d['uid']));

                        return ExpansionTile(
                          initiallyExpanded: _searchQuery.isNotEmpty,
                          leading: Checkbox(
                            value: allSelected,
                            activeColor: Colors.amber,
                            onChanged: (val) {
                              setState(() {
                                if (val == true) {
                                  _selectedUids.addAll(groupMembers.map((d) => d['uid'] as String));
                                } else {
                                  _selectedUids.removeAll(groupMembers.map((d) => d['uid'] as String));
                                }
                              });
                            },
                          ),
                          title: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                decoration: BoxDecoration(
                                  color: group.color,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                    group.name,
                                    style: TextStyle(
                                      // Έξυπνο χρώμα γραμματοσειράς:
                                        color: group.color.computeLuminance() > 0.5 ? Colors.black : Colors.white,
                                        fontWeight: FontWeight.bold
                                    )
                                ),
                              ),
                            ],
                          ),
                          children: groupMembers.map((driver) {
                            final uid = driver['uid'] as String;
                            final name = '${driver['displayName'] ?? ''} ${driver['lastName'] ?? ''}'.trim();
                            final plate = driver['plateNumber'] ?? '';

                            return Padding(
                              padding: const EdgeInsets.only(left: 32.0),
                              child: CheckboxListTile(
                                title: Text(name, style: const TextStyle(fontSize: 14)),
                                subtitle: plate.isNotEmpty ? Text(plate, style: const TextStyle(fontSize: 12, color: Colors.grey)) : null,
                                activeColor: Colors.amber,
                                value: _selectedUids.contains(uid),
                                onChanged: (val) {
                                  setState(() {
                                    if (val == true) {
                                      _selectedUids.add(uid);
                                    } else {
                                      _selectedUids.remove(uid);
                                    }
                                  });
                                },
                              ),
                            );
                          }).toList(),
                        );
                      }),

                      if (filteredDrivers.isNotEmpty) ...[
                        const Divider(),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          child: Text(_searchQuery.isEmpty ? 'ΟΛΟΙ ΟΙ ΣΥΝΑΔΕΛΦΟΙ' : 'ΑΠΟΤΕΛΕΣΜΑΤΑ ΑΝΑΖΗΤΗΣΗΣ',
                              style: const TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold)),
                        ),
                      ] else if (_searchQuery.isNotEmpty) ...[
                        const Padding(
                          padding: EdgeInsets.all(32.0),
                          child: Center(
                            child: Text('Δεν βρέθηκε οδηγός με αυτό το όνομα.', style: TextStyle(color: Colors.grey)),
                          ),
                        ),
                      ],

                      ...filteredDrivers.map((driver) {
                        final uid = driver['uid'] as String;
                        final name = '${driver['displayName'] ?? ''} ${driver['lastName'] ?? ''}'.trim();

                        return CheckboxListTile(
                          title: Text(name),
                          activeColor: Colors.amber,
                          value: _selectedUids.contains(uid),
                          onChanged: (val) {
                            setState(() {
                              if (val == true) {
                                _selectedUids.add(uid);
                              } else {
                                _selectedUids.remove(uid);
                              }
                            });
                          },
                        );
                      }),
                    ]
                  ],
                ),
              ),

              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: (_selectedUids.isNotEmpty || _sendToAll) ? Colors.amber : Colors.grey[300],
                        foregroundColor: (_selectedUids.isNotEmpty || _sendToAll) ? Colors.black : Colors.grey[600],
                      ),
                      icon: const Icon(Icons.send_rounded),
                      label: Text(
                        _sendToAll
                            ? 'Εκπομπή σε Όλους'
                            : 'Επιλογή (${_selectedUids.length}) οδηγών',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      onPressed: (_selectedUids.isNotEmpty || _sendToAll) ? _confirmSelection : null,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}