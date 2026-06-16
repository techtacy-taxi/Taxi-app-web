// lib/voice/voice_service.dart

import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'voice_models.dart';
// Τοπική διαχείριση ηχητικών αρχείων (path_provider/File σε κινητό,
// no-op σε web). Επιλέγεται αυτόματα ανά platform.
import '../web/_voice_io.dart';

class VoiceService {
  static final _fs = FirebaseFirestore.instance;
  static const _collection = 'messages';
  static const _maxMessages = 10; // max μηνύματα πριν σβήσει το παλιότερο

  // ─── Send ─────────────────────────────────────────────────────────────────

  static Future<void> sendMessage({
    required String   fromUid,
    required String   fromName,
    required String   fromLastName,
    required ToType   toType,
    String?           toGroupId,
    String?           toGroupName,
    String?           toUid,
    String?           toName,
    required Object   audioFile,
    required int      duration,
    required List<String> visibleTo,
  }) async {
    // Encode σε base64 (το readAudioBytes ξέρει τον πραγματικό τύπο ανά platform)
    final bytes      = await readAudioBytes(audioFile);
    final audioBase64 = base64Encode(bytes);

    final msg = VoiceMessage(
      id:          '',
      fromUid:      fromUid,
      fromName:     fromName,
      fromLastName: fromLastName,
      toType:      toType,
      toGroupId:   toGroupId,
      toGroupName: toGroupName,
      toUid:       toUid,
      toName:      toName,
      audioBase64: audioBase64,
      duration:    duration,
      visibleTo:   visibleTo,
      readBy:      [],
      timestamp:   DateTime.now(),
    );

    await _fs.collection(_collection).add(msg.toMap());

    // Cleanup — κράτα μόνο τα τελευταία _maxMessages για κάθε συνομιλία
    await _cleanup(fromUid: fromUid, toType: toType,
        toGroupId: toGroupId, toUid: toUid);
  }

  // ─── Cleanup ──────────────────────────────────────────────────────────────

  static Future<void> _cleanup({
    required String  fromUid,
    required ToType  toType,
    String?          toGroupId,
    String?          toUid,
  }) async {
    Query<Map<String, dynamic>> q = _fs
        .collection(_collection)
        .orderBy('timestamp', descending: false);

    // Φιλτράρουμε ανά conversation
    switch (toType) {
      case ToType.all:
        q = q.where('toType', isEqualTo: 'all');
        break; // Καλό είναι να βάζεις break
      case ToType.group:
        q = q.where('toGroupId', isEqualTo: toGroupId);
        break;
      case ToType.user:
      // Και οι δύο κατευθύνσεις της ίδιας συνομιλίας
        q = q.where('toType', isEqualTo: 'user');
        break;
      case ToType.users: // Η ΠΡΟΣΘΗΚΗ ΠΟΥ ΛΕΙΠΕΙ
        q = q.where('toType', isEqualTo: 'users');
        break;
    }

    final snap = await q.get();
    if (snap.docs.length <= _maxMessages) return;

    // Σβήνουμε τα παλιότερα
    final toDelete = snap.docs.length - _maxMessages;
    for (var i = 0; i < toDelete; i++) {
      await snap.docs[i].reference.delete();
    }
  }

  // ─── Fetch messages for user ──────────────────────────────────────────────

  static Stream<List<VoiceMessage>> messagesFor(String uid) {
    return _fs
        .collection(_collection)
        .where('visibleTo', arrayContains: uid)
        .orderBy('timestamp', descending: true)
        .snapshots()
        .map((snap) => snap.docs
        .map((d) => VoiceMessage.fromDoc(d))
        .toList());
  }

  // ─── Mark as read ─────────────────────────────────────────────────────────

  static Future<void> markRead(String messageId, String uid) async {
    await _fs.collection(_collection).doc(messageId).update({
      'readBy': FieldValue.arrayUnion([uid]),
    });
  }

  // ─── Save audio locally (κινητό· no-op σε web) ────────────────────────────

  static Future<String> saveLocally(VoiceMessage msg) async {
    final bytes = base64Decode(msg.audioBase64);
    return saveAudioLocally(msg.id, bytes);
  }

  // ─── Load local file path (αν υπάρχει· πάντα null σε web) ─────────────────

  static Future<String?> loadLocal(String messageId) async {
    return localAudioPath(messageId);
  }

  // ─── Groups ───────────────────────────────────────────────────────────────

  static Stream<List<VoiceGroup>> groups() {
    return _fs
        .collection('groups')
        .orderBy('name')
        .snapshots()
        .map((snap) => snap.docs
        .map((d) => VoiceGroup.fromDoc(d))
        .toList());
  }

  static Future<void> createGroup({
    required String       name,
    required List<String> memberUids,
    required String       createdBy,
    Color                 color = const Color(0xFF1565C0),
  }) async {
    await _fs.collection('groups').add(
      VoiceGroup(
        id:         '',
        name:       name,
        memberUids: memberUids,
        createdBy:  createdBy,
        color:      color,
      ).toMap(),
    );
  }

  static Future<void> updateGroup({
    required String       groupId,
    required String       name,
    required List<String> memberUids,
    Color                 color = const Color(0xFF1565C0),
  }) async {
    await _fs.collection('groups').doc(groupId).update({
      'name':       name,
      'memberUids': memberUids,
      'color':      VoiceGroup.colorToHex(color),
    });
  }

  static Future<void> deleteGroup(String groupId) async {
    await _fs.collection('groups').doc(groupId).delete();
  }

  // ─── Resolve visibleTo ────────────────────────────────────────────────────
  // Υπολογίζει ποιοι UIDs θα βλέπουν το μήνυμα

  static Future<List<String>> resolveVisibleTo({
    required String  fromUid,
    required ToType  toType,
    String?          toGroupId,
    String?          toUid,
    List<String>?    toUids,
  }) async {
    switch (toType) {
      case ToType.all:
      // Όλοι οι εγκεκριμένοι οδηγοί
        final snap = await _fs
            .collection('presence')
            .where('isApproved', isEqualTo: true)
            .get();
        return snap.docs.map((d) => d.id).toList();

      case ToType.group:
        final doc = await _fs.collection('groups').doc(toGroupId).get();
        if (!doc.exists) return [fromUid];
        final members = List<String>.from(doc.data()?['memberUids'] ?? []);
        if (!members.contains(fromUid)) members.add(fromUid);
        return members;

      case ToType.user:
        return [fromUid, toUid!];
      case ToType.users:
        final uids = List<String>.from(toUids ?? []);
        if (!uids.contains(fromUid)) uids.add(fromUid);
        return uids;
    }
  }

  // ─── canSend check ────────────────────────────────────────────────────────

  static Future<bool> canSend(String uid) async {
    final doc = await _fs.collection('presence').doc(uid).get();
    if (!doc.exists) return false;
    return doc.data()?['canSend'] ?? true;
  }

  // ─── Toggle canSend (admin only) ──────────────────────────────────────────

  static Future<void> toggleCanSend(String uid, bool value) async {
    await _fs.collection('presence').doc(uid).update({'canSend': value});
  }
}