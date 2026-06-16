// lib/voice/share_service.dart
//
// Κεντρικός υπολογισμός «κοινής θέας» δουλειών μεταξύ admins της ίδιας ομάδας.
//
// Η ιδιοκτησία ΔΕΝ αλλάζει ποτέ: ο ιδιοκτήτης (ownerUid/createdBy) και όλο το
// billing μένουν στον αρχικό admin. Το sharing δίνει μόνο ΔΙΚΑΙΩΜΑΤΑ θέασης /
// αποστολής / επεξεργασίας / διαγραφής σε άλλους admins, για λογαριασμό του.
//
// Πηγή αλήθειας: groups/{id}.savedJobShares = { ownerUid: { viewerUid: level } }

import 'package:cloud_firestore/cloud_firestore.dart';
import 'voice_models.dart';

class ShareService {
  static final _fs = FirebaseFirestore.instance;

  /// Map: ownerUid -> υψηλότερο ShareLevel που έχει ο [viewerUid] πάνω του,
  /// συγκεντρωμένο από ΟΛΕΣ τις ομάδες (αν ο ίδιος owner μοιράζεται σε
  /// πολλές ομάδες, κρατάμε το ισχυρότερο επίπεδο).
  ///
  /// ΔΕΝ περιλαμβάνει τον ίδιο τον viewer (τα δικά του τα έχει ούτως ή άλλως).
  static Future<Map<String, ShareLevel>> sharedOwnersFor(String viewerUid) async {
    final snap = await _fs.collection('groups').get();
    return _accumulate(
      snap.docs.map((d) => VoiceGroup.fromDoc(d)),
      viewerUid,
    );
  }

  /// Stream εκδοχή — ενημερώνεται όταν αλλάζουν τα shares.
  static Stream<Map<String, ShareLevel>> sharedOwnersStream(String viewerUid) {
    return _fs.collection('groups').snapshots().map((snap) => _accumulate(
          snap.docs.map((d) => VoiceGroup.fromDoc(d)),
          viewerUid,
        ));
  }

  static Map<String, ShareLevel> _accumulate(
    Iterable<VoiceGroup> groups,
    String viewerUid,
  ) {
    final out = <String, ShareLevel>{};
    for (final g in groups) {
      g.savedJobShares.forEach((ownerUid, viewers) {
        if (ownerUid == viewerUid) return;
        final lvl = shareLevelFromString(viewers[viewerUid]);
        if (lvl == ShareLevel.none) return;
        final existing = out[ownerUid];
        if (existing == null || lvl.index > existing.index) {
          out[ownerUid] = lvl;
        }
      });
    }
    return out;
  }
}
