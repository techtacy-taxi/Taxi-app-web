// ==========================================
// FILE: ./lib/jobs/job_form.dart
// ==========================================
//
// ΝΕΑ ΦΟΡΜΑ ΔΟΥΛΕΙΑΣ — ίδια με την κανονική (job_form.dart) με μία διαφορά:
// τα πεδία "Από / Προς" βρίσκουν σημεία/οδούς μέσω Google Maps και
// αποθηκεύουν συντεταγμένες + χιλιόμετρα διαδρομής στη δουλειά.
// Ενεργοποιείται από τον διακόπτη "Νέα Φόρμα Δουλειάς" στους Διαχειριστές.

import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'job_model.dart';
import 'client_model.dart';
import 'job_service.dart';
import 'job_shared_widgets.dart';
import 'saved_job_service.dart';
import 'places_service.dart';

// Key αποθήκευσης τελευταίων ρυθμίσεων νέας δουλειάς
const String _kLastJobSettings = 'last_job_settings_v1';

/// Προσυμπληρωμένα στοιχεία για νέα δουλειά (από αποθηκευμένη διαδρομή πελάτη).
/// Όλα προαιρετικά — γεμίζουν μόνο όσα δίνονται, τα υπόλοιπα ο χρήστης.
class JobPrefill {
  final PlacePick? from;
  final PlacePick? to;
  final double?    price;
  final String?    sourceId;   // πηγή προς προεπιλογή
  final String?    clientName; // όνομα πελάτη (γεμίζει το πεδίο πελάτη)
  final String?    clientPhone;
  final String?    clientEmail;
  final DateTime?  scheduledAt; // ώρα ραντεβού (από .ics)
  final int?       persons;     // άτομα
  final int?       luggage;     // βαλίτσες
  final String?    note;        // σχόλια (π.χ. email)
  final String?    flightOrShip; // πτήση / πλοίο
  final String?    vehicleType;  // 'taxi' | 'van' | 'any'
  final int?       childSeatCount; // παιδικά καθίσματα (από .ics)
  const JobPrefill({
    this.from,
    this.to,
    this.price,
    this.sourceId,
    this.clientName,
    this.clientPhone,
    this.clientEmail,
    this.scheduledAt,
    this.persons,
    this.luggage,
    this.note,
    this.flightOrShip,
    this.vehicleType,
    this.childSeatCount,
  });
}

class JobFormPage extends StatefulWidget {
  final String adminUid;
  final String adminName; // Εμφανιζόμενο όνομα για createdByName
  final bool   isMaster;  // αν δεν είναι master → app commission κλειδωμένο
  final Job?   editJob;
  // ── Αντιγραφή δουλειάς ──
  // Αν != null → ΑΝΤΙΓΡΑΦΟ υπάρχουσας δουλειάς: η φόρμα γεμίζει με όλα τα
  // στοιχεία της, αλλά συμπεριφέρεται ως ΝΕΑ δουλειά (createJob, νέο doc).
  // Το editJob/editSavedJob μένουν null ώστε η «Αποστολή» να δημιουργεί νέα.
  final Job?   copyFromJob;
  final JobPrefill? prefill; // προσυμπλήρωση από διαδρομή πελάτη
  final Future<void> Function()? onCreated; // καλείται μετά από επιτυχή αποστολή
  final Future<void> Function()? onSavedDraft; // καλείται μετά από επιτυχή αποθήκευση draft
  // ── Αποθηκευμένες δουλειές ──
  // Αν editSavedJobId != null → επεξεργαζόμαστε ΑΠΟΘΗΚΕΥΜΕΝΗ δουλειά (draft):
  // η «Αποθήκευση» κάνει update στο saved_jobs (όχι νέα εγγραφή).
  final Job?    editSavedJob;   // τα δεδομένα του draft (για προσυμπλήρωση)
  final String? editSavedJobId; // doc id στο saved_jobs
  // Αν η δουλειά προέρχεται από συμβάν ημερολογίου, κρατάμε το eventId ώστε,
  // όταν τελικά ΣΤΑΛΕΙ (από τις Αποθηκευμένες), να μαρκάρουμε το συμβάν «Στάλθηκε».
  final String? calendarEventId;
  // ── Κοινή πρόσβαση (άλλος admin επεξεργάζεται ξένη δουλειά) ──
  // Αν != null → η δουλειά ΑΝΗΚΕΙ σε άλλον. Διατηρούμε την ιδιοκτησία του
  // (createdBy/ownerUid) και γράφουμε τον τρέχοντα ως lastEditedBy.
  final String? ownerOverrideUid;
  final String? ownerOverrideName;

  const JobFormPage({
    super.key,
    required this.adminUid,
    this.adminName  = '',
    this.isMaster   = false,
    this.editJob,
    this.copyFromJob,
    this.prefill,
    this.onCreated,
    this.onSavedDraft,
    this.editSavedJob,
    this.editSavedJobId,
    this.calendarEventId,
    this.ownerOverrideUid,
    this.ownerOverrideName,
  });

  bool get isSavedDraft => editSavedJobId != null;
  bool get isForeignOwned => ownerOverrideUid != null &&
      ownerOverrideUid!.isNotEmpty &&
      ownerOverrideUid != adminUid;

  @override
  State<JobFormPage> createState() => _JobFormPageState();
}

class _JobFormPageState extends State<JobFormPage> {

  // ─── Controllers ──────────────────────────────────────────────────────────
  final _priceCtrl   = TextEditingController();
  final _noteCtrl    = TextEditingController();

  // ─── Σημεία Google (Από / Προς) ───────────────────────────────────────────
  PlacePick? _fromPick;
  PlacePick? _toPick;

  // Διαδρομή
  double?   _routeKm;        // χιλιόμετρα
  String?   _routePolyline;  // encoded polyline
  bool      _routeLoading = false;
  bool      _routeIsAir   = false; // true = ευθεία (fallback χωρίς Directions)
  int       _routeReqId   = 0;     // ακυρώνει παλιά αιτήματα

  // ─── State ────────────────────────────────────────────────────────────────
  int     _persons     = 1;
  int     _luggage     = 0;
  int     _childSeatCount = 0;
  final   _childSeatPriceCtrl = TextEditingController();
  bool    _withReturn = false;
  bool    _withStops  = false;
  String  _vehicleType = 'any';
  double _appCommissionPerBookingDefault = 0;
  int    _shuttleExtraMinutesPerBooking  = 10;

  // ═══ Ομαδική μεταφορά (Shuttle / Λεωφορείο) — πολλαπλές κρατήσεις ═══
  // Η ΚΥΡΙΑ κράτηση είναι τα κανονικά πεδία της φόρμας (πελάτης/τηλ/από...).
  // Οι ΕΠΙΠΛΕΟΝ μπαίνουν εδώ. Κοινό σημείο: ο Προορισμός (default) ή η
  // Αφετηρία — καθορίζει ποια διεύθυνση είναι «δική» της κάθε κράτησης.
  bool get _isGroupVehicle =>
      _vehicleType == 'shuttle' || _vehicleType == 'bus';
  bool _groupSharedIsDestination = true; // κοινό = «Προς» (μαζεύουμε από καταλύματα)
  final List<_ExtraBooking> _extraBookings = [];
  String? _mainStopZoneName; // ζώνη/θέση της ΚΥΡΙΑΣ κράτησης όταν το «Από»
  int?    _mainStopOrder;    // επιλέχθηκε από πελάτη-κατάλυμα
  bool    _loadedContainer = false; // φορτώθηκαν στάσεις από edit ενωμένης

  // Αν επεξεργαζόμαστε ΕΝΩΜΕΝΗ (container) αποθηκευμένη, φόρτωσε τις
  // στάσεις της: η 1η γίνεται η κύρια κράτηση (τα πεδία της φόρμας έχουν
  // ήδη προσυμπληρωθεί από το job), οι υπόλοιπες γίνονται επιπλέον.
  // Προμήθεια app + έξτρα λεπτά Shuttle — ίδιο global ρύθμισης doc με τη
  // σελίδα «Διαχειριστές» (JobService.getAppSettings), όχι ανά tenant.
  Future<void> _loadAppCommissionDefaults() async {
    try {
      final settings = await JobService.getAppSettings();
      if (!mounted) return;
      setState(() {
        _appCommissionPerBookingDefault = settings['appCommission'] ?? 0;
        _shuttleExtraMinutesPerBooking =
            (settings['shuttleExtraMinutesPerBooking'] ?? 10).toInt();
      });
    } catch (_) {}
  }

