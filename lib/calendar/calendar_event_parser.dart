// lib/calendar/calendar_event_parser.dart
//
// Αναγνωρίζει τα στοιχεία μιας κράτησης από ένα Google Calendar event,
// ανεξάρτητα από το αν είναι «ακατάστατο» ή γραμμένο στη σταθερή φόρμα.
//
// ── ΚΑΝΟΝΕΣ ΑΝΑΓΝΩΡΙΣΗΣ (heuristics) ─────────────────────────────────────────
//
//  Σειρά ελέγχου ανά γραμμή/token:
//    1) Τηλέφωνο  → 00 + σύνολο 13–16 ψηφία (κινητό/διεθνές),
//                   ή + με 11–14 ψηφία (κινητό/διεθνές),
//                   ή 69 + σύνολο 10 ψηφία (κινητό),
//                   ή 2 + σύνολο 10 ψηφία (σταθερό).
//                   (αγνοούνται παρενθέσεις / κενά / παύλες)
//                   Προτεραιότητα κύριου πεδίου: κινητό. Σταθερό (αρχίζει με 2)
//                   πάει στο πεδίο μόνο αν δεν υπάρχει κινητό· αλλιώς → σχόλια.
//                   Τυχόν επιπλέον τηλέφωνα → σχόλια.
//    2) Τιμή      → περιέχει € (ή EUR / ευρώ) μαζί με αριθμό.
//    3) Email     → οτιδήποτε περιέχει '@' (π.χ. kostas@gmail.com).
//    4) Παιδικό   → "baby seat" με αριθμό πριν/μετά (κενό ή κολλητά).
//                   Σκέτο "baby seat" → 1.
//    5) Βαλίτσες  → "bag"/"bags" με αριθμό πριν/μετά (κενό ή κολλητά).
//    6) Άτομα     → αριθμός δίπλα στο "pax" ή "άτομα". 5+ → VAN.
//    7) Πτήση     → airline code 2 χαρακτ. + 2-4 ψηφία (π.χ. A3 691).
//    8) Μέρος     → περιέχει port / airport / λιμάνι / αεροδρόμιο.
//    9) Από/Προς  → παύλα "-" με λέξη πριν ΚΑΙ μετά.
//
// ── ΣΤΑΘΕΡΗ ΦΟΡΜΑ (ΥΠΟΧΡΕΩΤΙΚΟ #form στην 1η γραμμή) ─────────────────────────
//
//  Σειρά γραμμών (μετά το #form):
//    Από, Προς, Όνομα, Τηλ, Email, Τιμή, Πτήση/Πλοίο,
//    Άτομα, Βαλίτσες, Παιδικό κάθισμα, Σχόλια.
//  Κάθε γραμμή μπορεί να έχει ετικέτα-πρόθεμα (π.χ. "Τηλ 69...") που αφαιρείται,
//  ή μόνο την τιμή. Αν λείπει το #form → πάμε στους κανόνες (heuristics).

/// Αποτέλεσμα ανάλυσης ενός event. Όλα προαιρετικά.
class ParsedBooking {
  final String?   from;
  final String?   to;
  final String?   name;
  final String?   email;        // email πελάτη (ό,τι περιέχει @)
  final String?   phone;
  final String?   secondPhone;  // 2ο τηλέφωνο → πάει στα σχόλια
  final double?   price;
  final String?   flightOrShip;
  final int?      persons;
  final int?      luggage;      // βαλίτσες (bags/bag + αριθμός)
  final int?      childSeat;    // παιδικά καθίσματα (baby seat + αριθμός)
  final String?   vehicleType;  // 'van' αν 5+ άτομα, αλλιώς null
  final String?   note;
  final bool      usedForm; // true αν διαβάστηκε ως σταθερή φόρμα

  const ParsedBooking({
    this.from,
    this.to,
    this.name,
    this.email,
    this.phone,
    this.secondPhone,
    this.price,
    this.flightOrShip,
    this.persons,
    this.luggage,
    this.childSeat,
    this.vehicleType,
    this.note,
    this.usedForm = false,
  });

  bool get isEmpty =>
      (from == null || from!.isEmpty) &&
      (to == null || to!.isEmpty) &&
      (name == null || name!.isEmpty) &&
      phone == null &&
      price == null &&
      flightOrShip == null;
}

