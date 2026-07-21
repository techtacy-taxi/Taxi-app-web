// lib/map/map_page.dart
import '../main.dart' show startCallback;

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_theme.dart';
import '../models.dart';
import '../fcm_service.dart';
import '../owner_alerts.dart';
import '../owner_home_page.dart';
import '../public_booking_alert.dart';
import '../permissions.dart';
import '../access_guard.dart';
import '../profile_form.dart';
import '../voice/voice_inbox.dart';
import '../voice/voice_models.dart';
import '../voice/voice_service.dart';
import '../voice/groups_admin.dart' hide GroupBadge;
import 'driver_card.dart';
import 'map_menus.dart';
import 'home_top_overlay.dart';
import 'marker_builder.dart';
import '../ics_intent.dart';
import '../jobs/job_admin_page.dart';
import '../jobs/job_shared_widgets.dart';
import '../jobs/job_form.dart';
import '../jobs/places_service.dart';
import '../jobs/job_badge.dart';
import '../jobs/billing_page.dart';
import '../jobs/job_service.dart';
import '../masters/masters_admin_page.dart';
import '../masters/global_settings_page.dart';
import '../calendar/jobs_calendar_page.dart';
import '../pricing/pricing_zones_page.dart';
import '../settings_page.dart';
import '../viva_settings_page.dart';

class HomeMapPage extends StatefulWidget {
  const HomeMapPage({super.key});
  @override
  State<HomeMapPage> createState() => _HomeMapPageState();
}


// JSON style χάρτη Google Maps για dark mode (βασικό σκούρο θέμα).
const String _darkMapStyle = '''
[
  {"elementType":"geometry","stylers":[{"color":"#212121"}]},
  {"elementType":"labels.icon","stylers":[{"visibility":"off"}]},
  {"elementType":"labels.text.fill","stylers":[{"color":"#757575"}]},
  {"elementType":"labels.text.stroke","stylers":[{"color":"#212121"}]},
  {"featureType":"administrative","elementType":"geometry","stylers":[{"color":"#757575"}]},
  {"featureType":"administrative.country","elementType":"labels.text.fill","stylers":[{"color":"#9e9e9e"}]},
  {"featureType":"administrative.locality","elementType":"labels.text.fill","stylers":[{"color":"#bdbdbd"}]},
  {"featureType":"poi","elementType":"labels.text.fill","stylers":[{"color":"#757575"}]},
  {"featureType":"poi.park","elementType":"geometry","stylers":[{"color":"#181818"}]},
  {"featureType":"poi.park","elementType":"labels.text.fill","stylers":[{"color":"#616161"}]},
  {"featureType":"road","elementType":"geometry.fill","stylers":[{"color":"#2c2c2c"}]},
  {"featureType":"road","elementType":"labels.text.fill","stylers":[{"color":"#8a8a8a"}]},
  {"featureType":"road.arterial","elementType":"geometry","stylers":[{"color":"#373737"}]},
  {"featureType":"road.highway","elementType":"geometry","stylers":[{"color":"#3c3c3c"}]},
  {"featureType":"road.highway.controlled_access","elementType":"geometry","stylers":[{"color":"#4e4e4e"}]},
  {"featureType":"road.local","elementType":"labels.text.fill","stylers":[{"color":"#616161"}]},
  {"featureType":"transit","elementType":"labels.text.fill","stylers":[{"color":"#757575"}]},
  {"featureType":"water","elementType":"geometry","stylers":[{"color":"#0e1626"}]},
  {"featureType":"water","elementType":"labels.text.fill","stylers":[{"color":"#3d3d3d"}]}
]
''';

class _HomeMapPageState extends State<HomeMapPage> with WidgetsBindingObserver {

  // Ύψος του κάτω nav bar (χωρίς το safe-area inset — αυτό προστίθεται
  // ξεχωριστά όπου χρειάζεται μέσω MediaQuery.of(context).padding.bottom).
  static const double _kBottomNavHeight = 64;

  // ─── state ───────────────────────────────────────────────────────────────────

  VehicleType _vehicleType  = VehicleType.taxi;
  bool _hasBus = false; // δηλωμένη ΕΠΙΠΛΕΟΝ ικανότητα Λεωφορείου (Shuttle/Bus jobs)
  String _displayName       = 'Driver';
  String _lastName          = '';
  String _phone             = '';
  String _vehicleModel      = '';
  String _plateNumber       = '';
  String _referredBy        = '';
  String _appVersion        = '';
  bool   _isAvailable       = false;
  bool   _isOnline          = true;
  bool   _isApproved        = false;
  bool   _isAdmin           = false;
  bool   _isMaster          = false;
  bool   _isTenantOwner     = false; // multi-tenant: βλέπει μόνο Ζώνες & Τιμές (δικές του)
  bool   _isHomeOwner       = false; // Home Owner (ιδιοκτήτης καταλύματος): βλέπει μόνο τις δουλειές του πελάτη του
  String _ownerOfClientId   = '';
  String _ownerOfClientName = '';
  bool   _calendarEnabled   = false; // master controls per-admin calendar access
  bool   _isMuted           = false;
  List<String> _managedGroupIds = []; // ομάδες που διαχειρίζεται ο admin

  bool _dialogShown  = false;
  bool _initComplete = false;

  MarkerAsset?          _myAsset;
  GoogleMapController?  _mapController;
  bool                   _pendingAutoCenter = false; // κεντράρισε μόλις έρθει η πρώτη θέση
  Position?             _currentPosition;
  StreamSubscription<Position>?                            _positionSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _othersSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _groupsSub;
  double    _currentZoom = 16;
  Timer?    _publishTimer;
  Timer?    _approvalTimer;
  Position? _lastPublishedPosition;

  final Map<String, Map<String, dynamic>> _presenceCache = {};
  final Map<String, Marker>               _otherMarkers  = {};
  List<VoiceGroup>                        _allGroups     = [];
  String? _uid;

  // Ύψος της κάτω μπάρας «Οι δουλειές μου» (0 όταν είναι κρυμμένη). Όταν
  // εμφανίζεται, τα πλαϊνά FAB ανεβαίνουν τόσο ώστε να μην καλύπτονται.

  // ─── voice queue ─────────────────────────────────────────────────────────────
  final AudioPlayer              _autoPlayer    = AudioPlayer();
  final AndroidAudioManager      _androidAudio  = AndroidAudioManager();
  final List<VoiceMessage>       _playQueue     = [];
  bool                           _isAutoPlaying = false;
  bool                           _autoPlayerCtxSet = false;
  StreamSubscription<List<VoiceMessage>>? _voiceSub;
  final Set<String>              _seenIds       = {};

