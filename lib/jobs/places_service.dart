// ==========================================
// FILE: ./lib/jobs/places_service.dart
// ==========================================
//
// Βοηθητικά για το ΝΕΟ στιλ δουλειάς (Google Maps):
//  • Google Places Autocomplete + Place Details (εύρεση σημείων / οδών)
//  • Google Directions (διαδρομή οδήγησης + χιλιόμετρα)
//  • Αποκωδικοποίηση encoded polyline
//  • Υπολογισμός απόστασης (ευθεία) με Haversine
//  • Widget PlaceField — πεδίο "Από / Προς" με αναζήτηση Google
//
// ⚠️  ΠΡΟΣΟΧΗ — API KEY
//  Δύο ΞΕΧΩΡΙΣΤΑ κλειδιά — ένα για κάθε πλατφόρμα, ώστε το καθένα να μπορεί
//  να έχει το δικό του restriction στο Google Cloud Console:
//    • Android app  → restriction "Android apps" (package name + SHA-1)
//    • Web admin    → restriction "HTTP referrers" (τα domains σου)
//  Χρειάζονται ενεργά: "Places API (New)" και "Directions API" (ή Routes API).
//  Το ΠΑΛΙΟ κοινό/unrestricted κλειδί ΔΕΝ πρέπει να ξαναμπεί εδώ — μένει
//  ΜΟΝΟ ως server-side secret (ROUTES_API_KEY στο Cloud Functions), ποτέ σε
//  client κώδικα.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import 'client_model.dart';
import 'job_shared_widgets.dart';

// Διαστρωματικά βοηθητικά (επιλέγονται αυτόματα ανά platform):
//  • _platform_http : HTTP layer (dart:io σε κινητό, package:http σε web)
//  • _map_picker    : επιλογή σημείου στον χάρτη (GoogleMap σε κινητό,
//                     μη διαθέσιμο σε web)
import '../web/_platform_http.dart';
import '../web/_map_picker.dart';

// ─────────────────────────────────────────────────────────────────────────────
// API KEY
// ─────────────────────────────────────────────────────────────────────────────

/// Κλειδί ΜΟΝΟ για την Android εφαρμογή — restriction "Android apps":
/// package name com.example.my_taxi_app + SHA-1 του debug.keystore
/// (89:ED:34:13:AF:7B:72:57:76:16:6C:9A:EB:25:AA:FC:1E:39:75:AC — το ίδιο
/// keystore υπογράφει προς το παρόν και τα release APK, βλ. build.gradle.kts).
const String _kGooglePlacesKeyAndroid = 'ΒΑΛΕ_ΕΔΩ_ΤΟ_ΝΕΟ_ANDROID_KEY';

/// Κλειδί ΜΟΝΟ για το web admin — restriction "HTTP referrers":
/// taxi-app-web.pages.dev/* (και το δικό σου custom domain αν υπάρχει).
const String _kGooglePlacesKeyWeb = 'ΒΑΛΕ_ΕΔΩ_ΤΟ_ΝΕΟ_WEB_KEY';

/// Κλειδί για τις web υπηρεσίες (Places / Directions) — διαλέγεται αυτόματα
/// ανά platform ώστε καθένα να δουλεύει ΜΟΝΟ από εκεί που πρέπει.
const String kGoogleWebApiKey =
    kIsWeb ? _kGooglePlacesKeyWeb : _kGooglePlacesKeyAndroid;

/// Χώρα + γλώσσα για τα αποτελέσματα αναζήτησης.
const String _kCountry  = 'gr';
const String _kLanguage = 'el';

// ─────────────────────────────────────────────────────────────────────────────
// Μοντέλα
// ─────────────────────────────────────────────────────────────────────────────

/// Μια πρόβλεψη του Autocomplete (δεν έχει ακόμα συντεταγμένες).
class PlacePrediction {
  final String placeId;
  final String mainText;
  final String secondaryText;
  const PlacePrediction({
    required this.placeId,
    required this.mainText,
    required this.secondaryText,
  });

  String get fullText =>
      secondaryText.isEmpty ? mainText : '$mainText, $secondaryText';
}

/// Ένα επιλεγμένο σημείο — περιγραφή + (προαιρετικά) συντεταγμένες.
class PlacePick {
  final String  description;
  final double? lat;
  final double? lng;
  const PlacePick({required this.description, this.lat, this.lng});

  bool get hasCoords => lat != null && lng != null;

