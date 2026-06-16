// lib/voice/voice_models.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

// ─── ΤοType enum ─────────────────────────────────────────────────────────────
enum ToType { all, group, user, users }

// ─── Επίπεδο κοινής πρόσβασης (sharing) ───────────────────────────────────────
// Τι μπορεί να κάνει ένας άλλος admin στις δουλειές (αποθηκευμένες + ανοιχτές)
// του ιδιοκτήτη, μέσα στην ίδια ομάδα. Η ΙΔΙΟΚΤΗΣΙΑ δεν αλλάζει ποτέ.
enum ShareLevel {
  none,   // καμία πρόσβαση
  view,   // Εμφάνιση μόνο
  send,   // Εμφάνιση + αποστολή + επεξεργασία (όχι διαγραφή)
  full,   // Εμφάνιση + όλα + διαγραφή
}

ShareLevel shareLevelFromString(String? s) {
  switch (s) {
    case 'view': return ShareLevel.view;
    case 'send': return ShareLevel.send;
    case 'full': return ShareLevel.full;
    default:     return ShareLevel.none;
  }
}

extension ShareLevelX on ShareLevel {
  String get wire => name; // none/view/send/full
  bool get canView   => this != ShareLevel.none;
  bool get canSend   => this == ShareLevel.send || this == ShareLevel.full;
  bool get canEdit   => this == ShareLevel.send || this == ShareLevel.full;
  bool get canDelete => this == ShareLevel.full;
  String get label {
    switch (this) {
      case ShareLevel.none: return 'Κλειστό';
      case ShareLevel.view: return 'Εμφάνιση';
      case ShareLevel.send: return 'Εμφάνιση + αποστολή/επεξεργασία';
      case ShareLevel.full: return 'Εμφάνιση + όλα + διαγραφή';
    }
  }
}

// ─── Group ────────────────────────────────────────────────────────────────────
class VoiceGroup {
  final String       id;
  final String       name;
  final List<String> memberUids;
  final List<String> adminUids;     // UIDs που διαχειρίζονται την ομάδα
  final String       createdBy;
  final Color        color;

  // Κοινή πρόσβαση δουλειών: { ownerUid: { otherAdminUid: 'view'|'send'|'full' } }
  // ownerUid = ο admin που ΜΟΙΡΑΖΕΤΑΙ τις δικές του δουλειές.
  final Map<String, Map<String, String>> savedJobShares;

  const VoiceGroup({
    required this.id,
    required this.name,
    required this.memberUids,
    this.adminUids = const [],
    required this.createdBy,
    this.color = const Color(0xFF1565C0),
    this.savedJobShares = const {},
  });

  /// Επίπεδο πρόσβασης που έχει ο [viewerUid] στις δουλειές του [ownerUid]
  /// μέσα σε ΑΥΤΗ την ομάδα.
  ShareLevel levelFor({required String ownerUid, required String viewerUid}) {
    if (ownerUid == viewerUid) return ShareLevel.full; // δικά του
    final m = savedJobShares[ownerUid];
    if (m == null) return ShareLevel.none;
    return shareLevelFromString(m[viewerUid]);
  }

  static String colorToHex(Color c) {
    return '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  static Color hexToColor(String hex) {
    if (hex.isEmpty) return const Color(0xFF1565C0);
    final clean = hex.replaceAll('#', '');
    try {
      if (clean.length == 6) {
        return Color(int.parse('FF$clean', radix: 16));
      } else if (clean.length == 8) {
        return Color(int.parse(clean, radix: 16));
      }
      return const Color(0xFF1565C0);
    } catch (e) {
      return const Color(0xFF1565C0);
    }
  }

  // Reads both 'color' and 'colorHex' for backward compatibility
  static Color _parseColor(Map<String, dynamic> d) {
    if (d['color'] != null && d['color'].toString().isNotEmpty) {
      return hexToColor(d['color'].toString());
    }
    if (d['colorHex'] != null && d['colorHex'].toString().isNotEmpty) {
      return hexToColor(d['colorHex'].toString());
    }
    return const Color(0xFF1565C0);
  }