  Future<void> _maybeLoadContainer() async {
    final id = widget.editSavedJobId;
    if (id == null || id.isEmpty) return;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('saved_jobs').doc(id).get();
      final d = doc.data();
      if (d == null || d['isShuttleContainer'] != true) return;
      final stops = (d['shuttleStops'] as List? ?? [])
          .whereType<Map>()
          .map((m) => ShuttleStop.fromMap(Map<String, dynamic>.from(m)))
          .toList();
      if (stops.isEmpty) return;
      final sharedIsPickup = d['shuttleSharedIsPickup'] == true;
      setState(() {
        _loadedContainer = true;
        if (_vehicleType != 'bus') _vehicleType = 'shuttle';
        _groupSharedIsDestination = !sharedIsPickup;
        // Κύρια κράτηση ← 1η στάση
        final first = stops.first;
        _clientNameCtrl.text  = first.name;
        _clientPhoneCtrl.text = first.phone ?? '';
        _clientEmailCtrl.text = first.email ?? '';
        _flightShipCtrl.text  = first.flightOrShip ?? '';
        _priceCtrl.text = first.price.toStringAsFixed(2);
        _persons = first.persons;
        _luggage = first.luggage;
        _mainStopZoneName = first.zoneName;
        _mainStopOrder    = first.orderInZone;
        final ownPick = PlacePick(
            description: first.address, lat: first.lat, lng: first.lng);
        if (sharedIsPickup) {
          _toPick = ownPick;
        } else {
          _fromPick = ownPick;
        }
        // Επιπλέον κρατήσεις ← υπόλοιπες στάσεις
        _extraBookings.clear();
        for (final st in stops.skip(1)) {
          final b = _ExtraBooking();
          b.nameCtrl.text   = st.name;
          b.phoneCtrl.text  = st.phone ?? '';
          b.emailCtrl.text  = st.email ?? '';
          b.flightCtrl.text = st.flightOrShip ?? '';
          b.priceCtrl.text  = st.price.toStringAsFixed(2);
          b.personsCtrl.text = '${st.persons}';
          b.luggageCtrl.text = '${st.luggage}';
          b.childSeatCtrl.text = '${st.childSeatCount}';
          b.noteCtrl.text = st.note ?? '';
          b.pick = PlacePick(
              description: st.address, lat: st.lat, lng: st.lng);
          b.zoneName    = st.zoneName;
          b.orderInZone = st.orderInZone;
          _extraBookings.add(b);
        }
      });
    } catch (_) {}
  }

  // Χτίζει τις στάσεις (κύρια + επιπλέον) για αποθήκευση container.
  // isPickupHere = παίρνουμε ΑΠΟ τη στάση (όταν το κοινό σημείο είναι ο
  // προορισμός) — αλλιώς αφήνουμε ΣΤΗ στάση.
  List<ShuttleStop> _buildGroupStops(Job job) {
    final isPickupHere = _groupSharedIsDestination;
    final mainOwn = isPickupHere ? _fromPick : _toPick;
    final stops = <ShuttleStop>[
      ShuttleStop(
        savedJobId:   widget.editSavedJobId ?? '',
        name:         _clientNameCtrl.text.trim(),
        phone:        _clientPhoneCtrl.text.trim().isNotEmpty
            ? _clientPhoneCtrl.text.trim() : null,
        email:        _clientEmailCtrl.text.trim().isNotEmpty
            ? _clientEmailCtrl.text.trim() : null,
        flightOrShip: _flightShipCtrl.text.trim().isNotEmpty
            ? _flightShipCtrl.text.trim() : null,
        address:      (mainOwn?.description ?? '').trim(),
        lat:          mainOwn?.lat,
        lng:          mainOwn?.lng,
        isPickupHere: isPickupHere,
        price:        job.price,
        persons:      _persons,
        luggage:      _luggage,
        childSeatCount: _childSeatCount,
        note:         _noteCtrl.text.trim().isNotEmpty
            ? _noteCtrl.text.trim() : null,
        zoneName:     _mainStopZoneName,
        orderInZone:  _mainStopOrder,
      ),
    ];
    for (final b in _extraBookings) {
      final addr = (b.pick?.description ?? '').trim();
      if (addr.isEmpty && b.nameCtrl.text.trim().isEmpty) continue;
      stops.add(ShuttleStop(
        savedJobId:   '',
        name:         b.nameCtrl.text.trim(),
        phone:        b.phoneCtrl.text.trim().isNotEmpty
            ? b.phoneCtrl.text.trim() : null,
        email:        b.emailCtrl.text.trim().isNotEmpty
            ? b.emailCtrl.text.trim() : null,
        flightOrShip: b.flightCtrl.text.trim().isNotEmpty
            ? b.flightCtrl.text.trim() : null,
        address:      addr,
        lat:          b.pick?.lat,
        lng:          b.pick?.lng,
        isPickupHere: isPickupHere,
        price:        double.tryParse(
                b.priceCtrl.text.trim().replaceAll(',', '.')) ?? 0,
        persons:      int.tryParse(b.personsCtrl.text.trim()) ?? 1,
        luggage:      int.tryParse(b.luggageCtrl.text.trim()) ?? 0,
        childSeatCount: int.tryParse(b.childSeatCtrl.text.trim()) ?? 0,
        note:         b.noteCtrl.text.trim().isNotEmpty
            ? b.noteCtrl.text.trim() : null,
        zoneName:     b.zoneName,
        orderInZone:  b.orderInZone,
      ));
    }
    return stops;
  }

  // Αποθήκευση ομαδικής (Shuttle/Λεωφορείο με 2+ κρατήσεις) ως container
  // στις Αποθηκευμένες — ίδια δομή με το «Ένωση» ώστε όλα τα υπάρχοντα UI
  // να δουλεύουν αυτούσια. Επιστρέφει true αν χειρίστηκε την αποθήκευση.
  Future<bool> _saveGroupIfNeeded(Job job) async {
    if (!_isGroupVehicle) return false;
    if (_extraBookings.isEmpty && !_loadedContainer) return false;
    final shared = _groupSharedIsDestination ? _toPick : _fromPick;
    final stops = _buildGroupStops(job);
    // Χρόνος Shuttle: ΒΑΣΗ 60' (1η κράτηση) + Χ' ΓΙΑ ΚΑΘΕ επιπλέον κράτηση —
    // π.χ. με Χ=10: 1 κράτηση=60', 2=70', 3=80', 4=90' κ.ο.κ. Το Χ δηλώνεται
    // από τον master (Ρυθμίσεις Online Φόρμας → Δυναμικοί Τύποι).
    const shuttleBaseMinutes = 60;
    final totalShuttleMinutes = stops.length <= 1
        ? 0 // ένα shuttle με μία μόνο κράτηση δεν είναι «ενωμένο» — καμία προσαύξηση
        : shuttleBaseMinutes +
            (stops.length - 1) * _shuttleExtraMinutesPerBooking;
    await SavedJobService.saveGroupContainer(
      job: job,
      stops: stops,
      shuttleTotalMinutes: totalShuttleMinutes,
      sharedPointName: (shared?.description ?? '').trim(),
      sharedPointLat: shared?.lat,
      sharedPointLng: shared?.lng,
      sharedIsPickup: !_groupSharedIsDestination,
      ownerUid: widget.isForeignOwned
          ? widget.ownerOverrideUid! : widget.adminUid,
      ownerName: widget.isForeignOwned
          ? (widget.ownerOverrideName ?? '') : widget.adminName,
      updateId: _loadedContainer ? widget.editSavedJobId : null,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('🚐 Η ομαδική μεταφορά αποθηκεύτηκε στις «Αποθηκευμένες» '
            'ως ενωμένη — από εκεί γίνεται και η αποστολή.'),
        backgroundColor: Color(0xFF1565C0),
        duration: Duration(seconds: 3),
      ));
      Navigator.of(context).pop(true);
    }
    return true;
  }


  int     _timeoutMins = 5;

  // Συνολικό κόστος παιδικών καθισμάτων
  double get _childSeatTotal {
    final p = double.tryParse(
        _childSeatPriceCtrl.text.trim().replaceAll(',', '.')) ?? 0;
    return _childSeatCount * p;
  }

  JobSource? _selectedSource;
  List<JobSource> _sources = [];

  // Πελάτες (auto-suggest στο "Από")
  List<Client> _clients = [];

  String?  _selectedGroupId;
  List<Map<String, dynamic>> _groups = [];

  // Συγκεκριμένοι οδηγοί (αντί για ομάδα) — 1 ή περισσότεροι
  final Set<String>         _targetUids  = {};
  final Map<String, String> _targetNames = {};
  List<Map<String, dynamic>> _allDrivers = [];

  DateTime? _scheduledAt;
  bool      _isScheduled   = false;
  bool      _isSaving      = false;
  bool      _availableOnly = true;
  bool      _exclusiveTarget = false; // αποκλειστική αποστολή σε ομάδα/οδηγούς

  // Χειροκίνητο toggle «Προπληρωμένο» — ο πελάτης έχει ήδη πληρώσει ΟΛΟΚΛΗΡΗ
  // την τιμή με άλλο τρόπο (μετρητά στον master, τραπεζικό έμβασμα, κλπ.),
  // όχι μέσω της online φόρμας/Viva. Ο οδηγός δεν εισπράττει τίποτα· το
  // κέρδος του το χρωστάει αυτός που έβγαλε τη δουλειά (βλ. onJobBilling).
  bool      _fullyPaidManual = false;

  // Editable commission overrides
  final _commissionCtrl    = TextEditingController(); // πηγή
  final _appCommissionCtrl = TextEditingController(); // app
  bool  _commissionEdited    = false;
  bool  _appCommissionEdited = false;

  // ── Βραδινό γιαούρτι (23:30–05:30) ──
  // _nightAuto = τι λέει ο αυτόματος κανόνας (ώρα ραντεβού ή, αν άμεση, τώρα).
  // _nightOverride = null → ακολούθα το auto· true/false → χειροκίνητο.
  bool  _nightAuto = false;
  bool? _nightOverride;
  bool get _isNight => _nightOverride ?? _nightAuto;

  // Optional client fields
  final _clientNameCtrl  = TextEditingController();
  final _clientPhoneCtrl = TextEditingController();
  final _clientEmailCtrl = TextEditingController();
  final _flightShipCtrl  = TextEditingController();

  // Τιμή πάνω στην οποία υπολογίζονται οι προμήθειες:
  // αρχική τιμή + παιδικά καθίσματα. Έτσι μια ποσοστιαία προμήθεια
  // (γιαούρτι %) εφαρμόζεται στο ΣΥΝΟΛΟ μαζί με τα παιδικά καθίσματα.
  double get _commissionablePrice {
    final base = double.tryParse(_priceCtrl.text) ?? 0;
    return base + _childSeatTotal;
  }

  // Προμήθεια πηγής (ημερήσια ή βραδινή ανάλογα με _isNight)
  double get _commission {
    if (_commissionEdited) return double.tryParse(_commissionCtrl.text) ?? 0;
    if (_selectedSource == null) return 0;
    return _selectedSource!.calculateFor(_commissionablePrice, _isNight);
  }

  // Προμήθεια App
  double get _appCommission {
    if (_appCommissionEdited) return double.tryParse(_appCommissionCtrl.text) ?? 0;
    if (_selectedSource != null) {
      final fromSource = _selectedSource!.calculateApp(_commissionablePrice);
      if (fromSource > 0) return fromSource;
    }
    // Καμία πηγή/χειροκίνητη τιμή → η γενική προμήθεια app ανά κράτηση,
    // όπως τη δηλώνει ο master στις ρυθμίσεις.
    return _appCommissionPerBookingDefault;
  }

  double get _driverEarning {
    // Ο οδηγός κρατά τιμή + παιδικά καθίσματα, μείον τις προμήθειες
    return _commissionablePrice - _commission - _appCommission;
  }

  // ─── Lifecycle ────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _loadAppCommissionDefaults();
    _loadGroups();
    _loadClients();
    if (widget.editJob != null) {
      _prefill(widget.editJob!);
      _loadSources();
      // Αν η δουλειά ήταν ήδη προπληρωμένη (online ή χειροκίνητα), ο
      // διακόπτης πρέπει να δείχνει ΑΝΟΙΧΤΟΣ όταν την ξανανοίγεις — αλλιώς
      // φαίνεται σαν να μην είναι προπληρωμένη ενώ είναι.
      _fullyPaidManual = widget.editJob!.fullyPaid;
    } else if (widget.editSavedJob != null) {
      _prefill(widget.editSavedJob!);
      _maybeLoadContainer();
      _loadSources();
      _fullyPaidManual = widget.editSavedJob!.fullyPaid;
    } else if (widget.copyFromJob != null) {
      // ΑΝΤΙΓΡΑΦΟ: γέμισε τα πεδία αλλά συμπεριφέρου ως νέα δουλειά.
      _prefill(widget.copyFromJob!);
      _loadSources();
      // ΣΗΜΑΝΤΙΚΟ: το αντίγραφο είναι ΝΕΑ, μη πληρωμένη κράτηση — ο
      // διακόπτης ΔΕΝ πρέπει να «κληρονομήσει» το fullyPaid του πρωτότυπου.
      _fullyPaidManual = false;
      // Αν η αρχική ήταν προγραμματισμένη → ζήτα νέα ώρα αμέσως.
      // Άκυρο = μένει κενό → βγαίνει ΑΜΕΣΑ.
      if (widget.copyFromJob!.scheduledAt != null) {
        _scheduledAt = null;
        _isScheduled = false;
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          await _pickScheduledTime();
          if (!mounted) return;
          setState(() => _isScheduled = _scheduledAt != null);
        });
      }
    } else {
      _initNewJob();
    }
    // Όταν αλλάζει η τιμή → ξαναϋπολόγισε προμήθειες πηγής/App
    _priceCtrl.addListener(() {
      _recomputeCommissions();
      setState(() {});
    });
    // Αρχικός υπολογισμός βραδινού (για άμεση δουλειά = τώρα).
    _recomputeNightAuto();
  }

  /// Ξαναϋπολογίζει τα πεδία προμηθειών από την επιλεγμένη πηγή + τιμή,
  /// εκτός αν ο χρήστης τα έχει αλλάξει χειροκίνητα.
  void _recomputeCommissions() {
    if (_selectedSource == null) return;
    final price = _commissionablePrice;
    if (!_commissionEdited) {
      final c = _selectedSource!.calculateFor(price, _isNight);
      _commissionCtrl.text = c != 0 ? c.toStringAsFixed(2) : '';
    }
    if (!_appCommissionEdited) {
      final ac = _selectedSource!.calculateApp(price);
      _appCommissionCtrl.text = ac > 0 ? ac.toStringAsFixed(2) : '';
    }
  }

  // Νέα δουλειά: πρώτα φέρνουμε τις τελευταίες ρυθμίσεις, μετά τις πηγές
  Future<void> _initNewJob() async {
    await _restoreLastSettings();
    _applyPrefill(); // διαδρομή πελάτη — υπερισχύει των τελευταίων ρυθμίσεων
    await _loadSources();
  }

  /// Εφαρμόζει τα προσυμπληρωμένα στοιχεία από αποθηκευμένη διαδρομή πελάτη.
  void _applyPrefill() {
    final p = widget.prefill;
    if (p == null) return;
    if (p.from != null) _fromPick = p.from;
    if (p.to   != null) _toPick   = p.to;
    if (p.price != null && p.price! > 0) {
      _priceCtrl.text = p.price!.toStringAsFixed(2);
    }
    if (p.sourceId != null && p.sourceId!.isNotEmpty) {
      // Θα επιλεγεί μέσα στο _loadSources μέσω _pendingSourceId
      _pendingSourceId = p.sourceId;
    }
    if (p.clientName != null && p.clientName!.isNotEmpty) {
      _clientNameCtrl.text = p.clientName!;
    }
    if (p.clientPhone != null && p.clientPhone!.isNotEmpty) {
      _clientPhoneCtrl.text = p.clientPhone!;
    }
    if (p.clientEmail != null && p.clientEmail!.isNotEmpty) {
      _clientEmailCtrl.text = p.clientEmail!;
    }
    // ── Από .ics: ώρα ραντεβού / άτομα / βαλίτσες / πτήση / σχόλια ──
    if (p.scheduledAt != null) {
      _isScheduled = true;
      _scheduledAt = p.scheduledAt;
    }
    if (p.persons != null && p.persons! > 0) _persons = p.persons!;
    if (p.luggage != null && p.luggage! >= 0) _luggage = p.luggage!;
    if (p.note != null && p.note!.isNotEmpty) _noteCtrl.text = p.note!;
    if (p.flightOrShip != null && p.flightOrShip!.isNotEmpty) {
      _flightShipCtrl.text = p.flightOrShip!;
    }
    if (p.vehicleType != null && p.vehicleType!.isNotEmpty) {
      _vehicleType = p.vehicleType!;
    }
    if (p.childSeatCount != null && p.childSeatCount! > 0) {
      _childSeatCount = p.childSeatCount!;
      _childSeatPriceCtrl.text = '0'; // baby seat με 0 τιμή
    }
    // Αν έχουμε και τα δύο σημεία → υπολόγισε απόσταση
    if (_fromPick != null && _toPick != null) {
      _recomputeRoute();
    }
  }

  // Τελευταίες ρυθμίσεις: αποθηκεύονται μετά τη δημιουργία δουλειάς
  String? _pendingGroupId;
  String? _pendingSourceId;

  Future<void> _restoreLastSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw   = prefs.getString(_kLastJobSettings);
      if (raw == null) return;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      _pendingGroupId  = data['groupId']  as String?;
      _pendingSourceId = data['sourceId'] as String?;
      if (!mounted) return;
      setState(() {
        if (_pendingGroupId != null) _selectedGroupId = _pendingGroupId;
      });
    } catch (_) {}
  }

  Future<void> _saveLastSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kLastJobSettings, jsonEncode({
        'groupId':  _selectedGroupId,
        'sourceId': _selectedSource?.id,
      }));
    } catch (_) {}
  }

  @override
  void dispose() {
    for (final b in _extraBookings) { b.dispose(); }
    _priceCtrl.dispose();
    _noteCtrl.dispose();
    _childSeatPriceCtrl.dispose();
    _commissionCtrl.dispose();
    _appCommissionCtrl.dispose();
    _clientNameCtrl.dispose();
    _clientPhoneCtrl.dispose();
    _clientEmailCtrl.dispose();
    _flightShipCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSources() async {
    // Σιγουρέψου ότι υπάρχει η πηγή Standard Rate
    await JobService.ensureStandardRate();

    final snap = await FirebaseFirestore.instance
        .collection('sources')
        .orderBy('name')
        .get();
    var all = snap.docs.map((d) => JobSource.fromDoc(d)).toList();

    // Master βλέπει όλες· admin βλέπει δικές του + global (Standard Rate)
    if (!widget.isMaster) {
      all = all
          .where((s) => s.createdBy == widget.adminUid || s.isGlobal)
          .toList();
    }
    // Global πηγές (Standard Rate) πρώτες
    all.sort((a, b) {
      if (a.isGlobal && !b.isGlobal) return -1;
      if (!a.isGlobal && b.isGlobal) return 1;
      return a.name.compareTo(b.name);
    });

    if (!mounted) return;
    setState(() {
      _sources = all;
      // Default επιλογή πηγής
      if (_selectedSource == null && all.isNotEmpty) {
        // Αν επεξεργαζόμαστε δουλειά → βρες την αρχική της πηγή
        final editSourceId =
            widget.editJob?.sourceId ?? widget.editSavedJob?.sourceId;
        if (editSourceId != null && editSourceId.isNotEmpty) {
          final match = all.where((s) => s.id == editSourceId).toList();
          if (match.isNotEmpty) _selectedSource = match.first;
        }
        // Νέα δουλειά → δοκίμασε την τελευταία πηγή που χρησιμοποιήθηκε
        if (_selectedSource == null && _pendingSourceId != null) {
          final match = all.where((s) => s.id == _pendingSourceId).toList();
          if (match.isNotEmpty) _selectedSource = match.first;
        }
        // Αλλιώς → Standard Rate (global) ή η πρώτη διαθέσιμη
        _selectedSource ??= all.firstWhere(
          (s) => s.isGlobal,
          orElse: () => all.first,
        );
        // Προ-συμπλήρωσε προμήθειες (μόνο για νέα δουλειά, όχι edit/draft)
        if (widget.editJob == null && widget.editSavedJob == null) {
          _recomputeCommissions();
        }
      }
    });
  }

  Future<void> _loadClients() async {
    // Master βλέπει όλους, admin μόνο δικούς του (& μόνο του tenant του).
    // Εξαίρεση: αν ο master έχει ενεργοποιήσει την προσωπική προτίμηση «να
    // μη βλέπω πελάτες άλλων» (masterHideOtherClients), φιλτράρει σαν admin.
    bool hideOthers = false;
    if (widget.isMaster) {
      try {
        final doc = await FirebaseFirestore.instance
            .collection('presence').doc(widget.adminUid).get();
        hideOthers = doc.data()?['masterHideOtherClients'] == true;
      } catch (_) {}
    }
    final effectiveIsMaster = widget.isMaster && !hideOthers;
    final tid = effectiveIsMaster ? null : await JobService.myTenantId();
    final list = await JobService.clientsOnce(
        createdBy: effectiveIsMaster ? null : widget.adminUid,
        tenantId:  tid);
    if (!mounted) return;
    setState(() => _clients = list);
  }

  /// Όταν επιλεγεί πελάτης στο πεδίο "Από": γεμίζει η διεύθυνση-βάση και, αν
  /// ο πελάτης έχει αποθηκευμένες διαδρομές, εμφανίζεται επιλογή προορισμού.
  Future<void> _onClientPicked(Client c) async {
    _mainStopZoneName = c.shuttleZoneName;
    _mainStopOrder    = c.shuttleOrder;
    // Βάλε το "Από" = διεύθυνση-βάση πελάτη
    setState(() {
      _fromPick = PlacePick(
          description: c.fromName.isNotEmpty ? c.fromName : c.name,
          lat: c.fromLat, lng: c.fromLng);
      _clientNameCtrl.text = c.name;
      if ((c.phone ?? '').isNotEmpty &&
          _clientPhoneCtrl.text.trim().isEmpty) {
        _clientPhoneCtrl.text = c.phone!;
      }
    });

    // Ειδοποίηση αν αυτός ο πελάτης έχει δικό του Shuttle Bus — να το ξέρει
    // ο admin που φτιάχνει τη δουλειά (π.χ. να μη στείλει ταξί άδικα).
    if (c.hasShuttleBus && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Row(children: const [
          Icon(Icons.directions_bus_filled_rounded, color: Colors.white, size: 18),
          SizedBox(width: 8),
          Expanded(child: Text('Αυτός ο πελάτης διαθέτει δικό του Shuttle.')),
        ]),
        backgroundColor: Colors.amber.shade900,
        duration: const Duration(seconds: 3),
      ));
    }

    if (c.routes.isEmpty) {
      _recomputeRoute();
      return;
    }

    // Διάλεξε αποθηκευμένη διαδρομή (ή κράτα μόνο το "Από")
    final route = await showModalBottomSheet<ClientRoute?>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _ClientRoutePicker(client: c),
    );

    if (route == null) {
      // Ο χρήστης έκλεισε ή διάλεξε "μόνο Από" — άφησε το Προς ελεύθερο
      _recomputeRoute();
      return;
    }

    setState(() {
      _toPick = PlacePick(
          description: route.toName, lat: route.toLat, lng: route.toLng);
      if (route.price > 0) {
        _priceCtrl.text = route.price.toStringAsFixed(2);
      }
      // Πηγή
      if (route.sourceId != null && route.sourceId!.isNotEmpty) {
        final match =
            _sources.where((s) => s.id == route.sourceId).toList();
        if (match.isNotEmpty) {
          _selectedSource      = match.first;
          _commissionEdited    = false;
          _appCommissionEdited = false;
        }
      }
    });
    _recomputeCommissions();
    _recomputeRoute();
    setState(() {});
  }

  Future<void> _loadGroups() async {
    final fs = FirebaseFirestore.instance;
    final results = await Future.wait([
      fs.collection('groups').orderBy('name').get(),
      fs.collection('presence')
          .where('isApproved', isEqualTo: true).get(),
    ]);
    if (!mounted) return;
    setState(() {
      _groups = results[0].docs
          .map((d) => {'id': d.id, 'name': d.data()['name'] ?? ''})
          .toList();
      _allDrivers = results[1].docs.map((d) {
        final data = d.data();
        final name =
            '${data['displayName'] ?? ''} ${data['lastName'] ?? ''}'.trim();
        return {'uid': d.id, 'name': name, 'phone': data['phone'] ?? ''};
      }).where((m) => (m['name'] as String).isNotEmpty).toList()
        ..sort((a, b) =>
            (a['name'] as String).compareTo(b['name'] as String));
    });
  }

  // Chip εναλλαγής τρόπου αποστολής
  Widget _recipientModeChip({
    required String label, required IconData icon,
    required bool selected, required VoidCallback onTap,
  }) =>
      InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          decoration: BoxDecoration(
            color: selected ? Colors.amber.shade100 : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: selected ? Colors.amber : Colors.grey.shade300,
                width: selected ? 2 : 1),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 22,
                color: selected ? Colors.amber.shade800 : Colors.grey),
            const SizedBox(height: 4),
            Text(label,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: selected
                        ? Colors.amber.shade900 : Colors.grey[700])),
          ]),
        ),
      );

  // Picker ΠΟΛΛΑΠΛΩΝ οδηγών — αναζήτηση + checkboxes
  Future<void> _pickSpecificDrivers() async {
    String query = '';
    final tempSel = Set<String>.from(_targetUids);
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          final filtered = _allDrivers.where((d) {
            if (query.isEmpty) return true;
            final q = query.toLowerCase();
            return (d['name'] as String).toLowerCase().contains(q) ||
                   (d['phone'] as String).toLowerCase().contains(q);
          }).toList();
          return Padding(
            padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom),
            child: SizedBox(
              height: MediaQuery.of(ctx).size.height * 0.75,
              child: Column(children: [
                const SizedBox(height: 12),
                const SheetHandle(bottomMargin: 0),
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Text('Επιλογή Οδηγών (${tempSel.length})',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: TextField(
                    decoration: InputDecoration(
                      hintText:   'Αναζήτηση ονόματος ή τηλεφώνου...',
                      prefixIcon: const Icon(Icons.search_rounded),
                      filled:     true,
                      fillColor:  Colors.grey.shade100,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onChanged: (v) => setS(() => query = v),
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: filtered.isEmpty
                      ? const Center(child: Text('Κανένας οδηγός',
                          style: TextStyle(color: Colors.grey)))
                      : ListView.builder(
                          itemCount: filtered.length,
                          itemBuilder: (_, i) {
                            final d   = filtered[i];
                            final uid = d['uid'] as String;
                            final sel = tempSel.contains(uid);
                            return CheckboxListTile(
                              value: sel,
                              activeColor: Colors.amber,
                              secondary: CircleAvatar(
                                backgroundColor: Colors.amber.shade100,
                                child: Text(
                                  (d['name'] as String).isNotEmpty
                                      ? (d['name'] as String)[0]
                                      : '?',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Colors.black),
                                ),
                              ),
                              title: Text(d['name'] as String),
                              subtitle: (d['phone'] as String).isNotEmpty
                                  ? Text(d['phone'] as String)
                                  : null,
                              onChanged: (v) => setS(() {
                                if (v == true) {
                                  tempSel.add(uid);
                                } else {
                                  tempSel.remove(uid);
                                }
                              }),
                            );
                          },
                        ),
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: tempSel.isNotEmpty
                              ? Colors.amber : Colors.grey.shade300,
                          foregroundColor: Colors.black,
                        ),
                        icon:  const Icon(Icons.check_rounded),
                        label: Text(tempSel.isEmpty
                            ? 'Επίλεξε οδηγούς'
                            : 'Επιβεβαίωση (${tempSel.length})'),
                        onPressed: tempSel.isEmpty
                            ? null
                            : () => Navigator.pop(ctx, true),
                      ),
                    ),
                  ),
                ),
              ]),
            ),
          );
        },
      ),
    );
    if (changed == true && mounted) {
      setState(() {
        _targetUids
          ..clear()
          ..addAll(tempSel);
        _targetNames.clear();
        for (final uid in tempSel) {
          final d = _allDrivers.firstWhere(
            (e) => e['uid'] == uid,
            orElse: () => <String, dynamic>{'name': ''},
          );
          _targetNames[uid] = (d['name'] as String?) ?? '';
        }
        // ομάδα + συγκεκριμένοι οδηγοί αμοιβαία αποκλειόμενα
        if (_targetUids.isNotEmpty) {
          _selectedGroupId   = null;
        }
      });
    }
  }

  void _prefill(Job job) {
    _fromPick = PlacePick(
        description: job.from, lat: job.fromLat, lng: job.fromLng);
    _toPick = PlacePick(
        description: job.to, lat: job.toLat, lng: job.toLng);
    _routeKm       = job.routeKm;
    _routePolyline = job.routePolyline;
    // Η τιμή που εμφανίζεται είναι η ΒΑΣΙΚΗ (χωρίς παιδικά καθίσματα)
    final childTotal  = job.childSeatCount * job.childSeatPrice;
    final basePrice   = job.price - childTotal;
    _priceCtrl.text   = basePrice.toStringAsFixed(2);
    _noteCtrl.text    = job.note ?? '';
    _persons          = job.persons;
    _luggage          = job.luggage;
    _childSeatCount   = job.childSeatCount;
    if (job.childSeatPrice > 0) {
      _childSeatPriceCtrl.text = job.childSeatPrice.toStringAsFixed(2);
    }
    _withReturn       = job.withReturn;
    _withStops        = job.withStops;
    _vehicleType      = job.vehicleType;
    _timeoutMins      = job.timeoutMins;
    _selectedGroupId  = job.groupId;
    _targetUids
      ..clear()
      ..addAll(job.targetUids);
    _targetNames.clear();
    for (var i = 0; i < job.targetUids.length; i++) {
      _targetNames[job.targetUids[i]] =
          i < job.targetNames.length ? job.targetNames[i] : '';
    }
    _isScheduled      = job.scheduledAt != null;
    _scheduledAt      = job.scheduledAt;
    _availableOnly    = job.availableOnly;
    _exclusiveTarget  = job.exclusiveTarget;
    _clientNameCtrl.text  = job.clientName   ?? '';
    _clientPhoneCtrl.text = job.clientPhone  ?? '';
    _clientEmailCtrl.text = job.clientEmail  ?? '';
    _flightShipCtrl.text  = job.flightOrShip ?? '';
    if (job.commission != 0) {
      _commissionCtrl.text = job.commission.toStringAsFixed(2);
      _commissionEdited = true;
    }
    if (job.appCommission > 0) {
      _appCommissionCtrl.text = job.appCommission.toStringAsFixed(2);
      _appCommissionEdited = true;
    }
  }

  // ─── Σημεία & Διαδρομή ────────────────────────────────────────────────────

  void _swapFromTo() {
    setState(() {
      final tmp = _fromPick;
      _fromPick = _toPick;
      _toPick   = tmp;
    });
    _recomputeRoute();
  }

  void _onFromPicked(PlacePick p) {
    setState(() => _fromPick = p);
    _recomputeRoute();
  }

  void _onToPicked(PlacePick p) {
    setState(() => _toPick = p);
    _recomputeRoute();
  }

  /// Όταν επιλεγεί ΠΕΛΑΤΗΣ στο πεδίο «Προς»: ο προορισμός γίνεται η
  /// διεύθυνση-βάση του πελάτη (π.χ. δρομολόγιο αεροδρόμιο → κατάλυμα).
  /// ΔΕΝ αλλάζει όνομα/τηλέφωνο πελάτη της δουλειάς — μόνο ο προορισμός.
  void _onClientPickedAsDestination(Client c) {
    _onToPicked(PlacePick(
        description: c.fromName.isNotEmpty ? c.fromName : c.name,
        lat: c.fromLat, lng: c.fromLng));
  }

  /// Υπολογίζει χιλιόμετρα + polyline όταν υπάρχουν 2 σημεία με συντεταγμένες.
  /// Πρώτα δοκιμάζει Directions (διαδρομή οδήγησης) — αν αποτύχει, ευθεία.
  Future<void> _recomputeRoute() async {
    final f = _fromPick, t = _toPick;
    if (f == null || t == null || !f.hasCoords || !t.hasCoords) {
      setState(() {
        _routeKm       = null;
        _routePolyline = null;
        _routeLoading  = false;
        _routeIsAir    = false;
      });
      return;
    }

    final reqId = ++_routeReqId;
    setState(() => _routeLoading = true);

    // Άμεσο fallback: ευθεία γραμμή (Haversine) — δείχνεται αμέσως.
    final airKm = haversineKm(f.lat!, f.lng!, t.lat!, t.lng!);

    RouteResult? route;
    try {
      route = await PlacesService.route(
        fromLat: f.lat!, fromLng: f.lng!,
        toLat:   t.lat!, toLng:   t.lng!,
      );
    } catch (_) {
      route = null;
    }

    if (!mounted || reqId != _routeReqId) return; // ακυρώθηκε από νεότερο
    setState(() {
      _routeLoading  = false;
      if (route != null) {
        _routeKm       = route.km;
        _routePolyline = route.polyline;
        _routeIsAir    = false;
      } else {
        _routeKm       = airKm;
        _routePolyline = null;
        _routeIsAir    = true;
      }
    });
  }

  // ─── Save ─────────────────────────────────────────────────────────────────

  /// Επικυρώνει & χτίζει το Job από τη φόρμα. Επιστρέφει null αν invalid
  /// (και δείχνει error). Δεν κάνει writes.
  Job? _buildJob() {
    final fromText = (_fromPick?.description ?? '').trim();
    final toText   = (_toPick?.description   ?? '').trim();
    if (fromText.isEmpty || toText.isEmpty) {
      _showError('Συμπλήρωσε Από και Προς');
      return null;
    }
    final basePrice = double.tryParse(_priceCtrl.text.trim());
    if (basePrice == null || basePrice <= 0) {
      _showError('Συμπλήρωσε έγκυρη τιμή');
      return null;
    }
    // Συνολική τιμή = τιμή διαδρομής + παιδικά καθίσματα
    final price = basePrice + _childSeatTotal;

    final comm    = _commission;
    final appComm = _appCommission;
    final parts   = <String>[];
    if (_selectedSource != null && comm != 0) {
      // Αρνητικό γιαούρτι = δίνεις στον οδηγό (το δείχνουμε με +).
      final sign = comm < 0 ? '+' : '-';
      final tag  = _isNight ? ' (βραδ.)' : '';
      parts.add('${_selectedSource!.name}$tag $sign${comm.abs().toStringAsFixed(2)}€');
    }
    if (_selectedSource != null && appComm > 0) parts.add('App -${appComm.toStringAsFixed(2)}€');
    final label = parts.join(' / ');

    return Job(
      id:               widget.editJob?.id ?? '',
      from:             fromText,
      to:               toText,
      fromLat:          _fromPick?.lat,
      fromLng:          _fromPick?.lng,
      toLat:            _toPick?.lat,
      toLng:            _toPick?.lng,
      routeKm:          _routeKm,
      routePolyline:    _routePolyline,
      price:            price,
      commission:       comm,
      appCommission:    appComm,
      commissionLabel:  label,
      persons:          _persons,
      luggage:          _luggage,
      childSeat:        _childSeatCount > 0,
      childSeatCount:   _childSeatCount,
      childSeatPrice:   double.tryParse(
          _childSeatPriceCtrl.text.trim().replaceAll(',', '.')) ?? 0,
      withReturn:       _withReturn,
      withStops:        _withStops,
      vehicleType:      _vehicleType,
      status:           JobStatus.open,
      // Ιδιοκτησία: αν επεξεργαζόμαστε ξένη δουλειά, ΔΙΑΤΗΡΟΥΜΕ τον ιδιοκτήτη.
      createdBy:        widget.isForeignOwned
          ? widget.ownerOverrideUid!
          : widget.adminUid,
      createdByName:    widget.isForeignOwned
          ? (widget.ownerOverrideName ?? '')
          : widget.adminName,
      note:             _noteCtrl.text.trim().isNotEmpty ? _noteCtrl.text.trim() : null,
      clientName:       _clientNameCtrl.text.trim().isNotEmpty ? _clientNameCtrl.text.trim() : null,
      clientPhone:      _clientPhoneCtrl.text.trim().isNotEmpty ? _clientPhoneCtrl.text.trim() : null,
      clientEmail:      _clientEmailCtrl.text.trim().isNotEmpty ? _clientEmailCtrl.text.trim() : null,
      flightOrShip:     _flightShipCtrl.text.trim().isNotEmpty ? _flightShipCtrl.text.trim() : null,
      isReturn:         widget.editJob?.isReturn ?? widget.editSavedJob?.isReturn ?? false,
      availableOnly:    _availableOnly,
      exclusiveTarget:  _exclusiveTarget,
      sourceId:         _selectedSource?.id,
      sourceName:       _selectedSource?.name,
      scheduledAt:      _isScheduled ? _scheduledAt : null,
      createdAt:        DateTime.now(),
      groupId:          _targetUids.isNotEmpty ? null : _selectedGroupId,
      targetUids:       _targetUids.toList(),
      targetNames:      _targetUids
          .map((u) => _targetNames[u] ?? '')
          .toList(),
      timeoutMins:      _timeoutMins,
      // ── Προπληρωμένο ─────────────────────────────────────────────────
      // Αν η δουλειά που επεξεργαζόμαστε έχει ήδη ΠΡΑΓΜΑΤΙΚΗ πληρωμή Viva
      // (ήρθε από την online φόρμα), ΔΙΑΤΗΡΟΥΜΕ αυτά τα στοιχεία όπως είναι
      // — το χειροκίνητο toggle δεν μπορεί να τα σβήσει/αλλάξει κατά λάθος.
      // Αλλιώς, εφαρμόζουμε το χειροκίνητο toggle του admin/master.
      depositPaid:      widget.editJob?.vivaOrderCode != null
          ? widget.editJob!.depositPaid
          : _fullyPaidManual,
      depositAmount:    widget.editJob?.vivaOrderCode != null
          ? widget.editJob!.depositAmount
          : (_fullyPaidManual ? price : 0),
      fullyPaid:        widget.editJob?.vivaOrderCode != null
          ? widget.editJob!.fullyPaid
          : _fullyPaidManual,
      vivaOrderCode:    widget.editJob?.vivaOrderCode,
      // Read-only, ΠΟΤΕ δεν αλλάζει χειροκίνητα — απλά διατηρείται.
      bookingNumber:    widget.editJob?.bookingNumber ?? widget.editSavedJob?.bookingNumber,
    );
  }

  /// ΑΠΟΘΗΚΕΥΣΗ ως προσχέδιο (saved_jobs) — δεν στέλνεται σε κανέναν.
  Future<void> _saveDraft() async {
    if (_isSaving) return;

    final job = _buildJob();
    if (job == null) return;

    setState(() => _isSaving = true);
    try {
      // Ομαδική (Shuttle/Λεωφορείο με 2+ κρατήσεις) → container στις Αποθηκευμένες
      if (await _saveGroupIfNeeded(job)) return;
      if (widget.isSavedDraft) {
        if (widget.isForeignOwned) {
          await SavedJobService.updateAsEditor(
            widget.editSavedJobId!, job,
            editorUid: widget.adminUid, editorName: widget.adminName,
          );
        } else {
          await SavedJobService.update(widget.editSavedJobId!, job);
        }
      } else {
        await SavedJobService.save(job,
            ownerUid: widget.adminUid, ownerName: widget.adminName,
            calendarEventId: widget.calendarEventId);
      }
      // Ενημέρωση καλούντος (π.χ. ημερολόγιο → σήμα «Αποθηκεύτηκε»)
      if (widget.onSavedDraft != null) {
        try { await widget.onSavedDraft!(); } catch (_) {}
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('💾 Αποθηκεύτηκε στις «Αποθηκευμένες»'),
            backgroundColor: Color(0xFF1565C0),
            duration: Duration(seconds: 2),
          ),
        );
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        _showError('Σφάλμα αποθήκευσης: $e');
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _save() async {
    // Re-entrancy guard: εμποδίζει διπλή αποστολή από γρήγορο διπλό tap
    // ή από ταυτόχρονο πάτημα και των δύο κουμπιών «Αποστολή».
    if (_isSaving) return;

    final job = _buildJob();
    if (job == null) return;

    setState(() => _isSaving = true);

    try {
      // Ομαδική (Shuttle/Λεωφορείο με 2+ κρατήσεις) → πρώτα αποθηκεύεται ως
      // ενωμένη στις Αποθηκευμένες (η αποστολή γίνεται από εκεί).
      if (await _saveGroupIfNeeded(job)) return;
      // Αν επεξεργαζόμασταν ΑΠΟΘΗΚΕΥΜΕΝΗ δουλειά και πατήθηκε «Αποστολή» →
      // στείλ' την κανονικά ΚΑΙ σβήσε το προσχέδιο.
      if (widget.isSavedDraft) {
        await JobService.createJob(job);
        try { await SavedJobService.delete(widget.editSavedJobId!); } catch (_) {}
        if (widget.onCreated != null) {
          try { await widget.onCreated!(); } catch (_) {}
        }
        if (mounted) Navigator.of(context).pop(true);
        return;
      }

      if (widget.editJob == null) {
        await JobService.createJob(job);
        // Αποθήκευση τελευταίων ρυθμίσεων (ομάδα + πηγή)
        await _saveLastSettings();
        // Ενημέρωση καλούντος (π.χ. ημερολόγιο → σήμανση event ως μετατρεμμένο)
        if (widget.onCreated != null) {
          try { await widget.onCreated!(); } catch (_) {}
        }
      } else {
        // Resend δουλειάς που δεν έχει ανατεθεί
        final isUntaken = widget.editJob!.takenBy == null;
        final resendMap = job.toMap();
        if (isUntaken) {
          // Ξανα-βγαίνει ΑΠΟ ΤΗΝ ΑΡΧΗ με τα δεδομένα της φόρμας —
          // σαν νέα δουλειά, σεβόμενη ομάδα/οδηγό/διαθέσιμους.
          resendMap['createdAt']       = FieldValue.serverTimestamp();
          resendMap['stageStartedAt']  = FieldValue.serverTimestamp();
          resendMap['escalationStage'] = 0;     // ξεκινά από το 1ο στάδιο
          resendMap['stopped']         = false; // ξεμπλοκάρει αν ήταν σταματημένη
          resendMap['status']          = JobStatus.open.name;
          resendMap['takenBy']         = null;
          resendMap['takenByName']     = null;
          resendMap['takenAt']         = null;
        }
        await JobService.updateJob(widget.editJob!.id, resendMap);
        if (mounted && isUntaken) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('🔔 Η δουλειά στάλθηκε ξανά '
                  'από την αρχή (βάσει επιλογών φόρμας)'),
              backgroundColor: Color(0xFF1E8E3E),
              duration: Duration(seconds: 3),
            ),
          );
        }
      }

      if (mounted) {
        Navigator.of(context).removeRoute(ModalRoute.of(context)!);
      }
    } catch (e) {
      if (mounted) {
        _showError('Σφάλμα: $e');
        setState(() => _isSaving = false);
      }
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red),
    );
  }

  // ─── Date/Time picker ─────────────────────────────────────────────────────

  Future<void> _pickScheduledTime() async {
    final now  = DateTime.now();
    final date = await showDatePicker(
      context:     context,
      initialDate: _scheduledAt ?? now,
      firstDate:   now,
      lastDate:    now.add(const Duration(days: 30)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context:     context,
      initialTime: TimeOfDay.fromDateTime(_scheduledAt ?? now),
    );
    if (time == null || !mounted) return;
    setState(() {
      _scheduledAt = DateTime(date.year, date.month, date.day, time.hour, time.minute);
      _recomputeNightAuto();
      _recomputeCommissions();
    });
  }

  /// Υπολογίζει αν η δουλειά πέφτει στο βραδινό ωράριο (23:30–05:30):
  ///  • Ραντεβού → η ώρα ραντεβού (_scheduledAt)
  ///  • Άμεση    → η τρέχουσα ώρα (τώρα)
  /// Αλλάζει ΜΟΝΟ το _nightAuto· το χειροκίνητο override μένει ως έχει.
  void _recomputeNightAuto() {
    final ref = (_isScheduled && _scheduledAt != null)
        ? _scheduledAt!
        : DateTime.now();
    _nightAuto = isNightYogurt(ref);
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F8F8),
      appBar: AppBar(
        title: Text(
            widget.isSavedDraft
                ? 'Αποθηκευμένη'
                : (widget.editJob != null
                    ? 'Επεξεργασία'
                    : (widget.copyFromJob != null
                        ? 'Νέα Δουλειά (Αντίγραφο)'
                        : 'Νέα Δουλειά')),
            style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.amber,
        foregroundColor: Colors.black,
        elevation: 0,
        actions: [
          if (_isSaving)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(width: 20, height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black)),
            )
          else ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              child: AppButtonTonal(
                label: 'Αποθήκευση',
                icon: Icons.bookmark_add_rounded,
                onPressed: _isSaving ? null : _saveDraft,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 8, 8, 8),
              child: AppButton(
                label: 'Αποστολή',
                icon: Icons.send_rounded,
                color: Colors.black,
                fg: Colors.amber,
                onPressed: _isSaving ? null : _save,
              ),
            ),
          ],
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [

          // ── Booking ID — read-only, ΠΟΤΕ δεν αλλάζει χειροκίνητα. Αν η
          // δουλειά ήρθε από δημόσια φόρμα, δείχνει τον αριθμό· αν είναι
          // δική σου χειροκίνητη δουλειά, μένει κενό/γκρι.
          Builder(builder: (_) {
            final bn = widget.editJob?.bookingNumber ?? widget.editSavedJob?.bookingNumber;
            return Container(
              margin: const EdgeInsets.only(bottom: 14),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.grey.shade200,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.grey.shade400),
              ),
              child: Row(children: [
                Icon(Icons.confirmation_number_outlined,
                    size: 18, color: Colors.grey.shade600),
                const SizedBox(width: 10),
                Text('Booking ID',
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600,
                        color: Colors.grey.shade700)),
                const Spacer(),
                Text(bn != null ? '#$bn' : '—',
                    style: TextStyle(
                        fontSize: 14, fontWeight: FontWeight.bold,
                        color: bn != null ? Colors.grey.shade900 : Colors.grey.shade500)),
              ]),
            );
          }),

          // ── Από / Προς (Google Maps) ───────────────────────────────────────
          _section('Διαδρομή'),
          PlaceField(
            label:    'Από *',
            icon:     Icons.trip_origin_rounded,
            value:    _fromPick,
            onPicked: _onFromPicked,
            clients:  _clients,
            onClientPicked: _onClientPicked,
          ),
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Material(
                color: Colors.amber.shade50,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: _swapFromTo,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Icon(Icons.swap_vert_rounded,
                        color: Colors.amber.shade800),
                  ),
                ),
              ),
            ),
          ),
          PlaceField(
            label:    'Προς *',
            icon:     Icons.place_rounded,
            value:    _toPick,
            onPicked: _onToPicked,
            // Πελάτες ΚΑΙ στο «Προς» — ίδια λίστα με το «Από» (σέβεται το
            // «μάτι» masterHideOtherClients μέσω του _loadClients).
            clients:  _clients,
            onClientPicked: _onClientPickedAsDestination,
          ),
          // Απόσταση διαδρομής
          if (_routeLoading || _routeKm != null) ...[
            const SizedBox(height: 10),
            _routeInfoBox(),
          ],

          // ── Τιμή & Πηγή ────────────────────────────────────────────────────
          const SizedBox(height: 20),
          _section('Τιμή & Πηγή'),
          Row(children: [
            Expanded(
              child: _field(
                controller:  _priceCtrl,
                label:       'Τιμή (€) *',
                icon:        Icons.euro_rounded,
                isNumber:    true,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<JobSource?>(
                initialValue: _selectedSource,
                decoration: InputDecoration(
                  labelText:   'Πηγή / Γιαούρτι',
                  prefixIcon:  const Icon(Icons.handshake_rounded),
                  filled:      true,
                  fillColor:   Colors.white,
                  border:      OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
                items: [
                  ..._sources.map((s) => DropdownMenuItem(
                    value: s,
                    child: Text(s.name, overflow: TextOverflow.ellipsis),
                  )),
                ],
                onChanged: (v) {
                  setState(() {
                    _selectedSource       = v;
                    _commissionEdited     = false;
                    _appCommissionEdited  = false;
                    if (v != null) {
                      final price = _commissionablePrice;
                      final c    = v.calculateFor(price, _isNight);
                      final ac   = v.calculateApp(price);
                      _commissionCtrl.text    = c  != 0 ? c.toStringAsFixed(2)  : '';
                      _appCommissionCtrl.text = ac > 0 ? ac.toStringAsFixed(2) : '';
                    } else {
                      _commissionCtrl.text    = '';
                      _appCommissionCtrl.text = '';
                    }
                  });
                },
              ),
            ),
          ]),

          // ── Προπληρωμένο (χειροκίνητο) ──────────────────────────────────
          // Ο πελάτης έχει ήδη πληρώσει ΟΛΟΚΛΗΡΗ την τιμή με άλλο τρόπο
          // (μετρητά στον master, έμβασμα, κλπ.) — ΟΧΙ μέσω της online
          // φόρμας. Ο οδηγός δεν εισπράττει τίποτα από τον πελάτη· το κέρδος
          // του οδηγού το χρωστάει αυτός που έβγαλε τη δουλειά (master/admin).
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(
              color: _fullyPaidManual
                  ? const Color(0xFFD97757).withValues(alpha: 0.10)
                  : Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _fullyPaidManual
                    ? const Color(0xFFD97757)
                    : Colors.grey.shade300,
              ),
            ),
            child: SwitchListTile(
              title: Row(children: [
                const Icon(Icons.warning_amber_rounded, size: 18, color: Color(0xFFD97757)),
                const SizedBox(width: 10),
                const Text('Προπληρωμένο (ολόκληρο ποσό)'),
              ]),
              subtitle: Text(
                _fullyPaidManual
                    ? 'Ο οδηγός δεν θα εισπράξει τίποτα — εσύ του χρωστάς το κέρδος του.'
                    : 'Ενεργοποίησε αν ο πελάτης έχει ήδη πληρώσει ολόκληρη την τιμή με άλλο τρόπο (μετρητά, έμβασμα κλπ.), όχι μέσω online φόρμας.',
                style: const TextStyle(fontSize: 12),
              ),
              value: _fullyPaidManual,
              activeThumbColor: const Color(0xFFD97757),
              onChanged: (v) => setState(() => _fullyPaidManual = v),
            ),
          ),

          // ── Επεξεργάσιμα πεδία προμηθειών ──────────────────────────────
          if (_selectedSource != null) ...[
            const SizedBox(height: 12),
            // Προμήθεια πηγής
            Row(children: [
              Expanded(
                child: TextFormField(
                  controller: _commissionCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true, signed: true),
                  onChanged: (_) => setState(() => _commissionEdited = true),
                  decoration: InputDecoration(
                    labelText:  _isNight ? 'Βραδινό Γιαούρτι (€)' : 'Γιαούρτι (€)',
                    prefixIcon: Icon(
                        _isNight ? Icons.nightlight_round : Icons.handshake_rounded,
                        color: _isNight ? Colors.indigo : Colors.orange),
                    filled:     true,
                    fillColor:  _isNight
                        ? Colors.indigo.shade50
                        : Colors.orange.shade50,
                    border:     OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              // Προμήθεια App — κλειδωμένη για admin (μόνο master μπορεί να αλλάξει)
              Expanded(
                child: TextFormField(
                  controller: _appCommissionCtrl,
                  readOnly: !widget.isMaster,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setState(() => _appCommissionEdited = true),
                  decoration: InputDecoration(
                    labelText:  widget.isMaster
                        ? 'Προμήθεια App (€)'
                        : 'Προμήθεια App (κλειδωμένη)',
                    prefixIcon: Icon(widget.isMaster
                        ? Icons.phone_iphone_rounded
                        : Icons.lock_outline_rounded,
                        color: widget.isMaster ? Colors.blue : Colors.grey),
                    filled:     true,
                    fillColor:  widget.isMaster
                        ? Colors.blue.shade50
                        : Colors.grey.shade100,
                    border:     OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ]),
            // ── Διακόπτης βραδινού (auto 23:30–05:30, με override) ──
            const SizedBox(height: 10),
            Row(children: [
              Icon(_isNight ? Icons.nightlight_round : Icons.wb_sunny_rounded,
                  size: 18,
                  color: _isNight ? Colors.indigo : Colors.amber.shade700),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _isNight ? 'Βραδινή τιμή (23:30–05:30)' : 'Ημερήσια τιμή',
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 13.5),
                ),
              ),
              if (_nightOverride != null)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: TextButton(
                    onPressed: () => setState(() {
                      _nightOverride = null;
                      _commissionEdited = false;
                      _recomputeCommissions();
                    }),
                    child: const Text('Auto', style: TextStyle(fontSize: 12)),
                  ),
                ),
              Switch(
                value: _isNight,
                activeTrackColor: Colors.indigo,
                onChanged: (v) => setState(() {
                  _nightOverride = v;
                  _commissionEdited = false;
                  _recomputeCommissions();
                }),
              ),
            ]),
          ],

          // Preview τιμής
          if ((double.tryParse(_priceCtrl.text) ?? 0) > 0) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color:        Colors.amber.shade50,
                borderRadius: BorderRadius.circular(10),
                border:       Border.all(color: Colors.amber.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_commission > 0)
                    _previewRow('Γιαούρτι:', '-${_commission.toStringAsFixed(2)}€',
                        Colors.orange),
                  if (_appCommission > 0)
                    _previewRow('App:', '-${_appCommission.toStringAsFixed(2)}€',
                        Colors.blue),
                  _previewRow(
                      'Καθαρό κέρδος οδηγού:',
                      '${_driverEarning.toStringAsFixed(2)}€',
                      const Color(0xFF1E8E3E),
                      bold: true),
                ],
              ),
            ),
          ],

          // ── Επιβάτες & Αποσκευές ──────────────────────────────────────────
          const SizedBox(height: 20),
          _section('Επιβάτες & Αποσκευές'),
          Row(children: [
            Expanded(child: _stepper(
              label: 'Άτομα',
              icon:  Icons.person_rounded,
              value: _persons,
              min:   1, max: 8,
              onChanged: (v) => setState(() => _persons = v),
            )),
            const SizedBox(width: 12),
            Expanded(child: _stepper(
              label: 'Βαλίτσες',
              icon:  Icons.luggage_rounded,
              value: _luggage,
              min:   0, max: 10,
              onChanged: (v) => setState(() => _luggage = v),
            )),
          ]),
          const SizedBox(height: 10),
          // Παιδικά καθίσματα: ποσότητα + τιμή ανά κάθισμα
          Row(children: [
            Expanded(child: _stepper(
              label: 'Παιδικά καθίσματα',
              icon:  Icons.child_care_rounded,
              value: _childSeatCount,
              min:   0, max: 5,
              onChanged: (v) {
                setState(() => _childSeatCount = v);
                _recomputeCommissions();
              },
            )),
            const SizedBox(width: 12),
            // Ίδιο πλαίσιο με το stepper δίπλα — συμμετρικό ύψος & δομή
            Expanded(child: _childSeatPriceBox()),
          ]),
          if (_childSeatCount > 0 && _childSeatTotal > 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '+ ${_childSeatTotal.toStringAsFixed(2)}€ '
                'για $_childSeatCount παιδικά καθίσματα '
                '(προστίθεται στην τιμή)',
                style: TextStyle(
                    fontSize: 12, color: Colors.teal.shade700,
                    fontWeight: FontWeight.w600),
              ),
            ),

          // ── Χαρακτηριστικά διαδρομής ───────────────────────────────────────
          const SizedBox(height: 20),
          _section('Χαρακτηριστικά Διαδρομής'),
          Row(children: [
            Expanded(child: _featureToggle(
              label:    'Με επιστροφή',
              icon:     Icons.swap_horiz_rounded,
              active:   _withReturn,
              color:    const Color(0xFF1565C0),
              onTap:    () => setState(() => _withReturn = !_withReturn),
            )),
            const SizedBox(width: 10),
            Expanded(child: _featureToggle(
              label:    'Με στάσεις',
              icon:     Icons.more_horiz_rounded,
              active:   _withStops,
              color:    const Color(0xFFAD1457),
              onTap:    () => setState(() => _withStops = !_withStops),
            )),
          ]),

          // ── Τύπος οχήματος ─────────────────────────────────────────────────
          const SizedBox(height: 20),
          _section('Τύπος Οχήματος'),
          Row(children: [
            _vehicleChip('any',  'Taxi / Van', Icons.directions_car_rounded),
            const SizedBox(width: 8),
            _vehicleChip('taxi', 'Taxi',       Icons.local_taxi_rounded),
            const SizedBox(width: 8),
            _vehicleChip('van',  'Van',        Icons.airport_shuttle_rounded),
          ]),
          // ── Ομαδική μεταφορά: Shuttle / Λεωφορείο ──────────────────────────
          const SizedBox(height: 8),
          Row(children: [
            _vehicleChip('shuttle', 'Shuttle',   Icons.directions_bus_rounded),
            const SizedBox(width: 8),
            _vehicleChip('bus',     'Λεωφορείο', Icons.directions_bus_filled_rounded),
          ]),
          if (_isGroupVehicle) ...[
            const SizedBox(height: 14),
            _section('Κρατήσεις ομαδικής μεταφοράς'),
            const Padding(
              padding: EdgeInsets.only(bottom: 6),
              child: Text(
                  'Η 1η κράτηση είναι τα πεδία της φόρμας (πελάτης, τηλέφωνο, '
                  'διεύθυνση). Πρόσθεσε εδώ τις επόμενες — κάθε μία με δικά '
                  'της στοιχεία, διεύθυνση και τιμή.',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
            ),
            // Κοινό σημείο: Προορισμός (μαζεύουμε από καταλύματα) ή Αφετηρία
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true,
                    label: Text('Κοινό: Προορισμός', style: TextStyle(fontSize: 12)),
                    icon: Icon(Icons.flag_rounded, size: 16)),
                ButtonSegment(value: false,
                    label: Text('Κοινό: Αφετηρία', style: TextStyle(fontSize: 12)),
                    icon: Icon(Icons.trip_origin_rounded, size: 16)),
              ],
              selected: {_groupSharedIsDestination},
              onSelectionChanged: (v) =>
                  setState(() => _groupSharedIsDestination = v.first),
            ),
            const SizedBox(height: 10),
            for (int i = 0; i < _extraBookings.length; i++)
              _extraBookingCard(i),
            OutlinedButton.icon(
              onPressed: () =>
                  setState(() => _extraBookings.add(_ExtraBooking())),
              icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
              label: Text('Προσθήκη κράτησης '
                  '(σύνολο: ${_extraBookings.length + 1})'),
            ),
          ],

          // ── Αποστολή σε... ────────────────────────────────────────────────
          const SizedBox(height: 20),
          _section('Αποστολή σε'),
          // Toggle: Ομάδα/Όλοι ή Συγκεκριμένοι Οδηγοί
          Row(children: [
            Expanded(child: _recipientModeChip(
              label:    'Ομάδα / Όλοι',
              icon:     Icons.groups_rounded,
              selected: _targetUids.isEmpty,
              onTap:    () => setState(() {
                _targetUids.clear();
                _targetNames.clear();
              }),
            )),
            const SizedBox(width: 8),
            Expanded(child: _recipientModeChip(
              label:    'Συγκεκριμένοι Οδηγοί',
              icon:     Icons.person_pin_rounded,
              selected: _targetUids.isNotEmpty,
              onTap:    _pickSpecificDrivers,
            )),
          ]),
          const SizedBox(height: 10),
          // Επιλεγμένοι οδηγοί
          if (_targetUids.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.blue.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Icon(Icons.person_pin_rounded, color: Colors.blue),
                    const SizedBox(width: 8),
                    Expanded(child: Text(
                      'Μόνο σε ${_targetUids.length} '
                      '${_targetUids.length == 1 ? "οδηγό" : "οδηγούς"}',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 13),
                    )),
                    AppButtonTonal(
                      label: 'Αλλαγή',
                      icon: Icons.edit_rounded,
                      onPressed: _pickSpecificDrivers,
                    ),
                  ]),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6, runSpacing: 6,
                    children: _targetUids.map((uid) {
                      final name = _targetNames[uid] ?? '';
                      return Chip(
                        label: Text(name.isNotEmpty ? name : '—',
                            style: const TextStyle(fontSize: 12)),
                        backgroundColor: Colors.white,
                        visualDensity: VisualDensity.compact,
                        onDeleted: () => setState(() {
                          _targetUids.remove(uid);
                          _targetNames.remove(uid);
                        }),
                      );
                    }).toList(),
                  ),
                ],
              ),
            )
          else if (_groups.isNotEmpty)
            DropdownButtonFormField<String?>(
              initialValue: _selectedGroupId,
              decoration: InputDecoration(
                labelText:  'Ομάδα',
                prefixIcon: const Icon(Icons.groups_rounded),
                filled:     true,
                fillColor:  Colors.white,
                border:     OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              items: [
                const DropdownMenuItem(value: null,
                    child: Text('Όλοι οι οδηγοί')),
                ..._groups.map((g) => DropdownMenuItem(
                  value: g['id'] as String,
                  child: Text(g['name'] as String),
                )),
              ],
              onChanged: (v) => setState(() {
                _selectedGroupId   = v;
              }),
            ),

          // ── Χρονοπρογραμματισμός ──────────────────────────────────────────
          const SizedBox(height: 20),
          _section('Χρόνος'),
          _switchTile(
            label:    'Προγραμματισμένη',
            icon:     Icons.schedule_rounded,
            value:    _isScheduled,
            onChanged: (v) {
              setState(() {
                _isScheduled = v;
                _recomputeNightAuto();
                _recomputeCommissions();
              });
              if (v && _scheduledAt == null) _pickScheduledTime();
            },
          ),
          if (_isScheduled) ...[
            const SizedBox(height: 8),
            InkWell(
              onTap: _pickScheduledTime,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color:  Colors.white,
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(children: [
                  const Icon(Icons.calendar_today_rounded, color: Colors.amber),
                  const SizedBox(width: 12),
                  Text(
                    _scheduledAt != null
                        ? '${_scheduledAt!.day}/${_scheduledAt!.month}/${_scheduledAt!.year}'
                        '  ${_scheduledAt!.hour.toString().padLeft(2, '0')}:'
                        '${_scheduledAt!.minute.toString().padLeft(2, '0')}'
                        : 'Επίλεξε ώρα',
                    style: TextStyle(
                      fontSize: 15,
                      color: _scheduledAt != null ? Colors.black : Colors.grey,
                    ),
                  ),
                ]),
              ),
            ),
          ],

          // Timeout
          const SizedBox(height: 16),
          Row(children: [
            const Icon(Icons.timer_rounded, color: Colors.grey, size: 20),
            const SizedBox(width: 8),
            Text('Timeout: $_timeoutMins λεπτά',
                style: const TextStyle(fontSize: 14)),
            const Spacer(),
            SizedBox(
              width: 150,
              child: Slider(
                value:    _timeoutMins.toDouble(),
                min:      2, max: 30, divisions: 14,
                activeColor: Colors.amber,
                label:    '$_timeoutMins λεπτά',
                onChanged: (v) => setState(() => _timeoutMins = v.toInt()),
              ),
            ),
          ]),

          // Available first toggle
          const SizedBox(height: 10),
          _switchTile(
            label:    'Πρώτα σε διαθέσιμους',
            icon:     Icons.person_search_rounded,
            value:    _availableOnly,
            onChanged: (v) => setState(() => _availableOnly = v),
          ),

          // ── Αποκλειστική αποστολή ─────────────────────────────────────────
          // Εμφανίζεται μόνο όταν έχει επιλεγεί ομάδα Ή συγκεκριμένοι οδηγοί.
          if (_targetUids.isNotEmpty ||
              (_selectedGroupId != null && _selectedGroupId!.isNotEmpty)) ...[
            const SizedBox(height: 10),
            Container(
              decoration: BoxDecoration(
                color: _exclusiveTarget
                    ? Colors.deepOrange.withValues(alpha: 0.08)
                    : Colors.grey.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _exclusiveTarget
                      ? Colors.deepOrange.withValues(alpha: 0.5)
                      : Colors.grey.shade300,
                ),
              ),
              child: SwitchListTile(
                activeThumbColor: Colors.deepOrange,
                secondary: Icon(Icons.lock_rounded,
                    color: _exclusiveTarget
                        ? Colors.deepOrange
                        : Colors.grey),
                title: const Text('Αποκλειστική αποστολή',
                    style: TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 14)),
                subtitle: Text(
                  _exclusiveTarget
                      ? 'Θα σταλεί ΜΟΝΟ εδώ. Αν δεν το πάρει κανείς, '
                        'δεν θα χτυπήσει σε άλλους.'
                      : 'Αν ενεργό, στέλνεται μόνο στην επιλογή σου χωρίς '
                        'κλιμάκωση σε όλους.',
                  style: TextStyle(
                      fontSize: 11.5, color: Colors.grey[600]),
                ),
                value: _exclusiveTarget,
                onChanged: (v) => setState(() => _exclusiveTarget = v),
              ),
            ),
          ],

          // ── Πελάτης ───────────────────────────────────────────────────────
          const SizedBox(height: 20),
          _section('Στοιχεία Πελάτη (προαιρετικό)'),
          _field(
            controller: _clientNameCtrl,
            label:      'Όνομα Πελάτη',
            icon:       Icons.person_rounded,
            capitalize: true,
          ),
          const SizedBox(height: 10),
          // ΝΕΟ: Πεδίο Τηλεφώνου Πελάτη
          _field(
            controller: _clientPhoneCtrl,
            label:      'Τηλέφωνο Πελάτη',
            icon:       Icons.phone_rounded,
            isNumber:   true,
          ),
          const SizedBox(height: 10),
          // ΝΕΟ: Πεδίο Email Πελάτη
          _field(
            controller: _clientEmailCtrl,
            label:      'Email Πελάτη',
            icon:       Icons.email_rounded,
          ),
          const SizedBox(height: 10),
          _field(
            controller: _flightShipCtrl,
            label:      'Πτήση / Πλοίο',
            icon:       Icons.flight_rounded,
            capitalize: true,
          ),

          // ── Σχόλιο ────────────────────────────────────────────────────────
          const SizedBox(height: 20),
          _section('Σχόλιο (προαιρετικό)'),
          _field(
            controller: _noteCtrl,
            label:      'Σχόλιο',
            icon:       Icons.notes_rounded,
            maxLines:   3,
          ),

          const SizedBox(height: 32),
          // Info banner για resend
          if (widget.editJob != null && widget.editJob!.takenBy == null)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.blue.shade200),
              ),
              child: Row(children: [
                Icon(Icons.info_outline_rounded,
                    color: Colors.blue.shade700, size: 16),
                const SizedBox(width: 8),
                Expanded(child: Text(
                  'Η αποστολή θα σταλεί ξανά σε ΟΛΟΥΣ τους οδηγούς',
                  style: TextStyle(fontSize: 12, color: Colors.blue.shade700),
                )),
              ]),
            ),
          FilledButton.icon(
            onPressed: _isSaving ? null : _save,
            style: FilledButton.styleFrom(
              backgroundColor: Colors.amber,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            icon: Icon(widget.editJob != null && widget.editJob!.takenBy == null
                ? Icons.campaign_rounded
                : Icons.send_rounded),
            label: Text(
              widget.editJob == null
                  ? 'Αποστολή Δουλειάς'
                  : (widget.editJob!.takenBy == null
                      ? '🔔 Αποστολή σε Όλους'
                      : 'Αποθήκευση'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
          // Κουμπί ΑΠΟΘΗΚΕΥΣΗΣ ως προσχέδιο — όχι κατά το resend ληφθείσας δουλειάς
          if (widget.editJob == null) ...[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _isSaving ? null : _saveDraft,
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF1565C0),
                side: const BorderSide(color: Color(0xFF1565C0)),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              icon: const Icon(Icons.bookmark_add_rounded),
              label: Text(
                widget.isSavedDraft
                    ? 'Ενημέρωση αποθηκευμένης'
                    : 'Αποθήκευση (για μετά)',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
          SizedBox(height: 32 + MediaQuery.of(context).padding.bottom),
        ],
      ),
    );
  }

  // ─── Shared widgets ───────────────────────────────────────────────────────

  Widget _section(String label) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(label.toUpperCase(),
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
            color: Colors.grey[500], letterSpacing: 1.2)),
  );

  // Κουτί απόστασης διαδρομής
  Widget _routeInfoBox() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color:        Colors.blue.shade50,
        borderRadius: BorderRadius.circular(10),
        border:       Border.all(color: Colors.blue.shade200),
      ),
      child: Row(children: [
        Icon(Icons.straighten_rounded,
            size: 20, color: Colors.blue.shade700),
        const SizedBox(width: 10),
        Expanded(
          child: _routeLoading
              ? Row(children: [
                  const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Text('Υπολογισμός διαδρομής…',
                      style: TextStyle(
                          fontSize: 13, color: Colors.blue.shade800)),
                ])
              : Text(
                  'Απόσταση: ${_routeKm!.toStringAsFixed(1)} χλμ'
                  '${_routeIsAir ? "  (ευθεία)" : ""}',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.blue.shade900),
                ),
        ),
        if (!_routeLoading && _routeIsAir)
          Tooltip(
            message: 'Δεν βρέθηκε διαδρομή οδήγησης — '
                'εμφανίζεται απόσταση σε ευθεία γραμμή.',
            child: Icon(Icons.info_outline_rounded,
                size: 16, color: Colors.blue.shade400),
          ),
      ]),
    );
  }

  // Κουμπί toggle για χαρακτηριστικό διαδρομής (επιστροφή / στάσεις)
  Widget _featureToggle({
    required String   label,
    required IconData icon,
    required bool     active,
    required Color    color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
        decoration: BoxDecoration(
          color: active ? color.withValues(alpha: 0.12) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active ? color : Colors.grey.shade300,
            width: active ? 2 : 1,
          ),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(active ? icon : Icons.add_rounded,
              size: 19, color: active ? color : Colors.grey),
          const SizedBox(width: 7),
          Flexible(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: active
                        ? FontWeight.bold : FontWeight.w500,
                    color: active ? color : Colors.grey.shade700)),
          ),
        ]),
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String                label,
    required IconData              icon,
    bool                           isNumber   = false,
    bool                           capitalize = false,
    int                            maxLines   = 1,
    ValueChanged<String>?          onChanged,
  }) {
    return TextFormField(
      controller:       controller,
      keyboardType:     isNumber ? TextInputType.number : TextInputType.text,
      textCapitalization: capitalize
          ? TextCapitalization.words : TextCapitalization.none,
      maxLines: maxLines,
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText:  label,
        prefixIcon: Icon(icon),
        filled:     true,
        fillColor:  Colors.white,
        border:     OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  // Πλαίσιο τιμής/κάθισμα — ΙΔΙΑ εμφάνιση/ύψος με το _stepper δίπλα του:
  // ίδιο border, ίδιο padding, ετικέτα πάνω, στοιχείο ύψους 32 κάτω.
  Widget _childSeatPriceBox() {
    final enabled = _childSeatCount > 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color:        enabled ? Colors.teal.shade50 : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(12),
        border:       Border.all(
            color: enabled ? Colors.teal.shade200 : Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.euro_rounded, size: 16,
                color: enabled ? Colors.teal : Colors.grey[600]),
            const SizedBox(width: 6),
            Text('Τιμή/κάθισμα (€)',
                style: TextStyle(fontSize: 12,
                    color: enabled ? Colors.teal.shade700 : Colors.grey[600])),
          ]),
          const SizedBox(height: 8),
          SizedBox(
            height: 32,
            child: TextFormField(
              controller: _childSeatPriceCtrl,
              enabled: enabled,
              textAlign: TextAlign.center,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold),
              onChanged: (_) {
                _recomputeCommissions();
                setState(() {});
              },
              decoration: InputDecoration(
                isDense: true,
                hintText: '0.00',
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                filled:    true,
                fillColor: Colors.white,
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: Colors.teal.shade200),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Colors.teal, width: 2),
                ),
                disabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stepper({
    required String   label,
    required IconData icon,
    required int      value,
    required int      min,
    required int      max,
    required ValueChanged<int> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color:        Colors.white,
        borderRadius: BorderRadius.circular(12),
        border:       Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, size: 16, color: Colors.grey[600]),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
          ]),
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            GestureDetector(
              onTap: value > min ? () => onChanged(value - 1) : null,
              child: Container(
                width: 32, height: 32,
                decoration: BoxDecoration(
                  color:        value > min ? Colors.amber : Colors.grey[200],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.remove_rounded,
                    size: 18,
                    color: value > min ? Colors.black : Colors.grey),
              ),
            ),
            Text('$value',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            GestureDetector(
              onTap: value < max ? () => onChanged(value + 1) : null,
              child: Container(
                width: 32, height: 32,
                decoration: BoxDecoration(
                  color:        value < max ? Colors.amber : Colors.grey[200],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.add_rounded,
                    size: 18,
                    color: value < max ? Colors.black : Colors.grey),
              ),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _switchTile({
    required String   label,
    required IconData icon,
    required bool     value,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      decoration: BoxDecoration(
        color:        Colors.white,
        borderRadius: BorderRadius.circular(12),
        border:       Border.all(color: Colors.grey.shade300),
      ),
      child: SwitchListTile(
        title: Row(children: [
          Icon(icon, size: 18, color: Colors.grey[600]),
          const SizedBox(width: 10),
          Text(label),
        ]),
        value:       value,
        activeThumbColor: Colors.amber,
        onChanged:   onChanged,
      ),
    );
  }

  Widget _previewRow(String label, String value, Color color,
      {bool bold = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[700])),
          const Spacer(),
          Text(value,
              style: TextStyle(
                  fontSize:   13,
                  fontWeight: bold ? FontWeight.bold : FontWeight.w600,
                  color:      color)),
        ]),
      );

  // Κάρτα μίας ΕΠΙΠΛΕΟΝ κράτησης της ομαδικής μεταφοράς.
  Widget _extraBookingCard(int i) {
    final b = _extraBookings[i];
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.amber.shade200),
        borderRadius: BorderRadius.circular(12),
        color: Colors.amber.shade50.withValues(alpha: 0.4),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(
                'Κράτηση ${i + 2}'
                '${b.zoneName != null ? ' · ${b.zoneName}${b.orderInZone != null ? ' #${b.orderInZone}' : ''}' : ''}',
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13.5,
                    color: Colors.amber.shade900)),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Αφαίρεση κράτησης',
            icon: const Icon(Icons.close_rounded, size: 18, color: Colors.red),
            onPressed: () => setState(() {
              _extraBookings.removeAt(i).dispose();
            }),
          ),
        ]),
        PlaceField(
          label: _groupSharedIsDestination
              ? 'Διεύθυνση παραλαβής *' : 'Διεύθυνση άφησης *',
          icon: Icons.place_rounded,
          value: b.pick,
          onPicked: (p) => setState(() => b.pick = p),
          clients: _clients,
          onClientPicked: (c) => setState(() {
            b.pick = PlacePick(
                description: c.fromName.isNotEmpty ? c.fromName : c.name,
                lat: c.fromLat, lng: c.fromLng);
            b.zoneName    = c.shuttleZoneName;
            b.orderInZone = c.shuttleOrder;
          }),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: TextField(
              controller: b.nameCtrl,
              decoration: const InputDecoration(isDense: true,
                  labelText: 'Όνομα', border: OutlineInputBorder()),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: b.phoneCtrl,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(isDense: true,
                  labelText: 'Τηλέφωνο', border: OutlineInputBorder()),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: TextField(
              controller: b.emailCtrl,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(isDense: true,
                  labelText: 'Email', border: OutlineInputBorder()),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: b.flightCtrl,
              decoration: const InputDecoration(isDense: true,
                  labelText: 'Πτήση/Πλοίο', border: OutlineInputBorder()),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: TextField(
              controller: b.personsCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(isDense: true,
                  labelText: 'Άτομα', border: OutlineInputBorder()),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: b.luggageCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(isDense: true,
                  labelText: 'Βαλίτσες', border: OutlineInputBorder()),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: b.childSeatCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(isDense: true,
                  labelText: 'Παιδικό κάθισμα', border: OutlineInputBorder()),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: b.priceCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(isDense: true,
                  labelText: 'Τιμή €', border: OutlineInputBorder()),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        TextField(
          controller: b.noteCtrl,
          decoration: const InputDecoration(isDense: true,
              labelText: 'Σχόλια', border: OutlineInputBorder()),
        ),
      ]),
    );
  }

  Widget _vehicleChip(String type, String label, IconData icon) {
    final selected = _vehicleType == type;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _vehicleType = type),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color:        selected ? Colors.amber : Colors.white,
            borderRadius: BorderRadius.circular(10),
            border:       Border.all(
              color: selected ? Colors.amber : Colors.grey.shade300,
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 20, color: selected ? Colors.black : Colors.grey[600]),
            const SizedBox(height: 4),
            Text(label,
                style: TextStyle(
                    fontSize:   11,
                    fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                    color:      selected ? Colors.black : Colors.grey[600])),
          ]),
        ),
      ),
    );
  }
}
// ─────────────────────────────────────────────────────────────────────────────
// _ClientRoutePicker — επιλογή αποθηκευμένης διαδρομής πελάτη
// ─────────────────────────────────────────────────────────────────────────────

