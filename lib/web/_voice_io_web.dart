// ============================================================================
// FILE: ./lib/web/_voice_io_web.dart
// ============================================================================
//
// Stub τοπικής διαχείρισης ηχητικών για Web.
// Στο web δεν υπάρχει filesystem (dart:io). Η αποθήκευση τοπικά δεν
// υποστηρίζεται· μελλοντική αναπαραγωγή θα γίνεται από τα base64 bytes
// απευθείας στον browser.

/// Δεν χρησιμοποιείται στο web (η αποστολή φωνητικών είναι ανενεργή).
Future<List<int>> readAudioBytes(Object audioFile) async {
  throw UnsupportedError('Η αποστολή φωνητικών δεν υποστηρίζεται στο web.');
}

/// No-op στο web — δεν αποθηκεύουμε αρχεία τοπικά.
Future<String> saveAudioLocally(String messageId, List<int> bytes) async {
  throw UnsupportedError('Τοπική αποθήκευση ήχου μη διαθέσιμη στο web.');
}

/// Πάντα null στο web — δεν υπάρχει τοπικό αρχείο.
Future<String?> localAudioPath(String messageId) async => null;

/// Στο web η τοπική αποθήκευση ΔΕΝ είναι διαθέσιμη.
const bool kLocalAudioAvailable = false;
