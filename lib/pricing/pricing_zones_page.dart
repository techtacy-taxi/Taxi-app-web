// lib/pricing/pricing_zones_page.dart
//
// «Ζώνες & Τιμές» — μόνο master.
//
// Διαχείριση:
//   • Ζώνες τιμολόγησης: ΟΡΘΟΓΩΝΙΑ πάνω στον χάρτη (Βόρειο/Νότιο/Ανατολικό/
//     Δυτικό όριο), π.χ. «Λαύριο», «Αεροδρόμιο», «Λαγονήσι».
//       - Web: 4 λαβές στις γωνίες (σαν crop tool φωτογραφίας) — τραβάς μια
//         γωνία και αλλάζει μέγεθος/σχήμα ελεύθερα (μπορεί να γίνει επίμηκες).
//         Μια λαβή στο κέντρο μετακινεί όλο το ορθογώνιο.
//       - Κινητό: ένα slider «Μέγεθος» μεγαλώνει/μικραίνει το ΥΠΑΡΧΟΝ σχήμα
//         αναλογικά (πλάτος & ύψος μαζί) — αν έχει γίνει επίμηκες από το web,
//         ΜΕΝΕΙ επίμηκες, δεν ξαναγίνεται τετράγωνο/κύκλος.
//   • Παλιές ζώνες (μόνο lat/lng/radius, από πριν αυτή την αλλαγή) συνεχίζουν
//     να δουλεύουν κανονικά — μετατρέπονται αυτόματα σε τετράγωνο ορθογώνιο
//     γύρω από το παλιό τους κέντρο με βάση την παλιά ακτίνα, και μόλις τις
//     αποθηκεύσεις ξανά, αποκτούν μόνιμα τα νέα πεδία (north/south/east/west).
//   • Διαδρομές: πάγιες τιμές Ταξί/Βαν (+ προαιρετικά τιμή ξένου πελάτη)
//     ανάμεσα σε δύο ζώνες, με κατεύθυνση (Από → Προς).
//   • Δυναμικός τύπος: βάση/χλμ/λεπτό/ελάχιστη χρέωση/νυχτερινές προσαυξήσεις/
//     επιβάρυνση Βαν/βαλίτσες/παιδικά καθίσματα — για διαδρομές εκτός ζωνών.
//
// Ίδιο Firestore (pricing_zones, pricing_routes, app_settings/pricing) το
// διαβάζει η δημόσια φόρμα κράτησης μέσω του Cloud Function estimatePrice —
// ό,τι αλλάξει εδώ ισχύει αμέσως και εκεί. Το functions/index.js ξέρει να
// διαβάζει και τα παλιά κυκλικά δεδομένα και τα νέα ορθογώνια.
//
// Χρησιμοποιείται και από τον Web Admin Panel (admin_shell.dart) και από την
// Android εφαρμογή (menu χάρτη, μόνο master) — ίδιο widget, ίδιο lib/.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../jobs/job_shared_widgets.dart';

const Color _kAmber     = Color(0xFFFFB300);
const Color _kAmberDark = Color(0xFF5A3D00);

// ── Μετατροπές μέτρων ↔ μοιρών (πρόχειρες, αρκετά ακριβείς για την Αττική) ──
const double _kMetersPerDegLat = 111320.0;
double _mToDegLat(double m) => m / _kMetersPerDegLat;
double _degLatToM(double d) => d * _kMetersPerDegLat;
double _cosLat(double atLatDeg) =>
    math.cos(atLatDeg * math.pi / 180).abs().clamp(0.01, 1.0);
double _mToDegLng(double m, double atLatDeg) => m / (_kMetersPerDegLat * _cosLat(atLatDeg));
double _degLngToM(double d, double atLatDeg) => d * _kMetersPerDegLat * _cosLat(atLatDeg);

// Απλή δομή ορίων ορθογωνίου.
class _Bounds {
  final double north, south, east, west;
  const _Bounds({required this.north, required this.south, required this.east, required this.west});
  LatLng get center => LatLng((north + south) / 2, (east + west) / 2);
  double get halfHeightM => _degLatToM((north - south) / 2);
  double get halfWidthM => _degLngToM((east - west) / 2, center.latitude);
}

// ─── Models ─────────────────────────────────────────────────────────────────