class _ClientRoutePicker extends StatelessWidget {
  final Client client;
  const _ClientRoutePicker({required this.client});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 12),
          const SheetHandle(bottomMargin: 0),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Row(children: [
              const Icon(Icons.person_pin_circle_rounded, color: Colors.amber),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Διαδρομές — ${client.name}',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ]),
          ),
          if (client.fromName.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(children: [
                Icon(Icons.trip_origin_rounded,
                    size: 13, color: Colors.amber.shade700),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(client.fromName,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12.5, color: Colors.grey[700])),
                ),
              ]),
            ),
          const Divider(height: 1),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: client.routes.length,
              separatorBuilder: (_, _) =>
                  Divider(height: 1, color: Colors.grey.shade100),
              itemBuilder: (_, i) {
                final r = client.routes[i];
                return ListTile(
                  leading: const Icon(Icons.place_rounded, color: Colors.red),
                  title: Text(r.toName,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Row(children: [
                    if (r.price > 0)
                      Text('${r.price.toStringAsFixed(2)}€',
                          style: TextStyle(
                              color: Colors.green.shade700,
                              fontWeight: FontWeight.bold, fontSize: 13)),
                    if (r.price > 0 &&
                        (r.sourceName ?? '').isNotEmpty)
                      const Text('  •  ',
                          style: TextStyle(color: Colors.grey)),
                    if ((r.sourceName ?? '').isNotEmpty)
                      Flexible(
                        child: Text(r.sourceName!,
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: Colors.orange.shade800, fontSize: 12)),
                      ),
                  ]),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.pop(context, r),
                );
              },
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => Navigator.pop(context, null),
                icon: const Icon(Icons.edit_location_alt_rounded),
                label: const Text('Μόνο το «Από» — νέος προορισμός'),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

// ── Μία επιπλέον κράτηση ομαδικής μεταφοράς (Shuttle/Λεωφορείο) ──
class _ExtraBooking {
  final nameCtrl    = TextEditingController();
  final phoneCtrl   = TextEditingController();
  final emailCtrl   = TextEditingController();
  final flightCtrl  = TextEditingController();
  final priceCtrl   = TextEditingController();
  final personsCtrl   = TextEditingController(text: '1');
  final luggageCtrl   = TextEditingController(text: '0');
  final childSeatCtrl = TextEditingController(text: '0');
  final noteCtrl      = TextEditingController();
  PlacePick? pick;
  String? zoneName;
  int?    orderInZone;
  void dispose() {
    nameCtrl.dispose(); phoneCtrl.dispose(); emailCtrl.dispose();
    flightCtrl.dispose(); priceCtrl.dispose();
    personsCtrl.dispose(); luggageCtrl.dispose();
    childSeatCtrl.dispose(); noteCtrl.dispose();
  }
}
