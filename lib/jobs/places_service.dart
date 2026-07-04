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
// ⚠️  API KEY — ΠΩΣ ΔΟΥΛΕΥΕΙ ΤΩΡΑ (ΑΛΛΑΓΗ ΑΣΦΑΛΕΙΑΣ)
//  Ο client (Android + web admin) ΔΕΝ καλεί πλέον τη Google απευθείας και
//  ΔΕΝ κρατάει κανένα API key. Λόγος: το Places API (New) καλείται με απλή
//  HTTP/REST κλήση (όχι μέσω του native Android SDK), και η Google ΔΕΝ
//  μπορεί να επαληθεύσει "Android apps" restriction (package+SHA-1) σε
//  τέτοιες κλήσεις — ένα Android-restricted κλειδί απορρίπτει πάντα με 403,
//  ενώ ένα unrestricted κλειδί θα ήταν εκτεθειμένο μέσα στο APK.
//
//  Αντ' αυτού, όλες οι κλήσεις (autocomplete / place details / route /
//  reverse geocode) περνάνε από 4 Cloud Functions — proxy προς τη Google με
//  το κλειδί ΜΟΝΟ server-side (secret ROUTES_API_KEY, ίδιο με του
//  estimatePrice). Απαιτείται σύνδεση (Firebase Auth) — δουλεύει ίδια σε
//  Android ΚΑΙ web admin, αφού είναι το ίδιο κοινό αρχείο.
//
//  Cloud Functions (functions/index.js): placesAutocomplete, placesDetails,
//  placesRoute, placesReverseGeocode.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import 'client_model.dart';
import 'job_shared_widgets.dart';

// Διαστρωματικό βοηθητικό (επιλέγεται αυτόματα ανά platform):
//  • _map_picker    : επιλογή σημείου στον χάρτη (GoogleMap σε κινητό,
//                     μη διαθέσιμο σε web)
import '../web/_map_picker.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Μοντέλα
// ─────────────────────────────────────────────────────────────────────────────

/// Αναγνωρίζει αν το κείμενο περιέχει έναν κωδικό τοποθεσίας Google Maps
/// (Plus Code / Open Location Code) — π.χ. "M3W4+9W Λαύριο" ή global
/// "8FVC9G8F+6X". Το Places Autocomplete δεν τους καταλαβαίνει καλά ως
/// ελεύθερο κείμενο· γι' αυτό λύνονται ξεχωριστά μέσω resolvePlusCode
/// (Geocoding API, που τους δέχεται απευθείας — και με τοπωνύμιο μετά).
final RegExp _plusCodeRegex = RegExp(
  r'\b[23456789CFGHJMPQRVWX]{4,8}\+[23456789CFGHJMPQRVWX]{2,3}\b',
  caseSensitive: false,
);
bool looksLikePlusCode(String input) => _plusCodeRegex.hasMatch(input.trim());

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
// PlacesService — κλήσεις προς τις Cloud Functions (proxy Places/Routes/Geocoding)
// ─────────────────────────────────────────────────────────────────────────────

class PlacesService {
  PlacesService._();

  /// Καλεί μια callable Cloud Function και επιστρέφει το αποτέλεσμα ως
  /// Map<String, dynamic> — με round-trip μέσω JSON ώστε να δουλεύει ομοιόμορφα
  /// σε Android/iOS/web (το raw data ενός callable μπορεί να έρθει ως
  /// Map<Object?, Object?> ανά platform).
  static Future<Map<String, dynamic>> _call(
    String name,
    Map<String, dynamic> payload,
  ) async {
    try {
      final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable(name);
      final result = await callable.call(payload);
      final decoded = jsonDecode(jsonEncode(result.data));
      return (decoded as Map).cast<String, dynamic>();
    } on FirebaseFunctionsException catch (e) {
      throw PlacesException(e.code, e.message);
    }
  }