class CalendarEventParser {
  /// Κύρια είσοδος. Δέχεται τίτλο + περιγραφή + location του event.
  /// Τα συνδυάζει και επιστρέφει ό,τι κατάφερε να αναγνωρίσει.
  static ParsedBooking parse({
    String? title,
    String? description,
    String? location,
  }) {
    // Συγκεντρώνουμε όλες τις γραμμές (τίτλος πρώτος, μετά description).
    final lines = <String>[];
    if (title != null && title.trim().isNotEmpty) {
      lines.addAll(_splitLines(title));
    }
    if (description != null && description.trim().isNotEmpty) {
      lines.addAll(_splitLines(description));
    }

    // Αφαιρούμε τον ΥΠΟΧΡΕΩΤΙΚΟ #FORM marker (αν λείπει → δεν είναι φόρμα).
    bool hasFormMarker = false;
    if (lines.isNotEmpty &&
        lines.first.trim().toUpperCase().replaceAll(' ', '') == '#FORM') {
      hasFormMarker = true;
      lines.removeAt(0);
    }

    // ── 1) Σταθερή φόρμα — ΜΟΝΟ αν υπάρχει #form στην αρχή ──────────────────
    if (hasFormMarker) {
      final formResult = _tryForm(lines);
      if (formResult != null) return formResult;
    }

    // ── 2) Heuristics (κανόνες) ────────────────────────────────────────────
    return _heuristics(lines, location: location);
  }

  // ───────────────────────────────────────────────────────────────────────────
  // ΣΤΑΘΕΡΗ ΦΟΡΜΑ (υποχρεωτικό #form στην αρχή)
  // Σειρά γραμμών:
  //   0=Από 1=Προς 2=Όνομα 3=Τηλ 4=Email 5=Τιμή 6=Πτήση/Πλοίο
  //   7=Άτομα 8=Βαλίτσες 9=Παιδικό κάθισμα 10=Σχόλια (+ ό,τι ακολουθεί)
  // Κάθε γραμμή μπορεί να έχει ετικέτα-πρόθεμα (π.χ. "Τηλ 69...", "email a@b.gr").
  // Η ετικέτα αφαιρείται· μένει μόνο η τιμή. Κενές γραμμές παραλείπονται.
  // ───────────────────────────────────────────────────────────────────────────

  static ParsedBooking? _tryForm(List<String> lines) {
    // Καθάρισε κάθε γραμμή από την ετικέτα της (αν υπάρχει).
    final l = lines.map((e) => e.trim()).toList();

    String? at(int i) {
      if (i >= l.length) return null;
      final v = l[i].trim();
      return v.isEmpty ? null : v;
    }

    // Αφαιρεί γνωστή ετικέτα από την αρχή της γραμμής (π.χ. "τηλ", "email").
    String? strip(int i, List<String> labels) {
      final raw = at(i);
      if (raw == null) return null;
      var v = raw;
      for (final lab in labels) {
        final re = RegExp('^' + RegExp.escape(lab) + r'\s*[:\-]?\s*',
            caseSensitive: false);
        if (re.hasMatch(v)) { v = v.replaceFirst(re, '').trim(); break; }
      }
      return v.isEmpty ? null : v;
    }

    final from  = strip(0, ['από', 'απο', 'from']);
    final to    = strip(1, ['προς', 'to']);
    final name  = strip(2, ['όνομα', 'ονομα', 'name']);
    final phoneRaw = strip(3, ['τηλέφωνο', 'τηλεφωνο', 'τηλ', 'phone', 'tel']);
    final emailRaw = strip(4, ['email', 'e-mail', 'mail']);
    final priceRaw = strip(5, ['τιμή', 'τιμη', 'price']);
    final flight = strip(6, ['πτήση', 'πτηση', 'πλοίο', 'πλοιο',
        'πτήση η πλοίο', 'flight', 'ship']);
    final personsRaw = strip(7, ['άτομα', 'ατομα', 'pax', 'persons']);
    final bagsRaw = strip(8, ['βαλίτσες', 'βαλιτσες', 'bags', 'bag', 'luggage']);
    final seatRaw = strip(9, ['παιδικό κάθισμα', 'παιδικο καθισμα',
        'παιδικό', 'παιδικο', 'baby seat', 'babyseat']);

    final phone = phoneRaw != null ? _parsePhone(phoneRaw) : null;
    final email = emailRaw != null ? (_findEmail(emailRaw) ?? emailRaw) : null;
    final price = priceRaw != null ? _parsePrice(priceRaw) : null;
    final persons = personsRaw != null
        ? int.tryParse(_digits(personsRaw)) : null;

    // Βαλίτσες: είτε σκέτος αριθμός στη γραμμή, είτε με τη λέξη bag/bags.
    int? luggage;
    if (bagsRaw != null) {
      luggage = int.tryParse(_digits(bagsRaw)) ?? _findBags(bagsRaw);
    }

    // Παιδικό κάθισμα: αριθμός, ή με "baby seat", ή σκέτη η λέξη → 1.
    int? childSeat;
    if (seatRaw != null) {
      childSeat = int.tryParse(_digits(seatRaw)) ?? _findBabySeat(seatRaw);
    }

    final vehicleType = (persons != null && persons >= 5) ? 'van' : null;

    // Σχόλια: γραμμή 10 (index 10) και ό,τι ακολουθεί.
    final extra = <String>[];
    for (var i = 10; i < l.length; i++) {
      var line = l[i].trim();
      if (line.isEmpty) continue;
      // αφαίρεσε προαιρετική ετικέτα "Σχόλια"
      line = line.replaceFirst(
          RegExp(r'^(?:σχόλια|σχολια|comments?)\s*[:\-]?\s*',
              caseSensitive: false), '').trim();
      if (line.isNotEmpty) extra.add(line);
    }
    final note = extra.isEmpty ? null : extra.join('\n');

    return ParsedBooking(
      from: from,
      to: to,
      name: name,
      email: email,
      phone: phone,
      price: price,
      flightOrShip: flight,
      persons: persons,
      luggage: luggage,
      childSeat: childSeat,
      vehicleType: vehicleType,
      note: note,
      usedForm: true,
    );
  }

