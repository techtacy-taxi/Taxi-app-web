// ============================================================================
// FILE: ./lib/web/map_web_page.dart
// ============================================================================
//
// Ζωντανός χάρτης οδηγών ΓΙΑ WEB (master/admin).
//
// Διαβάζει ΤΟ ΙΔΙΟ presence + groups με την Android app — κανένας νέος
// κανόνας Firestore. Χρησιμοποιεί ΤΟΝ ΙΔΙΟ marker builder (buildMarkerAsset)
// ώστε τα markers να είναι πανομοιότυπα με το κινητό: όνομα, εικονίδιο
// οχήματος, χρώμα κατάστασης ΚΑΙ χρώματα ομάδας γύρω από το όνομα.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../map/marker_builder.dart';
import '../map/driver_card.dart';
import '../models.dart';
import '../voice/voice_models.dart';

const Color _amber = Color(0xFFFFB300);
const LatLng _kAthens = LatLng(37.9838, 23.7275);
const double _kWebZoom = 12; // σταθερό zoom για το rendering των markers

class MapWebPage extends StatefulWidget {
  final String uid; // για να μη δείχνει τον εαυτό του (αν είναι κι οδηγός)
  const MapWebPage({super.key, required this.uid});

  @override
  State<MapWebPage> createState() => _MapWebPageState();
}

class _MapWebPageState extends State<MapWebPage> {
  GoogleMapController? _controller;
  Set<Marker> _markers = {};
  int _online = 0, _total = 0;
  bool _loaded = false;

  List<VoiceGroup> _groups = [];
  Map<String, Map<String, dynamic>> _presence = {};

  StreamSubscription? _presenceSub;
  StreamSubscription? _groupsSub;

  @override
  void initState() {
    super.initState();
    // Groups πρώτα (για χρώματα ομάδας), μετά presence.
    _groupsSub = FirebaseFirestore.instance
        .collection('groups')
        .snapshots()
        .listen((snap) {
      _groups = snap.docs.map((d) => VoiceGroup.fromDoc(d)).toList();
      _rebuildMarkers();
    });
    _presenceSub = FirebaseFirestore.instance
        .collection('presence')
        .snapshots()
        .listen((snap) {
      _presence = {
        for (final d in snap.docs) d.id: d.data(),
      };
      _rebuildMarkers();
    });
  }

  @override
  void dispose() {
    _presenceSub?.cancel();
    _groupsSub?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _rebuildMarkers() async {
    final markers = <Marker>{};
    var online = 0, total = 0;

    for (final entry in _presence.entries) {
      final id = entry.key;
      if (id == widget.uid) continue; // όχι ο εαυτός μας
      final data = entry.value;
      final lat = (data['lat'] as num?)?.toDouble();
      final lng = (data['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;

      total++;

      // Κατάσταση + stale έλεγχος (>2h) — ίδια λογική με το κινητό.
      final rawOnline = (data['online'] as bool?) ?? false;
      final available = (data['available'] as bool?) ?? false;
      final updatedAt = (data['updatedAt'] as Timestamp?)?.toDate();
      final isStale = updatedAt == null ||
          DateTime.now().difference(updatedAt).inHours >= 2;
      final isOnline = rawOnline && !isStale;
      final isAvailable = isOnline && available;
      if (isOnline) online++;

      // Όνομα (ίδια λογική με το map_page)
      final firstName = (data['displayName'] as String?)?.trim();
      final lastName = (data['lastName'] as String?)?.trim();
      final initial = (firstName != null && firstName.isNotEmpty)
          ? '${firstName[0].toUpperCase()}.'
          : '';
      final safeName = (lastName != null && lastName.isNotEmpty)
          ? (initial.isNotEmpty ? '$lastName $initial' : lastName)
          : (firstName != null && firstName.isNotEmpty ? firstName : 'Οδηγός');

      final vehicle = ((data['vehicleType'] as String?) ?? 'taxi') == 'van'
          ? VehicleType.van
          : VehicleType.taxi;

      // Χρώματα ομάδας (ίδιο με το κινητό)
      final dGroups =
          _groups.where((g) => g.memberUids.contains(id)).toList();

      // ΙΔΙΟΣ marker builder με την Android app
      final asset = await buildMarkerAsset(
        name: safeName,
        type: vehicle,
        color: statusColor(online: isOnline, available: isAvailable),
        currentZoom: _kWebZoom,
        groupColors: dGroups.map((g) => g.color).toList(),
      );

      markers.add(Marker(
        markerId: MarkerId(id),
        position: LatLng(lat, lng),
        icon: asset.icon,
        anchor: asset.anchor,
        // Πάτημα → πλήρης κάρτα οδηγού (ίδια με το κινητό).
        onTap: () {
          if (!mounted) return;
          showDriverCard(
            context: context,
            data: data,
            vehicle: vehicle,
            driverUid: id,
            allGroups: _groups,
          );
        },
      ));
    }

    if (!mounted) return;
    setState(() {
      _markers = markers;
      _online = online;
      _total = total;
      _loaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: const CameraPosition(
                target: _kAthens, zoom: _kWebZoom),
            markers: _markers,
            myLocationButtonEnabled: false,
            mapToolbarEnabled: false,
            zoomControlsEnabled: true,
            onMapCreated: (c) => _controller = c,
          ),
          Positioned(
            top: 14, left: 14,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                boxShadow: const [
                  BoxShadow(blurRadius: 10, color: Colors.black12),
                ],
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.local_taxi_rounded, color: _amber, size: 22),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('$_online σε σύνδεση',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 14)),
                    Text('$_total οδηγοί συνολικά',
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey[600])),
                  ],
                ),
              ]),
            ),
          ),
          if (!_loaded)
            const Center(
              child: CircularProgressIndicator(color: _amber),
            ),
        ],
      ),
    );
  }
}