  Map<String, dynamic> toJson() =>
      {'description': description, 'lat': lat, 'lng': lng};

  static PlacePick? fromJson(Map<String, dynamic>? j) {
    if (j == null) return null;
    return PlacePick(
      description: j['description'] as String? ?? '',
      lat: (j['lat'] as num?)?.toDouble(),
      lng: (j['lng'] as num?)?.toDouble(),
    );
  }
}

/// Αποτέλεσμα διαδρομής (Directions).
class RouteResult {
  final double  km;          // χιλιόμετρα διαδρομής
  final int?    minutes;     // εκτιμώμενη διάρκεια (λεπτά, με κίνηση αν ζητήθηκε)
  final String? polyline;    // encoded polyline (μπορεί να είναι null)
  const RouteResult({required this.km, this.minutes, this.polyline});
}

// ─────────────────────────────────────────────────────────────────────────────
// PlacesService — κλήσεις προς Google (Places API New + Routes API)
// ─────────────────────────────────────────────────────────────────────────────

class PlacesService {
  PlacesService._();

  static Future<Map<String, dynamic>?> _request(
    Uri uri, {
    String method = 'GET',
    Map<String, String> headers = const {},
    Object? body,
  }) async {
    try {
      return await platformJsonRequest(
        uri,
        method: method,
        headers: headers,
        body: body,
      );
    } on PlatformHttpException catch (e) {
      // Διατηρούμε το ίδιο PlacesException interface για τον υπόλοιπο κώδικα.
      throw PlacesException(e.status, e.message);
    }
  }

  /// Αναζήτηση σημείων / οδών — Places API (New) :autocomplete.
  static Future<List<PlacePrediction>> autocomplete(
    String input, {
    String? sessionToken,
  }) async {
    final q = input.trim();
    if (q.length < 2) return [];

    final uri = Uri.https('places.googleapis.com', '/v1/places:autocomplete');
    final data = await _request(
      uri,
      method: 'POST',
      headers: {'X-Goog-Api-Key': kGoogleWebApiKey},
      body: {
        'input':                q,
        'languageCode':         _kLanguage,
        'regionCode':           _kCountry,
        'includedRegionCodes':  [_kCountry],
        'sessionToken': ?sessionToken,
      },
    );
    if (data == null) return [];

    final suggestions = (data['suggestions'] as List? ?? []);
    final out = <PlacePrediction>[];
    for (final s in suggestions) {
      final pp = (s as Map)['placePrediction'] as Map<String, dynamic>?;
      if (pp == null) continue;
      final sf  = pp['structuredFormat'] as Map<String, dynamic>?;
      final main = sf?['mainText']?['text'] as String?;
      final sec  = sf?['secondaryText']?['text'] as String?;
      final full = pp['text']?['text'] as String?;
      final id   = pp['placeId'] as String? ?? '';
      if (id.isEmpty) continue;
      out.add(PlacePrediction(
        placeId:       id,
        mainText:      main ?? full ?? '',
        secondaryText: sec ?? '',
      ));
    }
    return out;
  }

  /// Λεπτομέρειες σημείου → συντεταγμένες — Places API (New) GET /v1/places/{id}.
  static Future<PlacePick?> details(
    String placeId,
    String fallbackDescription, {
    String? sessionToken,
  }) async {
    final uri = Uri.https(
      'places.googleapis.com',
      '/v1/places/$placeId',
      {
        'languageCode': _kLanguage,
        'sessionToken': ?sessionToken,
      },
    );
    final data = await _request(
      uri,
      headers: {
        'X-Goog-Api-Key':   kGoogleWebApiKey,
        'X-Goog-FieldMask': 'location,formattedAddress,displayName',
      },
    );
    if (data == null) return null;

    final loc = data['location'] as Map<String, dynamic>?;
    if (loc == null) return null;

    final name = data['displayName']?['text'] as String? ?? '';
    final addr = data['formattedAddress'] as String? ?? '';
    String desc = fallbackDescription;
    if (name.isNotEmpty && addr.isNotEmpty) {
      desc = addr.startsWith(name) ? addr : '$name, $addr';
    } else if (addr.isNotEmpty) {
      desc = addr;
    } else if (name.isNotEmpty) {
      desc = name;
    }

    return PlacePick(
      description: desc,
      lat: (loc['latitude']  as num?)?.toDouble(),
      lng: (loc['longitude'] as num?)?.toDouble(),
    );
  }

