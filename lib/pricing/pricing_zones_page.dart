// lib/pricing/pricing_zones_page.dart
//
// «Ζώνες & Τιμές» — μόνο master.
//
// Διαχείριση:
//   • Ζώνες τιμολόγησης: κύκλοι πάνω στον χάρτη (κέντρο + ακτίνα), π.χ.
//     «Λαύριο», «Αεροδρόμιο», «Λαγονήσι». Προσθήκη με tap στον χάρτη,
//     μετακίνηση με tap σε νέο σημείο, επεξεργασία ονόματος/ακτίνας, διαγραφή.
//   • Διαδρομές: πάγιες τιμές Ταξί/Βαν (+ προαιρετικά τιμή ξένου πελάτη)
//     ανάμεσα σε δύο ζώνες, με κατεύθυνση (Από → Προς).
//   • Δυναμικός τύπος: βάση/χλμ/λεπτό/ελάχιστη χρέωση/νυχτερινές προσαυξήσεις/
//     επιβάρυνση Βαν/βαλίτσες/παιδικά καθίσματα — για διαδρομές εκτός ζωνών.
//
// Ίδιο Firestore (pricing_zones, pricing_routes, app_settings/pricing) το
// διαβάζει η δημόσια φόρμα κράτησης μέσω του Cloud Function estimatePrice —
// ό,τι αλλάξει εδώ ισχύει αμέσως και εκεί.
//
// Χρησιμοποιείται και από τον Web Admin Panel (admin_shell.dart) και από την
// Android εφαρμογή (menu χάρτη, μόνο master) — ίδιο widget, ίδιο lib/.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../jobs/job_shared_widgets.dart';

const Color _kAmber     = Color(0xFFFFB300);
const Color _kAmberDark = Color(0xFF5A3D00);

// ─── Models ─────────────────────────────────────────────────────────────────

class PricingZone {
  final String id;
  final String name;
  final double lat;
  final double lng;
  final double radius; // μέτρα

  PricingZone({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
    required this.radius,
  });

  factory PricingZone.fromDoc(QueryDocumentSnapshot<Map<String, dynamic>> d) {
    final m = d.data();
    return PricingZone(
      id:     d.id,
      name:   (m['name'] ?? '') as String,
      lat:    (m['lat'] as num?)?.toDouble() ?? 0,
      lng:    (m['lng'] as num?)?.toDouble() ?? 0,
      radius: (m['radius'] as num?)?.toDouble() ?? 3000,
    );
  }
}

class PricingRoute {
  final String id;
  final String fromZoneId;
  final String toZoneId;
  final double taxi;
  final double van;
  final double? taxiForeign;
  final double? vanForeign;

  PricingRoute({
    required this.id,
    required this.fromZoneId,
    required this.toZoneId,
    required this.taxi,
    required this.van,
    this.taxiForeign,
    this.vanForeign,
  });

  factory PricingRoute.fromDoc(QueryDocumentSnapshot<Map<String, dynamic>> d) {
    final m = d.data();
    double? numOrNull(dynamic v) => v == null ? null : (v as num).toDouble();
    return PricingRoute(
      id:          d.id,
      fromZoneId:  (m['fromZoneId'] ?? '') as String,
      toZoneId:    (m['toZoneId'] ?? '') as String,
      taxi:        (m['taxi'] as num?)?.toDouble() ?? 0,
      van:         (m['van']  as num?)?.toDouble() ?? 0,
      taxiForeign: numOrNull(m['taxiForeign']),
      vanForeign:  numOrNull(m['vanForeign']),
    );
  }
}

// ─── Page ───────────────────────────────────────────────────────────────────

enum _MapMode { view, placeZone, moveZone }

class PricingZonesPage extends StatefulWidget {
  const PricingZonesPage({super.key});

  @override
  State<PricingZonesPage> createState() => _PricingZonesPageState();
}

class _PricingZonesPageState extends State<PricingZonesPage> {
  final _db = FirebaseFirestore.instance;
  GoogleMapController? _mapCtrl;
  _MapMode _mode = _MapMode.view;
  String? _selectedZoneId;
  bool _didFitBounds = false;

