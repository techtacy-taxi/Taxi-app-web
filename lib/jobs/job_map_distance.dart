// lib/jobs/job_map_distance.dart
//
// Χάρτης με τα 2 σημεία (Από/Προς) + αποστάσεις (διαδρομή, χρόνος, απόσταση
// οδηγού από τον πελάτη) — ΙΔΙΑ λογική/στυλ με το job_popup.dart (το popup
// «Νέα Δουλειά»), αλλά ως ανεξάρτητο widget ώστε να μπορεί να μπει και στην
// αναλυτική κάρτα (JobDetailsSheet) χωρίς να τη μετατρέψουμε σε StatefulWidget.
//
// Η απόσταση οδηγού ξαναϋπολογίζεται ΚΑΘΕ ΦΟΡΑ που ανοίγει η κάρτα (initState),
// ώστε να είναι πάντα φρέσκια όταν την κοιτάζει ο οδηγός.

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'job_model.dart';
import 'places_service.dart';

class JobMapDistanceCard extends StatefulWidget {
  final Job job;
  const JobMapDistanceCard({super.key, required this.job});

  @override
  State<JobMapDistanceCard> createState() => _JobMapDistanceCardState();
}

class _JobMapDistanceCardState extends State<JobMapDistanceCard> {
  double? _driverDistanceKm;
  bool    _distanceLoading = true;
  bool    _driverDistanceIsAir = false;
  int?    _routeMinutesFallback;

  @override
  void initState() {
    super.initState();
    _computeDriverDistance();
    _ensureRouteMinutes();
  }

  Future<void> _ensureRouteMinutes() async {
    final job = widget.job;
    if (job.routeMinutes != null) return;
    if (job.fromLat == null || job.fromLng == null ||
        job.toLat == null   || job.toLng == null) {
      return;
    }
    try {
      final route = await PlacesService.route(
        fromLat: job.fromLat!, fromLng: job.fromLng!,
        toLat:   job.toLat!,   toLng:   job.toLng!,
        departureTime: job.scheduledAt,
      );
      if (!mounted || route?.minutes == null) return;
      setState(() => _routeMinutesFallback = route!.minutes);
    } catch (_) {/* αγνόησε — απλώς δεν δείχνουμε χρόνο */}
  }

  Future<void> _computeDriverDistance() async {
    final job = widget.job;
    if (job.fromLat == null || job.fromLng == null) {
      if (mounted) setState(() => _distanceLoading = false);
      return;
    }
    try {
      Position? pos;
      try {
        pos = await Geolocator.getCurrentPosition(
          locationSettings:
              const LocationSettings(accuracy: LocationAccuracy.high),
        ).timeout(const Duration(seconds: 10));
      } catch (_) {
        pos = await Geolocator.getLastKnownPosition();
      }
      if (pos == null) {
        if (mounted) setState(() => _distanceLoading = false);
        return;
      }

      final route = await PlacesService.route(
        fromLat: pos.latitude,  fromLng: pos.longitude,
        toLat:   job.fromLat!,  toLng:   job.fromLng!,
      );

      final km = route?.km ??
          haversineKm(pos.latitude, pos.longitude,
              job.fromLat!, job.fromLng!);

      if (!mounted) return;
      setState(() {
        _driverDistanceKm    = km;
        _driverDistanceIsAir = route == null;
        _distanceLoading     = false;
      });
    } catch (_) {
      if (mounted) setState(() => _distanceLoading = false);
    }
  }

  double _zoomForSpan(double latSpan, double lngSpan) {
    var span = math.max(latSpan, lngSpan * 0.78);
    span = span * 1.12 + 0.003;
    if (span <= 0.0008) return 14.5;
    final z = math.log(360.0 / span) / math.ln2;
    return (z - 0.15).clamp(4.0, 16.5);
  }

