// ==========================================
// FILE: ./lib/jobs/client_model.dart
// ==========================================
//
// Μοντέλα για την καρτέλα "Πελάτες".
//
//  • Client      → ένας πελάτης (π.χ. Χίλτον) με μια πραγματική διεύθυνση-βάση
//                  (το "Από", με συντεταγμένες) + λίστα αποθηκευμένων διαδρομών.
//  • ClientRoute → μια αποθηκευμένη διαδρομή του πελάτη: προορισμός (Προς),
//                  τιμή και (προαιρετικά) πηγή. Διαλέγοντάς την ανοίγει νέα
//                  δουλειά με προσυμπληρωμένα Από / Προς / Τιμή / Πηγή.

import 'package:cloud_firestore/cloud_firestore.dart';

// ─── ClientRoute ────────────────────────────────────────────────────────────

class ClientRoute {
  final String  toName;     // περιγραφή προορισμού (π.χ. "Αεροδρόμιο")
  final double? toLat;
  final double? toLng;
  final double  price;      // τιμή διαδρομής (ημέρα)
  final double? nightPrice; // τιμή διαδρομής τη ΝΥΧΤΑ — προαιρετική, αν κενή ισχύει η ίδια με ημέρα
  final String? sourceId;   // πηγή (γιαούρτι) — προαιρετικό
  final String? sourceName;

  const ClientRoute({
    required this.toName,
    this.toLat,
    this.toLng,
    this.price = 0,
    this.nightPrice,
    this.sourceId,
    this.sourceName,
  });

  bool get hasCoords => toLat != null && toLng != null;

  factory ClientRoute.fromMap(Map<String, dynamic> d) => ClientRoute(
        toName:     d['toName'] as String? ?? '',
        toLat:      (d['toLat'] as num?)?.toDouble(),
        toLng:      (d['toLng'] as num?)?.toDouble(),
        price:      (d['price'] as num?)?.toDouble() ?? 0,
        nightPrice: (d['nightPrice'] as num?)?.toDouble(),
        sourceId:   d['sourceId']   as String?,
        sourceName: d['sourceName'] as String?,
      );

  Map<String, dynamic> toMap() => {
        'toName': toName,
        if (toLat != null) 'toLat': toLat,
        if (toLng != null) 'toLng': toLng,
        'price': price,
        if (nightPrice != null) 'nightPrice': nightPrice,
        if (sourceId   != null) 'sourceId':   sourceId,
        if (sourceName != null) 'sourceName': sourceName,
      };

  ClientRoute copyWith({
    String?  toName,
    double?  toLat,
    double?  toLng,
    double?  price,
    double?  nightPrice,
    String?  sourceId,
    String?  sourceName,
  }) =>
      ClientRoute(
        toName:     toName     ?? this.toName,
        toLat:      toLat      ?? this.toLat,
        toLng:      toLng      ?? this.toLng,
        price:      price      ?? this.price,
        nightPrice: nightPrice ?? this.nightPrice,
        sourceId:   sourceId   ?? this.sourceId,
        sourceName: sourceName ?? this.sourceName,
      );
}

// ─── Client ─────────────────────────────────────────────────────────────────

class Client {
  final String  id;
  final String  name;        // π.χ. "Χίλτον"
  final String  fromName;    // πραγματική διεύθυνση-βάση (το "Από")
  final double? fromLat;
  final double? fromLng;
  final String? phone;       // προαιρετικό τηλέφωνο πελάτη
  final bool    hasShuttleBus; // ✅ διαθέτει υπηρεσία Shuttle Bus
  final bool    showInOnlineForm; // 🌐 εμφανίζεται στις προτάσεις Από/Προς των ONLINE φορμών (booking/booking2/index) — στη φόρμα δουλειάς της εφαρμογής φαίνεται ΠΑΝΤΑ
  final String? shuttleZoneId;   // 🚐 ζώνη του καταλύματος (από pricing_zones) — αναγνώριση χωρίς γεωγραφικό υπολογισμό
  final String? shuttleZoneName; // όνομα ζώνης για εμφάνιση χωρίς επιπλέον fetch
  final int?    shuttleOrder;    // θέση στη σειρά παραλαβής Shuttle ΜΕΣΑ στη ζώνη (1 = πρώτο στην παραλαβή, τελευταίο στην επιστροφή)
  final List<ClientRoute> routes;
  final String  createdBy;
  final String  createdByName;
  final DateTime? createdAt;

