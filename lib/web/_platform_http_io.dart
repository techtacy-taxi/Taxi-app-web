// ============================================================================
// FILE: ./lib/web/_platform_http_io.dart
// ============================================================================
//
// Υλοποίηση HTTP για Android / iOS (dart:io HttpClient).
// Ίδια ακριβώς λογική με τον παλιό κώδικα του PlacesService._request —
// απλώς μεταφέρθηκε εδώ ώστε το web να μπορεί να έχει δική του υλοποίηση.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Εξαίρεση που πετάει το HTTP layer — το PlacesService την ξαναπιάνει.
class PlatformHttpException implements Exception {
  final String  status;
  final String? message;
  PlatformHttpException(this.status, this.message);
  @override
  String toString() => 'PlatformHttpException($status): ${message ?? ""}';
}

/// Κάνει αίτημα και επιστρέφει το JSON ως Map (ή null αν κενό σώμα).
/// Πετάει PlatformHttpException σε σφάλμα δικτύου ή HTTP != 200.
Future<Map<String, dynamic>?> platformJsonRequest(
  Uri uri, {
  String method = 'GET',
  Map<String, String> headers = const {},
  Object? body,
}) async {
  final client = HttpClient();
  try {
    client.connectionTimeout = const Duration(seconds: 12);
    final req = method == 'POST'
        ? await client.postUrl(uri)
        : await client.getUrl(uri);
    headers.forEach(req.headers.set);
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final resp = await req.close();
    final text = await resp.transform(utf8.decoder).join();
    final data = text.isEmpty ? null : jsonDecode(text);
    if (resp.statusCode != 200) {
      final msg = (data is Map && data['error'] is Map)
          ? data['error']['message'] as String?
          : null;
      throw PlatformHttpException('HTTP ${resp.statusCode}', msg ?? text);
    }
    return data is Map<String, dynamic> ? data : null;
  } on PlatformHttpException {
    rethrow;
  } catch (e) {
    throw PlatformHttpException('NETWORK', e.toString());
  } finally {
    client.close(force: true);
  }
}