  // ───────────────────────────────────────────────────────────────────────────
  // HEURISTICS
  // ───────────────────────────────────────────────────────────────────────────

  static ParsedBooking _heuristics(List<String> lines, {String? location}) {
    String? phone, secondPhone, flight, name, from, to, email;
    double? price;
    int?    persons;
    int?    luggage;
    int?    childSeat;
    final placeHits = <String>[];      // γραμμές που μοιάζουν με «μέρος»
    final leftovers = <String>[];      // ό,τι δεν ταίριασε → σχόλια
    // Συλλογή τηλεφώνων με τύπο — η ανάθεση γίνεται στο τέλος ώστε τα κινητά
    // να έχουν προτεραιότητα για το κύριο πεδίο, τα σταθερά (αρχίζουν με 2)
    // να πάνε στο πεδίο μόνο αν ΔΕΝ υπάρχει κινητό, αλλιώς στα σχόλια.
    final mobilePhones   = <String>[];
    final landlinePhones = <String>[];

    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;

      // 0) Email — οποιοδήποτε token με '@' (π.χ. kostas@gmail.com)
      final em = _findEmail(line);
      if (em != null) {
        email ??= em;
        final rest = _stripToken(line, em).replaceAll(em, '').trim();
        if (rest.isNotEmpty) leftovers.add(rest);
        continue;
      }

      // 1) Τηλέφωνο (ολόκληρη γραμμή ή token μέσα στη γραμμή)
      final (ph, isLand) = _findPhoneTyped(line);
      if (ph != null) {
        if (isLand) {
          if (!landlinePhones.contains(ph)) landlinePhones.add(ph);
        } else {
          if (!mobilePhones.contains(ph)) mobilePhones.add(ph);
        }
        final rest = _stripToken(line, ph).trim();
        if (rest.isNotEmpty) leftovers.add(rest);
        continue;
      }

      // 2) Τιμή
      final pr = _parsePrice(line);
      if (pr != null && price == null && _looksLikePrice(line)) {
        price = pr;
        continue;
      }

      // 2.5) Παιδικό κάθισμα (baby seat) — έλεγχος ΠΡΙΝ τις βαλίτσες/άτομα.
      final bs = _findBabySeat(line);
      if (bs != null && childSeat == null) {
        childSeat = bs;
        final rest = line
            .replaceAll(RegExp(r'\d*\s*baby\s*seat\s*\d*',
                caseSensitive: false), '')
            .trim();
        if (rest.isNotEmpty) leftovers.add(rest);
        continue;
      }

      // 2.6) Βαλίτσες (bag/bags)
      final bg = _findBags(line);
      if (bg != null && luggage == null) {
        luggage = bg;
        final rest = line
            .replaceAll(RegExp(r'\d*\s*bags?\s*\d*',
                caseSensitive: false), '')
            .trim();
        if (rest.isNotEmpty) leftovers.add(rest);
        continue;
      }

      // 3) Άτομα (pax ή άτομα, πριν ή μετά)
      final px = _findPax(line);
      if (px != null && persons == null) {
        persons = px;
        final rest = line
            .replaceAll(
                RegExp(r'\d+\s*(?:pax|άτομα|ατομα|ατομο|άτομο)',
                    caseSensitive: false),
                '')
            .replaceAll(
                RegExp(r'(?:pax|άτομα|ατομα|ατομο|άτομο)\s*\d+',
                    caseSensitive: false),
                '')
            .trim();
        // μην πετάξεις τυχόν χρήσιμη υπόλοιπη πληροφορία (π.χ. από-προς)
        if (rest.isNotEmpty) {
          final dash = _splitDash(rest);
          if (dash != null) { from ??= dash.$1; to ??= dash.$2; }
          else {
            leftovers.add(rest);
          }
        }
        continue;
      }

      // 4) Πτήση
      final fl = _findFlight(line);
      if (fl != null && flight == null) {
        flight = fl;
        // Συχνά η ίδια γραμμή έχει και από-προς. Δοκίμασε.
        final dash = _splitDash(line);
        if (dash != null) { from ??= dash.$1; to ??= dash.$2; }
        continue;
      }

      // 6) Από/Προς με παύλα
      final dash = _splitDash(line);
      if (dash != null && (from == null && to == null)) {
        from = dash.$1;
        to   = dash.$2;
        continue;
      }

      // 5) Μέρος (port/airport/λιμάνι/αεροδρόμιο)
      if (_looksLikePlace(line)) {
        placeHits.add(line);
        continue;
      }

      leftovers.add(line);
    }

