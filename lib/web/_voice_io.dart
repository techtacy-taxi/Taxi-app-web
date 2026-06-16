// ============================================================================
// FILE: ./lib/web/_voice_io.dart
// ============================================================================
//
// Τοπική αποθήκευση/ανάγνωση ηχητικών αρχείων — platform-agnostic πρόσοψη.
//
//   • Android / iOS → _voice_io_mobile.dart  (path_provider + File)
//   • Web           → _voice_io_web.dart      (μη διαθέσιμο — no-op)
//
// Στο web δεν αποθηκεύουμε αρχεία τοπικά· η μελλοντική αναπαραγωγή θα γίνεται
// απευθείας από τα base64 bytes μέσα στον browser (<audio>).

export '_voice_io_mobile.dart'
    if (dart.library.io) '_voice_io_mobile.dart'
    if (dart.library.html) '_voice_io_web.dart';
