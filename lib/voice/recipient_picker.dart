// lib/voice/recipient_picker.dart
//
// REDESIGN: ίδια ΑΚΡΙΒΩΣ λογική επιλογής (αναζήτηση, ομάδες, πολλαπλή
// επιλογή, αποθήκευση τελευταίας επιλογής) — μόνο νέο οπτικό στυλ
// (AppColors, pill κάρτες, dark mode).

import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_theme.dart';
import '../jobs/job_shared_widgets.dart';
import 'voice_models.dart';

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

  String _initialsOf(String name) => name.trim().isEmpty
      ? '?'
      : name.trim().split(RegExp(r'\s+')).take(2).map((w) => w[0]).join().toUpperCase();

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
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
          decoration: BoxDecoration(
            color: c.scaffold,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: SheetHandle(bottomMargin: 0),
              ),
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(children: [
                  Text('Νέο μήνυμα',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600, color: c.textMain)),
                ]),
              ),

              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: TextField(
                  controller: _searchController,
                  style: TextStyle(fontSize: 13, color: c.textMain),
                  decoration: InputDecoration(
                    hintText: 'Αναζήτηση ονόματος...',
                    hintStyle: TextStyle(fontSize: 13, color: c.textFaint),
                    prefixIcon: Icon(Icons.search_rounded, color: c.textFaint, size: 19),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: Icon(Icons.clear_rounded, color: c.textFaint, size: 18),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: c.card,
                    contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 4),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: c.cardBorder, width: 0.8),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: c.cardBorder, width: 0.8),
                    ),
                  ),
                  onChanged: (val) => setState(() => _searchQuery = val),
                ),
              ),
              const SizedBox(height: 10),

              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : ListView(
                        controller: scrollController,
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        children: [
                          if (_searchQuery.isEmpty) ...[
                            _recipientRow(c,
                                selected: _sendToAll,
                                leadingBg: c.amberSoft,
                                leadingFg: c.amberDeep,
                                initials: 'ΟΛ',
                                title: 'Όλοι οι οδηγοί',
                                bold: true,
                                onTap: () => setState(() {
                                  _sendToAll = !_sendToAll;
                                  if (_sendToAll) _selectedUids.clear();
                                })),
                            const SizedBox(height: 10),
                          ],

                          if (!_sendToAll) ...[
                            if (_searchQuery.isEmpty) ...[
                              ..._groups.map((group) {
                                final groupMembers = filteredDrivers
                                    .where((d) => group.memberUids.contains(d['uid']))
                                    .toList();
                                if (groupMembers.isEmpty) return const SizedBox.shrink();
                                final allSelected = groupMembers
                                    .every((d) => _selectedUids.contains(d['uid']));

                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 10),
                                  child: Theme(
                                    data: Theme.of(context).copyWith(
                                        dividerColor: Colors.transparent),
                                    child: ExpansionTile(
                                      tilePadding: EdgeInsets.zero,
                                      childrenPadding: const EdgeInsets.only(left: 14),
                                      shape: const Border(),
                                      initiallyExpanded: _searchQuery.isNotEmpty,
                                      leading: Checkbox(
                                        value: allSelected,
                                        activeColor: c.amber,
                                        onChanged: (val) => setState(() {
                                          if (val == true) {
                                            _selectedUids.addAll(
                                                groupMembers.map((d) => d['uid'] as String));
                                          } else {
                                            _selectedUids.removeAll(
                                                groupMembers.map((d) => d['uid'] as String));
                                          }
                                        }),
                                      ),
                                      title: Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 10, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: group.color,
                                          borderRadius: BorderRadius.circular(9),
                                        ),
                                        child: Text(group.name,
                                            style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                                color: group.color.computeLuminance() > 0.5
                                                    ? Colors.black
                                                    : Colors.white)),
                                      ),
                                      children: groupMembers.map((driver) {
                                        final uid  = driver['uid'] as String;
                                        final name =
                                            '${driver['displayName'] ?? ''} ${driver['lastName'] ?? ''}'.trim();
                                        return _recipientRow(c,
                                            selected: _selectedUids.contains(uid),
                                            leadingBg: c.bluePale,
                                            leadingFg: c.blueDeep,
                                            initials: _initialsOf(name),
                                            title: name,
                                            onTap: () => setState(() {
                                              if (_selectedUids.contains(uid)) {
                                                _selectedUids.remove(uid);
                                              } else {
                                                _selectedUids.add(uid);
                                              }
                                            }));
                                      }).toList(),
                                    ),
                                  ),
                                );
                              }),
                            ],

                            if (filteredDrivers.isEmpty && _searchQuery.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.all(28.0),
                                child: Center(
                                  child: Text('Δεν βρέθηκε οδηγός με αυτό το όνομα.',
                                      style: TextStyle(fontSize: 12.5, color: c.textFaint)),
                                ),
                              ),

                            ...filteredDrivers.map((driver) {
                              final uid  = driver['uid'] as String;
                              final name =
                                  '${driver['displayName'] ?? ''} ${driver['lastName'] ?? ''}'.trim();
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: _recipientRow(c,
                                    selected: _selectedUids.contains(uid),
                                    leadingBg: c.bluePale,
                                    leadingFg: c.blueDeep,
                                    initials: _initialsOf(name),
                                    title: name,
                                    onTap: () => setState(() {
                                      if (_selectedUids.contains(uid)) {
                                        _selectedUids.remove(uid);
                                      } else {
                                        _selectedUids.add(uid);
                                      }
                                    })),
                              );
                            }),
                          ],
                        ],
                      ),
              ),

              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                      label: Text(_sendToAll
                          ? 'Συνέχεια — Όλοι οι οδηγοί'
                          : 'Συνέχεια (${_selectedUids.length})'),
                      onPressed:
                          (_selectedUids.isNotEmpty || _sendToAll) ? _confirmSelection : null,
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

  Widget _recipientRow(AppColors c, {
    required bool   selected,
    required Color  leadingBg,
    required Color  leadingFg,
    required String initials,
    required String title,
    bool bold = false,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: selected ? c.amberSoft : c.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? c.amber : c.cardBorder,
            width: selected ? 1.5 : 0.8,
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(children: [
          Container(
            width: 30, height: 30,
            decoration: BoxDecoration(color: leadingBg, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: Text(initials,
                style: TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w700, color: leadingFg)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(title,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: bold || selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected
                        ? (c.isDark ? c.amberDeep : const Color(0xFF633806))
                        : c.textMain)),
          ),
          if (selected)
            Icon(Icons.check_rounded, size: 17, color: c.amberDeep),
        ]),
      ),
    );
  }
}