    // Αν δεν βρέθηκε «από» αλλά υπάρχει location του event → χρησιμοποίησέ το.
    if ((from == null || from.isEmpty) &&
        location != null && location.trim().isNotEmpty) {
      from = location.trim();
    }
    // Αν δεν βρέθηκε από/προς αλλά υπάρχουν place hits → πρώτο=Από, δεύτερο=Προς.
    if (from == null && placeHits.isNotEmpty) from = placeHits.first;
    if (to == null && placeHits.length > 1) to = placeHits[1];

    // ── Ανάθεση τηλεφώνων ──────────────────────────────────────────────────
    // Προτεραιότητα κύριου πεδίου: κινητό. Σταθερό (αρχίζει με 2) μπαίνει στο
    // πεδίο μόνο αν δεν υπάρχει κανένα κινητό. Τα υπόλοιπα → σχόλια.
    final extraPhones = <String>[];
    if (mobilePhones.isNotEmpty) {
      phone = mobilePhones.first;
      extraPhones.addAll(mobilePhones.skip(1)); // τυχόν 2ο κινητό
      extraPhones.addAll(landlinePhones);       // όλα τα σταθερά
    } else if (landlinePhones.isNotEmpty) {
      phone = landlinePhones.first;             // μόνο σταθερό υπάρχει
      extraPhones.addAll(landlinePhones.skip(1));
    }
    if (extraPhones.isNotEmpty) {
      secondPhone = extraPhones.first;          // 2ο τηλέφωνο → ειδικό χειρισμό
      // 3ο+ τηλέφωνα (σπάνιο) → σχόλια
      for (final p in extraPhones.skip(1)) {
        leftovers.add('📞 Τηλέφωνο: $p');
      }
    }

    // Όνομα: πρώτη ΣΥΝΤΟΜΗ γραμμή (1-4 λέξεις) που μοιάζει με όνομα.
    // Μεγαλύτερες/αβέβαιες γραμμές μένουν στα leftovers → πάνε στα σχόλια,
    // ώστε ο χρήστης να αποφασίσει αντί να μπει λάθος στο πεδίο «Όνομα».
    for (final cand in leftovers) {
      final words = cand.trim().split(RegExp(r'\s+')).length;
      if (words <= 4 && _looksLikeName(cand)) { name = cand; break; }
    }
    if (name != null) leftovers.remove(name);

