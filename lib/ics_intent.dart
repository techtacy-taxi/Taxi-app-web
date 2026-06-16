// lib/ics_intent.dart
//
// Διαχειρίζεται το άνοιγμα αρχείων .ics (κρατήσεις transfer) από το κινητό.
//
//  • Όταν ο χρήστης πατά ένα .ics και επιλέγει το Athens Taxi από το
//    «Άνοιγμα με…», το native (MainActivity.kt) διαβάζει το περιεχόμενο
//    και το στέλνει εδώ μέσω MethodChannel.
//  • Ο parser μετατρέπει το .ics σε IcsBooking.
//  • Το map_page.dart ακούει και ανοίγει τη Νέα Δουλειά προ-συμπληρωμένη.
//
// Μορφή .ics (νέα) — όλα τα στοιχεία είναι στο DESCRIPTION:
//   Booking Number: ....
//   Client: ....
//   Email: ....
//   Phone: ....
//   Leg 1: <Από> To <Προς>
//     Transport: ferry ....            → Πτήση/Πλοίο
//     Notes: ....                      → Σχόλια
//   Vehicles: Van: 1 / Taxi: 1         → επιλογή οχήματος
//   Passengers: N                      → Άτομα
//   Luggage: N                         → Βαλίτσες
//   Price: €...                        → Τιμή
//   Amount Paid: €...                  → Σχόλια
//   DTSTART (TZID Europe/Athens ή UTC) → ώρα ραντεβού

import 'package:flutter/services.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Μοντέλο κράτησης
// ─────────────────────────────────────────────────────────────────────────────
class IcsBooking {
  final String?   from;          // Από
  final String?   to;            // Προς
  final DateTime? scheduledAt;   // Ώρα ραντεβού (DTSTART)
  final int       persons;       // Άτομα
  final int       luggage;       // Βαλίτσες
  final String?   phone;         // Τηλέφωνο
  final String?   name;          // Όνομα πελάτη
  final String?   email;         // → Σχόλια
  final String?   flightOrShip;  // Transport (πλοίο/μεταφορικό) → Πτήση/Πλοίο
  final String    vehicleType;   // 'taxi' | 'van' | 'any'
  final double?   price;         // Τιμή
  final String?   bookingNumber; // → Σχόλια
  final String?   amountPaid;    // πληρωμένο → Σχόλια
  final String?   notes;         // ελεύθερες σημειώσεις → Σχόλια
  final int       childSeats;    // 1 αν αναφέρεται baby/child seat, αλλιώς 0

  const IcsBooking({
    this.from,
    this.to,
    this.scheduledAt,
    this.persons = 1,
    this.luggage = 0,
    this.phone,
    this.name,
    this.email,
    this.flightOrShip,
    this.vehicleType = 'any',
    this.price,
    this.bookingNumber,
    this.amountPaid,
    this.notes,
    this.childSeats = 0,
  });

  /// Κείμενο για το πεδίο «Σχόλια»:
  /// Σημειώσεις + Email + Αρ. κράτησης + Πληρωμένο.
  String? get noteForComments {
    final lines = <String>[];
    if (notes != null && notes!.trim().isNotEmpty) {
      lines.add('Σημ.: ${notes!.trim()}');
    }
    if (email != null && email!.trim().isNotEmpty) {
      lines.add('Email: ${email!.trim()}');
    }
    if (bookingNumber != null && bookingNumber!.trim().isNotEmpty) {
      lines.add('Κράτηση: ${bookingNumber!.trim()}');
    }
    if (amountPaid != null && amountPaid!.trim().isNotEmpty) {
      lines.add('Πληρωμένο: ${amountPaid!.trim()}');
    }
    return lines.isEmpty ? null : lines.join('\n');
  }

  bool get isEmpty =>
      (from == null || from!.isEmpty) &&
      (to == null || to!.isEmpty) &&
      scheduledAt == null &&
      phone == null &&
      name == null;
}

// ─────────────────────────────────────────────────────────────────────────────
// Channel + parser
// ─────────────────────────────────────────────────────────────────────────────
class IcsIntent {
  static const MethodChannel _channel = MethodChannel('athens_taxi/ics');