  LatLngBounds _boundsOf(List<LatLng> pts) {
    double minLat = pts.first.latitude,  maxLat = pts.first.latitude;
    double minLng = pts.first.longitude, maxLng = pts.first.longitude;
    for (final p in pts) {
      if (p.latitude  < minLat) minLat = p.latitude;
      if (p.latitude  > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    return LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );
  }

  Widget _distanceChip({
    required IconData icon,
    required String   label,
    required String   value,
    required Color    color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 10),
      decoration: BoxDecoration(
        color:        color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border:       Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10, color: Colors.grey[600])),
              Text(value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: color)),
            ],
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    if (!job.hasRouteCoords) return const SizedBox.shrink();

    final from = LatLng(job.fromLat!, job.fromLng!);
    final to   = LatLng(job.toLat!,   job.toLng!);

    final routeKm = job.routeKm ??
        haversineKm(job.fromLat!, job.fromLng!, job.toLat!, job.toLng!);
    final routeMin = job.routeMinutes ?? _routeMinutesFallback;

    final List<LatLng> linePts;
    if (job.routePolyline != null && job.routePolyline!.isNotEmpty) {
      linePts = decodePolyline(job.routePolyline!)
          .map((p) => LatLng(p[0], p[1]))
          .toList();
    } else {
      linePts = [from, to];
    }

    final markers = <Marker>{
      Marker(
        markerId: const MarkerId('from'),
        position: from,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
        infoWindow: const InfoWindow(title: 'Από'),
      ),
      Marker(
        markerId: const MarkerId('to'),
        position: to,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        infoWindow: const InfoWindow(title: 'Προς'),
      ),
    };

    final polylines = <Polyline>{
      Polyline(
        polylineId: const PolylineId('route'),
        points:     linePts,
        color:      const Color(0xFF1565C0),
        width:      4,
      ),
    };

    final bounds = _boundsOf([from, to]);
    final latSpan = (bounds.northeast.latitude - bounds.southwest.latitude).abs();
    final lngSpan = (bounds.northeast.longitude - bounds.southwest.longitude).abs();
    final center = LatLng(
      (bounds.southwest.latitude + bounds.northeast.latitude) / 2
          + latSpan * 0.12,
      (bounds.southwest.longitude + bounds.northeast.longitude) / 2,
    );
    final zoom = _zoomForSpan(latSpan, lngSpan);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            height: 220,
            width:  double.infinity,
            child: Stack(
              children: [
                GoogleMap(
                  liteModeEnabled:         true,
                  initialCameraPosition:
                      CameraPosition(target: center, zoom: zoom),
                  markers:                 markers,
                  polylines:               polylines,
                  zoomControlsEnabled:     false,
                  mapToolbarEnabled:       false,
                  myLocationButtonEnabled: false,
                ),
                if (routeMin != null)
                  Positioned(
                    top:   10,
                    right: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color:        Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.18),
                            blurRadius: 4,
                            offset: const Offset(0, 1),
                          ),
                        ],
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.schedule_rounded,
                            size: 15, color: Color(0xFF6A1B9A)),
                        const SizedBox(width: 5),
                        Text(
                          formatRouteMinutes(routeMin),
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF6A1B9A)),
                        ),
                      ]),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: _distanceChip(
              icon:  Icons.straighten_rounded,
              label: 'Διαδρομή',
              value: '${routeKm.toStringAsFixed(1)} χλμ',
              color: const Color(0xFF1565C0),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _distanceChip(
              icon:  Icons.schedule_rounded,
              label: job.scheduledAt != null ? 'Χρόνος (ραντεβού)' : 'Χρόνος',
              value: routeMin != null ? formatRouteMinutes(routeMin) : '—',
              color: const Color(0xFF6A1B9A),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _distanceChip(
              icon:  Icons.directions_car_rounded,
              label: _driverDistanceIsAir
                  ? 'Απόσταση από σένα (ευθεία)'
                  : 'Απόσταση από σένα',
              value: _distanceLoading
                  ? '…'
                  : (_driverDistanceKm != null
                      ? '${_driverDistanceKm!.toStringAsFixed(1)} χλμ'
                      : '—'),
              color: const Color(0xFF1E8E3E),
            ),
          ),
        ]),
      ],
    );
  }
}