    final note = leftovers.isEmpty ? null : leftovers.join('\n');

    // 5+ άτομα → VAN
    final vehicleType = (persons != null && persons >= 5) ? 'van' : null;

    return ParsedBooking(
      from: from,
      to: to,
      name: name,
      email: email,
      phone: phone,
      secondPhone: secondPhone,
      price: price,
      flightOrShip: flight,
      persons: persons,
      luggage: luggage,
      childSeat: childSeat,
      vehicleType: vehicleType,
      note: note,
      usedForm: false,
    );
  }

  // ───────────────────────────────────────────────────────────────────────────
  // ΚΑΝΟΝΕΣ (helpers)
  // ───────────────────────────────────────────────────────────────────────────

  /// Τηλέφωνο (αγνοώντας παρενθέσεις/κενά/παύλες — μετράμε μόνο ψηφία):
  ///   • Αρχίζει με 00 → σύνολο 13–16 ψηφία.            (κινητό/διεθνές)
  ///   • Αρχίζει με +  → 11–14 ψηφία μετά το +.          (κινητό/διεθνές)
  ///   • Αρχίζει με 69 → σύνολο 10 ψηφία.                (κινητό)
  ///   • Αρχίζει με 2  → σύνολο 10 ψηφία.                (σταθερό — landline)
  /// Επιστρέφει (καθαρό τηλέφωνο, isLandline) ή (null, false).
  static (String?, bool) _parsePhoneTyped(String s) {
    final t = s.trim();
    if (t.isEmpty) return (null, false);

    final plus = t.startsWith('+');
    final digits = t.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.isEmpty) return (null, false);

    if (plus) {
      if (digits.length >= 11 && digits.length <= 14) return ('+$digits', false);
      return (null, false);
    }

    if (digits.startsWith('00')) {
      if (digits.length >= 13 && digits.length <= 16) return (digits, false);
      return (null, false);
    }

    if (digits.startsWith('69') && digits.length == 10) return (digits, false);

    // Σταθερό: αρχίζει με 2, σύνολο 10 ψηφία.
    if (digits.startsWith('2') && digits.length == 10) return (digits, true);

    return (null, false);
  }

  /// Συμβατότητα: επιστρέφει μόνο το τηλέφωνο (ή null).
  static String? _parsePhone(String s) => _parsePhoneTyped(s).$1;

  /// Ψάχνει τηλέφωνο μέσα σε μια γραμμή που μπορεί να έχει κι άλλα.
  /// Επιστρέφει (τηλέφωνο, isLandline) ή (null, false).
  static (String?, bool) _findPhoneTyped(String line) {
    // ── Link WhatsApp (wa.me/χρτ.gg κ.λπ.): ό,τι ακολουθεί το "wa.me/" ΕΙΝΑΙ
    // το τηλέφωνο, μαζί με το "+" αν υπάρχει — π.χ. https://wa.me/+306936123322.
    // Ελέγχεται ΠΡΩΤΗ, πριν οτιδήποτε άλλο, γιατί είναι το πιο αξιόπιστο σημάδι.
    final waMatch =
        RegExp(r'wa\.me/\+?(\d[\d\s\-]{6,})', caseSensitive: false)
            .firstMatch(line);
    if (waMatch != null) {
      final digits = waMatch.group(1)!.replaceAll(RegExp(r'[\s\-]'), '');
      final withPlus = digits.startsWith('+') ? digits : '+$digits';
      final p = _parsePhoneTyped(withPlus);
      if (p.$1 != null) return p;
    }

    // Ολόκληρη γραμμή πρώτα.
    final whole = _parsePhoneTyped(line);
    if (whole.$1 != null) return whole;

    // Token-based: σπάσε σε κομμάτια και δοκίμασε καθένα + γειτονικά μαζί.
    final tokens = line.split(RegExp(r'\s+'));
    for (var i = 0; i < tokens.length; i++) {
      for (var span = 1; span <= 3 && i + span <= tokens.length; span++) {
        final chunk = tokens.sublist(i, i + span).join(' ');
        final p = _parsePhoneTyped(chunk);
        if (p.$1 != null) return p;
      }
    }
    return (null, false);
  }

  /// Συμβατότητα.
  static String? _findPhone(String line) => _findPhoneTyped(line).$1;

  /// Email: απλός κανόνας — κάτι@κάτι.κάτι. Επιστρέφει το πρώτο που θα βρει.
  static String? _findEmail(String line) {
    final m = RegExp(r'[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}')
        .firstMatch(line);
    return m?.group(0);
  }

  static String _stripToken(String line, String cleaned) {
    // Αφαίρεσε τα ψηφία/σύμβολα του τηλεφώνου από τη γραμμή για να μείνει το υπόλοιπο.
    return line.replaceAll(RegExp(r'[+\d()\-\s]{8,}'), ' ').trim();
  }

  /// Πτήση: airline code 2 χαρακτήρων (1ος γράμμα, 2ος γράμμα Ή ψηφίο) +
  /// αριθμός πτήσης 2-4 ψηφία. Σύνολο 5-6 χαρακτήρες αγνοώντας το κενό.
  /// Πιάνει: A3 691, FR1450, A3691, FR 1450, U2 1234, BA 999, EK0203.
  static String? _findFlight(String line) {
    final m = RegExp(r'\b([A-Za-z][A-Za-z0-9])\s?(\d{2,4})\b')
        .firstMatch(line);
    if (m == null) return null;
    final code = m.group(1)!;
    final nums = m.group(2)!;
    final total = code.length + nums.length; // 2 + (2..4) = 4..6
    if (total >= 5 && total <= 6) {
      return '${code.toUpperCase()} $nums';
    }
    return null;
  }

  /// Άτομα: αριθμός δίπλα σε "pax" ή "άτομα/ατομα", είτε πριν είτε μετά,
  /// με ή χωρίς κενό. Πιάνει: 8 pax, pax 8, 8pax, pax8, 8 άτομα, άτομα 8.
  static int? _findPax(String line) {
    final t = line.toLowerCase();
    // αριθμός ΠΡΙΝ τη λέξη
    var m = RegExp(r'(\d+)\s*(?:pax|άτομα|ατομα|ατομο|άτομο)')
        .firstMatch(t);
    m ??= RegExp(r'(?:pax|άτομα|ατομα|ατομο|άτομο)\s*(\d+)')
        .firstMatch(t); // αριθμός ΜΕΤΑ τη λέξη
    if (m == null) return null;
    return int.tryParse(m.group(1)!);
  }

  /// Βαλίτσες: αριθμός πριν ή μετά τη λέξη bag/bags (με κενό ή κολλητά).
  /// π.χ. "10bags", "10 bags", "bags 10", "bags10", "3 bag".
  static int? _findBags(String line) {
    final t = line.toLowerCase();
    var m = RegExp(r'(\d+)\s*bags?').firstMatch(t);   // αριθμός ΠΡΙΝ
    m ??= RegExp(r'bags?\s*(\d+)').firstMatch(t);      // αριθμός ΜΕΤΑ
    if (m == null) return null;
    return int.tryParse(m.group(1)!);
  }

  /// Παιδικό κάθισμα: αριθμός πριν/μετά το "baby seat" (κενό ή κολλητά).
  /// π.χ. "2 baby seat", "baby seat 2", "2babyseat". Σκέτο "baby seat" → 1.
  static int? _findBabySeat(String line) {
    final t = line.toLowerCase();
    if (!RegExp(r'baby\s*seat').hasMatch(t)) return null;
    var m = RegExp(r'(\d+)\s*baby\s*seat').firstMatch(t);   // αριθμός ΠΡΙΝ
    m ??= RegExp(r'baby\s*seat\s*(\d+)').firstMatch(t);      // αριθμός ΜΕΤΑ
    if (m == null) return 1; // σκέτο "baby seat" → 1
    return int.tryParse(m.group(1)!) ?? 1;
  }
  static bool _looksLikePlace(String line) {
    final t = line.toLowerCase();
    return t.contains('airport') ||
        t.contains('port') ||
        t.contains('λιμάνι') ||
        t.contains('λιμανι') ||
        t.contains('αεροδρόμιο') ||
        t.contains('αεροδρομιο');
  }

  /// Από/Προς: παύλα "-" με μη-κενό κείμενο πριν ΚΑΙ μετά.
  /// Επιστρέφει (from, to) ή null.
  static (String, String)? _splitDash(String line) {
    // Πρώτη παύλα με κείμενο εκατέρωθεν. Δέχεται "-", "–", "—".
    final m = RegExp(r'^(.*?\S)\s*[-–—]\s*(\S.*)$').firstMatch(line.trim());
    if (m == null) return null;
    var a = m.group(1)!.trim();
    var b = m.group(2)!.trim();
    if (a.isEmpty || b.isEmpty) return null;

    // Όριο «από»: έως 3 λέξεις πριν την παύλα, και ΟΧΙ σκέτος αριθμός
    // (π.χ. ώρα "10-12" → απόρριψη).
    if (RegExp(r'^\d+$').hasMatch(a)) return null;
    final aWords = a.split(RegExp(r'\s+'));
    if (aWords.length > 3) return null;

    // Όριο «προς»: είτε έως 3 λέξεις, είτε αριθμός έως 3 ΕΝΩΜΕΝΑ ψηφία
    // (π.χ. 153, 15, 8 — αλλά ΟΧΙ "1 5 3" χωριστά, ούτε 4+ ψηφία).
    final bWords = b.split(RegExp(r'\s+'));
    final bIsShortNumber = RegExp(r'^\d{1,3}$').hasMatch(b);
    final bIsLongNumber  = RegExp(r'^\d{4,}$').hasMatch(b);
    if (bIsLongNumber) return null; // π.χ. ώρα/μεγάλος αριθμός → όχι προορισμός
    if (!bIsShortNumber && bWords.length > 3) {
      b = bWords.take(3).join(' ');
    }

    return (a, b);
  }

  /// true αν η γραμμή έχει σαφή ένδειξη τιμής (€, EUR, ευρώ).
  static bool _looksLikePrice(String line) {
    final t = line.toLowerCase();
    return t.contains('€') || t.contains('eur') || t.contains('ευρώ') ||
        t.contains('ευρω') || _priceAfterEquals(line) != null;
  }

  /// Τιμή μετά από '=' (με ή χωρίς κενό), έως 3 ψηφία. π.χ. =53, = 153.
  static double? _priceAfterEquals(String line) {
    final m = RegExp(r'=\s*(\d{1,3})(?:[.,](\d{1,2}))?').firstMatch(line);
    if (m == null) return null;
    final intPart = m.group(1)!;
    final dec     = m.group(2);
    final str = dec == null ? intPart : '$intPart.$dec';
    return double.tryParse(str);
  }

  /// "€110.00" / "€56" / "110 EUR" / "1.234,56" → double. Χρειάζεται σύμβολο/λέξη.
  static double? _parsePrice(String? s) {
    if (s == null) return null;
    if (!_looksLikePrice(s)) return null;
    // Προτεραιότητα: τιμή μετά από '=' (πιο συγκεκριμένο).
    final eq = _priceAfterEquals(s);
    if (eq != null) return eq;
    var t = s.replaceAll(RegExp(r'[^\d.,]'), '');
    if (t.isEmpty) return null;
    if (t.contains(',') && t.contains('.')) {
      t = t.replaceAll('.', '').replaceAll(',', '.'); // 1.234,56 → 1234.56
    } else if (t.contains(',')) {
      t = t.replaceAll(',', '.');
    }
    return double.tryParse(t);
  }

  /// Όνομα: κείμενο με γράμματα, χωρίς να μοιάζει με μέρος, χωρίς πολλά ψηφία.
  static bool _looksLikeName(String line) {
    final t = line.trim();
    if (t.isEmpty) return false;
    if (_looksLikePlace(t)) return false;
    if (_looksLikePrice(t)) return false;
    // Πάρα πολλά ψηφία → μάλλον δεν είναι όνομα.
    final digitCount = RegExp(r'\d').allMatches(t).length;
    if (digitCount > 2) return false;
    // Πρέπει να έχει τουλάχιστον 2 γράμματα.
    final letterCount = RegExp(r'[A-Za-zΑ-Ωα-ωΆ-Ώά-ώ]').allMatches(t).length;
    return letterCount >= 2;
  }

  static String _digits(String s) =>
      RegExp(r'\d+').firstMatch(s)?.group(0) ?? '';

  static List<String> _splitLines(String s) =>
      s.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
}