  /// Αναζήτηση σημείων / οδών — proxy Places API (New) :autocomplete.
  static Future<List<PlacePrediction>> autocomplete(
    String input, {
    String? sessionToken,
  }) async {
    final q = input.trim();
    if (q.length < 2) return [];

    final data = await _call('placesAutocomplete', {
      'input': q,
      'sessionToken': ?sessionToken,
    });

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

  /// Λύνει έναν κωδικό τοποθεσίας Google Maps (Plus Code) σε συντεταγμένες +
  /// διεύθυνση — proxy Geocoding API. Επιστρέφει null αν δεν βρέθηκε τίποτα.
  static Future<PlacePick?> resolvePlusCode(String code) async {
    final q = code.trim();
    if (q.isEmpty) return null;
    final data = await _call('resolvePlusCode', {'code': q});
    final results = data['results'] as List? ?? [];
    if (results.isEmpty) return null;
    final r0 = results.first as Map<String, dynamic>;
    final loc = (r0['geometry'] as Map?)?['location'] as Map?;
    if (loc == null) return null;
    final addr = r0['formatted_address'] as String? ?? q;
    return PlacePick(
      description: addr,
      lat: (loc['lat'] as num?)?.toDouble(),
      lng: (loc['lng'] as num?)?.toDouble(),
    );
  }

  /// Λεπτομέρειες σημείου → συντεταγμένες — proxy Places API (New) place details.
  static Future<PlacePick?> details(
    String placeId,
    String fallbackDescription, {
    String? sessionToken,
  }) async {
    final data = await _call('placesDetails', {
      'placeId': placeId,
      'sessionToken': ?sessionToken,
    });

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

  /// Διαδρομή οδήγησης μεταξύ δύο σημείων — proxy Routes API computeRoutes.
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
    try {
      final data = await _call('placesRoute', {
        'fromLat': fromLat, 'fromLng': fromLng,
        'toLat':   toLat,   'toLng':   toLng,
        if (departureTime != null)
          'departureTimeIso': departureTime.toUtc().toIso8601String(),
      });
      final routes = data['routes'] as List? ?? [];
      if (routes.isEmpty) return null;
      final r0 = routes.first as Map<String, dynamic>;
      final meters = (r0['distanceMeters'] as num?)?.toDouble() ?? 0;
      if (meters <= 0) return null;
      final poly = r0['polyline']?['encodedPolyline'] as String?;
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

  /// Αντίστροφη γεωκωδικοποίηση: συντεταγμένες → διεύθυνση (proxy Geocoding API).
  /// Επιστρέφει null σε αποτυχία — ο καλών βάζει fallback περιγραφή.
  static Future<String?> reverseGeocode(double lat, double lng) async {
    try {
      final data = await _call('placesReverseGeocode', {'lat': lat, 'lng': lng});
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
  // Αν το τρέχον κείμενο είναι κωδικός τοποθεσίας (Plus Code) που λύθηκε.
  PlacePick? _plusCodePick;

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
    final q = v.trim();
    if (q.length < 2) {
      setState(() {
        _results = [];
        _error   = null;
        _plusCodePick = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error   = null;
      _plusCodePick = null;
    });

    // Κωδικός τοποθεσίας Google Maps (Plus Code), π.χ. "M3W4+9W Λαύριο" — το
    // autocomplete δεν τους καταλαβαίνει καλά, λύνονται ξεχωριστά.
    if (looksLikePlusCode(q)) {
      try {
        final pick = await PlacesService.resolvePlusCode(q);
        if (!mounted) return;
        setState(() {
          _results      = [];
          _loading      = false;
          _plusCodePick = pick;
          _error = pick == null
              ? 'Δεν βρέθηκε αυτός ο κωδικός τοποθεσίας.'
              : null;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error   = 'Δεν ήταν δυνατή η εύρεση του κωδικού τοποθεσίας.';
        });
      }
      return;
    }

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

  // Μετατρέπει το σφάλμα σε κατανοητό μήνυμα. Οι κλήσεις πλέον περνάνε από
  // Cloud Function (proxy) — τα πιθανά σφάλματα είναι κυρίως σύνδεση/auth,
  // όχι πια θέμα κλειδιού/restriction στη συσκευή.
  String _friendlyError(PlacesException e) {
    final code = e.status.toLowerCase();
    if (code.contains('unauthenticated')) {
      return 'Χρειάζεται ξανά σύνδεση στην εφαρμογή για αναζήτηση.';
    }
    if (code.contains('unavailable') || code == 'network') {
      return 'Δεν υπάρχει σύνδεση για αναζήτηση.';
    }
    final detail = (e.message != null && e.message!.isNotEmpty)
        ? '\n${e.message}'
        : '';
    return 'Σφάλμα αναζήτησης.$detail';
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
    // Αν λύθηκε ήδη ως Plus Code, χρησιμοποίησε τις πραγματικές συντεταγμένες
    // αντί για απλό κείμενο χωρίς σημείο στο χάρτη.
    if (_plusCodePick != null) {
      Navigator.pop(context, _PlaceSheetResult(pick: _plusCodePick));
      return;
    }
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
    if (_plusCodePick != null) {
      final pick = _plusCodePick!;
      return ListView(
        children: [
          ListTile(
            leading: const CircleAvatar(
              backgroundColor: Colors.amber,
              child: Icon(Icons.grid_view_rounded, color: Colors.white),
            ),
            title: const Text('Κωδικός τοποθεσίας (Plus Code)',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            subtitle: Text(pick.description,
                maxLines: 2, overflow: TextOverflow.ellipsis),
            trailing: const Icon(Icons.check_circle_rounded,
                color: Colors.green),
            onTap: () => Navigator.pop(
                context, _PlaceSheetResult(pick: pick)),
          ),
          Divider(height: 1, color: Colors.grey.shade200),
        ],
      );
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