  /// Αρχεία .ics που ανοίγουν ΕΝΩ τρέχει ήδη η εφαρμογή.
  static void listen(void Function(IcsBooking) onBooking) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onIcs' && call.arguments is String) {
        final b = parseIcs(call.arguments as String);
        if (b != null && !b.isEmpty) onBooking(b);
      }
      return null;
    });
  }

  /// Κράτηση αν η εφαρμογή ΑΝΟΙΞΕ πατώντας .ics (cold start). Καλείται μία φορά.
  static Future<IcsBooking?> initial() async {
    try {
      final s = await _channel.invokeMethod<String>('getInitialIcs');
      if (s == null || s.isEmpty) return null;
      final b = parseIcs(s);
      return (b != null && !b.isEmpty) ? b : null;
    } catch (_) {
      return null;
    }
  }

  // ── Parser ─────────────────────────────────────────────────────────────────
  static IcsBooking? parseIcs(String raw) {
    if (!raw.contains('VCALENDAR') && !raw.contains('VEVENT')) return null;

    // 1) Κανονικοποίηση + unfolding (συνέχεια γραμμής ξεκινά με κενό ή tab)
    final normalized = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final rawLines = normalized.split('\n');
    final unfolded = <String>[];
    for (final l in rawLines) {
      if (l.isEmpty) continue;
      if ((l.startsWith(' ') || l.startsWith('\t')) && unfolded.isNotEmpty) {
        unfolded[unfolded.length - 1] += l.substring(1);
      } else {
        unfolded.add(l);
      }
    }

    // 2) Κράτα μόνο τις ιδιότητες του VEVENT
    //    (αγνόησε VTIMEZONE και τα nested υπο-μπλοκ, π.χ. VALARM που έχει
    //     δικό του DESCRIPTION:Alarm και θα «έσβηνε» τα στοιχεία της κράτησης)
    String? description, location, dtstart;
    bool inEvent = false;
    int  subLevel = 0; // >0 = μέσα σε υπο-συστατικό
    for (final line in unfolded) {
      final up = line.toUpperCase();
      if (up == 'BEGIN:VEVENT') { inEvent = true; subLevel = 0; continue; }
      if (up == 'END:VEVENT')   { inEvent = false; subLevel = 0; continue; }
      if (!inEvent) continue;
      if (up.startsWith('BEGIN:')) { subLevel++; continue; }
      if (up.startsWith('END:'))   { if (subLevel > 0) subLevel--; continue; }
      if (subLevel > 0) continue; // μέσα σε VALARM κ.λπ.

      final idx = line.indexOf(':');
      if (idx < 0) continue;
      final key = line.substring(0, idx).split(';').first.trim().toUpperCase();
      final value = line.substring(idx + 1);
      switch (key) {
        case 'DESCRIPTION':
          description = _unescape(value);
          break;
        case 'LOCATION':
          location = _unescape(value).trim();
          break;
        case 'DTSTART':
          dtstart = value.trim();
          break;
      }
    }

    if (description == null && location == null && dtstart == null) return null;

    // 3) Διάβασε τα πεδία του DESCRIPTION (Key: Value ανά γραμμή)
    String? bookingNumber, name, email, phone, transport, notes, priceStr,
        amountPaid, legLine;
    int persons = 1, luggage = 0;

    if (description != null) {
      for (var line in description.split('\n')) {
        line = line.trim();
        if (line.isEmpty) continue;
        final ci = line.indexOf(':');
        if (ci < 0) continue;
        final k = line.substring(0, ci).trim().toLowerCase();
        final v = line.substring(ci + 1).trim();
        if (v.isEmpty) continue;

        if (k.startsWith('booking number')) {
          bookingNumber = v;
        } else if (k == 'client') {
          name = v;
        } else if (k == 'email') {
          email = v;
        } else if (k == 'phone') {
          phone = v;
        } else if (k.startsWith('leg')) {
          legLine ??= v; // πρώτο leg
        } else if (k == 'transport') {
          transport ??= v;
        } else if (k == 'notes') {
          notes = v;
        } else if (k == 'passengers') {
          persons = int.tryParse(_digits(v)) ?? persons;
        } else if (k == 'luggage') {
          luggage = int.tryParse(_digits(v)) ?? luggage;
        } else if (k == 'price') {
          priceStr = v;
        } else if (k.startsWith('amount paid')) {
          amountPaid = v;
        }
      }
    }

    // 4) Όχημα: Van: n / Taxi: n  (ψάχνει σε όλο το description)
    String vehicleType = 'any';
    if (description != null) {
      final van = RegExp(r'Van\s*:\s*(\d+)', caseSensitive: false)
          .firstMatch(description);
      final taxi = RegExp(r'Taxi\s*:\s*(\d+)', caseSensitive: false)
          .firstMatch(description);
      final vanN = van != null ? (int.tryParse(van.group(1)!) ?? 0) : 0;
      final taxiN = taxi != null ? (int.tryParse(taxi.group(1)!) ?? 0) : 0;
      if (vanN > 0) {
        vehicleType = 'van';
      } else if (taxiN > 0) {
        vehicleType = 'taxi';
      }
    }

    // 5) Από / Προς από το Leg ("X To Y"). Fallback: LOCATION για το «Από».
    String? from, to;
    if (legLine != null) {
      final m = RegExp(r'^(.*?)\s+[Tt]o\s+(.*)$').firstMatch(legLine);
      if (m != null) {
        from = m.group(1)?.trim();
        to = m.group(2)?.trim();
      } else {
        from = legLine.trim();
      }
    }
    if ((from == null || from.isEmpty) && location != null) from = location;

    return IcsBooking(
      from: from,
      to: to,
      scheduledAt: _parseIcsDate(dtstart),
      persons: persons,
      luggage: luggage,
      phone: phone,
      name: name,
      email: email,
      flightOrShip: transport,
      vehicleType: vehicleType,
      price: _parsePrice(priceStr),
      bookingNumber: bookingNumber,
      amountPaid: amountPaid,
      notes: notes,
      childSeats: _hasBabySeat(notes ?? description) ? 1 : 0,
    );
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  /// true αν αναφέρεται παιδικό κάθισμα (baby/child/car seat ή ελληνικά).
  static bool _hasBabySeat(String? text) {
    if (text == null) return false;
    final t = text.toLowerCase();
    return t.contains('baby seat') ||
        t.contains('child seat') ||
        t.contains('car seat') ||
        t.contains('booster') ||
        (t.contains('παιδικ') && t.contains('καθισμ'));
  }
  static String _unescape(String s) => s
      .replaceAll(r'\n', '\n')
      .replaceAll(r'\N', '\n')
      .replaceAll(r'\,', ',')
      .replaceAll(r'\;', ';')
      .replaceAll(r'\\', '\\');

  static String _digits(String s) =>
      RegExp(r'\d+').firstMatch(s)?.group(0) ?? '';

  /// "€110.00" / "€56" / "1.234,56" → double
  static double? _parsePrice(String? s) {
    if (s == null) return null;
    var t = s.replaceAll(RegExp(r'[^\d.,]'), '');
    if (t.isEmpty) return null;
    if (t.contains(',') && t.contains('.')) {
      // 1.234,56 → 1234.56
      t = t.replaceAll('.', '').replaceAll(',', '.');
    } else if (t.contains(',')) {
      t = t.replaceAll(',', '.');
    }
    return double.tryParse(t);
  }

  /// 20260530T201000 / 20260531T120500Z / ...
  /// Με Z → UTC → τοπική ώρα συσκευής (Αθήνα). Χωρίς Z → τοπική ώρα.
  static DateTime? _parseIcsDate(String? v) {
    if (v == null) return null;
    var s = v.trim();
    final utc = s.endsWith('Z');
    if (utc) s = s.substring(0, s.length - 1);
    final m = RegExp(r'^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2}))?')
        .firstMatch(s);
    if (m == null) return null;
    final y = int.parse(m.group(1)!);
    final mo = int.parse(m.group(2)!);
    final d = int.parse(m.group(3)!);
    final h = m.group(4) != null ? int.parse(m.group(4)!) : 0;
    final mi = m.group(5) != null ? int.parse(m.group(5)!) : 0;
    final se = m.group(6) != null ? int.parse(m.group(6)!) : 0;
    return utc
        ? DateTime.utc(y, mo, d, h, mi, se).toLocal()
        : DateTime(y, mo, d, h, mi, se);
  }
}