  const Client({
    required this.id,
    required this.name,
    this.fromName = '',
    this.fromLat,
    this.fromLng,
    this.phone,
    this.hasShuttleBus = false,
    this.showInOnlineForm = true,
    this.shuttleZoneId,
    this.shuttleZoneName,
    this.shuttleOrder,
    this.routes = const [],
    required this.createdBy,
    this.createdByName = '',
    this.createdAt,
  });

  bool get hasFromCoords => fromLat != null && fromLng != null;

  factory Client.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data()!;
    final rawRoutes = d['routes'];
    final routes = rawRoutes is List
        ? rawRoutes
            .whereType<Map>()
            .map((e) => ClientRoute.fromMap(Map<String, dynamic>.from(e)))
            .toList()
        : <ClientRoute>[];
    return Client(
      id:            doc.id,
      name:          d['name']     as String? ?? '',
      fromName:      d['fromName'] as String? ?? '',
      fromLat:       (d['fromLat'] as num?)?.toDouble(),
      fromLng:       (d['fromLng'] as num?)?.toDouble(),
      phone:         d['phone']    as String?,
      hasShuttleBus: d['hasShuttleBus'] == true,
      showInOnlineForm: d['showInOnlineForm'] != false, // default: φαίνεται
      shuttleZoneId:   d['shuttleZoneId'] as String?,
      shuttleZoneName: d['shuttleZoneName'] as String?,
      shuttleOrder:    (d['shuttleOrder'] as num?)?.toInt(),
      routes:        routes,
      createdBy:     d['createdBy']     as String? ?? '',
      createdByName: d['createdByName'] as String? ?? '',
      createdAt:     (d['createdAt'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toMap() => {
        'name':     name,
        'fromName': fromName,
        if (fromLat != null) 'fromLat': fromLat,
        if (fromLng != null) 'fromLng': fromLng,
        if (phone != null && phone!.isNotEmpty) 'phone': phone,
        'hasShuttleBus': hasShuttleBus,
        'showInOnlineForm': showInOnlineForm,
        'shuttleZoneId':   shuttleZoneId,
        'shuttleZoneName': shuttleZoneName,
        'shuttleOrder':    shuttleOrder,
        'routes':        routes.map((r) => r.toMap()).toList(),
        'createdBy':     createdBy,
        'createdByName': createdByName,
        'createdAt':     createdAt != null
            ? Timestamp.fromDate(createdAt!)
            : FieldValue.serverTimestamp(),
      };

  Client copyWith({
    String?  name,
    String?  fromName,
    double?  fromLat,
    double?  fromLng,
    String?  phone,
    bool?    hasShuttleBus,
    bool?    showInOnlineForm,
    String?  shuttleZoneId,
    String?  shuttleZoneName,
    int?     shuttleOrder,
    List<ClientRoute>? routes,
  }) =>
      Client(
        id:            id,
        name:          name     ?? this.name,
        fromName:      fromName ?? this.fromName,
        fromLat:       fromLat  ?? this.fromLat,
        fromLng:       fromLng  ?? this.fromLng,
        phone:         phone    ?? this.phone,
        hasShuttleBus: hasShuttleBus ?? this.hasShuttleBus,
        showInOnlineForm: showInOnlineForm ?? this.showInOnlineForm,
        shuttleZoneId:   shuttleZoneId   ?? this.shuttleZoneId,
        shuttleZoneName: shuttleZoneName ?? this.shuttleZoneName,
        shuttleOrder:    shuttleOrder    ?? this.shuttleOrder,
        routes:        routes   ?? this.routes,
        createdBy:     createdBy,
        createdByName: createdByName,
        createdAt:     createdAt,
      );
}