  /// Διαδρομή οδήγησης μεταξύ δύο σημείων — Routes API computeRoutes.
  /// Επιστρέφει null αν αποτύχει — ο καλών κάνει fallback σε ευθεία.
  ///
  /// [departureTime] : αν δοθεί (π.χ. η ώρα ενός ραντεβού στο μέλλον), ο χρόνος
  /// υπολογίζεται με πρόβλεψη κίνησης για εκείνη την ώρα. Αν είναι null, ο χρόνος
  /// υπολογίζεται με την τρέχουσα κίνηση (κατάλληλο για άμεσες δουλειές).
  static Future<RouteResult?> route({
    required double fromLat,
    required double fromLng,
    required double toLat,
    required double toLng,
    DateTime? departureTime,
  }) async {
    final uri =
        Uri.https('routes.googleapis.com', '/directions/v2:computeRoutes');
    try {
      // Το Routes API δέχεται departureTime μόνο για ΜΕΛΛΟΝΤΙΚΗ ώρα.
      final now = DateTime.now();
      final useDeparture =
          departureTime != null && departureTime.isAfter(now);

      final body = <String, dynamic>{
        'origin': {
          'location': {
            'latLng': {'latitude': fromLat, 'longitude': fromLng},
          },
        },
        'destination': {
          'location': {
            'latLng': {'latitude': toLat, 'longitude': toLng},
          },
        },
        'travelMode':         'DRIVE',
        // TRAFFIC_AWARE_OPTIMAL για ραντεβού (πρόβλεψη), TRAFFIC_AWARE για τώρα.
        'routingPreference':
            useDeparture ? 'TRAFFIC_AWARE_OPTIMAL' : 'TRAFFIC_AWARE',
        'languageCode':       _kLanguage,
        'units':              'METRIC',
        if (useDeparture)
          'departureTime': departureTime.toUtc().toIso8601String(),
      };

      final data = await _request(
        uri,
        method: 'POST',
        headers: {
          'X-Goog-Api-Key':   kGoogleWebApiKey,
          'X-Goog-FieldMask':
              'routes.distanceMeters,routes.duration,routes.polyline.encodedPolyline',
        },
        body: body,
      );
      if (data == null) return null;
      final routes = data['routes'] as List? ?? [];
      if (routes.isEmpty) return null;
      final r0 = routes.first as Map<String, dynamic>;
      final meters = (r0['distanceMeters'] as num?)?.toDouble() ?? 0;
      if (meters <= 0) return null;
      final poly = r0['polyline']?['encodedPolyline'] as String?;
      // duration έρχεται ως string δευτερολέπτων, π.χ. "1234s".
      final minutes = _parseDurationMinutes(r0['duration']);
      return RouteResult(
          km: meters / 1000.0, minutes: minutes, polyline: poly);
    } catch (_) {
      return null;
    }
  }

  /// Μετατροπή του πεδίου duration του Routes API ("1234s") σε λεπτά.
  static int? _parseDurationMinutes(dynamic raw) {
    if (raw == null) return null;
    final s = raw.toString().trim();
    final numStr = s.endsWith('s') ? s.substring(0, s.length - 1) : s;
    final secs = double.tryParse(numStr);
    if (secs == null || secs <= 0) return null;
    return (secs / 60).round();
  }

  /// Αντίστροφη γεωκωδικοποίηση: συντεταγμένες → διεύθυνση (Geocoding API).
  /// Επιστρέφει null σε αποτυχία — ο καλών βάζει fallback περιγραφή.
  static Future<String?> reverseGeocode(double lat, double lng) async {
    try {
      final uri = Uri.https('maps.googleapis.com', '/maps/api/geocode/json', {
        'latlng':   '$lat,$lng',
        'key':      kGoogleWebApiKey,
        'language': _kLanguage,
        'region':   _kCountry,
      });
      final data = await _request(uri);
      if (data == null) return null;
      final results = data['results'] as List? ?? [];
      if (results.isEmpty) return null;
      final addr =
          (results.first as Map)['formatted_address'] as String?;
      return (addr == null || addr.trim().isEmpty) ? null : addr.trim();
    } catch (_) {
      return null;
    }
  }
}

class PlacesException implements Exception {
  final String  status;
  final String? message;
  PlacesException(this.status, this.message);
  @override
  String toString() => 'PlacesException($status): ${message ?? ""}';
}