  factory VoiceGroup.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data()!;
    return VoiceGroup(
      id:         doc.id,
      name:       d['name']      ?? '',
      memberUids: List<String>.from(d['memberUids'] ?? []),
      adminUids:  List<String>.from(d['adminUids']  ?? []),
      createdBy:  d['createdBy'] ?? '',
      color:      _parseColor(d),
      savedJobShares: _parseShares(d['savedJobShares']),
    );
  }

  static Map<String, Map<String, String>> _parseShares(dynamic raw) {
    if (raw is! Map) return const {};
    final out = <String, Map<String, String>>{};
    raw.forEach((owner, inner) {
      if (inner is Map) {
        final m = <String, String>{};
        inner.forEach((viewer, lvl) {
          final s = lvl?.toString() ?? '';
          if (s == 'view' || s == 'send' || s == 'full') {
            m[viewer.toString()] = s;
          }
        });
        if (m.isNotEmpty) out[owner.toString()] = m;
      }
    });
    return out;
  }

  // Μέθοδος toMap για το VoiceGroup
  Map<String, dynamic> toMap() => {
    'name':       name,
    'memberUids': memberUids,
    'adminUids':  adminUids,
    'createdBy':  createdBy,
    'colorHex':   colorToHex(color),
    'savedJobShares': savedJobShares,
  };
}

// ─── Message ──────────────────────────────────────────────────────────────────
class VoiceMessage {
  final String   id;
  final String   fromUid;
  final String   fromName;
  final String   fromLastName;
  final ToType   toType;
  final String?  toGroupId;
  final String?  toGroupName;
  final String?  toUid;
  final String?  toName;
  final List<String> toUids;
  final String   audioBase64;
  final int      duration;
  final List<String> visibleTo;
  final List<String> readBy;
  final DateTime timestamp;

  const VoiceMessage({
    required this.id,
    required this.fromUid,
    required this.fromName,
    required this.fromLastName,
    required this.toType,
    this.toGroupId,
    this.toGroupName,
    this.toUid,
    this.toName,
    this.toUids = const [],
    required this.audioBase64,
    required this.duration,
    required this.visibleTo,
    required this.readBy,
    required this.timestamp,
  });

  factory VoiceMessage.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data()!;
    return VoiceMessage(
      id:           doc.id,
      fromUid:      d['fromUid']      ?? '',
      fromName:     d['fromName']     ?? '',
      fromLastName: d['fromLastName'] ?? '',
      toType:       ToType.values.firstWhere(
            (e) => e.name == d['toType'],
        orElse: () => ToType.all,
      ),
      toGroupId:   d['toGroupId'],
      toGroupName: d['toGroupName'],
      toUid:       d['toUid'],
      toName:      d['toName'],
      toUids:      List<String>.from(d['toUids'] ?? []),
      audioBase64: d['audioBase64'] ?? '',
      duration:    (d['duration']  as num?)?.toInt() ?? 0,
      visibleTo:   List<String>.from(d['visibleTo'] ?? []),
      readBy:      List<String>.from(d['readBy']    ?? []),
      timestamp:   (d['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  // Μέθοδος toMap για το VoiceMessage (Λύνει το σφάλμα στο voice_service.dart)
  Map<String, dynamic> toMap() => {
    'fromUid':      fromUid,
    'fromName':     fromName,
    'fromLastName': fromLastName,
    'toType':       toType.name,
    if (toGroupId   != null) 'toGroupId':   toGroupId,
    if (toGroupName != null) 'toGroupName': toGroupName,
    if (toUid       != null) 'toUid':       toUid,
    if (toName      != null) 'toName':      toName,
    if (toUids.isNotEmpty)   'toUids':      toUids,
    'audioBase64': audioBase64,
    'duration':    duration,
    'visibleTo':   visibleTo,
    'readBy':      readBy,
    'timestamp':   FieldValue.serverTimestamp(),
  };

  // Getter για το πλήρες όνομα (Λύνει το σφάλμα στο voice_inbox.dart)
  String get fromFullName => '$fromName $fromLastName'.trim();

  // Getter για την ετικέτα παραλήπτη (Λύνει το σφάλμα στο voice_inbox.dart)
  String get toLabel {
    switch (toType) {
      case ToType.all:   return 'Όλοι';
      case ToType.group: return toGroupName ?? 'Ομάδα';
      case ToType.user:  return toName      ?? 'Οδηγός';
      case ToType.users: return '${toUids.length} Επιλεγμένοι';
    }
  }

  bool isUnread(String uid) => !readBy.contains(uid);
}