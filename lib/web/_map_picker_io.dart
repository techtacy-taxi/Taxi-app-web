// ============================================================================
// FILE: ./lib/web/_map_picker_io.dart
// ============================================================================
//
// Επιλογή σημείου στον χάρτη για Android / iOS.
// Περιέχει το MapPointPickerPage (μεταφέρθηκε από το places_service.dart)
// και την openMapPicker(...) που το ανοίγει.
//
// ⚠️  Συμπεριφορά Android: ΑΚΡΙΒΩΣ ίδια με πριν — ίδιο GoogleMap, ίδια
//     σταθερή πινέζα στο κέντρο, ίδιο reverse-geocode στο «ΟΚ».

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../jobs/places_service.dart';

/// Στο IO (κινητό) ο χάρτης ΕΙΝΑΙ διαθέσιμος.
const bool kMapPickerAvailable = true;

/// Ανοίγει τον picker χάρτη και επιστρέφει το επιλεγμένο σημείο (ή null).
/// Δέχεται απλά double ώστε να μην χρειάζεται ο καλών να ξέρει τον τύπο LatLng.
Future<PlacePick?> openMapPicker(
  BuildContext context, {
  required String title,
  double? initialLat,
  double? initialLng,
}) {
  final LatLng? initial =
      (initialLat != null && initialLng != null)
          ? LatLng(initialLat, initialLng)
          : null;
  return Navigator.of(context).push<PlacePick>(
    MaterialPageRoute(
      builder: (_) => _MapPointPickerPage(title: title, initial: initial),
    ),
  );
}

// ─── Σελίδα picker (πρώην MapPointPickerPage στο places_service) ────────────

class _MapPointPickerPage extends StatefulWidget {
  final String  title;
  final LatLng? initial;
  const _MapPointPickerPage({required this.title, this.initial});

  @override
  State<_MapPointPickerPage> createState() => _MapPointPickerPageState();
}

class _MapPointPickerPageState extends State<_MapPointPickerPage> {
  static const LatLng _kAthens = LatLng(37.9838, 23.7275);

  late LatLng _target = widget.initial ?? _kAthens;
  bool _resolving = false;

  Future<void> _confirm() async {
    if (_resolving) return;
    setState(() => _resolving = true);

    final lat = _target.latitude;
    final lng = _target.longitude;
    String? addr;
    try {
      addr = await PlacesService.reverseGeocode(lat, lng);
    } catch (_) {}

    if (!mounted) return;
    final description = addr ??
        'Πινέζα: ${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';
    Navigator.of(context).pop(
      PlacePick(description: description, lat: lat, lng: lng),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Σημείο στον χάρτη — ${widget.title}'),
        backgroundColor: Colors.amber,
        foregroundColor: Colors.black87,
      ),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: _target,
              zoom: widget.initial != null ? 16 : 12,
            ),
            onCameraMove: (pos) => _target = pos.target,
            myLocationEnabled: true,
            myLocationButtonEnabled: true,
            zoomControlsEnabled: false,
            compassEnabled: false,
            mapToolbarEnabled: false,
          ),
          IgnorePointer(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 42),
                child: Icon(Icons.location_pin,
                    size: 46,
                    color: Colors.red.shade700,
                    shadows: const [
                      Shadow(blurRadius: 6, color: Colors.black38),
                    ]),
              ),
            ),
          ),
          Positioned(
            top: 12, left: 16, right: 16,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.93),
                borderRadius: BorderRadius.circular(12),
                boxShadow: const [
                  BoxShadow(blurRadius: 8, color: Colors.black12),
                ],
              ),
              child: const Text(
                'Μετακίνησε τον χάρτη ώστε η πινέζα να δείχνει το σημείο '
                'και πάτησε ΟΚ.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13.5),
              ),
            ),
          ),
          Positioned(
            left: 16, right: 16,
            bottom: 24 + MediaQuery.of(context).padding.bottom,
            child: SizedBox(
              height: 52,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green.shade600,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  textStyle: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold),
                ),
                onPressed: _resolving ? null : _confirm,
                icon: _resolving
                    ? const SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.4, color: Colors.white))
                    : const Icon(Icons.check_rounded),
                label: Text(_resolving ? 'Εύρεση διεύθυνσης…' : 'ΟΚ'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
