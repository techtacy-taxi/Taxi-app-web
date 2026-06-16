// lib/models.dart

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

// ─── Vehicle type ─────────────────────────────────────────────────────────────
enum VehicleType { taxi, van }

// ─── Menu actions ─────────────────────────────────────────────────────────────
enum MenuAction { editName, jobs, taxi, van, groups, mute, checkUpdate, broadcastUpdate, billing, masters, calendar }

// ─── SharedPreferences key για broadcast αναβάθμισης ──────────────────────────
const kPrefsLastBroadcast = 'last_seen_broadcast_v1';

// ─── Marker asset typedef ─────────────────────────────────────────────────────
typedef MarkerAsset = ({BitmapDescriptor icon, Offset anchor});

// ─── Update URL ───────────────────────────────────────────────────────────────
const kUpdateUrl =
    'https://1drv.ms/f/c/c0d22f107774b4ef/IgD0H-yFOgsmQ5r1-hKgGXMpAQ-laBkWeATQGHQJBfzoG28?e=olbi0w';

// ─── SharedPreferences keys ───────────────────────────────────────────────────
const kPrefsNameKey      = 'display_name';
const kPrefsVehicleKey   = 'vehicle_type';
const kPrefsAvailableKey = 'available';

// Τελευταία τοποθεσία που στάλθηκε στο Firebase — μοιράζεται μεταξύ
// foreground (map_page) και background (main.dart task handler) isolate,
// ώστε το φίλτρο 100μ να ισχύει συνεχόμενα.
const kPrefsLastPubLat   = 'last_pub_lat';
const kPrefsLastPubLng   = 'last_pub_lng';
const kPrefsLastPubMs    = 'last_pub_ms';

// ─── Κανόνες ανανέωσης τοποθεσίας (εξοικονόμηση Firebase) ──────────────────────
// Δεν γράφουμε στο Firebase αν ο οδηγός δεν κινήθηκε πάνω από αυτή την απόσταση.
const double kMinMoveMeters = 100;
// Πόσο συχνά επιτρέπεται write όταν ο οδηγός είναι ΔΙΑΘΕΣΙΜΟΣ.
const Duration kPublishIntervalAvailable   = Duration(minutes: 3);
// Πόσο συχνά επιτρέπεται write όταν ο οδηγός είναι ΜΗ διαθέσιμος.
const Duration kPublishIntervalUnavailable = Duration(minutes: 15);

// ─── Map constants ────────────────────────────────────────────────────────────
const kAthens = CameraPosition(
  target: LatLng(38.0, 23.85),
  zoom: 9.0,
);
const kMarkerHideZoom    = 9.0;
const kBaseCanvasHeight  = 260.0;
const kCarCenterFraction = 0.75;

// ─── Status color helper ──────────────────────────────────────────────────────
Color statusColor({required bool online, required bool available}) {
  if (!online) return const Color(0xFF111111);
  return available ? const Color(0xFF1E8E3E) : const Color(0xFFC5221F);
}
