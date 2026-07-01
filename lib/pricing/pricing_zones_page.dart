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

enum _MapMode { view, addZone, moveZone }

class PricingZonesPage extends StatefulWidget {
  const PricingZonesPage({super.key});

  @override
  State<PricingZonesPage> createState() => _PricingZonesPageState();
}

class _PricingZonesPageState extends State<PricingZonesPage> {
  final _db = FirebaseFirestore.instance;
  _MapMode _mode = _MapMode.view;
  String? _selectedZoneId;

  static const CameraPosition _initialCamera = CameraPosition(
    target: LatLng(37.9838, 23.7275), // Αθήνα
    zoom: 9.3,
  );

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.of(context).size.width >= 900;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ζώνες & Τιμές'),
        backgroundColor: _kAmber,
        foregroundColor: Colors.black87,
      ),
      body: isDesktop
          ? Row(
              children: [
                Expanded(flex: 3, child: _buildMap()),
                const VerticalDivider(width: 1),
                SizedBox(width: 420, child: _buildPanel()),
              ],
            )
          : Column(
              children: [
                SizedBox(height: 320, child: _buildMap()),
                Expanded(child: _buildPanel()),
              ],
            ),
    );
  }

  Widget _buildMap() {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _db.collection('pricing_zones').snapshots(),
      builder: (context, snap) {
        final zones = (snap.data?.docs ?? []).map(PricingZone.fromDoc).toList();
        final circles = <Circle>{
          for (final z in zones)
            Circle(
              circleId: CircleId(z.id),
              center: LatLng(z.lat, z.lng),
              radius: z.radius,
              consumeTapEvents: true,
              strokeWidth: z.id == _selectedZoneId ? 3 : 1,
              strokeColor: z.id == _selectedZoneId ? Colors.deepPurple : _kAmber,
              fillColor: (z.id == _selectedZoneId ? Colors.deepPurple : _kAmber)
                  .withValues(alpha: 0.18),
              onTap: () => _onZoneTap(z),
            ),
        };
        return Stack(
          children: [
            GoogleMap(
              initialCameraPosition: _initialCamera,
              circles: circles,
              onMapCreated: (_) {},
              onTap: (latLng) => _onMapTap(latLng),
              myLocationButtonEnabled: false,
              zoomControlsEnabled: true,
            ),
            Positioned(left: 12, right: 12, bottom: 12, child: _buildModeBar()),
          ],
        );
      },
    );
  }

  Widget _buildModeBar() {
    if (_mode == _MapMode.view) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          AppButton(
            label: 'Νέα ζώνη',
            icon: Icons.add_location_alt_rounded,
            onPressed: () => setState(() {
              _mode = _MapMode.addZone;
              _selectedZoneId = null;
            }),
          ),
        ],
      );
    }
    final label = _mode == _MapMode.addZone
        ? 'Πατήστε στον χάρτη για τη θέση της νέας ζώνης'
        : 'Πατήστε στον χάρτη για τη νέα θέση της ζώνης';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [BoxShadow(blurRadius: 8, color: Colors.black26)],
      ),
      child: Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
          TextButton(
            onPressed: () => setState(() => _mode = _MapMode.view),
            child: const Text('Άκυρο'),
          ),
        ],
      ),
    );
  }

  void _onZoneTap(PricingZone z) {
    if (_mode == _MapMode.moveZone) return; // περιμένουμε tap στον χάρτη, όχι σε ζώνη
    setState(() => _selectedZoneId = z.id);
    _openZoneDialog(existing: z);
  }

  Future<void> _onMapTap(LatLng pos) async {
    if (_mode == _MapMode.addZone) {
      setState(() => _mode = _MapMode.view);
      await _openZoneDialog(newPosition: pos);
    } else if (_mode == _MapMode.moveZone && _selectedZoneId != null) {
      await _db.collection('pricing_zones').doc(_selectedZoneId).update({
        'lat': pos.latitude,
        'lng': pos.longitude,
      });
      setState(() => _mode = _MapMode.view);
    }
  }

  Future<void> _openZoneDialog({PricingZone? existing, LatLng? newPosition}) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    double radius = existing?.radius ?? 3000;

    await showDialog<void>(
      context: context,
      builder: (dctx) => StatefulBuilder(
        builder: (c, setLocal) {
          return Dialog(
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: double.infinity,
                  color: _kAmber,
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                  child: Text(
                    existing == null ? 'Νέα ζώνη' : 'Επεξεργασία ζώνης',
                    style: const TextStyle(
                        color: _kAmberDark, fontSize: 17, fontWeight: FontWeight.w900),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: nameCtrl,
                        decoration: const InputDecoration(labelText: 'Όνομα ζώνης (π.χ. Λαύριο)'),
                      ),
                      const SizedBox(height: 18),
                      Text('Ακτίνα: ${(radius / 1000).toStringAsFixed(1)} χλμ'),
                      Slider(
                        min: 500, max: 20000, divisions: 39,
                        value: radius,
                        label: '${(radius / 1000).toStringAsFixed(1)} χλμ',
                        onChanged: (v) => setLocal(() => radius = v),
                      ),
                      const SizedBox(height: 10),
                      if (existing != null)
                        Row(
                          children: [
                            Expanded(
                              child: AppButtonTonal(
                                label: 'Μετακίνηση',
                                icon: Icons.open_with_rounded,
                                onPressed: () {
                                  Navigator.of(dctx).pop();
                                  setState(() {
                                    _mode = _MapMode.moveZone;
                                    _selectedZoneId = existing.id;
                                  });
                                },
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: AppButtonTonal(
                                label: 'Διαγραφή',
                                icon: Icons.delete_outline_rounded,
                                fg: Colors.red,
                                onPressed: () async {
                                  Navigator.of(dctx).pop();
                                  await _confirmDeleteZone(existing);
                                },
                              ),
                            ),
                          ],
                        ),
                      const SizedBox(height: 10),
                      AppButton(
                        label: 'Αποθήκευση',
                        icon: Icons.check_rounded,
                        onPressed: () async {
                          final name = nameCtrl.text.trim();
                          if (name.isEmpty) return;
                          if (existing == null && newPosition != null) {
                            await _db.collection('pricing_zones').add({
                              'name':   name,
                              'lat':    newPosition.latitude,
                              'lng':    newPosition.longitude,
                              'radius': radius,
                            });
                          } else if (existing != null) {
                            await _db.collection('pricing_zones').doc(existing.id).update({
                              'name':   name,
                              'radius': radius,
                            });
                          }
                          if (dctx.mounted) Navigator.of(dctx).pop();
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _confirmDeleteZone(PricingZone z) async {
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
      await _db.collection('pricing_zones').doc(z.id).delete();
      if (_selectedZoneId == z.id) setState(() => _selectedZoneId = null);
    }
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
                  if (existing == null) {
                    await db.collection('pricing_routes').add(data);
                  } else {
                    await db.collection('pricing_routes').doc(existing.id).update(data);
                  }
                  if (dctx.mounted) Navigator.of(dctx).pop();
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
    'base', 'perKm', 'perMin', 'minCharge', 'minChargeNight', 'nightPctTaxi', 'nightPctVan',
    'vanExtra', 'luggageFree', 'luggagePer', 'seatPrice',
  ];

  static const _defaults = {
    'base': 3.5, 'perKm': 1.0, 'perMin': 0.2, 'minCharge': 25.0, 'minChargeNight': 35.0,
    'nightPctTaxi': 30.0, 'nightPctVan': 25.0, 'vanExtra': 15.0,
    'luggageFree': 4.0, 'luggagePer': 1.0, 'seatPrice': 5.0,
  };

  static const _labels = {
    'base':           'Βάση εκκίνησης (€)',
    'perKm':          '€ ανά χιλιόμετρο (εντός Αττικής)',
    'perMin':         '€ ανά λεπτό',
    'minCharge':      'Ελάχιστη χρέωση διαδρομής, ημέρα (€)',
    'minChargeNight': 'Ελάχιστη χρέωση διαδρομής, νύχτα (€)',
    'nightPctTaxi':   'Νυχτερινή προσαύξηση Ταξί (%)',
    'nightPctVan':    'Νυχτερινή προσαύξηση Βαν (%)',
    'vanExtra':       'Πρόσθετο Βαν (€, δυναμικός τύπος)',
    'luggageFree':    'Δωρεάν βαλίτσες',
    'luggagePer':     '€ ανά επιπλέον βαλίτσα',
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
                'Εκτός Αττικής ισχύει πάντα 2€/χλμ (σταθερό στον server) και η φόρμα ζητά επικοινωνία μέσω WhatsApp.',
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
    };
    await widget.db.collection('app_settings').doc('pricing').set(data, SetOptions(merge: true));
    if (mounted) setState(() => _saving = false);
  }
}