// ─────────────────────────────────────────────────────────────────────────────
// Γεωμετρικά βοηθητικά
// ─────────────────────────────────────────────────────────────────────────────

/// Απόσταση σε χιλιόμετρα (ευθεία γραμμή — Haversine).
double haversineKm(double lat1, double lng1, double lat2, double lng2) {
  const earthR = 6371.0; // km
  final dLat = _deg2rad(lat2 - lat1);
  final dLng = _deg2rad(lng2 - lng1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_deg2rad(lat1)) *
          math.cos(_deg2rad(lat2)) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  return earthR * c;
}

double _deg2rad(double d) => d * (math.pi / 180.0);

/// Μορφοποίηση διάρκειας σε λεπτά → ανθρώπινο κείμενο («25 λεπτά», «1ω 25λ»).
String formatRouteMinutes(int minutes) {
  if (minutes <= 0) return '—';
  if (minutes < 60) return '$minutes λεπτά';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return m == 0 ? '$hω' : '$hω $mλ';
}

/// Αποκωδικοποίηση encoded polyline → λίστα [lat, lng].
List<List<double>> decodePolyline(String encoded) {
  final points = <List<double>>[];
  int index = 0, lat = 0, lng = 0;
  while (index < encoded.length) {
    int b, shift = 0, result = 0;
    do {
      b = encoded.codeUnitAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    final dlat = ((result & 1) != 0) ? ~(result >> 1) : (result >> 1);
    lat += dlat;

    shift = 0;
    result = 0;
    do {
      b = encoded.codeUnitAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    final dlng = ((result & 1) != 0) ? ~(result >> 1) : (result >> 1);
    lng += dlng;

    points.add([lat / 1e5, lng / 1e5]);
  }
  return points;
}

// ─────────────────────────────────────────────────────────────────────────────
// PlaceField — πεδίο "Από / Προς" με αναζήτηση Google
// ─────────────────────────────────────────────────────────────────────────────

class PlaceField extends StatelessWidget {
  final String      label;
  final IconData    icon;
  final PlacePick?  value;
  final ValueChanged<PlacePick> onPicked;

  /// Προαιρετικά: λίστα πελατών για auto-suggest στην κορυφή του search sheet.
  /// Αφορά κυρίως το πεδίο "Από".
  final List<Client> clients;

  /// Καλείται όταν ο χρήστης επιλέξει ΠΕΛΑΤΗ (όχι απλό σημείο Google).
  /// Επιστρέφει τον πελάτη ώστε ο γονέας να γεμίσει "Από" + προτεινόμενες
  /// διαδρομές. Αν είναι null, η επιλογή πελάτη συμπεριφέρεται σαν απλό σημείο.
  final ValueChanged<Client>? onClientPicked;

  const PlaceField({
    super.key,
    required this.label,
    required this.icon,
    required this.value,
    required this.onPicked,
    this.clients = const [],
    this.onClientPicked,
  });

  @override
  Widget build(BuildContext context) {
    final has    = value != null && value!.description.isNotEmpty;
    final coords = value?.hasCoords ?? false;

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () async {
        final picked = await showModalBottomSheet<_PlaceSheetResult>(
          context: context,
          isScrollControlled: true,
          backgroundColor: Colors.white,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          builder: (_) => _PlaceSearchSheet(
            title:   label,
            initial: value?.description ?? '',
            clients: clients,
          ),
        );
        if (picked == null) return;
        if (picked.client != null && onClientPicked != null) {
          onClientPicked!(picked.client!);
        } else if (picked.pick != null) {
          onPicked(picked.pick!);
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: has ? Colors.amber.shade400 : Colors.grey.shade400,
            width: has ? 1.5 : 1,
          ),
        ),
        child: Row(children: [
          Icon(icon, color: has ? Colors.amber.shade800 : Colors.grey),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey[600],
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(
                  has ? value!.description : 'Αναζήτηση στο Google Maps…',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: has ? FontWeight.w600 : FontWeight.normal,
                    color: has ? Colors.black87 : Colors.grey[500],
                  ),
                ),
              ],
            ),
          ),
          if (has && coords)
            Icon(Icons.check_circle_rounded,
                size: 18, color: Colors.green.shade600)
          else if (has && !coords)
            Icon(Icons.error_outline_rounded,
                size: 18, color: Colors.orange.shade700)
          else
            Icon(Icons.search_rounded, size: 20, color: Colors.grey[500]),
          const SizedBox(width: 6),
          // ── Πινέζα: επιλογή ακριβούς σημείου στον χάρτη ──────────────────
          // Εμφανίζεται ΜΟΝΟ όταν ο χάρτης-picker είναι διαθέσιμος (κινητό).
          // Στο web κρύβεται — η εύρεση σημείου γίνεται μέσω αναζήτησης Google.
          if (kMapPickerAvailable)
            Material(
              color: Colors.red.shade50,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () async {
                  final picked = await openMapPicker(
                    context,
                    title: label.replaceAll('*', '').trim(),
                    initialLat: value?.hasCoords ?? false ? value!.lat : null,
                    initialLng: value?.hasCoords ?? false ? value!.lng : null,
                  );
                  if (picked != null) onPicked(picked);
                },
                child: Padding(
                  padding: const EdgeInsets.all(7),
                  child: Icon(Icons.push_pin_rounded,
                      size: 19, color: Colors.red.shade700),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}

// ─── Αποτέλεσμα search sheet: είτε σημείο Google είτε επιλογή πελάτη ─────────

class _PlaceSheetResult {
  final PlacePick? pick;
  final Client?    client;
  const _PlaceSheetResult({this.pick, this.client});
}

// ─── Bottom sheet αναζήτησης ────────────────────────────────────────────────

class _PlaceSearchSheet extends StatefulWidget {
  final String title;
  final String initial;
  final List<Client> clients;
  const _PlaceSearchSheet({
    required this.title,
    required this.initial,
    this.clients = const [],
  });

  @override
  State<_PlaceSearchSheet> createState() => _PlaceSearchSheetState();
}

class _PlaceSearchSheetState extends State<_PlaceSearchSheet> {
  final _ctrl = TextEditingController();
  Timer?  _debounce;
  List<PlacePrediction> _results = [];
  bool    _loading = false;
  String? _error;
  late final String _sessionToken;

  @override
  void initState() {
    super.initState();
    _sessionToken =
        DateTime.now().millisecondsSinceEpoch.toString();
    _ctrl.text = widget.initial;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 380), () => _search(v));
  }

  /// Πελάτες που ταιριάζουν με το τρέχον κείμενο (ή όλοι αν κενό).
  List<Client> get _matchingClients {
    if (widget.clients.isEmpty) return const [];
    final q = _ctrl.text.trim().toLowerCase();
    if (q.isEmpty) return widget.clients;
    return widget.clients.where((c) {
      return c.name.toLowerCase().contains(q) ||
          c.fromName.toLowerCase().contains(q);
    }).toList();
  }

  Future<void> _search(String v) async {
    if (v.trim().length < 2) {
      setState(() {
        _results = [];
        _error   = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error   = null;
    });
    try {
      final res = await PlacesService.autocomplete(v,
          sessionToken: _sessionToken);
      if (!mounted) return;
      setState(() {
        _results = res;
        _loading = false;
      });
    } on PlacesException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error   = _friendlyError(e);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error   = 'Δεν υπάρχει σύνδεση για αναζήτηση.';
      });
    }
  }

  // Μετατρέπει το σφάλμα του Google σε κατανοητό μήνυμα.
  String _friendlyError(PlacesException e) {
    final msg = (e.message ?? '').toLowerCase();
    if (e.status.contains('403') ||
        e.status == 'REQUEST_DENIED' ||
        msg.contains('blocked') ||
        msg.contains('referer') ||
        msg.contains('not authorized') ||
        msg.contains('permission')) {
      return 'Το Google απέρριψε την αναζήτηση (403).\n\n'
          'Το API key είναι κλειδωμένο. Στο Google Cloud Console:\n'
          '• Application restrictions → "None" (ή χωρίς περιορισμό Android)\n'
          '• API restrictions → να επιτρέπει "Places API (New)"\n'
          '• Να υπάρχει ενεργή χρέωση (Billing) στο project.';
    }
    if (msg.contains('billing')) {
      return 'Δεν είναι ενεργή η χρέωση (Billing) στο Google Cloud project.';
    }
    if (e.status == 'NETWORK') {
      return 'Δεν υπάρχει σύνδεση για αναζήτηση.';
    }
    final detail = (e.message != null && e.message!.isNotEmpty)
        ? '\n${e.message}'
        : '';
    return 'Σφάλμα αναζήτησης: ${e.status}$detail';
  }

  Future<void> _pick(PlacePrediction p) async {
    setState(() => _loading = true);
    final pick = await PlacesService.details(
      p.placeId, p.fullText, sessionToken: _sessionToken,
    );
    if (!mounted) return;
    Navigator.pop(
      context,
      _PlaceSheetResult(
        pick: pick ?? PlacePick(description: p.fullText),
      ),
    );
  }

  void _useTyped() {
    final t = _ctrl.text.trim();
    if (t.isEmpty) return;
    Navigator.pop(
        context, _PlaceSheetResult(pick: PlacePick(description: t)));
  }

  void _pickClient(Client c) {
    Navigator.pop(context, _PlaceSheetResult(client: c));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.78,
        child: Column(children: [
          const SizedBox(height: 12),
          const SheetHandle(bottomMargin: 0),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
            child: Row(children: [
              const Icon(Icons.place_rounded, color: Colors.amber),
              const SizedBox(width: 8),
              Text(widget.title,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold)),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _ctrl,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              onChanged: _onChanged,
              onSubmitted: (_) => _useTyped(),
              decoration: InputDecoration(
                hintText: 'Πληκτρολόγησε διεύθυνση ή σημείο…',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _ctrl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear_rounded),
                        onPressed: () {
                          _ctrl.clear();
                          setState(() => _results = []);
                        },
                      ),
                filled: true,
                fillColor: Colors.grey.shade100,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          if (_matchingClients.isNotEmpty) _buildClientsStrip(),
          Expanded(child: _buildBody()),
        ]),
      ),
    );
  }

  // Λωρίδα προτεινόμενων πελατών (auto-suggest στο "Από").
  Widget _buildClientsStrip() {
    final clients = _matchingClients;
    return Container(
      constraints: const BoxConstraints(maxHeight: 220),
      margin: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 4, 16, 4),
            child: Row(children: [
              Icon(Icons.star_rounded, size: 16, color: Colors.amber.shade700),
              const SizedBox(width: 6),
              Text('Πελάτες',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey[700])),
            ]),
          ),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 4),
              itemCount: clients.length,
              separatorBuilder: (_, _) =>
                  Divider(height: 1, color: Colors.grey.shade100),
              itemBuilder: (_, i) {
                final c = clients[i];
                return ListTile(
                  dense: true,
                  leading: Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                        color: Colors.amber.shade100,
                        borderRadius: BorderRadius.circular(9)),
                    child: const Icon(Icons.person_pin_circle_rounded,
                        color: Colors.amber, size: 20),
                  ),
                  title: Text(c.name,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 14)),
                  subtitle: c.fromName.isEmpty
                      ? null
                      : Text(c.fromName,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12)),
                  trailing: c.routes.isEmpty
                      ? null
                      : Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                              color: Colors.amber.shade50,
                              borderRadius: BorderRadius.circular(10)),
                          child: Text('${c.routes.length} διαδρομές',
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.amber.shade900)),
                        ),
                  onTap: () => _pickClient(c),
                );
              },
            ),
          ),
          Divider(height: 1, color: Colors.grey.shade200),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
          child: CircularProgressIndicator(color: Colors.amber));
    }
    if (_error != null) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(Icons.cloud_off_rounded,
                size: 44, color: Colors.grey.shade400),
            const SizedBox(height: 10),
            Text(_error!,
                textAlign: TextAlign.left,
                style: TextStyle(color: Colors.grey[600])),
            const SizedBox(height: 16),
            if (_ctrl.text.trim().isNotEmpty)
              OutlinedButton.icon(
                onPressed: _useTyped,
                icon: const Icon(Icons.edit_location_alt_rounded),
                label: Text('Χρήση «${_ctrl.text.trim()}» χωρίς σημείο'),
              ),
          ],
        ),
      );
    }
    if (_results.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _ctrl.text.trim().length < 2
                ? 'Γράψε τουλάχιστον 2 χαρακτήρες'
                : 'Κανένα αποτέλεσμα',
            style: TextStyle(color: Colors.grey[500]),
          ),
        ),
      );
    }
    return ListView.separated(
      itemCount: _results.length,
      separatorBuilder: (_, _) => Divider(
          height: 1, color: Colors.grey.shade100),
      itemBuilder: (_, i) {
        final p = _results[i];
        return ListTile(
          leading: const Icon(Icons.location_on_rounded,
              color: Colors.amber),
          title: Text(p.mainText,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: p.secondaryText.isEmpty
              ? null
              : Text(p.secondaryText,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
          onTap: () => _pick(p),
        );
      },
    );
  }
}