  // Επεξεργασία επιλεγμένης/νέας ζώνης — ΧΩΡΙΣ popup:
  //  • όνομα: πεδίο στην πάνω κίτρινη μπάρα (AppBar)
  //  • ακτίνα: slider σε μπάρα τέρμα κάτω (πάνω από το navigation bar)
  //  • Αποθήκευση: κουμπί τέρμα δεξιά στην πάνω μπάρα
  final _nameCtrl = TextEditingController();
  double _editRadius = 3000;
  LatLng? _dragPosition;      // θέση κατά τη μετακίνηση / νέα ζώνη
  LatLng _cameraCenter = const LatLng(37.9838, 23.7275);
  bool _saving = false;

  bool get _isEditing =>
      _mode == _MapMode.placeZone || _selectedZoneId != null;

  static const CameraPosition _initialCamera = CameraPosition(
    target: LatLng(37.9838, 23.7275), // Αθήνα
    zoom: 9.3,
  );

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.of(context).size.width >= 900;

    // Η πάνω κίτρινη μπάρα: σε λειτουργία επεξεργασίας δείχνει το πεδίο
    // ονόματος + Αποθήκευση (τέρμα δεξιά). Αλλιώς τον κανονικό τίτλο.
    final appBar = AppBar(
      backgroundColor: _kAmber,
      foregroundColor: Colors.black87,
      title: _isEditing
          ? TextField(
              controller: _nameCtrl,
              autofocus: _mode == _MapMode.placeZone && _nameCtrl.text.isEmpty,
              decoration: const InputDecoration(
                hintText: 'Όνομα ζώνης (π.χ. Λαύριο)',
                border: InputBorder.none,
                hintStyle: TextStyle(color: Colors.black45),
              ),
              style: const TextStyle(
                  color: Colors.black87, fontWeight: FontWeight.w600),
            )
          : const Text('Ζώνες & Τιμές'),
      actions: [
        if (_isEditing) ...[
          TextButton(
            onPressed: _saving ? null : _cancelEdit,
            child: const Text('Άκυρο', style: TextStyle(color: Colors.black54)),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green.shade700,
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.check_rounded, size: 18),
              label: Text(_saving ? '...' : 'Αποθήκευση'),
              onPressed: _saving ? null : _saveZone,
            ),
          ),
        ],
      ],
      bottom: isDesktop
          ? null
          : const TabBar(
              labelColor: Colors.black87,
              unselectedLabelColor: Colors.black54,
              indicatorColor: Colors.black87,
              tabs: [
                Tab(text: 'Χάρτης'),
                Tab(text: 'Διαδρομές'),
                Tab(text: 'Δυναμικός τύπος'),
              ],
            ),
    );

    if (isDesktop) {
      return Scaffold(
        appBar: appBar,
        body: Row(
          children: [
            Expanded(flex: 3, child: _buildMap()),
            const VerticalDivider(width: 1),
            SizedBox(width: 420, child: _buildPanel()),
          ],
        ),
      );
    }

    // Κινητό: 3 tabs, με SafeArea ώστε τίποτα να μην κρύβεται πίσω από τη
    // μπάρα πλοήγησης του Android.
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: appBar,
        body: SafeArea(
          child: TabBarView(
            children: [
              _buildMap(),
              _RoutesTab(db: _db),
              _PricingConfigTab(db: _db),
            ],
          ),
        ),
      ),
    );
  }

  // ── Έναρξη/ακύρωση/αποθήκευση επεξεργασίας ──────────────────────────────

  void _startNewZone() {
    setState(() {
      _mode = _MapMode.placeZone;
      _selectedZoneId = null;
      _nameCtrl.text = '';
      _editRadius = 3000;
      _dragPosition = _cameraCenter; // ξεκινά στο κέντρο του χάρτη
    });
  }

  void _selectZone(PricingZone z) {
    setState(() {
      _mode = _MapMode.view;
      _selectedZoneId = z.id;
      _nameCtrl.text = z.name;
      _editRadius = z.radius;
      _dragPosition = null;
    });
  }

  void _startMove(PricingZone z) {
    setState(() {
      _mode = _MapMode.moveZone;
      _selectedZoneId = z.id;
      _dragPosition = LatLng(z.lat, z.lng);
    });
  }

  void _cancelEdit() {
    setState(() {
      _mode = _MapMode.view;
      _selectedZoneId = null;
      _dragPosition = null;
      _nameCtrl.text = '';
    });
  }

  Future<void> _saveZone() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Δώστε όνομα στη ζώνη')),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      if (_mode == _MapMode.placeZone) {
        final pos = _dragPosition ?? _cameraCenter;
        final ref = await _db.collection('pricing_zones').add({
          'name': name,
          'lat': pos.latitude,
          'lng': pos.longitude,
          'radius': _editRadius,
        });
        if (mounted) {
          setState(() {
            _mode = _MapMode.view;
            _selectedZoneId = ref.id; // η νέα ζώνη μένει επιλεγμένη (μωβ)
            _dragPosition = null;
          });
        }
      } else if (_selectedZoneId != null) {
        final data = <String, dynamic>{
          'name': name,
          'radius': _editRadius,
        };
        // Αν έγινε μετακίνηση, αποθηκεύουμε και τη νέα θέση.
        if (_mode == _MapMode.moveZone && _dragPosition != null) {
          data['lat'] = _dragPosition!.latitude;
          data['lng'] = _dragPosition!.longitude;
        }
        await _db.collection('pricing_zones').doc(_selectedZoneId).update(data);
        if (mounted) {
          setState(() {
            _mode = _MapMode.view;
            _dragPosition = null;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: Colors.red,
          content: Text('Απέτυχε η αποθήκευση: $e'),
          duration: const Duration(seconds: 6),
        ));
      }
    }
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _deleteSelected(List<PricingZone> zones) async {
    final z = zones.where((x) => x.id == _selectedZoneId).cast<PricingZone?>().firstOrNull;
    if (z == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Διαγραφή ζώνης;'),
        content: Text(
            'Η ζώνη «${z.name}» θα διαγραφεί. Οι διαδρομές που τη χρησιμοποιούν δεν θα ταιριάζουν πια σε καμία ζώνη.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('Άκυρο')),
          TextButton(
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('Διαγραφή', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok == true) {
      try {
        await _db.collection('pricing_zones').doc(z.id).delete();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            backgroundColor: Colors.red,
            content: Text('Απέτυχε η διαγραφή: $e'),
          ));
        }
      }
      if (mounted) _cancelEdit();
    }
  }

  // ── Χάρτης ────────────────────────────────────────────────────────────────

  void _fitBoundsToZones(List<PricingZone> zones) {
    if (_mapCtrl == null || zones.isEmpty) return;
    if (zones.length == 1) {
      _mapCtrl!.animateCamera(
        CameraUpdate.newLatLngZoom(LatLng(zones.first.lat, zones.first.lng), 11),
      );
      return;
    }
    double minLat = zones.first.lat, maxLat = zones.first.lat;
    double minLng = zones.first.lng, maxLng = zones.first.lng;
    for (final z in zones) {
      if (z.lat < minLat) minLat = z.lat;
      if (z.lat > maxLat) maxLat = z.lat;
      if (z.lng < minLng) minLng = z.lng;
      if (z.lng > maxLng) maxLng = z.lng;
    }
    _mapCtrl!.animateCamera(CameraUpdate.newLatLngBounds(
      LatLngBounds(southwest: LatLng(minLat, minLng), northeast: LatLng(maxLat, maxLng)),
      60,
    ));
  }

  Widget _buildMap() {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _db.collection('pricing_zones').snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Container(
            color: Colors.red.shade50,
            padding: const EdgeInsets.all(16),
            alignment: Alignment.center,
            child: Text(
              'Σφάλμα ανάγνωσης ζωνών:\n${snap.error}\n\n'
              'Πιθανή αιτία: δεν έχουν γίνει deploy οι Firestore rules '
              '(firebase deploy --only firestore:rules).',
              style: const TextStyle(color: Colors.red),
              textAlign: TextAlign.center,
            ),
          );
        }
        final zones = (snap.data?.docs ?? []).map(PricingZone.fromDoc).toList();
        if (zones.isNotEmpty && !_didFitBounds) {
          _didFitBounds = true;
          WidgetsBinding.instance.addPostFrameCallback((_) => _fitBoundsToZones(zones));
        }

        final selected = _selectedZoneId != null
            ? zones.where((z) => z.id == _selectedZoneId).cast<PricingZone?>().firstOrNull
            : null;

        final circles = <Circle>{
          for (final z in zones)
            Circle(
              circleId: CircleId(z.id),
              // Η επιλεγμένη ζώνη ακολουθεί το drag & τη live ακτίνα.
              center: (z.id == _selectedZoneId && _dragPosition != null)
                  ? _dragPosition!
                  : LatLng(z.lat, z.lng),
              radius: z.id == _selectedZoneId ? _editRadius : z.radius,
              consumeTapEvents: true,
              strokeWidth: z.id == _selectedZoneId ? 3 : 1,
              strokeColor: z.id == _selectedZoneId ? Colors.deepPurple : _kAmber,
              fillColor: (z.id == _selectedZoneId ? Colors.deepPurple : _kAmber)
                  .withValues(alpha: 0.18),
              onTap: () => _selectZone(z),
            ),
          // Νέα ζώνη υπό τοποθέτηση — κόκκινος κύκλος.
          if (_mode == _MapMode.placeZone && _dragPosition != null)
            Circle(
              circleId: const CircleId('_newZone'),
              center: _dragPosition!,
              radius: _editRadius,
              strokeWidth: 3,
              strokeColor: Colors.red,
              fillColor: Colors.red.withValues(alpha: 0.18),
            ),
        };

        final markers = <Marker>{};
        if (_mode == _MapMode.moveZone && selected != null) {
          markers.add(Marker(
            markerId: const MarkerId('_dragMarker'),
            position: _dragPosition ?? LatLng(selected.lat, selected.lng),
            draggable: true,
            onDrag: (p) => setState(() => _dragPosition = p),
            onDragEnd: (p) => setState(() => _dragPosition = p),
          ));
        }
        if (_mode == _MapMode.placeZone && _dragPosition != null) {
          markers.add(Marker(
            markerId: const MarkerId('_newZoneMarker'),
            position: _dragPosition!,
            draggable: true,
            icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
            onDrag: (p) => setState(() => _dragPosition = p),
            onDragEnd: (p) => setState(() => _dragPosition = p),
          ));
        }

        return Stack(
          children: [
            GoogleMap(
              initialCameraPosition: _initialCamera,
              circles: circles,
              markers: markers,
              onCameraMove: (pos) => _cameraCenter = pos.target,
              onMapCreated: (c) {
                _mapCtrl = c;
                if (zones.isNotEmpty) {
                  WidgetsBinding.instance.addPostFrameCallback((_) => _fitBoundsToZones(zones));
                }
              },
              myLocationButtonEnabled: false,
              zoomControlsEnabled: true,
            ),
            if (snap.connectionState == ConnectionState.active && zones.isEmpty)
              Positioned(
                top: 72, left: 16, right: 16,
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white, borderRadius: BorderRadius.circular(10),
                    boxShadow: const [BoxShadow(blurRadius: 8, color: Colors.black26)],
                  ),
                  child: const Text(
                    'Δεν βρέθηκε καμία ζώνη στη βάση. Αν μόλις έτρεξες το seed_pricing.js, '
                    'έλεγξε ότι έγινε deploy το firestore.rules — αλλιώς η φόρμα δεν έχει '
                    'άδεια να τις διαβάσει.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ),
            // Πάνω σειρά κουμπιών: Νέα ζώνη + (αν υπάρχει επιλογή) Μετακίνηση/Διαγραφή
            Positioned(
              left: 0, right: 0, top: 12,
              child: Center(
                child: Wrap(
                  spacing: 8,
                  children: [
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _kAmber,
                        foregroundColor: Colors.black87,
                        textStyle: const TextStyle(fontWeight: FontWeight.bold),
                        elevation: 4,
                      ),
                      icon: const Icon(Icons.add_location_alt_rounded, size: 18),
                      label: const Text('Νέα ζώνη'),
                      onPressed: _mode == _MapMode.placeZone ? null : _startNewZone,
                    ),
                    if (selected != null && _mode != _MapMode.placeZone) ...[
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.deepPurple,
                          foregroundColor: Colors.white,
                          elevation: 4,
                        ),
                        icon: const Icon(Icons.open_with_rounded, size: 18),
                        label: Text(_mode == _MapMode.moveZone ? 'Σύρετε…' : 'Μετακίνηση'),
                        onPressed: _mode == _MapMode.moveZone ? null : () => _startMove(selected),
                      ),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red.shade700,
                          foregroundColor: Colors.white,
                          elevation: 4,
                        ),
                        icon: const Icon(Icons.delete_outline_rounded, size: 18),
                        label: const Text('Διαγραφή'),
                        onPressed: () => _deleteSelected(zones),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            // Μπάρα ακτίνας — τέρμα κάτω, ΠΑΝΩ από τη μπάρα πλοήγησης (SafeArea).
            if (_isEditing)
              Positioned(
                left: 0, right: 0, bottom: 0,
                child: SafeArea(
                  top: false,
                  child: Container(
                    margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: const [BoxShadow(blurRadius: 10, color: Colors.black38)],
                    ),
                    child: Row(
                      children: [
                        Text('Ακτίνα: ${(_editRadius / 1000).toStringAsFixed(1)} χλμ',
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                        Expanded(
                          child: Slider(
                            min: 500, max: 20000, divisions: 39,
                            value: _editRadius.clamp(500, 20000),
                            activeColor: _mode == _MapMode.placeZone ? Colors.red : Colors.deepPurple,
                            label: '${(_editRadius / 1000).toStringAsFixed(1)} χλμ',
                            onChanged: (v) => setState(() => _editRadius = v),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildPanel() {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(
            labelColor: Colors.black87,
            indicatorColor: _kAmber,
            tabs: [Tab(text: 'Διαδρομές'), Tab(text: 'Δυναμικός τύπος')],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _RoutesTab(db: _db),
                _PricingConfigTab(db: _db),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Tab: Διαδρομές ────────────────────────────────────────────────────────

class _RoutesTab extends StatelessWidget {
  final FirebaseFirestore db;
  const _RoutesTab({required this.db});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: db.collection('pricing_zones').orderBy('name').snapshots(),
      builder: (context, zoneSnap) {
        final zones = (zoneSnap.data?.docs ?? []).map(PricingZone.fromDoc).toList();
        final zoneName = {for (final z in zones) z.id: z.name};
        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: db.collection('pricing_routes').snapshots(),
          builder: (context, routeSnap) {
            final routes = (routeSnap.data?.docs ?? []).map(PricingRoute.fromDoc).toList();
            return Column(
              children: [
                Expanded(
                  child: routes.isEmpty
                      ? const Center(child: Text('Δεν υπάρχουν διαδρομές ακόμα'))
                      : ListView.separated(
                          padding: const EdgeInsets.all(12),
                          itemCount: routes.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (c, i) {
                            final r = routes[i];
                            final fromN = zoneName[r.fromZoneId] ?? '—';
                            final toN = zoneName[r.toZoneId] ?? '—';
                            return Card(
                              child: ListTile(
                                title: Text('$fromN → $toN'),
                                subtitle: Text(
                                  'Ταξί ${r.taxi.toStringAsFixed(0)}€'
                                  '${r.taxiForeign != null ? " / ξένος ${r.taxiForeign!.toStringAsFixed(0)}€" : ""}'
                                  '  ·  Βαν ${r.van.toStringAsFixed(0)}€'
                                  '${r.vanForeign != null ? " / ξένος ${r.vanForeign!.toStringAsFixed(0)}€" : ""}',
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.edit_rounded),
                                      onPressed: () => _openRouteDialog(context, zones, existing: r),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.delete_outline_rounded, color: Colors.red),
                                      onPressed: () => db.collection('pricing_routes').doc(r.id).delete(),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: AppButton(
                    label: 'Νέα διαδρομή',
                    icon: Icons.add_road_rounded,
                    onPressed: zones.length < 2 ? null : () => _openRouteDialog(context, zones),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _openRouteDialog(BuildContext context, List<PricingZone> zones,
      {PricingRoute? existing}) async {
    String? fromId = existing?.fromZoneId ?? (zones.isNotEmpty ? zones.first.id : null);
    String? toId = existing?.toZoneId ?? (zones.length > 1 ? zones[1].id : null);
    final taxiCtrl  = TextEditingController(text: existing?.taxi.toStringAsFixed(0) ?? '');
    final vanCtrl   = TextEditingController(text: existing?.van.toStringAsFixed(0) ?? '');
    final taxiFCtrl = TextEditingController(text: existing?.taxiForeign?.toStringAsFixed(0) ?? '');
    final vanFCtrl  = TextEditingController(text: existing?.vanForeign?.toStringAsFixed(0) ?? '');

    await showDialog<void>(
      context: context,
      builder: (dctx) => StatefulBuilder(
        builder: (c, setLocal) {
          return AlertDialog(
            title: Text(existing == null ? 'Νέα διαδρομή' : 'Επεξεργασία διαδρομής'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: fromId,
                    decoration: const InputDecoration(labelText: 'Από ζώνη'),
                    items: [for (final z in zones) DropdownMenuItem(value: z.id, child: Text(z.name))],
                    onChanged: (v) => setLocal(() => fromId = v),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: toId,
                    decoration: const InputDecoration(labelText: 'Προς ζώνη'),
                    items: [for (final z in zones) DropdownMenuItem(value: z.id, child: Text(z.name))],
                    onChanged: (v) => setLocal(() => toId = v),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: taxiCtrl, keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Τιμή Ταξί (€)'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: taxiFCtrl, keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Τιμή Ταξί ξένου πελάτη (€) — προαιρετικό'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: vanCtrl, keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Τιμή Βαν (€)'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: vanFCtrl, keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Τιμή Βαν ξένου πελάτη (€) — προαιρετικό'),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(dctx).pop(), child: const Text('Άκυρο')),
              FilledButton(
                onPressed: () async {
                  if (fromId == null || toId == null || fromId == toId) return;
                  final data = {
                    'fromZoneId': fromId,
                    'toZoneId':   toId,
                    'taxi': double.tryParse(taxiCtrl.text.replaceAll(',', '.')) ?? 0,
                    'van':  double.tryParse(vanCtrl.text.replaceAll(',', '.')) ?? 0,
                    'taxiForeign': taxiFCtrl.text.trim().isEmpty
                        ? null : double.tryParse(taxiFCtrl.text.replaceAll(',', '.')),
                    'vanForeign': vanFCtrl.text.trim().isEmpty
                        ? null : double.tryParse(vanFCtrl.text.replaceAll(',', '.')),
                  };
                  try {
                    if (existing == null) {
                      await db.collection('pricing_routes').add(data);
                    } else {
                      await db.collection('pricing_routes').doc(existing.id).update(data);
                    }
                    if (dctx.mounted) Navigator.of(dctx).pop();
                  } catch (e) {
                    if (dctx.mounted) {
                      ScaffoldMessenger.of(dctx).showSnackBar(SnackBar(
                        backgroundColor: Colors.red,
                        content: Text('Απέτυχε η αποθήκευση: $e'),
                        duration: const Duration(seconds: 6),
                      ));
                    }
                  }
                },
                child: const Text('Αποθήκευση'),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ─── Tab: Δυναμικός τύπος ────────────────────────────────────────────────────

class _PricingConfigTab extends StatefulWidget {
  final FirebaseFirestore db;
  const _PricingConfigTab({required this.db});

  @override
  State<_PricingConfigTab> createState() => _PricingConfigTabState();
}

class _PricingConfigTabState extends State<_PricingConfigTab> {
  static const _keys = [
    'base', 'perKm', 'perKmOutside', 'perMin', 'minCharge', 'minChargeNight',
    'nightPctTaxi', 'nightPctVan', 'vanPct', 'luggagePer', 'seatPrice',
  ];

  static const _defaults = {
    'base': 3.5, 'perKm': 1.0, 'perKmOutside': 2.0, 'perMin': 0.2,
    'minCharge': 25.0, 'minChargeNight': 35.0,
    'nightPctTaxi': 30.0, 'nightPctVan': 25.0,
    'vanPct': 90.0, 'luggagePer': 0.0, 'seatPrice': 5.0,
  };

  static const _labels = {
    'base':           'Βάση εκκίνησης (€)',
    'perKm':          '€ ανά χιλιόμετρο (εντός Αττικής)',
    'perKmOutside':   '€ ανά χιλιόμετρο (εκτός Αττικής)',
    'perMin':         '€ ανά λεπτό',
    'minCharge':      'Ελάχιστη χρέωση διαδρομής, ημέρα (€)',
    'minChargeNight': 'Ελάχιστη χρέωση διαδρομής, νύχτα (€)',
    'nightPctTaxi':   'Νυχτερινή προσαύξηση Ταξί (%)',
    'nightPctVan':    'Νυχτερινή προσαύξηση Βαν (%)',
    'vanPct':         'Βαν = Ταξί + (%) — δυναμικός τύπος',
    'luggagePer':     '€ ανά βαλίτσα',
    'seatPrice':      '€ ανά παιδικό κάθισμα',
  };

  final Map<String, TextEditingController> _c = {
    for (final k in _keys) k: TextEditingController(),
  };
  bool _nightAppliesToZones = true;
  bool _loaded = false;
  bool _saving = false;

  @override
  void dispose() {
    for (final ctrl in _c.values) {
      ctrl.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: widget.db.collection('app_settings').doc('pricing').snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Σφάλμα ανάγνωσης ρυθμίσεων:\n${snap.error}\n\n'
              'Πιθανή αιτία: δεν έχουν γίνει deploy οι Firestore rules.',
              style: const TextStyle(color: Colors.red),
            ),
          );
        }
        if (!_loaded && snap.hasData) {
          final data = snap.data!.data() ?? {};
          for (final k in _keys) {
            final v = (data[k] as num?)?.toDouble() ?? _defaults[k]!;
            _c[k]!.text = (v == v.roundToDouble()) ? v.toStringAsFixed(0) : v.toString();
          }
          _nightAppliesToZones = data['nightAppliesToZones'] as bool? ?? true;
          _loaded = true;
        }
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Ισχύει για διαδρομές εκτός ζωνών',
                  style: TextStyle(color: Colors.grey, fontSize: 12)),
              const SizedBox(height: 4),
              const Text(
                'Εκτός Αττικής χρησιμοποιείται το «€/χλμ εκτός Αττικής» και η φόρμα ζητά επικοινωνία μέσω WhatsApp.',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
              const SizedBox(height: 10),
              for (final k in _keys) ...[
                TextFormField(
                  controller: _c[k],
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: _labels[k]),
                ),
                const SizedBox(height: 10),
              ],
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Νυχτερινή προσαύξηση και στις σταθερές τιμές ζωνών'),
                value: _nightAppliesToZones,
                onChanged: (v) => setState(() => _nightAppliesToZones = v),
              ),
              const SizedBox(height: 12),
              AppButton(
                label: _saving ? 'Αποθήκευση…' : 'Αποθήκευση',
                icon: Icons.save_rounded,
                onPressed: _saving ? null : _save,
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final data = <String, dynamic>{
      for (final k in _keys)
        k: double.tryParse(_c[k]!.text.replaceAll(',', '.')) ?? _defaults[k],
      'nightAppliesToZones': _nightAppliesToZones,
      // Ο μαθηματικός τύπος αφαιρέθηκε — καθαρίζουμε τυχόν παλιά τιμή ώστε ο
      // server να χρησιμοποιεί πάντα τον ενσωματωμένο υπολογισμό.
      'customFormula': '',
    };
    try {
      await widget.db.collection('app_settings').doc('pricing').set(data, SetOptions(merge: true));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: Colors.red,
          content: Text('Απέτυχε η αποθήκευση: $e'),
          duration: const Duration(seconds: 6),
        ));
      }
    }
    if (mounted) setState(() => _saving = false);
  }
}