class PricingZone {
  final String id;
  final String name;
  final double lat;
  final double lng;
  final double radius; // μέτρα — ΠΑΛΙΟ μοντέλο (κύκλος), κρατιέται για fallback
  final double? north, south, east, west; // ΝΕΟ μοντέλο (ορθογώνιο)
  final double rotationDeg; // περιστροφή ορθογωνίου γύρω από το κέντρο (μοίρες)

  PricingZone({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
    required this.radius,
    this.north,
    this.south,
    this.east,
    this.west,
    this.rotationDeg = 0,
  });

  bool get hasBounds => north != null && south != null && east != null && west != null;

  // Πάντα επιστρέφει ορθογώνιο — είτε το αποθηκευμένο, είτε παράγωγο (τετράγωνο)
  // από το παλιό μοντέλο κύκλου, για ζώνες που δεν έχουν ακόμα μετατραπεί.
  _Bounds get bounds {
    if (hasBounds) return _Bounds(north: north!, south: south!, east: east!, west: west!);
    final dLat = _mToDegLat(radius);
    final dLng = _mToDegLng(radius, lat);
    return _Bounds(north: lat + dLat, south: lat - dLat, east: lng + dLng, west: lng - dLng);
  }

  factory PricingZone.fromDoc(QueryDocumentSnapshot<Map<String, dynamic>> d) {
    final m = d.data();
    return PricingZone(
      id:     d.id,
      name:   (m['name'] ?? '') as String,
      lat:    (m['lat'] as num?)?.toDouble() ?? 0,
      lng:    (m['lng'] as num?)?.toDouble() ?? 0,
      radius: (m['radius'] as num?)?.toDouble() ?? 3000,
      north:  (m['north'] as num?)?.toDouble(),
      south:  (m['south'] as num?)?.toDouble(),
      east:   (m['east'] as num?)?.toDouble(),
      west:   (m['west'] as num?)?.toDouble(),
      rotationDeg: (m['rotationDeg'] as num?)?.toDouble() ?? 0,
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

class PricingZonesPage extends StatefulWidget {
  const PricingZonesPage({super.key});

  @override
  State<PricingZonesPage> createState() => _PricingZonesPageState();
}

class _PricingZonesPageState extends State<PricingZonesPage> {
  final _db = FirebaseFirestore.instance;
  GoogleMapController? _mapCtrl;
  String? _selectedZoneId; // != null: επεξεργασία υπάρχουσας ζώνης
  bool _placingNew = false; // true: τοποθέτηση νέας ζώνης
  bool _didFitBounds = false;

  // Ορθογώνιο υπό επεξεργασία (νέα ζώνη ή επιλεγμένη υπάρχουσα).
  double? _editNorth, _editSouth, _editEast, _editWest;
  double _editRotation = 0; // μοίρες
  LatLng _cameraCenter = const LatLng(37.9838, 23.7275);
  bool _saving = false;

  final _nameCtrl = TextEditingController();

  // Custom εικονίδια λαβών (φορτώνονται 1 φορά από τα assets):
  //  • _cornerIcon → μαύρο τετράγωνο (λαβές γωνιών, μέγεθος/σχήμα)
  //  • _rotateIcon → βελάκι κυκλικό (λαβή περιστροφής)
  // Το κόκκινο κέντρο ΜΕΝΕΙ όπως ήταν (BitmapDescriptor.defaultMarker...).
  BitmapDescriptor? _cornerIcon;
  BitmapDescriptor? _rotateIcon;

  bool get _isEditing => _placingNew || _selectedZoneId != null;

  static const CameraPosition _initialCamera = CameraPosition(
    target: LatLng(37.9838, 23.7275), // Αθήνα
    zoom: 9.3,
  );

  @override
  void initState() {
    super.initState();
    _loadHandleIcons();
  }

  // Διαβάζει τα PNG assets (ήδη κομμένα/διάφανα γύρω-γύρω) και τα φορτώνει σε
  // συγκεκριμένο pixel μέγεθος ως BitmapDescriptor για τους δείκτες χάρτη.
  Future<void> _loadHandleIcons() async {
    try {
      final corner = await _bitmapFromAsset('assets/icons/handle_corner.png', 17);
      final rotate = await _bitmapFromAsset('assets/icons/handle_rotate.png', 17);
      if (!mounted) return;
      setState(() {
        _cornerIcon = corner;
        _rotateIcon = rotate;
      });
    } catch (_) {
      // Αν αποτύχει το φόρτωμα (π.χ. ξέχασε να μπει στο pubspec.yaml), οι
      // λαβές γυρίζουν αυτόματα στις προεπιλεγμένες πινέζες — καμία κρασάρισμα.
    }
  }

  Future<BitmapDescriptor> _bitmapFromAsset(String assetPath, int targetWidth) async {
    final bytes = await rootBundle.load(assetPath);
    final codec = await ui.instantiateImageCodec(
      bytes.buffer.asUint8List(),
      targetWidth: targetWidth,
    );
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.bytes(data!.buffer.asUint8List());
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.of(context).size.width >= 900;

    final appBar = AppBar(
      backgroundColor: _kAmber,
      foregroundColor: Colors.black87,
      title: _isEditing
          ? TextField(
              controller: _nameCtrl,
              autofocus: _placingNew && _nameCtrl.text.isEmpty,
              decoration: const InputDecoration(
                hintText: 'Όνομα ζώνης (π.χ. Λαύριο)',
                border: InputBorder.none,
                hintStyle: TextStyle(color: Colors.black45),
              ),
              style: const TextStyle(color: Colors.black87, fontWeight: FontWeight.w600),
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
            Expanded(flex: 3, child: _buildMap(isDesktop: true)),
            const VerticalDivider(width: 1),
            SizedBox(width: 420, child: _buildPanel()),
          ],
        ),
      );
    }

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: appBar,
        body: SafeArea(
          child: TabBarView(
            // ΣΗΜΑΝΤΙΚΟ: χωρίς swipe αλλαγής tab — αλλιώς το σύρσιμο του
            // δαχτύλου πάνω στον χάρτη άλλαζε κατά λάθος tab. Τα tabs
            // αλλάζουν ΜΟΝΟ πατώντας το όνομά τους.
            physics: const NeverScrollableScrollPhysics(),
            children: [
              _buildMap(isDesktop: false),
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
      _placingNew = true;
      _selectedZoneId = null;
      _nameCtrl.text = '';
      final dLat = _mToDegLat(3000);
      final dLng = _mToDegLng(3000, _cameraCenter.latitude);
      _editNorth = _cameraCenter.latitude + dLat;
      _editSouth = _cameraCenter.latitude - dLat;
      _editEast  = _cameraCenter.longitude + dLng;
      _editWest  = _cameraCenter.longitude - dLng;
      _editRotation = 0;
    });
  }

  void _selectZone(PricingZone z) {
    setState(() {
      _placingNew = false;
      _selectedZoneId = z.id;
      _nameCtrl.text = z.name;
      final b = z.bounds;
      _editNorth = b.north;
      _editSouth = b.south;
      _editEast  = b.east;
      _editWest  = b.west;
      _editRotation = z.rotationDeg;
    });
  }

  void _cancelEdit() {
    setState(() {
      _placingNew = false;
      _selectedZoneId = null;
      _editNorth = _editSouth = _editEast = _editWest = null;
      _nameCtrl.text = '';
    });
  }

  // Μετακίνηση όλου του ορθογωνίου (ίδιο μέγεθος, νέο κέντρο) — λαβή κέντρου.
  void _translateTo(LatLng newCenter) {
    final oldCenter = _Bounds(north: _editNorth!, south: _editSouth!, east: _editEast!, west: _editWest!).center;
    final dLat = newCenter.latitude - oldCenter.latitude;
    final dLng = newCenter.longitude - oldCenter.longitude;
    setState(() {
      _editNorth = _editNorth! + dLat;
      _editSouth = _editSouth! + dLat;
      _editEast  = _editEast! + dLng;
      _editWest  = _editWest! + dLng;
    });
  }

  // Αλλαγή μεγέθους τραβώντας μια γωνία (μόνο web) — ελεύθερο σχήμα.
  // Λειτουργεί και με περιστροφή: μεταφράζουμε το σημείο στο «τοπικό» σύστημα
  // του ορθογωνίου (αντίστροφη περιστροφή), και το μισό πλάτος/ύψος γίνεται η
  // απόστασή του από το κέντρο. Το κέντρο μένει σταθερό.
  void _resizeToPoint(_Bounds b, LatLng p) {
    final c = b.center;
    final dxM = _degLngToM(p.longitude - c.longitude, c.latitude);
    final dyM = _degLatToM(p.latitude - c.latitude);
    final rad = -_editRotation * math.pi / 180; // αντίστροφη περιστροφή
    final lx = (dxM * math.cos(rad) - dyM * math.sin(rad)).abs();
    final ly = (dxM * math.sin(rad) + dyM * math.cos(rad)).abs();
    final hw = lx.clamp(200.0, 60000.0);
    final hh = ly.clamp(200.0, 60000.0);
    final dLat = _mToDegLat(hh);
    final dLng = _mToDegLng(hw, c.latitude);
    setState(() {
      _editNorth = c.latitude + dLat;
      _editSouth = c.latitude - dLat;
      _editEast  = c.longitude + dLng;
      _editWest  = c.longitude - dLng;
    });
  }

  // Περιστροφή: η γωνία ορίζεται από τη θέση της πράσινης λαβής ως προς το
  // κέντρο (atan2 σε μέτρα). 0° = η λαβή ακριβώς βόρεια.
  void _rotateTo(_Bounds b, LatLng p) {
    final c = b.center;
    final dxM = _degLngToM(p.longitude - c.longitude, c.latitude);
    final dyM = _degLatToM(p.latitude - c.latitude);
    final deg = math.atan2(dxM, dyM) * 180 / math.pi;
    setState(() => _editRotation = deg);
  }

  // Αναλογική μεγέθυνση/σμίκρυνση (κινητό) — κρατά το ΥΠΑΡΧΟΝ σχήμα (π.χ.
  // επίμηκες), δεν το ξαναφέρνει σε τετράγωνο/κύκλο.
  double get _editAvgHalfSizeM {
    final b = _Bounds(north: _editNorth!, south: _editSouth!, east: _editEast!, west: _editWest!);
    return (b.halfHeightM + b.halfWidthM) / 2;
  }

  void _scaleProportionally(double newAvgHalfSizeM) {
    final b = _Bounds(north: _editNorth!, south: _editSouth!, east: _editEast!, west: _editWest!);
    final curAvg = _editAvgHalfSizeM;
    final scale = curAvg > 1 ? newAvgHalfSizeM / curAvg : 1.0;
    final center = b.center;
    final newHalfHeightM = (b.halfHeightM * scale).clamp(200.0, 40000.0);
    final newHalfWidthM  = (b.halfWidthM  * scale).clamp(200.0, 40000.0);
    final dLat = _mToDegLat(newHalfHeightM);
    final dLng = _mToDegLng(newHalfWidthM, center.latitude);
    setState(() {
      _editNorth = center.latitude + dLat;
      _editSouth = center.latitude - dLat;
      _editEast  = center.longitude + dLng;
      _editWest  = center.longitude - dLng;
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
    final b = _Bounds(north: _editNorth!, south: _editSouth!, east: _editEast!, west: _editWest!);
    final center = b.center;
    final data = <String, dynamic>{
      'name':   name,
      'lat':    center.latitude,
      'lng':    center.longitude,
      'radius': (b.halfHeightM + b.halfWidthM) / 2, // fallback/legacy πληροφορία
      'north':  b.north,
      'south':  b.south,
      'east':   b.east,
      'west':   b.west,
      'rotationDeg': _editRotation,
    };
    try {
      if (_placingNew) {
        await _db.collection('pricing_zones').add(data);
      } else if (_selectedZoneId != null) {
        await _db.collection('pricing_zones').doc(_selectedZoneId).update(data);
      }
      // Μετά την αποθήκευση βγαίνουμε από τη λειτουργία επεξεργασίας —
      // τα κουμπιά Αποθήκευση/Άκυρο φεύγουν και ο τίτλος επανέρχεται.
      // Για νέα αλλαγή (και ονόματος), απλώς ξαναπατάς πάνω στη ζώνη.
      if (mounted) _cancelEdit();
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
    double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
    for (final z in zones) {
      final b = z.bounds;
      if (b.south < minLat) minLat = b.south;
      if (b.north > maxLat) maxLat = b.north;
      if (b.west < minLng) minLng = b.west;
      if (b.east > maxLng) maxLng = b.east;
    }
    _mapCtrl!.animateCamera(CameraUpdate.newLatLngBounds(
      LatLngBounds(southwest: LatLng(minLat, minLng), northeast: LatLng(maxLat, maxLng)),
      60,
    ));
  }

  Widget _buildMap({required bool isDesktop}) {
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
        final editingBounds = _isEditing && _editNorth != null
            ? _Bounds(north: _editNorth!, south: _editSouth!, east: _editEast!, west: _editWest!)
            : null;

        final polygons = <Polygon>{
          for (final z in zones)
            if (!(z.id == _selectedZoneId && editingBounds != null))
              Polygon(
                polygonId: PolygonId(z.id),
                points: _rectPoints(z.bounds, z.rotationDeg),
                consumeTapEvents: true,
                strokeWidth: 1,
                strokeColor: _kAmber,
                fillColor: _kAmber.withValues(alpha: 0.18),
                onTap: () => _selectZone(z),
              ),
          if (editingBounds != null)
            Polygon(
              polygonId: PolygonId(_placingNew ? '_newZone' : _selectedZoneId!),
              points: _rectPoints(editingBounds, _editRotation),
              strokeWidth: 3,
              strokeColor: _placingNew ? Colors.red : Colors.deepPurple,
              fillColor: (_placingNew ? Colors.red : Colors.deepPurple).withValues(alpha: 0.18),
            ),
        };

        final markers = <Marker>{};
        if (editingBounds != null) {
          // Κέντρο — μετακίνηση όλου του ορθογωνίου (και στις δύο πλατφόρμες).
          markers.add(Marker(
            markerId: const MarkerId('_center'),
            position: editingBounds.center,
            draggable: true,
            icon: BitmapDescriptor.defaultMarkerWithHue(
                _placingNew ? BitmapDescriptor.hueRed : BitmapDescriptor.hueViolet),
            onDrag: _translateTo,
            onDragEnd: _translateTo,
          ));
          // Λαβή ΠΕΡΙΣΤΡΟΦΗΣ — πράσινη πινέζα πάνω από την (περιστραμμένη)
          // πάνω πλευρά. Τη σέρνεις γύρω-γύρω και το ορθογώνιο γυρίζει.
          final rotHandle = _offsetRotated(editingBounds.center, 0,
              editingBounds.halfHeightM * 1.45, _editRotation);
          markers.add(Marker(
            markerId: const MarkerId('_rot'),
            position: rotHandle,
            draggable: true,
            anchor: const Offset(0.5, 0.5),
            icon: _rotateIcon ??
                BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
            onDrag: (p) => _rotateTo(editingBounds, p),
            onDragEnd: (p) => _rotateTo(editingBounds, p),
          ));
          // Γωνίες — ΜΟΝΟ web: ελεύθερη αλλαγή μεγέθους/σχήματος, σαν crop tool.
          if (isDesktop) {
            final corners = _rectPoints(editingBounds, _editRotation);
            final ids = ['_nw', '_ne', '_se', '_sw'];
            for (int i = 0; i < 4; i++) {
              markers.add(Marker(
                markerId: MarkerId(ids[i]),
                position: corners[i],
                draggable: true,
                anchor: const Offset(0.5, 0.5),
                icon: _cornerIcon ??
                    BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
                onDrag: (p) => _resizeToPoint(editingBounds, p),
                onDragEnd: (p) => _resizeToPoint(editingBounds, p),
              ));
            }
          }
        }

        return Stack(
          children: [
            GoogleMap(
              initialCameraPosition: _initialCamera,
              polygons: polygons,
              markers: markers,
              onCameraMove: (pos) => _cameraCenter = pos.target,
              onMapCreated: (c) {
                _mapCtrl = c;
                if (zones.isNotEmpty) {
                  WidgetsBinding.instance.addPostFrameCallback((_) => _fitBoundsToZones(zones));
                }
              },
              myLocationButtonEnabled: false,
              zoomControlsEnabled: false, // zoom με 2 δάχτυλα (κινητό) / ροδέλα (web)
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
                      onPressed: _placingNew ? null : _startNewZone,
                    ),
                    if (selected != null)
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
                ),
              ),
            ),
            // Κινητό ΜΟΝΟ: slider αναλογικής μεγέθυνσης — κρατά επίμηκες σχήμα.
            if (_isEditing && !isDesktop && editingBounds != null)
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
                        Text('Μέγεθος: ${(_editAvgHalfSizeM / 1000).toStringAsFixed(1)} χλμ',
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                        Expanded(
                          child: Slider(
                            min: 300, max: 20000,
                            value: _editAvgHalfSizeM.clamp(300, 20000),
                            activeColor: _placingNew ? Colors.red : Colors.deepPurple,
                            label: '${(_editAvgHalfSizeM / 1000).toStringAsFixed(1)} χλμ',
                            onChanged: _scaleProportionally,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            // Web: μικρή υπενθύμιση για τις λαβές γωνιών.
            if (_isEditing && isDesktop)
              Positioned(
                left: 12, bottom: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text(
                    'Μαύρο τετράγωνο: μέγεθος/σχήμα · βελάκι: περιστροφή · κόκκινο: μετακίνηση',
                    style: TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  // Σημείο σε απόσταση (dxM ανατολικά, dyM βόρεια) από το κέντρο, ΜΕΤΑ από
  // περιστροφή κατά deg μοίρες (δεξιόστροφα).
  LatLng _offsetRotated(LatLng center, double dxM, double dyM, double deg) {
    final rad = deg * math.pi / 180;
    final rx = dxM * math.cos(rad) - dyM * math.sin(rad);
    final ry = dxM * math.sin(rad) + dyM * math.cos(rad);
    return LatLng(
      center.latitude + _mToDegLat(ry),
      center.longitude + _mToDegLng(rx, center.latitude),
    );
  }

  List<LatLng> _rectPoints(_Bounds b, double rotationDeg) {
    final c = b.center;
    final hw = b.halfWidthM, hh = b.halfHeightM;
    return [
      _offsetRotated(c, -hw,  hh, rotationDeg), // ΒΔ
      _offsetRotated(c,  hw,  hh, rotationDeg), // ΒΑ
      _offsetRotated(c,  hw, -hh, rotationDeg), // ΝΑ
      _offsetRotated(c, -hw, -hh, rotationDeg), // ΝΔ
    ];
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

  // Κύριες τιμές (Έλληνας/κοινή).
  final Map<String, TextEditingController> _c = {
    for (final k in _keys) k: TextEditingController(),
  };
  // Τιμές ξένου πελάτη — χρησιμοποιούνται μόνο όταν _foreignOn[key] == true.
  final Map<String, TextEditingController> _cForeign = {
    for (final k in _keys) k: TextEditingController(),
  };
  final Map<String, bool> _foreignOn = {for (final k in _keys) k: false};

  bool _nightAppliesToZones = true;
  bool _loaded = false;
  bool _saving = false;

  @override
  void dispose() {
    for (final ctrl in _c.values) {
      ctrl.dispose();
    }
    for (final ctrl in _cForeign.values) {
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
            final fv = (data['${k}Foreign'] as num?)?.toDouble();
            _foreignOn[k] = fv != null;
            _cForeign[k]!.text = fv != null
                ? ((fv == fv.roundToDouble()) ? fv.toStringAsFixed(0) : fv.toString())
                : _c[k]!.text; // αρχικοποίηση με την ίδια τιμή, βολικό σημείο εκκίνησης
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
              const SizedBox(height: 4),
              const Text(
                'Ο διακόπτης δίπλα σε κάθε τιμή ενεργοποιεί ξεχωριστή τιμή για ξένους πελάτες — '
                'αν μείνει κλειστός, όλοι πληρώνουν την ίδια τιμή, όπως πριν.',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
              const SizedBox(height: 12),
              for (final k in _keys) _buildFieldRow(k),
              const SizedBox(height: 8),
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

  Widget _buildFieldRow(String k) {
    final on = _foreignOn[k] ?? false;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(_labels[k]!, style: const TextStyle(fontSize: 15)),
              ),
              Switch(
                value: on,
                onChanged: (v) => setState(() {
                  _foreignOn[k] = v;
                  if (v && _cForeign[k]!.text.isEmpty) _cForeign[k]!.text = _c[k]!.text;
                }),
              ),
            ],
          ),
          if (!on)
            TextFormField(
              controller: _c[k],
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
            )
          else
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text('Έλληνας', style: TextStyle(fontSize: 11, color: Colors.grey)),
                      const SizedBox(height: 4),
                      TextFormField(
                        controller: _c[k],
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text('Ξένος', style: TextStyle(fontSize: 11, color: Colors.grey)),
                      const SizedBox(height: 4),
                      TextFormField(
                        controller: _cForeign[k],
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
                      ),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final data = <String, dynamic>{
      for (final k in _keys)
        k: double.tryParse(_c[k]!.text.replaceAll(',', '.')) ?? _defaults[k],
      for (final k in _keys)
        '${k}Foreign': (_foreignOn[k] ?? false)
            ? (double.tryParse(_cForeign[k]!.text.replaceAll(',', '.')) ?? _defaults[k])
            : null,
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