  // ─── lifecycle ───────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initPage();
  }

  Future<void> _initPage() async {
    final info = await PackageInfo.fromPlatform();
    // Το versionName είναι "1.0.<ημερομηνία>_<ώρα>" (build.gradle.kts). Κόβουμε
    // το σταθερό πρόθεμα "1.0." ώστε αυτό που βλέπει ο οδηγός/admin να είναι
    // ΑΚΡΙΒΩΣ ό,τι γράφει και το όνομα του .apk (π.χ. "v04-07-2026_1455"),
    // εύκολο για σύγκριση αν έχει την τελευταία έκδοση.
    _appVersion = info.version.split('+').first.replaceFirst(RegExp(r'^1\.0\.'), '');
    _uid = FirebaseAuth.instance.currentUser?.uid;

    if (_uid != null) {
      // Καταχώρηση FCM token — εντελώς non-blocking & crash-safe.
      // ignore: unawaited_futures
      Future(() => FcmService.initForUser(_uid!)).catchError((_) {});
      try {
        final doc = await FirebaseFirestore.instance
            .collection('presence').doc(_uid).get();
        if (doc.exists) {
          final data = doc.data();
          if (data != null) {
            _displayName  = data['displayName']  ?? 'Driver';
            _lastName     = data['lastName']     ?? '';
            _phone        = data['phone']        ?? '';
            _vehicleModel = data['vehicleModel'] ?? '';
            _plateNumber  = data['plateNumber']  ?? '';
            _referredBy   = data['referredBy']   ?? '';
            _isApproved   = data['isApproved']   ?? false;
            _isAdmin      = data['admin']        ?? false;
            _isMaster     = data['master']       ?? false;
            _isTenantOwner = data['tenantOwner'] ?? false;
            _isHomeOwner   = data['homeOwner'] ?? false;
            _ownerOfClientId   = data['ownerOfClientId'] ?? '';
            _ownerOfClientName = data['ownerOfClientName'] ?? '';
            _calendarEnabled = data['calendarEnabled'] ?? false;
            _managedGroupIds = List<String>.from(data['managedGroupIds'] ?? []);
            if ((data['vehicleType'] as String?) == VehicleType.van.name) {
              _vehicleType = VehicleType.van;
            }
            _hasBus = data['hasBus'] == true;
          }
        }
      } catch (e) {
        // π.χ. PERMISSION_DENIED για νέο χρήστη — ΔΕΝ μπλοκάρουμε το loading.
        // Ο χρήστης θα προχωρήσει στη φόρμα εγγραφής.
        debugPrint('presence read failed (continuing): $e');
      }
    }

    // Κάθε βήμα τυλιγμένο ώστε ένα αποτυχημένο write/read (π.χ.
    // PERMISSION_DENIED για νέο χρήστη) να ΜΗΝ μπλοκάρει το loading.
    try { _checkApproval(); } catch (_) {}
    try { await _loadSavedSettings(); } catch (_) {}
    try { _requestPermissions(); } catch (_) {}
    try { await _startForegroundService(); } catch (_) {}
    try { _startGroupsListener(); } catch (_) {}
    try { await _startRealtimePresence(); } catch (_) {}
    try { await _refreshVehicleIcon(); } catch (_) {}
    try { await _setOnline(true); } catch (_) {}
    try { _startLocationUpdates(); } catch (_) {}
    try { _startVoiceListener(); } catch (_) {}
    if ((_isAdmin || _isMaster) && _uid != null) {
      try { OwnerAlerts.instance.start(_uid!); } catch (_) {}
    }
    // Ειδοποιήσεις «νέα κράτηση από φόρμα» — ενεργές για ΚΑΘΕ admin/master
    // (όχι μόνο master πια). Το ownerUid φίλτρο μέσα στο PublicBookingAlerts
    // εξασφαλίζει ότι ο καθένας βλέπει/ακούει ΜΟΝΟ τις δικές του κρατήσεις.
    if (_isAdmin || _isMaster) {
      try { PublicBookingAlerts.instance.start(); } catch (_) {}
    }
    _lastPublishedPosition = null;
    try { _publishMyLocation(force: true); } catch (_) {}
    try { _startPeriodicLocationPublish(); } catch (_) {}

    if (mounted) setState(() => _initComplete = true);

    _setupIcs(); // άκουσε για αρχεία .ics (κρατήσεις)

    // Μηνιαίες συνδρομές: ΜΕΤΑΦΕΡΘΗΚΑΝ server-side (Cloud Function
    // `monthlyCharges`, τρέχει 1η του μήνα). Δεν χρεώνουμε πλέον από τον client
    // — αποφυγή διπλοχρέωσης & ο οδηγός δεν γράφει ο ίδιος το χρέος του.
    if (_uid != null) {
      // Εφάπαξ migration παλιών δουλειών (τρέχει μία φορά συνολικά)
      // ignore: unawaited_futures
      JobService.migrateOldJobs();
      // Migration v4: γέμισμα recipient/collector στις παλιές χρεώσεις
      // ignore: unawaited_futures
      JobService.migrateBillingRecipients();
    }
  }

  // ─── Άνοιγμα .ics → Νέα Δουλειά ───────────────────────────────────────────
  bool _icsBusy = false;

  void _setupIcs() {
    // Όταν ανοίγει .ics ενώ τρέχει η εφαρμογή
    IcsIntent.listen(_handleIcsBooking);
    // Όταν η εφαρμογή άνοιξε πατώντας .ics (cold start)
    IcsIntent.initial().then((b) {
      if (b != null) _handleIcsBooking(b);
    });
  }

  Future<void> _handleIcsBooking(IcsBooking b) async {
    if (!mounted || _icsBusy) return;
    if (!(_isAdmin || _isMaster)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Μόνο διαχειριστές μπορούν να φτιάξουν δουλειά από αρχείο.'),
      ));
      return;
    }
    _icsBusy = true;
    try {
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => JobFormPage(
          adminUid:  _uid ?? '',
          adminName: '$_displayName $_lastName'.trim(),
          isMaster:  _isMaster,
          prefill: JobPrefill(
            from: (b.from != null && b.from!.isNotEmpty)
                ? PlacePick(description: b.from!)
                : null,
            to: (b.to != null && b.to!.isNotEmpty)
                ? PlacePick(description: b.to!)
                : null,
            clientName:   b.name,
            clientPhone:  b.phone,
            persons:      b.persons,
            luggage:      b.luggage,
            scheduledAt:  b.scheduledAt,
            price:        b.price,          // Price: €...
            vehicleType:  b.vehicleType,    // Taxi / Van
            childSeatCount: b.childSeats,   // baby seat → 1 (τιμή 0)
            flightOrShip: b.flightOrShip,   // Transport (πλοίο/μεταφορικό)
            note:         b.noteForComments, // email + κράτηση + πληρωμένο + σημ.
          ),
        ),
      ));
    } finally {
      _icsBusy = false;
    }
  }

  void _checkApproval() {
    if (_uid == null) return;
    _approvalTimer?.cancel();
    _approvalTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      FirebaseFirestore.instance.collection('presence').doc(_uid).get().then((doc) {
        if (doc.exists && mounted) {
          final approved = doc.data()?['isApproved'] ?? false;
          if (approved != _isApproved) setState(() => _isApproved = approved);
        }
      });
    });
    FirebaseFirestore.instance.collection('presence').doc(_uid).snapshots().listen((doc) {
      if (doc.exists && mounted) {
        setState(() {
          _isApproved      = doc.data()?['isApproved']       ?? false;
          _isAdmin         = doc.data()?['admin']             ?? false;
          _isMaster        = doc.data()?['master']            ?? false;
          _isTenantOwner   = doc.data()?['tenantOwner']        ?? false;
          _isHomeOwner     = doc.data()?['homeOwner']          ?? false;
          _ownerOfClientId   = doc.data()?['ownerOfClientId'] ?? '';
          _ownerOfClientName = doc.data()?['ownerOfClientName'] ?? '';
          _calendarEnabled = doc.data()?['calendarEnabled']   ?? false;
          _managedGroupIds = List<String>.from(
              doc.data()?['managedGroupIds'] ?? []);
        });
        // In-app owner ειδοποιήσεις: ενεργές μόνο για admin/master.
        if ((_isAdmin || _isMaster) && _uid != null) {
          OwnerAlerts.instance.start(_uid!);
        } else {
          OwnerAlerts.instance.stop();
        }
        // Ειδοποιήσεις «νέα κράτηση από φόρμα» — ενεργές για κάθε admin/
        // master. Το ownerUid φίλτρο εξασφαλίζει σωστή απομόνωση ανά tenant.
        if (_isAdmin || _isMaster) {
          PublicBookingAlerts.instance.start();
        } else {
          PublicBookingAlerts.instance.dispose();
        }
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _setOnline(true);
      Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.best))
          .then((pos) {
        _currentPosition = pos;
        _lastPublishedPosition = null;
        _publishMyLocation(force: true);
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _positionSub?.cancel();
    _othersSub?.cancel();
    _groupsSub?.cancel();
    _publishTimer?.cancel();
    _approvalTimer?.cancel();
    _mapController?.dispose();
    _autoPlayer.dispose();
    _voiceSub?.cancel();
    OwnerAlerts.instance.stop();
    super.dispose();
  }

  // ─── permissions + service ────────────────────────────────────────────────────

  Future<void> _requestPermissions() async =>
      requestPermissions(context: context, uid: _uid);

  Future<void> _startForegroundService() async {
    if (await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.startService(
      serviceId: 256,
      notificationTitle: 'Athens Taxi Booking',
      notificationText:  'Η τοποθεσία σου στέλνεται στους συναδέλφους.',
      notificationIcon:  null,
      callback:          startCallback,
    );
  }

  // ─── settings ─────────────────────────────────────────────────────────────────

  Future<void> _loadSavedSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (_displayName == 'Driver') _displayName = prefs.getString(kPrefsNameKey) ?? 'Driver';
    if (_vehicleType == VehicleType.taxi && prefs.getString(kPrefsVehicleKey) == VehicleType.van.name) {
      _vehicleType = VehicleType.van;
    }
    _isAvailable = prefs.getBool(kPrefsAvailableKey) ?? false;
    _isMuted     = prefs.getBool('muted')            ?? false;
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kPrefsNameKey,      _displayName);
    await prefs.setString(kPrefsVehicleKey,   _vehicleType.name);
    await prefs.setBool(  kPrefsAvailableKey, _isAvailable);
    await prefs.setBool(  'muted',            _isMuted);
  }

  // ─── location ─────────────────────────────────────────────────────────────────

  Future<void> _publishMyLocation({bool force = false}) async {
    if (_uid == null) return;
    Position? pos = _currentPosition;
    if (pos == null) {
      pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high));
      _currentPosition = pos;
    }
    if (!force && _lastPublishedPosition != null) {
      final moved = Geolocator.distanceBetween(
        _lastPublishedPosition!.latitude, _lastPublishedPosition!.longitude,
        pos.latitude, pos.longitude,
      );
      if (moved < kMinMoveMeters) return;
    }
    final Map<String, dynamic> data = {
      'lat': pos.latitude, 'lng': pos.longitude,
      'online': true, 'available': _isAvailable,
      'appVersion': _appVersion, 'updatedAt': FieldValue.serverTimestamp(),
    };
    if (_displayName != 'Driver') data['displayName']  = _displayName;
    if (_lastName.isNotEmpty)     data['lastName']     = _lastName;
    if (_phone.isNotEmpty)        data['phone']        = _phone;
    if (_vehicleModel.isNotEmpty) data['vehicleModel'] = _vehicleModel;
    if (_plateNumber.isNotEmpty)  data['plateNumber']  = _plateNumber;
    data['vehicleType'] = _vehicleType.name;
    await FirebaseFirestore.instance.collection('presence').doc(_uid).set(data, SetOptions(merge: true));
    _lastPublishedPosition = pos;

    // Καταγραφή της σταλμένης θέσης/χρόνου στα SharedPreferences ώστε το
    // background isolate (main.dart) να μετράει το φίλτρο 100μ και το
    // interval από το ΙΔΙΟ σημείο — αλλιώς foreground & background θα
    // έκαναν διπλά writes.
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(kPrefsLastPubLat, pos.latitude);
      await prefs.setDouble(kPrefsLastPubLng, pos.longitude);
      await prefs.setInt(kPrefsLastPubMs,
          DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
  }

  Future<void> _startLocationUpdates() async {
    if (!await Geolocator.isLocationServiceEnabled()) return;
    final perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return;
    _positionSub?.cancel();
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 5),
    ).listen((pos) {
      _currentPosition = pos;
      _maybeAutoCenter();
      if (!mounted) return;
      setState(() {});
    });
    final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.best));
    _currentPosition = pos;
    _maybeAutoCenter();
    if (!mounted) return;
    setState(() {});
  }

  // Κεντράρισμα στη θέση σου με ζουμ, ΜΙΑ φορά — μόλις έρθει η πρώτη θέση
  // μετά το άνοιγμα του χάρτη, αν το onMapCreated είχε τρέξει πριν προλάβει
  // να έρθει η θέση (π.χ. αργό GPS fix).
  Future<void> _maybeAutoCenter() async {
    if (!_pendingAutoCenter) return;
    final map = _mapController;
    final pos = _currentPosition;
    if (map == null || pos == null) return;
    _pendingAutoCenter = false;
    await map.animateCamera(CameraUpdate.newLatLngZoom(
        LatLng(pos.latitude, pos.longitude), 14));
  }

  void _startPeriodicLocationPublish() {
    _publishTimer?.cancel();
    // Ticker κάθε 1 λεπτό. Σε κάθε χτύπο ξανα-ελέγχει το _isAvailable
    // ώστε το interval να είναι ΠΑΝΤΑ σωστό (2′ διαθέσιμος / 15′ μη
    // διαθέσιμος). Διαβάζει τον χρόνο τελευταίου write από τα
    // SharedPreferences — το ΙΔΙΟ σημείο που χρησιμοποιεί και το
    // background isolate — ώστε να μην γίνονται διπλά writes.
    // Το _publishMyLocation κρατάει το φίλτρο 100μ: αν ο οδηγός είναι
    // ακίνητος, δεν γράφεται τίποτα στο Firebase.
    _publishTimer = Timer.periodic(const Duration(minutes: 1), (_) async {
      final interval = _isAvailable
          ? kPublishIntervalAvailable
          : kPublishIntervalUnavailable;
      try {
        final prefs  = await SharedPreferences.getInstance();
        final lastMs = prefs.getInt(kPrefsLastPubMs);
        if (lastMs != null) {
          final elapsed =
              DateTime.now().millisecondsSinceEpoch - lastMs;
          if (elapsed < interval.inMilliseconds) return;
        }
      } catch (_) {}
      _publishMyLocation(force: false); // με φίλτρο 100μ
    });
  }

  // ─── presence + groups ────────────────────────────────────────────────────────

  void _startGroupsListener() {
    _groupsSub?.cancel();
    _groupsSub = FirebaseFirestore.instance.collection('groups').snapshots().listen((snap) {
      if (!mounted) return;
      setState(() { _allGroups = snap.docs.map((d) => VoiceGroup.fromDoc(d)).toList(); });
      _refreshVehicleIcon();
      _rebuildOtherMarkers();
    });
  }

  Future<void> _startRealtimePresence() async {
    if (_uid == null) return;
    _othersSub?.cancel();
    _othersSub = FirebaseFirestore.instance.collection('presence').snapshots().listen((snap) async {
      _presenceCache.clear();
      for (final doc in snap.docs) {
        if (doc.id == _uid) continue;
        _presenceCache[doc.id] = doc.data();
      }
      await _rebuildOtherMarkers();
    });
  }

  Future<void> _rebuildOtherMarkers() async {
    if (_currentZoom < kMarkerHideZoom) {
      if (!mounted) return;
      setState(() => _otherMarkers.clear());
      return;
    }
    final updated = <String, Marker>{};
    for (final entry in _presenceCache.entries) {
      final id   = entry.key;
      final data = entry.value;
      final lat  = (data['lat'] as num?)?.toDouble();
      final lng  = (data['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) { continue; }

      final firstName = (data['displayName'] as String?)?.trim();
      final lastName  = (data['lastName']    as String?)?.trim();
      final initial = (firstName != null && firstName.trim().isNotEmpty)
          ? '${firstName.trim()[0].toUpperCase()}.'
          : '';
      final safeName  = (lastName != null && lastName.isNotEmpty)
          ? (initial.isNotEmpty ? '$lastName $initial' : lastName)
          : (firstName != null && firstName.isNotEmpty ? firstName : 'Driver');
      final vehicle   = ((data['vehicleType'] as String?) ?? 'taxi') == 'van'
          ? VehicleType.van : VehicleType.taxi;
      final online    = (data['online']    as bool?) ?? false;
      final available = (data['available'] as bool?) ?? false;

      // Αν δεν έχει ανανεωθεί εδώ και 2+ ώρες → θεωρείται offline
      final updatedAt  = (data['updatedAt'] as Timestamp?)?.toDate();
      final isStale    = updatedAt == null ||
          DateTime.now().difference(updatedAt).inHours >= 2;
      final effectiveOnline    = online && !isStale;
      final effectiveAvailable = effectiveOnline && available;
      final dGroups   = _allGroups.where((g) => g.memberUids.contains(id)).toList();

      final asset = await buildMarkerAsset(
        name:        safeName,
        type:        vehicle,
        color:       statusColor(online: effectiveOnline, available: effectiveAvailable),
        currentZoom: _currentZoom,
        groupColors: dGroups.map((g) => g.color).toList(),
      );
      updated[id] = Marker(
        markerId: MarkerId('other:$id'),
        position: LatLng(lat, lng),
        icon:     asset.icon,
        anchor:   asset.anchor,
        onTap: () => showDriverCard(
          context:   context,
          data:      data,
          vehicle:   vehicle,
          driverUid: id,
          allGroups: _allGroups,
        ),
      );
    }
    if (!mounted) return;
    setState(() { _otherMarkers..clear()..addAll(updated); });
  }

  Future<void> _setOnline(bool value) async {
    _isOnline = value;
    await _refreshVehicleIcon();
    if (_uid == null) return;
    await FirebaseFirestore.instance.collection('presence').doc(_uid).update({
      'online': value, 'available': value ? _isAvailable : false,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> _refreshVehicleIcon() async {
    final myGroups = _uid != null
        ? _allGroups.where((g) => g.memberUids.contains(_uid)).toList()
        : <VoiceGroup>[];
    final myInitial = _displayName.trim().isNotEmpty &&
            _displayName != 'Driver'
        ? '${_displayName.trim()[0].toUpperCase()}.'
        : '';
    final myMarkerName = _lastName.isNotEmpty
        ? (myInitial.isNotEmpty ? '$_lastName $myInitial' : _lastName)
        : _displayName;
    final asset = await buildMarkerAsset(
      name:        myMarkerName,
      type:        _vehicleType,
      color:       statusColor(online: _isOnline, available: _isAvailable),
      currentZoom: _currentZoom,
      groupColors: myGroups.map((g) => g.color).toList(),
    );
    if (!mounted) return;
    setState(() => _myAsset = asset);
  }

  // ─── voice ────────────────────────────────────────────────────────────────────

  void _startVoiceListener() {
    if (_uid == null) return;
    // Ακύρωσε τυχόν προηγούμενο listener ώστε να ΜΗΝ υπάρχουν δύο
    // autoplayers που παίζουν το ίδιο μήνυμα ταυτόχρονα (ακούγεται σαν ηχός).
    _voiceSub?.cancel();
    _voiceSub = VoiceService.messagesFor(_uid!).listen((messages) {
      final unread = messages.where((m) =>
          m.isUnread(_uid!) && m.fromUid != _uid! && !_seenIds.contains(m.id)).toList();
      if (unread.isEmpty) return;
      for (final m in unread) {
        _seenIds.add(m.id);
        if (!_playQueue.any((q) => q.id == m.id)) _playQueue.add(m);
      }
      if (!_isAutoPlaying) _playNext();
    });
  }

  Future<void> _playNext() async {
    if (_playQueue.isEmpty || _isMuted) { _isAutoPlaying = false; return; }
    _isAutoPlaying = true;
    final msg = _playQueue.removeAt(0);
    try {
      // Δήλωσε τον ήχο ως ΦΩΝΗ (όχι μουσική) ώστε το MIUI/Xiaomi να ΜΗΝ
      // εφαρμόσει sound enhancement effects που ακούγονται σαν «τούνελ».
      if (!_autoPlayerCtxSet) {
        try {
          await _autoPlayer.setAndroidAudioAttributes(
            AndroidAudioAttributes(
              // voiceCommunication = pipeline «κλήσης». Το MIUI/Xiaomi ΔΕΝ
              // εφαρμόζει sound enhancement εδώ, ακόμη & με κλειστή οθόνη
              // (όπου το 'media' περνούσε από εφέ → τούνελ).
              contentType: AndroidAudioContentType.speech,
              usage:       AndroidAudioUsage.voiceCommunication,
            ),
          );
        } catch (e) {
          debugPrint('autoPlayer audio attrs not applied: $e');
        }
        _autoPlayerCtxSet = true;
      }
      // Καθαρό voice pipeline (χωρίς MIUI effects) ΑΛΛΑ δυνατά από το ηχείο.
      // ΣΗΜΑΝΤΙΚΟ: το switch του audio route κάνει λίγα ms — το κάνουμε ΠΡΙΝ
      // φορτώσουμε/παίξουμε & περιμένουμε λίγο, αλλιώς χάνονται τα πρώτα
      // δευτερόλεπτα του μηνύματος.
      try {
        await _androidAudio.setMode(AndroidAudioHardwareMode.inCommunication);
        await _androidAudio.setSpeakerphoneOn(true);
        await Future.delayed(const Duration(milliseconds: 350));
      } catch (_) {}

      final file = await VoiceService.saveLocally(msg);
      // Σταμάτα τυχόν προηγούμενη αναπαραγωγή πριν ξεκινήσεις νέα.
      await _autoPlayer.stop();
      await _autoPlayer.setFilePath(file);
      // Επιπλέον μικρό περιθώριο μετά το load, ώστε το route να έχει
      // σταθεροποιηθεί πριν αρχίσει ο ήχος.
      await Future.delayed(const Duration(milliseconds: 150));
      await _autoPlayer.play();
      // Περίμενε ΜΟΝΟ completed.
      await _autoPlayer.playerStateStream.firstWhere(
        (s) => s.processingState == ProcessingState.completed,
      );
      await _autoPlayer.stop();
      // Επαναφορά mode ώστε να μην επηρεάζονται άλλοι ήχοι της συσκευής.
      try {
        await _androidAudio.setSpeakerphoneOn(false);
        await _androidAudio.setMode(AndroidAudioHardwareMode.normal);
      } catch (_) {}
      await VoiceService.markRead(msg.id, _uid!);
    } catch (_) {}
    _playNext();
  }

  // ─── profile ──────────────────────────────────────────────────────────────────

  Future<void> _openVehiclePicker(BuildContext outerContext) async {
    final result = await showVehicleTypeMenu(
      context: outerContext, itemCtx: outerContext, currentType: _vehicleType,
      hasBus: _hasBus,
      onToggleBus: () async {
        _hasBus = !_hasBus;
        if (_uid != null) {
          await FirebaseFirestore.instance
              .collection('presence').doc(_uid)
              .set({'hasBus': _hasBus}, SetOptions(merge: true));
        }
        if (mounted) setState(() {});
      },
    );
    if (result != null && result != _vehicleType) {
      _vehicleType = result;
      await _saveSettings();
      await _refreshVehicleIcon();
      await _publishMyLocation(force: true);
      if (mounted) setState(() {});
    }
  }

  Future<void> _openProfileForm() async {
    await showProfileForm(
      context: context, uid: _uid, appVersion: _appVersion,
      displayName: _displayName, lastName: _lastName, phone: _phone,
      vehicleModel: _vehicleModel, referredBy: _referredBy,
      plateNumber: _plateNumber, vehicleType: _vehicleType, initialHasBus: _hasBus,
      onSaved: ({required name, required lastName, required phone,
          required vehicleModel, required referredBy, required plateNumber, required vehicleType,
          required hasBus,
          required homeOwner, required ownerOfClientId, required ownerOfClientName}) {
        _saveProfile(name: name, lastName: lastName, phone: phone,
            vehicleModel: vehicleModel, referredBy: referredBy,
            plateNumber: plateNumber, vehicleType: vehicleType, hasBus: hasBus,
            homeOwner: homeOwner, ownerOfClientId: ownerOfClientId,
            ownerOfClientName: ownerOfClientName);
      },
    );
  }

  Future<void> _saveProfile({
    required String name, required String lastName, required String phone,
    required String vehicleModel, required String referredBy,
    required String plateNumber, required VehicleType vehicleType,
    required bool hasBus,
    required bool homeOwner, required String? ownerOfClientId,
    required String? ownerOfClientName,
  }) async {
    bool currentApproval = _isApproved;
    if (_uid != null) {
      try {
        final doc = await FirebaseFirestore.instance.collection('presence').doc(_uid).get();
        if (doc.exists) currentApproval = doc.data()?['isApproved'] ?? _isApproved;
      } catch (_) {}
    }
    _displayName = name; _lastName = lastName; _phone = phone;
    _vehicleModel = vehicleModel; _referredBy = referredBy;
    _plateNumber = plateNumber; _vehicleType = vehicleType;
    _hasBus = hasBus;

    await _saveSettings();

    // ── Home Owner: ΔΕΝ έχει όχημα — δεν δημοσιεύει θέση/διαθεσιμότητα.
    if (!homeOwner) {
      await _refreshVehicleIcon();
      try {
        final freshPos = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(accuracy: LocationAccuracy.best));
        _currentPosition = freshPos;
      } catch (_) {}
      _lastPublishedPosition = null;
      await _publishMyLocation(force: true);
    }

    if (_uid != null) {
      await FirebaseFirestore.instance.collection('presence').doc(_uid).set({
        'displayName': _displayName, 'lastName': _lastName, 'phone': _phone,
        'vehicleModel': _vehicleModel, 'vehicleType': _vehicleType.name,
        'hasBus': _hasBus,
        'referredBy': _referredBy, 'plateNumber': _plateNumber,
        'appVersion': _appVersion, 'isApproved': currentApproval,
        'admin': _isAdmin, 'email': FirebaseAuth.instance.currentUser?.email,
        'homeOwner': homeOwner,
        if (homeOwner) 'ownerOfClientId': ownerOfClientId,
        if (homeOwner) 'ownerOfClientName': ownerOfClientName,
        if (homeOwner) 'available': false, // Home Owner: πάντα «Μη Διαθέσιμος», δεν έχει όχημα
      }, SetOptions(merge: true));
    }
    if (!mounted) return;
    setState(() { _isApproved = currentApproval; _dialogShown = true; _isHomeOwner = homeOwner; });
  }

  Future<void> _toggleAvailability() async {
    _isAvailable = !_isAvailable;
    await _saveSettings();
    await _refreshVehicleIcon();
    _startPeriodicLocationPublish();
    // Ένα μόνο write: το _publishMyLocation(force) γράφει ήδη
    // available + updatedAt + θέση. Δεν χρειάζεται δεύτερο update.
    await _publishMyLocation(force: true);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _handleMenuAction(MenuAction action, BuildContext menuCtx) async {
    switch (action) {
      case MenuAction.editName:
        await _openProfileForm();
        return;
      case MenuAction.groups:
        if (!mounted) return;
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => GroupsAdminPage(uid: _uid ?? ''),
        ));
        return;
      case MenuAction.jobs:
        if (!mounted) return;
        final myGroupIds = _allGroups
            .where((g) => g.memberUids.contains(_uid))
            .map((g) => g.id)
            .toList();
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => JobAdminPage(
            adminUid:        _uid ?? '',
            adminName:       '$_displayName $_lastName'.trim(),
            isAdmin:         _isAdmin || _isMaster,
            isMaster:        _isMaster,
            managedGroupIds: _isMaster ? <String>[] : _managedGroupIds,
            userGroupIds:    myGroupIds,
          ),
        ));
        return;
      case MenuAction.taxi:
      case MenuAction.van:
      case MenuAction.mute:
        return; // Handled by GestureDetector in PopupMenuItem
      case MenuAction.checkUpdate:
        final uri = Uri.parse(kUpdateUrl);
        if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
        return;
      case MenuAction.broadcastUpdate:
        await _broadcastUpdate();
        return;
      case MenuAction.billing:
        if (!mounted) return;
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => BillingPage(
            uid:             _uid ?? '',
            userName:        '$_displayName $_lastName'.trim(),
            isMaster:        _isMaster,
            isAdmin:         _isAdmin,
            managedGroupIds: _managedGroupIds,
          ),
        ));
        return;
      case MenuAction.masters:
        if (!mounted) return;
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => AccessGuard(
            uid: _uid ?? '',
            hasAccess: (d) => d['master'] == true,
            deniedMessage: 'Η πρόσβαση στους Διαχειριστές αφαιρέθηκε.',
            child: MastersAdminPage(masterUid: _uid ?? ''),
          ),
        ));
        return;
      case MenuAction.pricingZones:
        if (!mounted) return;
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => AccessGuard(
            uid: _uid ?? '',
            hasAccess: (d) => d['master'] == true || d['tenantOwner'] == true,
            deniedMessage: 'Η πρόσβαση στις Ζώνες & Τιμές αφαιρέθηκε.',
            child: const PricingZonesPage(),
          ),
        ));
        return;
      case MenuAction.tenants:
        // Η ξεχωριστή σελίδα tenants καταργήθηκε — όλα ζουν πλέον στις
        // Καθολικές ρυθμίσεις.
        if (!mounted) return;
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => GlobalSettingsPage(masterUid: _uid ?? ''),
        ));
        return;
      case MenuAction.vivaSettings:
        if (!mounted) return;
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => AccessGuard(
            uid: _uid ?? '',
            hasAccess: (d) => d['master'] == true || d['tenantOwner'] == true,
            deniedMessage: 'Η πρόσβαση στις Ρυθμίσεις Viva αφαιρέθηκε.',
            child: const VivaSettingsPage(),
          ),
        ));
        return;
      case MenuAction.calendar:
        // ΝΕΟ: Ημερολόγιο Δουλειών — ορατό σε ΟΛΟΥΣ (οδηγό/admin/master).
        // Το AccessGuard εδώ ΔΕΝ μπλοκάρει πρόσβαση — μόνο περνάει το
        // calendarEnabled ώστε να δείξουμε ή όχι το κουμπί Google Calendar
        // μέσα στην οθόνη (only-visible, not gated).
        if (!mounted) return;
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => JobsCalendarPage(
            uid:                    _uid ?? '',
            isAdmin:                _isAdmin,
            isMaster:               _isMaster,
            googleCalendarEnabled:  _isMaster || _calendarEnabled,
          ),
        ));
        return;
    }
  }

  // ─── Master: στέλνει ειδοποίηση αναβάθμισης σε όλους ─────────────────────
  Future<void> _broadcastUpdate() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(children: const [
          Icon(Icons.campaign_rounded, color: Colors.deepOrange),
          SizedBox(width: 10),
          Expanded(child: Text('Ειδοποίηση αναβάθμισης')),
        ]),
        content: const Text(
          'Θα σταλεί σε ΟΛΟΥΣ τους οδηγούς μήνυμα να αναβαθμίσουν '
          'στη νέα έκδοση. Συνέχεια;',
        ),
        actions: [
          AppButtonTonal(label: 'Άκυρο', onPressed: () => Navigator.pop(ctx, false)),
          AppButton(label: 'Αποστολή', color: Colors.deepOrange, onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      await FirebaseFirestore.instance
          .collection('app_broadcasts')
          .doc('current')
          .set({
        'type':   'upgrade',
        'sentAt': FieldValue.serverTimestamp(),
        'sentBy': _uid ?? '',
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Η ειδοποίηση αναβάθμισης στάλθηκε σε όλους!'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Σφάλμα: $e'), backgroundColor: Colors.red),
      );
    }
  }

  bool get _formComplete =>
      _displayName != 'Driver' && _lastName.isNotEmpty &&
      _phone.isNotEmpty && _vehicleModel.isNotEmpty && _plateNumber.isNotEmpty;

  // ─── build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (!_initComplete) {
      return Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: Image.asset('assets/app_icon.png',
                    width: 120, height: 120),
              ),
              const SizedBox(height: 28),
              const SizedBox(
                width: 32, height: 32,
                child: CircularProgressIndicator(
                    color: Colors.amber, strokeWidth: 3),
              ),
            ],
          ),
        ),
      );
    }

    if (!_formComplete) {
      if (!_dialogShown) {
        _dialogShown = true;
        Future.microtask(() { if (mounted) _openProfileForm(); });
      }
      return Scaffold(body: Center(child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Image.asset('assets/app_icon.png', width: 120, height: 120),
          const SizedBox(height: 20),
          const Text('Καλώς ήρθατε!\nΠαρακαλώ συμπληρώστε τα στοιχεία σας.',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 18)),
          const SizedBox(height: 24),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Colors.amber),
            icon: const Icon(Icons.person_outline),
            label: const Text('Συμπλήρωση Στοιχείων'),
            onPressed: () { _dialogShown = false; _openProfileForm(); },
          ),
        ]),
      )));
    }

    if (!_isApproved) {
      return Scaffold(body: Center(child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Image.asset('assets/app_icon.png', width: 120, height: 120),
          const SizedBox(height: 20),
          const Text('Το προφίλ σας δημιουργήθηκε.\nΠεριμένετε έγκριση από τον διαχειριστή...',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 18)),
          const SizedBox(height: 30),
          const CircularProgressIndicator(color: Colors.amber),
          const SizedBox(height: 24),
          AppButton(
            label: 'Επεξεργασία Στοιχείων',
            icon: Icons.edit_outlined,
            color: Colors.amber,
            fg: Colors.black,
            onPressed: () { _dialogShown = false; _openProfileForm(); },
          ),
        ]),
      )));
    }

    // Home Owner (ιδιοκτήτης καταλύματος) — ΔΕΝ βλέπει χάρτη/κανονική
    // εφαρμογή οδηγού· περιορισμένη οθόνη (Ανοιχτές/Αποθηκευμένες/Ιστορικό).
    if (_isHomeOwner && !_isAdmin && !_isMaster) {
      return OwnerHomePage(
        uid: _uid ?? '',
        displayName: _displayName,
        ownerOfClientId: _ownerOfClientId,
        ownerOfClientName: _ownerOfClientName,
      );
    }

    final userLatLng = _currentPosition == null
        ? kAthens.target
        : LatLng(_currentPosition!.latitude, _currentPosition!.longitude);

    final markers = <Marker>{
      if (_currentZoom >= kMarkerHideZoom)
        Marker(
          markerId: const MarkerId('vehicle'),
          position: userLatLng,
          icon:     _myAsset?.icon   ?? BitmapDescriptor.defaultMarker,
          anchor:   _myAsset?.anchor ?? const Offset(0.5, kCarCenterFraction),
        ),
      ..._otherMarkers.values,
    };

    final myGroupIds = _allGroups
        .where((g) => g.memberUids.contains(_uid))
        .map((g) => g.id)
        .toList();

    return JobListener(
      uid:         _uid ?? '',
      displayName: _displayName,
      lastName:    _lastName,
      vehicleType: _vehicleType.name,
      groupIds:    myGroupIds,
      isAvailable: _isAvailable,
      isMaster:    _isMaster,
      isAdmin:     _isAdmin,
      child: Scaffold(
        backgroundColor: Colors.white,
        body: Stack(children: [
        GoogleMap(
          initialCameraPosition: kAthens,
          myLocationButtonEnabled: false,
          zoomControlsEnabled:     false,
          mapToolbarEnabled:       false,
          markers:                 markers,
          myLocationEnabled:       false,
          onMapCreated: (c) async {
            _mapController = c;
            // Σκούρος χάρτης όταν το θέμα (auto ή χειροκίνητο) είναι dark.
            if (AppColors.isDarkNow(context)) {
              await c.setMapStyle(_darkMapStyle);
            }
            final z = await c.getZoomLevel();
            if (!mounted) return;
            _currentZoom = z;
            await _refreshVehicleIcon();
            await _rebuildOtherMarkers();
            if (_currentPosition != null) {
              // Κεντράρισμα στη θέση σου αμέσως — σαν να πάτησες το
              // κουμπί «η θέση μου».
              await c.animateCamera(CameraUpdate.newLatLngZoom(
                LatLng(_currentPosition!.latitude, _currentPosition!.longitude), 14));
            } else {
              // Η θέση δεν έχει έρθει ακόμη· μόλις φτάσει, κεντράρισε
              // αυτόματα μία φορά (χωρίς να χρειαστεί ο χρήστης να πατήσει
              // το κουμπί «η θέση μου»).
              _pendingAutoCenter = true;
            }
          },
          onCameraIdle: () async {
            final c = _mapController;
            if (c == null) return;
            final z = await c.getZoomLevel();
            if (!mounted) return;
            if ((z - _currentZoom).abs() < 0.05) return;
            _currentZoom = z;
            await Future.wait([_refreshVehicleIcon(), _rebuildOtherMarkers()]);
          },
        ),

        // ─── Top bar (compact redesign) ────────────────────────────────────
        Positioned(
          top: MediaQuery.of(context).padding.top + 10,
          left: 10, right: 10,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(
                child: HomeStatusBar(
                  isMaster:    _isMaster,
                  isAdmin:     _isAdmin,
                  displayName: _displayName,
                  isAvailable: _isAvailable,
                  onToggleAvailable: _toggleAvailability,
                  onTapAvatar: () => showMyCard(
                    context: context,
                    displayName: _displayName, lastName: _lastName,
                    phone: _phone, vehicleModel: _vehicleModel,
                    plateNumber: _plateNumber, appVersion: _appVersion,
                    vehicleType: _vehicleType,
                    isOnline: _isOnline, isAvailable: _isAvailable,
                    isMuted: _isMuted, uid: _uid,
                    allGroups: _allGroups, updateUrl: kUpdateUrl,
                  ),
                ),
              ),
            ]),
            if (_isAdmin || _isMaster) ...[
              const SizedBox(height: 8),
              OwnJobsTodayStats(uid: _uid ?? ''),
            ],
          ]),
        ),

        // ─── Recenter + floating chips (Δουλειές / Μηνύματα) + countdown ───
        //     Πάντα πάνω από το bottom nav + Android navigation bar.
        //     Το κουμπί «η θέση μου» κάθεται ΠΑΝΩ από τα chips (όχι πίσω),
        //     στο νέο στυλ (λευκή στρογγυλή κάρτα).
        Positioned(
          left: 10, right: 10,
          bottom: _kBottomNavHeight + MediaQuery.of(context).padding.bottom + 10,
          child: Builder(builder: (context) {
            final c = AppColors.of(context);
            return Column(mainAxisSize: MainAxisSize.min, children: [
              Align(
                alignment: Alignment.centerRight,
                child: Material(
                  color: c.card,
                  shape: CircleBorder(
                      side: BorderSide(color: c.cardBorder, width: 0.8)),
                  elevation: 2,
                  shadowColor: Colors.black26,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () {
                      if (_currentPosition != null && _mapController != null) {
                        _mapController!.animateCamera(CameraUpdate.newLatLngZoom(
                          LatLng(_currentPosition!.latitude,
                              _currentPosition!.longitude), 12));
                      }
                    },
                    child: SizedBox(
                      width: 48, height: 48,
                      child: Icon(Icons.my_location_rounded,
                          size: 24, color: c.amberDeep),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              HomeFloatingChips(
                uid: _uid ?? '',
                // Χωρίς το παλιό συρτάρι: το chip «Δουλειές» ανοίγει το
                // Ημερολόγιο στη ΣΗΜΕΡΙΝΗ μέρα — βλέπεις τις σημερινές στο
                // συρτάρι του και τις υπόλοιπες στον μήνα.
                onTapJobs: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => JobsCalendarPage(
                    uid:                   _uid ?? '',
                    isAdmin:               _isAdmin,
                    isMaster:              _isMaster,
                    googleCalendarEnabled: _isMaster || _calendarEnabled,
                  ),
                )),
                onTapMessages: () => openVoiceInboxSheet(
                  context: context, uid: _uid ?? '',
                  displayName: _displayName, lastName: _lastName,
                ),
              ),
              const SizedBox(height: 8),
              AppointmentCountdownBar(uid: _uid ?? ''),
            ]);
          }),
        ),

        // ─── Κάτω navigation bar (Χάρτης/Δουλειές/Ημερολόγιο/Χρεώσεις/
        //     Ρυθμίσεις) — πάντα ορατό, με σωστό SafeArea (Android nav bar).
        Positioned(
          left: 0, right: 0, bottom: 0,
          child: Builder(builder: (context) {
            final c = AppColors.of(context);
            return SafeArea(
            top: false,
            child: Container(
              height: _kBottomNavHeight,
              decoration: BoxDecoration(
                // Παίρνει τα χρώματα του θέματος: λευκή σε light mode,
                // σκούρα σε dark mode (πριν ήταν καρφωμένη λευκή).
                color: c.card,
                border: Border(top: BorderSide(color: c.divider)),
              ),
              child: Row(children: [
                _navItem(
                  icon: Icons.map_rounded,
                  label: 'Χάρτης',
                  selected: true,
                  onTap: () {}, // ήδη εδώ
                ),
                if (_isAdmin || _isMaster)
                  _navItem(
                    icon: Icons.work_rounded,
                    label: 'Δουλειές',
                    selected: false,
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => JobAdminPage(
                        adminUid:        _uid ?? '',
                        adminName:       '$_displayName $_lastName'.trim(),
                        isAdmin:         true,
                        isMaster:        _isMaster,
                        managedGroupIds: _isMaster ? const [] : _managedGroupIds,
                      ),
                    )),
                  )
                else
                  _navItem(
                    icon: Icons.history_rounded,
                    label: 'Ιστορικό',
                    selected: false,
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => JobAdminPage(
                        adminUid:     _uid ?? '',
                        adminName:    '$_displayName $_lastName'.trim(),
                        isAdmin:      false,
                        isMaster:     false,
                        userGroupIds: myGroupIds,
                      ),
                    )),
                  ),
                _navItem(
                  icon: Icons.calendar_month_rounded,
                  label: 'Ημερολόγιο',
                  selected: false,
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => JobsCalendarPage(
                      uid:                   _uid ?? '',
                      isAdmin:               _isAdmin,
                      isMaster:              _isMaster,
                      googleCalendarEnabled: _isMaster || _calendarEnabled,
                    ),
                  )),
                ),
                _navItem(
                  icon: Icons.receipt_long_rounded,
                  label: 'Χρεώσεις',
                  selected: false,
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => BillingPage(
                      uid: _uid ?? '',
                      userName: '$_displayName $_lastName'.trim(),
                      isMaster: _isMaster,
                      isAdmin:  _isAdmin,
                      managedGroupIds: _managedGroupIds,
                    ),
                  )),
                ),
                _navItem(
                  icon: Icons.settings_rounded,
                  label: 'Ρυθμίσεις',
                  selected: false,
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => SettingsPage(
                      uid:      _uid ?? '',
                      isAdmin:  _isAdmin,
                      isMaster: _isMaster,
                      onEditProfile: _openProfileForm,
                      onCheckUpdate: () => _handleMenuAction(MenuAction.checkUpdate, context),
                      onOpenVehiclePicker: () => _openVehiclePicker(context),
                      onBroadcastUpdate: _isMaster
                          ? () => _handleMenuAction(MenuAction.broadcastUpdate, context)
                          : null,
                      onSignOut: () async {
                        await FirebaseAuth.instance.signOut();
                      },
                      muted: _isMuted,
                      onMuteChanged: (v) async {
                        _isMuted = v;
                        await _saveSettings();
                        if (_uid != null) {
                          await FirebaseFirestore.instance
                              .collection('presence').doc(_uid)
                              .update({'muted': _isMuted});
                        }
                        if (mounted) setState(() {});
                      },
                    ),
                  )),
                ),
              ]),
            ),
          );
          }),
        ),

        ]),
      ),
    );
  }

  Widget _navItem({
    required IconData icon,
    required String   label,
    required bool     selected,
    required VoidCallback onTap,
  }) {
    final c = AppColors.of(context);
    // amberDeep είναι φωτεινό σε dark mode· textFaint αχνό και στα δύο.
    final color = selected ? c.amberDeep : c.textFaint;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(fontSize: 10, color: color)),
          ],
        ),
      ),
    );
  }
}
