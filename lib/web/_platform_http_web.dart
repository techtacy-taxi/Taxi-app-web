// ============================================================================
// FILE: ./lib/web/_platform_http_web.dart
// ============================================================================
//
// Υλοποίηση HTTP για Web (package:http).
// Στο web ΔΕΝ υπάρχει dart:io, οπότε χρησιμοποιούμε το http package που
// από κάτω μιλάει με το browser fetch / XHR.
//
// ⚠️  CORS: Οι κλήσεις προς places.googleapis.com / routes.googleapis.com /
//     maps.googleapis.com γίνονται απευθείας από τον browser. Το Google
//     επιτρέπει CORS σε αυτά τα endpoints όταν το κλειδί είναι κλειδί
//     τύπου "Browser" χωρίς Android restriction. Χρησιμοποιούμε το ίδιο
//     unrestricted web-service κλειδί (kGoogleWebApiKey).

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class PlatformHttpException implements Exception {
  final String  status;
  final String? message;
  PlatformHttpException(this.status, this.message);
  @override
  String toString() => 'PlatformHttpException($status): ${message ?? ""}';
}

Future<Map<String, dynamic>?> platformJsonRequest(
  Uri uri, {
  String method = 'GET',
  Map<String, String> headers = const {},
  Object? body,
}) async {
  try {
    final h = <String, String>{...headers};
    http.Response resp;
    if (method == 'POST') {
      h['Content-Type'] = 'application/json';
      resp = await http
          .post(uri, headers: h, body: body == null ? null : jsonEncode(body))
          .timeout(const Duration(seconds: 12));
    } else {
      resp = await http
          .get(uri, headers: h)
          .timeout(const Duration(seconds: 12));
    }

    final text = resp.body;
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
  }
}
