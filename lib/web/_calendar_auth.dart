// ============================================================================
// FILE: ./lib/web/_calendar_auth.dart
// ============================================================================
//
// Λήψη serverAuthCode για το Google Calendar — platform-agnostic πρόσοψη.
//
//   • Android / iOS → _calendar_auth_io.dart  (google_sign_in authorizeServer)
//   • Web           → _calendar_auth_web.dart   (Google Identity Services popup)
//
// Και οι δύο επιστρέφουν έναν authorization code (offline access) που μετά
// στέλνεται στην ΙΔΙΑ Cloud Function exchangeCalendarCode.

export '_calendar_auth_io.dart'
    if (dart.library.io) '_calendar_auth_io.dart'
    if (dart.library.html) '_calendar_auth_web.dart';
