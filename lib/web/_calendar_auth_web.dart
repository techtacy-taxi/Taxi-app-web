// ============================================================================
// FILE: ./lib/web/_calendar_auth_web.dart
// ============================================================================
//
// Λήψη serverAuthCode για Web — μέσω Google Identity Services (GIS).
//
// Ροή: google.accounts.oauth2.initCodeClient({access_type:'offline'}) ανοίγει
// popup, ο χρήστης δίνει συγκατάθεση, και το callback επιστρέφει authorization
// code. Αυτό στέλνεται στην ΙΔΙΑ Cloud Function exchangeCalendarCode.
//
// Απαιτεί το GIS script στο web/index.html:
//   <script src="https://accounts.google.com/gsi/client" async defer></script>
//
// Στο GCP, το Web OAuth client πρέπει να έχει στα Authorized JavaScript
// origins το domain (localhost:5000 + pages.dev).

import 'dart:async';
import 'dart:js_interop';

const String _kCalendarScope =
    'https://www.googleapis.com/auth/calendar.readonly';
const String _kDriveScope =
    'https://www.googleapis.com/auth/drive.file';
const String _kWebClientId =
    '566987559821-tlphsu640nfhfdhtevutr7kj58tpu2vq.apps.googleusercontent.com';

// ─── JS interop bindings για το Google Identity Services ───────────────────

@JS('google.accounts.oauth2.initCodeClient')
external _CodeClient _initCodeClient(_CodeClientConfig config);

extension type _CodeClient._(JSObject _) implements JSObject {
  external void requestCode();
}

extension type _CodeClientConfig._(JSObject _) implements JSObject {
  external factory _CodeClientConfig({
    required String client_id,
    required String scope,
    required String ux_mode,
    required JSFunction callback,
    String? access_type,
  });
}

extension type _CodeResponse._(JSObject _) implements JSObject {
  external String? get code;
  external String? get error;
}

/// Επιστρέφει (serverAuthCode, redirectUri) — ή (null, '') αν απέτυχε.
/// Στο web το GIS popup code flow απαιτεί redirect_uri = 'postmessage'.
Future<({String? code, String redirectUri})> obtainCalendarAuthCode() async {
  final completer = Completer<String?>();

  try {
    final client = _initCodeClient(_CodeClientConfig(
      client_id: _kWebClientId,
      scope: '$_kCalendarScope $_kDriveScope',
      ux_mode: 'popup',
      access_type: 'offline',
      callback: (_CodeResponse resp) {
        if (resp.error != null || resp.code == null || resp.code!.isEmpty) {
          if (!completer.isCompleted) completer.complete(null);
        } else {
          if (!completer.isCompleted) completer.complete(resp.code);
        }
      }.toJS,
    ));
    client.requestCode();
  } catch (_) {
    if (!completer.isCompleted) completer.complete(null);
  }

  final code = await completer.future.timeout(
    const Duration(seconds: 120),
    onTimeout: () => null,
  );
  return (code: code, redirectUri: 'postmessage');
}
