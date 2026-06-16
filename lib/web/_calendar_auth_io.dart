// ============================================================================
// FILE: ./lib/web/_calendar_auth_io.dart
// ============================================================================
//
// Λήψη serverAuthCode για Android / iOS — μέσω google_sign_in (όπως πριν).

import 'package:google_sign_in/google_sign_in.dart';

const String _kCalendarScope =
    'https://www.googleapis.com/auth/calendar.readonly';
const String _kDriveScope =
    'https://www.googleapis.com/auth/drive.file';
const String _kServerClientId =
    '566987559821-tlphsu640nfhfdhtevutr7kj58tpu2vq.apps.googleusercontent.com';

bool _gsiInitialized = false;

Future<void> _ensureInit() async {
  if (_gsiInitialized) return;
  try {
    await GoogleSignIn.instance.initialize(serverClientId: _kServerClientId);
  } catch (_) {}
  _gsiInitialized = true;
}

/// Επιστρέφει (serverAuthCode, redirectUri). Σε κινητό το redirectUri είναι
/// κενό (Android flow), για συμβατότητα με το web helper.
Future<({String? code, String redirectUri})> obtainCalendarAuthCode() async {
  await _ensureInit();
  try {
    final account = await GoogleSignIn.instance.authenticate(
      scopeHint: const <String>[_kCalendarScope, _kDriveScope],
    );
    final serverAuth = await account.authorizationClient
        .authorizeServer(const <String>[_kCalendarScope, _kDriveScope]);
    return (code: serverAuth?.serverAuthCode, redirectUri: '');
  } catch (_) {
    return (code: null, redirectUri: '');
  }
}
