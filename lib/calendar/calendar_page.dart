// lib/calendar/calendar_page.dart
//
// Σελίδα Ημερολογίου (μόνο admin/master με calendarEnabled).
//
//  • Μηνιαία προβολή (table_calendar) με αριθμό συμβάντων σε κάθε μέρα.
//  • Tap σε μέρα → ο μήνας μένει, από κάτω εμφανίζεται αναλυτικά η ημέρα.
//  • Κάθε συμβάν → κουμπί "Μετατροπή σε νέα δουλειά" (φόρμα με prefill).
//  • Σήμα "✓ Έγινε δουλειά" για όσα έχουν ήδη μετατραπεί (τοπικά).
//  • Read-only στο Google — ένα fetch ανά μήνα (με cache). Μηδέν write Firestore.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:table_calendar/table_calendar.dart';

import '../jobs/job_form.dart';
import '../jobs/job_shared_widgets.dart';
import '../jobs/places_service.dart';
import '../jobs/job_model.dart';
import '../jobs/saved_job_service.dart';
import 'calendar_event_parser.dart';
import 'converted_events_store.dart';
import 'google_calendar_service.dart';

class CalendarPage extends StatefulWidget {
  final String adminUid;
  final String adminName;
  final bool   isMaster;

  const CalendarPage({
    super.key,
    required this.adminUid,
    this.adminName = '',
    this.isMaster  = false,
  });

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  static const _purple = Color(0xFF5E35B1);

  DateTime _focusedDay  = DateTime.now();
  DateTime _selectedDay = DateTime.now();

  // Μορφή ημερολογίου: μήνας (μεγάλο) ή εβδομάδα (όταν τραβάς πάνω το panel).
  CalendarFormat _calendarFormat = CalendarFormat.month;
  final DraggableScrollableController _sheetCtrl =
      DraggableScrollableController();

  bool   _connected = false;
  bool   _loading   = true;
  String? _error;

  // Cache ανά μήνα: 'yyyy-mm' → events. Αποφεύγει επανάληψη fetch.
  final Map<String, List<CalendarEvent>> _monthCache = {};
  // Ομαδοποίηση ανά ημέρα για τον τρέχοντα μήνα.
  Map<DateTime, List<CalendarEvent>> _eventsByDay = {};
  // Τοπικά μετατρεμμένα eventIds.
  Map<String, ConvertState> _convertStates = {};

  @override
  void initState() {
    super.initState();
    _sheetCtrl.addListener(_onSheetMove);
    _init();
  }

  @override
  void dispose() {
    _sheetCtrl.removeListener(_onSheetMove);
    _sheetCtrl.dispose();
    super.dispose();
  }

  // Όταν το panel ημέρας ανεβαίνει πάνω από ένα όριο → μήνας γίνεται εβδομάδα.
  void _onSheetMove() {
    if (!_sheetCtrl.isAttached) return;
    final size = _sheetCtrl.size;
    final wantWeek = size > 0.55; // πάνω από ~55% ύψος → εβδομάδα
    final newFormat =
        wantWeek ? CalendarFormat.week : CalendarFormat.month;
    if (newFormat != _calendarFormat) {
      setState(() => _calendarFormat = newFormat);
    }
  }

  Future<void> _init() async {
    await initializeDateFormatting('el_GR', null);
    // Σιωπηλός έλεγχος (τοπικό flag) — ΧΩΡΙΣ κανένα popup. Αν έχει γίνει
    // σύνδεση «μία φορά», φέρνει τα events απευθείας από το Cloud Function.
    final ok = await GoogleCalendarService.instance.isConnected();
    _connected = ok;
    if (ok) {
      await _loadMonth(_focusedDay);
    }
    if (mounted) setState(() => _loading = false);
  }

  String _monthKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}';

  Future<void> _connect() async {
    setState(() { _loading = true; _error = null; });
    final ok = await GoogleCalendarService.instance.connect();
    if (!ok) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Η σύνδεση ημερολογίου ακυρώθηκε ή απέτυχε.';
        });
      }
      return;
    }
    _connected = true;
    await _loadMonth(_focusedDay);
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadMonth(DateTime month, {bool force = false}) async {
    final key = _monthKey(month);
    _convertStates = await ConvertedEventsStore.instance.statesMap();

    if (!force && _monthCache.containsKey(key)) {
      _rebuildDayMap(_monthCache[key]!);
      return;
    }

    final first = DateTime(month.year, month.month, 1);
    final next  = DateTime(month.year, month.month + 1, 1);
    try {
      final events = await GoogleCalendarService.instance.fetchEvents(
        from: first, to: next,
      );
      _monthCache[key] = events;
      _rebuildDayMap(events);
    } on CalendarAuthException {
      // Χάθηκε η σύνδεση (π.χ. ανακλήθηκε η πρόσβαση) → δείξε κουμπί σύνδεσης.
      if (mounted) {
        setState(() {
          _connected = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Σφάλμα φόρτωσης: $e');
    }
  }

  void _rebuildDayMap(List<CalendarEvent> events) {
    final map = <DateTime, List<CalendarEvent>>{};
    for (final ev in events) {
      final k = ev.dayKey;
      map.putIfAbsent(k, () => []).add(ev);
    }
    if (mounted) setState(() => _eventsByDay = map);
  }

  List<CalendarEvent> _eventsForDay(DateTime day) {
    final k = DateTime(day.year, day.month, day.day);
    return _eventsByDay[k] ?? const [];
  }

  // ─── Μετατροπή event → δουλειά ──────────────────────────────────────────────

  Future<void> _convertToJob(CalendarEvent ev) async {
    final parsed = CalendarEventParser.parse(
      title:       ev.title,
      description: ev.description,
      location:    ev.location,
    );

    // Από/Προς ως ελεύθερο κείμενο (PlacePick.description — ο χρήστης
    // μπορεί να το ξαναεπιλέξει στη φόρμα για να πάρει συντεταγμένες).
    PlacePick? fromPick;
    PlacePick? toPick;
    if (parsed.from != null && parsed.from!.trim().isNotEmpty) {
      fromPick = PlacePick(description: parsed.from!.trim());
    }
    if (parsed.to != null && parsed.to!.trim().isNotEmpty) {
      toPick = PlacePick(description: parsed.to!.trim());
    }

    // ── Δίχτυ ασφαλείας ───────────────────────────────────────────────────
    // Ό,τι ο parser ΔΕΝ ταξινόμησε με σιγουριά → στα σχόλια, ώστε να μη χαθεί
    // και ο χρήστης να αποφασίσει (π.χ. αβέβαιο όνομα/περιοχή/άλλη πληροφορία).
    final noteParts = <String>[];

    // 1) Δεύτερο τηλέφωνο (αν βρέθηκε) → στα σχόλια.
    if (parsed.secondPhone != null && parsed.secondPhone!.isNotEmpty) {
      noteParts.add('📞 2ο τηλέφωνο: ${parsed.secondPhone}');
    }

    // 2) Leftovers του parser (ό,τι δεν ταίριασε σε κανέναν κανόνα).
    if (parsed.note != null && parsed.note!.trim().isNotEmpty) {
      noteParts.add('❓ Προς έλεγχο: ${parsed.note!.trim()}');
    }

    // 3) Αν ΔΕΝ βρέθηκε «Από» ούτε «Προς», βάζουμε ολόκληρο το αρχικό κείμενο
    //    του event στα σχόλια ώστε ο χρήστης να το συμπληρώσει χειροκίνητα.
    if (fromPick == null && toPick == null) {
      final rawParts = <String>[];
      if (ev.title.trim().isNotEmpty) rawParts.add(ev.title.trim());
      if (ev.description != null && ev.description!.trim().isNotEmpty) {
        rawParts.add(ev.description!.trim());
      }
      if (ev.location != null && ev.location!.trim().isNotEmpty) {
        rawParts.add('📍 ${ev.location!.trim()}');
      }
      if (rawParts.isNotEmpty) {
        noteParts.add('📋 Από ημερολόγιο:\n${rawParts.join('\n')}');
      }
    }

    // Όχημα: van αν 5+ άτομα (από parser) Ή αν το event είναι πράσινο Basil.
    final vehicleType =
        (ev.isBasilGreen || parsed.vehicleType == 'van') ? 'van' : null;

    final prefill = JobPrefill(
      from:         fromPick,
      to:           toPick,
      price:        parsed.price,
      clientName:   parsed.name,
      clientPhone:  parsed.phone,
      clientEmail:  parsed.email,
      scheduledAt:  ev.allDay ? null : ev.start,
      persons:      parsed.persons,
      luggage:      parsed.luggage,
      childSeatCount: parsed.childSeat,
      vehicleType:  vehicleType,
      note:         noteParts.isEmpty ? null : noteParts.join('\n\n'),
      flightOrShip: parsed.flightOrShip,
    );

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => JobFormPage(
          adminUid:  widget.adminUid,
          adminName: widget.adminName,
          isMaster:  widget.isMaster,
          prefill:   prefill,
          calendarEventId: ev.id,
          // Αποστολή → σήμα «Στάλθηκε».
          onCreated: () async {
            if (ev.id.isEmpty) return;
            await ConvertedEventsStore.instance.markSent(ev.id);
            _convertStates =
                await ConvertedEventsStore.instance.statesMap();
            if (mounted) setState(() {});
          },
          // Αποθήκευση (draft) → σήμα «Αποθηκεύτηκε».
          onSavedDraft: () async {
            if (ev.id.isEmpty) return;
            await ConvertedEventsStore.instance.markSaved(ev.id);
            _convertStates =
                await ConvertedEventsStore.instance.statesMap();
            if (mounted) setState(() {});
          },
        ),
      ),
    );
  }

  // ─── Μαζική μετατροπή όλων των συμβάντων της ημέρας ─────────────────────────

  /// Φτιάχνει τα σχόλια (note) από τον parser — ίδια λογική με _convertToJob.
  String? _buildNote(CalendarEvent ev, ParsedBooking parsed,
      {required bool hasFrom, required bool hasTo}) {
    final noteParts = <String>[];
    if (parsed.secondPhone != null && parsed.secondPhone!.isNotEmpty) {
      noteParts.add('📞 2ο τηλέφωνο: ${parsed.secondPhone}');
    }
    if (parsed.note != null && parsed.note!.trim().isNotEmpty) {
      noteParts.add('❓ Προς έλεγχο: ${parsed.note!.trim()}');
    }
    if (!hasFrom && !hasTo) {
      final rawParts = <String>[];
      if (ev.title.trim().isNotEmpty) rawParts.add(ev.title.trim());
      if (ev.description != null && ev.description!.trim().isNotEmpty) {
        rawParts.add(ev.description!.trim());
      }
      if (ev.location != null && ev.location!.trim().isNotEmpty) {
        rawParts.add('📍 ${ev.location!.trim()}');
      }
      if (rawParts.isNotEmpty) {
        noteParts.add('📋 Από ημερολόγιο:\n${rawParts.join('\n')}');
      }
    }
    return noteParts.isEmpty ? null : noteParts.join('\n\n');
  }

  /// Picker: διάλεξε ΠΟΙΑ events θα μετατραπούν, μετά ρώτα τρόπο.
  Future<void> _pickEventsForDay() async {
    final dayEvents = _eventsForDay(_selectedDay);
    if (dayEvents.isEmpty) return;

    // Προεπιλογή: τσεκαρισμένα όσα ΔΕΝ έχουν μετατραπεί ακόμα.
    final selected = <String>{
      for (final ev in dayEvents)
        if ((_convertStates[ev.id] ?? ConvertState.none) == ConvertState.none)
          ev.id,
    };

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          return Container(
            margin: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFFFAF6EC),
              borderRadius: BorderRadius.circular(20),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Κίτρινο header
                Container(
                  width: double.infinity,
                  color: Colors.amber,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 16),
                  child: Row(children: [
                    const Icon(Icons.checklist_rounded,
                        color: Colors.black87, size: 22),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text('Επιλογή συμβάντων',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 18,
                              color: Colors.black87)),
                    ),
                    Text('${selected.length}/${dayEvents.length}',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            color: Colors.black87)),
                  ]),
                ),
                // Επιλογή όλων / κανενός
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Row(children: [
                    TextButton.icon(
                      icon: const Icon(Icons.done_all_rounded, size: 18),
                      label: const Text('Όλα'),
                      onPressed: () => setSheet(() =>
                          selected.addAll(dayEvents.map((e) => e.id))),
                    ),
                    TextButton.icon(
                      icon: const Icon(Icons.remove_done_rounded, size: 18),
                      label: const Text('Κανένα'),
                      onPressed: () => setSheet(selected.clear),
                    ),
                  ]),
                ),
                // Λίστα events
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    itemCount: dayEvents.length,
                    itemBuilder: (_, i) {
                      final ev = dayEvents[i];
                      final st = _convertStates[ev.id] ?? ConvertState.none;
                      final done = st != ConvertState.none;
                      final checked = selected.contains(ev.id);
                      final timeStr = ev.allDay
                          ? 'Ολοήμερο'
                          : DateFormat('HH:mm').format(ev.start);
                      return Card(
                        elevation: 0,
                        margin: const EdgeInsets.only(bottom: 6),
                        color: checked ? Colors.amber.shade50 : Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(
                              color: checked
                                  ? Colors.amber
                                  : Colors.grey.shade300),
                        ),
                        child: CheckboxListTile(
                          value: checked,
                          activeColor: Colors.amber.shade800,
                          controlAffinity: ListTileControlAffinity.leading,
                          onChanged: (v) => setSheet(() {
                            if (v == true) {
                              selected.add(ev.id);
                            } else {
                              selected.remove(ev.id);
                            }
                          }),
                          title: Row(children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: _purple.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(timeStr,
                                  style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: _purple)),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(ev.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                      color: Colors.black87)),
                            ),
                          ]),
                          subtitle: done
                              ? Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    st == ConvertState.sent
                                        ? '✓ Έγινε δουλειά'
                                        : '✓ Αποθηκεύτηκε',
                                    style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: st == ConvertState.sent
                                            ? Colors.green.shade700
                                            : Colors.blue.shade700),
                                  ),
                                )
                              : null,
                        ),
                      );
                    },
                  ),
                ),
                // Κουμπιά
                Padding(
                  padding: EdgeInsets.fromLTRB(
                      16, 4, 16, 16 + MediaQuery.of(ctx).viewPadding.bottom),
                  child: Row(children: [
                    Expanded(
                      child: AppButtonTonal(
                          label: 'Άκυρο',
                          onPressed: () => Navigator.pop(ctx, false)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: AppButton(
                          label: 'Συνέχεια (${selected.length})',
                          icon: Icons.arrow_forward_rounded,
                          color: Colors.amber,
                          fg: Colors.black,
                          onPressed: selected.isEmpty
                              ? null
                              : () => Navigator.pop(ctx, true)),
                    ),
                  ]),
                ),
              ],
            ),
          );
        },
      ),
    );

    if (confirmed != true) return;
    final chosen =
        dayEvents.where((ev) => selected.contains(ev.id)).toList();
    if (chosen.isEmpty) return;
    await _askModeAndConvert(chosen);
  }

  /// Ρωτά «με έλεγχο / χωρίς έλεγχο» και εκτελεί τη μετατροπή.
  Future<void> _askModeAndConvert(List<CalendarEvent> events) async {
    if (events.isEmpty) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        titlePadding: EdgeInsets.zero,
        title: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: const BoxDecoration(
            color: Colors.amber,
            borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
          ),
          child: Row(children: const [
            Icon(Icons.playlist_add_check_rounded,
                color: Colors.black87, size: 22),
            SizedBox(width: 10),
            Expanded(
              child: Text('Όλα σε δουλειές;',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                      color: Colors.black87)),
            ),
          ]),
        ),
        contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${events.length} συμβάντα θα μετατραπούν σε δουλειές.'),
            const SizedBox(height: 14),
            const Text('Πώς να γίνει;',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text(
                '• Με έλεγχο: ανοίγει η φόρμα ένα-ένα.\n'
                '• Χωρίς έλεγχο: όσα έχουν Από & Προς αποθηκεύονται '
                'αυτόματα· όσα λείπει βασικό στοιχείο ανοίγουν στη φόρμα.',
                style: TextStyle(fontSize: 12.5, color: Colors.black54)),
          ],
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        actions: [
          Row(children: [
            Expanded(
              child: AppButton(
                  label: 'Με έλεγχο',
                  icon: Icons.checklist_rounded,
                  color: const Color(0xFF1E8E3E),
                  fg: Colors.white,
                  onPressed: () => Navigator.pop(ctx, 'review')),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: AppButton(
                  label: 'Χωρίς έλεγχο',
                  icon: Icons.bolt_rounded,
                  color: Colors.amber,
                  fg: Colors.black,
                  onPressed: () => Navigator.pop(ctx, 'auto')),
            ),
          ]),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: AppButtonTonal(
                label: 'Άκυρο', onPressed: () => Navigator.pop(ctx)),
          ),
        ],
      ),
    );

    if (choice == 'review') {
      await _convertSequential(events);
    } else if (choice == 'auto') {
      await _convertAuto(events);
    }
  }

  /// «Με έλεγχο»: ανοίγει τη φόρμα διαδοχικά για κάθε συμβάν.
  Future<void> _convertSequential(List<CalendarEvent> events) async {
    for (final ev in events) {
      if (!mounted) return;
      // Ξαναέλεγξε μήπως μετατράπηκε στο μεταξύ.
      final st = _convertStates[ev.id] ?? ConvertState.none;
      if (st != ConvertState.none) continue;
      await _convertToJob(ev); // ανοίγει τη φόρμα και περιμένει να κλείσει
    }
  }

  /// «Χωρίς έλεγχο»: πλήρη (Από+Προς) → μαζική αποθήκευση· ελλιπή → φόρμα.
  Future<void> _convertAuto(List<CalendarEvent> events) async {
    final needForm = <CalendarEvent>[];
    int savedCount = 0;

    for (final ev in events) {
      final parsed = CalendarEventParser.parse(
        title:       ev.title,
        description: ev.description,
        location:    ev.location,
      );
      final hasFrom = parsed.from != null && parsed.from!.trim().isNotEmpty;
      final hasTo   = parsed.to   != null && parsed.to!.trim().isNotEmpty;

      if (!hasFrom || !hasTo) {
        needForm.add(ev); // λείπει βασικό → φόρμα μετά
        continue;
      }

      // Πλήρες → φτιάξε Job draft και αποθήκευσε κατευθείαν.
      final vehicleType =
          (ev.isBasilGreen || parsed.vehicleType == 'van') ? 'van' : 'any';
      final draft = Job(
        id:            '',
        from:          parsed.from!.trim(),
        to:            parsed.to!.trim(),
        price:         parsed.price ?? 0,
        persons:       parsed.persons ?? 1,
        luggage:       parsed.luggage ?? 0,
        childSeat:     (parsed.childSeat ?? 0) > 0,
        childSeatCount: parsed.childSeat ?? 0,
        vehicleType:   vehicleType,
        createdBy:     widget.adminUid,
        createdByName: widget.adminName,
        scheduledAt:   ev.allDay ? null : ev.start,
        createdAt:     DateTime.now(),
        clientName:    parsed.name,
        clientPhone:   parsed.phone,
        clientEmail:   parsed.email,
        flightOrShip:  parsed.flightOrShip,
        note:          _buildNote(ev, parsed, hasFrom: hasFrom, hasTo: hasTo),
      );

      try {
        await SavedJobService.save(draft,
            ownerUid: widget.adminUid, ownerName: widget.adminName,
            calendarEventId: ev.id);
        await ConvertedEventsStore.instance.markSaved(ev.id);
        savedCount++;
      } catch (_) {/* αν αποτύχει ένα, συνέχισε με τα υπόλοιπα */}
    }

    _convertStates = await ConvertedEventsStore.instance.statesMap();
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(savedCount > 0
              ? '💾 Αποθηκεύτηκαν $savedCount δουλειές'
                  '${needForm.isNotEmpty ? " · ${needForm.length} χρειάζονται συμπλήρωση" : ""}'
              : 'Καμία αυτόματη αποθήκευση — όλα χρειάζονται συμπλήρωση.'),
          backgroundColor: const Color(0xFF1565C0),
          duration: const Duration(seconds: 3),
        ),
      );
    }

    // Τα ελλιπή → φόρμα ένα-ένα.
    if (needForm.isNotEmpty) {
      await _convertSequential(needForm);
    }
  }

  // ─── UI ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F6F8),
      appBar: AppBar(
        backgroundColor: _purple,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Row(children: [
          Icon(Icons.calendar_month_rounded, size: 22),
          SizedBox(width: 10),
          Text('Ημερολόγιο', style: TextStyle(fontWeight: FontWeight.bold)),
        ]),
        actions: [
          IconButton(
            tooltip: 'Σωστός τρόπος γραφής',
            icon: const Icon(Icons.help_outline_rounded),
            onPressed: _showFormatHelp,
          ),
          if (_connected)
            IconButton(
              tooltip: 'Ανανέωση',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: () async {
                setState(() { _loading = true; _error = null; });
                _monthCache.clear(); // πέτα όλο το cache → σίγουρα φρέσκα
                await _loadMonth(_focusedDay, force: true);
                if (mounted) setState(() => _loading = false);
              },
            ),
          if (_connected)
            IconButton(
              tooltip: 'Αποσύνδεση ημερολογίου',
              icon: const Icon(Icons.link_off_rounded),
              onPressed: _confirmDisconnect,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _purple))
          : !_connected
              ? _buildConnectPrompt()
              : _buildCalendar(),
    );
  }

  // ─── Αποσύνδεση ημερολογίου ────────────────────────────────────────────────
  Future<void> _confirmDisconnect() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
        title: const Text('Αποσύνδεση ημερολογίου;'),
        content: const Text(
            'Θα διαγραφεί η πρόσβαση της εφαρμογής στο Google Calendar. '
            'Μπορείς να ξανασυνδεθείς όποτε θες.'),
        actions: [
          AppButtonTonal(label: 'Άκυρο', onPressed: () => Navigator.pop(ctx, false)),
          AppButton(label: 'Αποσύνδεση', color: Colors.red, onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
    );
    if (yes != true || !mounted) return;

    setState(() => _loading = true);
    await GoogleCalendarService.instance.disconnect();
    if (!mounted) return;
    setState(() {
      _connected = false;
      _loading   = false;
      _monthCache.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Το ημερολόγιο αποσυνδέθηκε.'),
    ));
  }

  // Το πρότυπο που αντιγράφεται για paste στο ημερολόγιο.
  static const String _formTemplate =
      '#form\n'
      'Από \n'
      'Προς \n'
      'Όνομα \n'
      'Τηλ \n'
      'Email \n'
      'Τιμή \n'
      'Πτήση η πλοίο \n'
      'Άτομα \n'
      'Βαλίτσες \n'
      'Παιδικό κάθισμα \n'
      'Σχόλια ';

  void _showFormatHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18)),
        titlePadding: const EdgeInsets.fromLTRB(20, 20, 12, 0),
        title: Row(children: [
          const Icon(Icons.event_available_rounded, color: _purple),
          const SizedBox(width: 10),
          const Expanded(
            child: Text('Σωστός τρόπος γραφής',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.pop(ctx),
          ),
        ]),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Για να αναγνωρίζεται σίγουρα το ραντεβού, γράψε #form στην '
                'πρώτη γραμμή και μετά κάθε πληροφορία σε δική της γραμμή με '
                'αυτή τη σειρά:',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 14),

              // Πίνακας σειρών της φόρμας
              _helpRow('1η γραμμή', '#form (υποχρεωτικό)'),
              _helpRow('2η γραμμή', 'Από (αφετηρία)'),
              _helpRow('3η γραμμή', 'Προς (προορισμός)'),
              _helpRow('4η γραμμή', 'Όνομα πελάτη'),
              _helpRow('5η γραμμή', 'Τηλέφωνο'),
              _helpRow('6η γραμμή', 'Email'),
              _helpRow('7η γραμμή', 'Τιμή (με €)'),
              _helpRow('8η γραμμή', 'Πτήση / Πλοίο'),
              _helpRow('9η γραμμή', 'Άτομα'),
              _helpRow('10η γραμμή', 'Βαλίτσες'),
              _helpRow('11η γραμμή', 'Παιδικό κάθισμα'),
              _helpRow('12η γραμμή', 'Σχόλια'),

              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _purple.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: _purple.withValues(alpha: 0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: const [
                      Icon(Icons.star_rounded,
                          size: 16, color: _purple),
                      SizedBox(width: 6),
                      Text('Συμβουλή',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: _purple,
                              fontSize: 13)),
                    ]),
                    const SizedBox(height: 6),
                    const Text(
                      'Δίπλα από κάθε λέξη γράψε την τιμή (π.χ. «Τηλ '
                      '6936123322») ή σβήσε τη λέξη και γράψε μόνο την τιμή. '
                      'Και τα δύο δουλεύουν.',
                      style: TextStyle(fontSize: 12.5),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),
              Row(children: [
                const Text('Πρότυπο για αντιγραφή:',
                    style: TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 13)),
                const Spacer(),
                AppButtonTonal(
                  label: 'Αντιγραφή',
                  icon: Icons.copy_rounded,
                  fg: _purple,
                  onPressed: () async {
                    await Clipboard.setData(
                        const ClipboardData(text: _formTemplate));
                    if (ctx.mounted) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(
                          content: Text('Αντιγράφηκε! Κάνε paste στο '
                              'ημερολόγιό σου.'),
                          backgroundColor: _purple,
                          duration: Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                ),
              ]),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text(
                  _formTemplate,
                  style: TextStyle(
                      fontSize: 12.5,
                      height: 1.5,
                      fontFamily: 'monospace'),
                ),
              ),

              const SizedBox(height: 14),
              Text(
                'Αν δεν χρησιμοποιήσεις #form, η εφαρμογή προσπαθεί να '
                'καταλάβει μόνη της τηλέφωνα, email, πτήσεις, άτομα, βαλίτσες '
                'κ.λπ. Ό,τι δεν είναι σίγουρο μπαίνει στα σχόλια για έλεγχο.',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _purple),
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Κατάλαβα'),
          ),
        ],
      ),
    );
  }

  Widget _helpRow(String left, String right) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        SizedBox(
          width: 78,
          child: Text(left,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.bold,
                  color: _purple)),
        ),
        const Icon(Icons.arrow_right_rounded, size: 18, color: Colors.grey),
        const SizedBox(width: 4),
        Expanded(
          child: Text(right, style: const TextStyle(fontSize: 13)),
        ),
      ]),
    );
  }

  Widget _buildConnectPrompt() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.calendar_month_rounded,
                size: 72, color: _purple),
            const SizedBox(height: 20),
            const Text(
              'Σύνδεση Google Ημερολογίου',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            Text(
              'Συνδέσου με τον Google λογαριασμό σου για να δεις τα ραντεβού '
              'σου και να τα μετατρέπεις σε δουλειές.',
              style: TextStyle(fontSize: 14, color: Colors.grey[600]),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: _purple,
                padding: const EdgeInsets.symmetric(
                    horizontal: 24, vertical: 14),
              ),
              icon: const Icon(Icons.link_rounded),
              label: const Text('Σύνδεση ημερολογίου'),
              onPressed: _connect,
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!,
                  style: const TextStyle(color: Colors.red, fontSize: 13),
                  textAlign: TextAlign.center),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCalendar() {
    return Stack(
      children: [
        // ── Ημερολόγιο (μεγάλο, καταλαμβάνει την οθόνη) ───────────────────
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Align(
              alignment: Alignment.topCenter,
              child: TableCalendar<CalendarEvent>(
                firstDay: DateTime.utc(2020, 1, 1),
                lastDay:  DateTime.utc(2035, 12, 31),
                focusedDay: _focusedDay,
                locale: 'el_GR',
                rowHeight: 72, // ψηλά κελιά — άπλωμα του μήνα στον διαθέσιμο χώρο
                daysOfWeekHeight: 30,
                calendarFormat: _calendarFormat,
                startingDayOfWeek: StartingDayOfWeek.monday,
                availableCalendarFormats: const {
                  CalendarFormat.month: 'Μήνας',
                  CalendarFormat.week:  'Εβδομάδα',
                },
                selectedDayPredicate: (d) => isSameDay(_selectedDay, d),
                eventLoader: _eventsForDay,
                calendarStyle: const CalendarStyle(
                  isTodayHighlighted: false, // το χειρίζεται ο todayBuilder
                  markersMaxCount: 0,
                  cellMargin: EdgeInsets.all(2),
                ),
                headerStyle: const HeaderStyle(
                  formatButtonVisible: false,
                  titleCentered: true,
                  titleTextStyle: TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold),
                ),
                onDaySelected: (selected, focused) {
                  setState(() {
                    _selectedDay = selected;
                    _focusedDay  = focused;
                  });
                  // Άνοιξε το panel ημέρας σε μεσαίο ύψος.
                  if (_sheetCtrl.isAttached) {
                    _sheetCtrl.animateTo(
                      0.5,
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOut,
                    );
                  }
                },
                onPageChanged: (focused) async {
                  _focusedDay = focused;
                  setState(() => _loading = true);
                  await _loadMonth(focused);
                  if (mounted) setState(() => _loading = false);
                },
                calendarBuilders: CalendarBuilders<CalendarEvent>(
                  defaultBuilder: (context, day, focusedDay) =>
                      _dayCell(day, events: _eventsForDay(day)),
                  outsideBuilder: (context, day, focusedDay) =>
                      _dayCell(day, events: const [], outside: true),
                  todayBuilder: (context, day, focusedDay) => _dayCell(
                    day,
                    events: _eventsForDay(day),
                    circleColor: _purple.withValues(alpha: 0.25),
                  ),
                  selectedBuilder: (context, day, focusedDay) => _dayCell(
                    day,
                    events: _eventsForDay(day),
                    circleColor: _purple,
                    numberColor: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ),

        // ── Draggable panel ημέρας (τράβα τη λαβή πάνω/κάτω) ───────────────
        DraggableScrollableSheet(
          controller: _sheetCtrl,
          initialChildSize: 0.32,
          minChildSize: 0.12,
          maxChildSize: 0.88,
          snap: true,
          snapSizes: const [0.12, 0.32, 0.5, 0.88],
          builder: (context, scrollController) {
            final dayEvents = _eventsForDay(_selectedDay);
            return Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(20)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.12),
                    blurRadius: 12,
                    offset: const Offset(0, -3),
                  ),
                ],
              ),
              child: Column(
                children: [
                  // Λαβή — σύρσιμη πάνω/κάτω για μεγέθυνση/σμίκρυνση panel.
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onVerticalDragUpdate: (d) {
                      if (!_sheetCtrl.isAttached) return;
                      final h = MediaQuery.of(context).size.height;
                      final delta = (d.primaryDelta ?? 0) / h;
                      final next =
                          (_sheetCtrl.size - delta).clamp(0.12, 0.88);
                      _sheetCtrl.jumpTo(next);
                    },
                    onVerticalDragEnd: (d) {
                      if (!_sheetCtrl.isAttached) return;
                      final v = d.primaryVelocity ?? 0;
                      const snaps = [0.12, 0.32, 0.5, 0.88];
                      double target;
                      if (v < -250) {
                        // γρήγορο πάνω → επόμενο μεγαλύτερο snap
                        target = snaps.firstWhere(
                            (s) => s > _sheetCtrl.size + 0.02,
                            orElse: () => snaps.last);
                      } else if (v > 250) {
                        // γρήγορο κάτω → επόμενο μικρότερο snap
                        target = snaps.lastWhere(
                            (s) => s < _sheetCtrl.size - 0.02,
                            orElse: () => snaps.first);
                      } else {
                        // αργό → πιο κοντινό snap
                        target = snaps.reduce((a, b) =>
                            (a - _sheetCtrl.size).abs() <
                                    (b - _sheetCtrl.size).abs()
                                ? a
                                : b);
                      }
                      _sheetCtrl.animateTo(target,
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOut);
                    },
                    child: Container(
                      color: Colors.transparent,
                      width: double.infinity,
                      padding: const EdgeInsets.only(top: 10, bottom: 8),
                      alignment: Alignment.center,
                      child: Container(
                        width: 44,
                        height: 5,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade400,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ),
                  // Header ημέρας
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(children: [
                      const Icon(Icons.event_note_rounded,
                          size: 18, color: _purple),
                      const SizedBox(width: 8),
                      Text(
                        _formatDayHeader(_selectedDay),
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.bold),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 3),
                        decoration: BoxDecoration(
                          color: _purple.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text('${dayEvents.length} συμβάντα',
                            style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: _purple)),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 8),
                  const Divider(height: 1),
                  // Κουμπί «Επιλογή» (αν υπάρχουν συμβάντα)
                  if (dayEvents.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                      child: SizedBox(
                        width: double.infinity,
                        child: AppButton(
                          label: 'Επιλογή σε δουλειές',
                          icon: Icons.checklist_rounded,
                          color: Colors.amber,
                          fg: Colors.black,
                          onPressed: _pickEventsForDay,
                        ),
                      ),
                    ),
                  Expanded(
                    child: dayEvents.isEmpty
                        ? ListView(
                            controller: scrollController,
                            children: [
                              const SizedBox(height: 40),
                              Center(
                                child: Text(
                                    'Κανένα συμβάν αυτή τη μέρα',
                                    style: TextStyle(
                                        color: Colors.grey[500])),
                              ),
                            ],
                          )
                        : ListView.builder(
                            controller: scrollController,
                            padding: const EdgeInsets.fromLTRB(
                                12, 10, 12, 24),
                            itemCount: dayEvents.length,
                            itemBuilder: (ctx, i) =>
                                _eventCard(dayEvents[i]),
                          ),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  // Κελί ημέρας: αριθμός (προαιρετικά σε κύκλο) πάνω, badge κάτω — ποτέ επικάλυψη.
  Widget _dayCell(
    DateTime day, {
    required List<CalendarEvent> events,
    bool outside = false,
    Color? circleColor,
    Color? numberColor,
  }) {
    final txtColor = numberColor ??
        (outside ? Colors.grey.shade400 : Colors.black87);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: circleColor == null
                ? null
                : BoxDecoration(color: circleColor, shape: BoxShape.circle),
            child: Text(
              '${day.day}',
              style: TextStyle(
                fontSize: 16,
                color: txtColor,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(height: 4),
          if (events.isNotEmpty)
            _countBadge(events.length)
          else
            const SizedBox(height: 18), // κρατάει σταθερό ύψος
        ],
      ),
    );
  }

  Widget _countBadge(int count) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: _purple,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$count',
        style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _eventCard(CalendarEvent ev) {
    final state = _convertStates[ev.id] ?? ConvertState.none;
    final converted = state != ConvertState.none;
    final isSaved = state == ConvertState.saved;
    final badgeColor = isSaved ? Colors.blue : Colors.green;
    final badgeText  = isSaved ? 'Αποθηκεύτηκε' : 'Στάλθηκε';
    final badgeIcon  = isSaved ? Icons.bookmark_rounded : Icons.check_rounded;
    final timeStr = ev.allDay
        ? 'Ολοήμερο'
        : '${ev.start.hour.toString().padLeft(2, '0')}:'
          '${ev.start.minute.toString().padLeft(2, '0')}';

    return Card(
      elevation: 1,
      margin: const EdgeInsets.only(bottom: 10),
      color: Colors.white,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: converted ? badgeColor.shade300 : Colors.grey.shade300,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── ΑΠΑΛΟ ΚΙΤΡΙΝΟ HEADER (ώρα + τίτλος + σήμανση) ────────────
          Container(
            width: double.infinity,
            color: const Color(0xFFFAEEDA),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(timeStr,
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: _purple)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(ev.title,
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87)),
              ),
              if (converted)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: badgeColor.shade300),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(badgeIcon, size: 13, color: badgeColor.shade700),
                      const SizedBox(width: 3),
                      Text(badgeText,
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: badgeColor.shade700)),
                    ]),
                  ),
                  InkWell(
                    onTap: () => _clearMark(ev),
                    borderRadius: BorderRadius.circular(20),
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.close_rounded,
                          size: 16, color: Colors.black54),
                    ),
                  ),
                ]),
            ]),
          ),
          // ── BODY ──────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (ev.location != null && ev.location!.isNotEmpty) ...[
              Row(children: [
                Icon(Icons.place_rounded,
                    size: 14, color: Colors.grey[500]),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(ev.location!,
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey[700])),
                ),
              ]),
            ],
            if (ev.description != null && ev.description!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                ev.description!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
            ],
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: converted
                  ? AppButtonTonal(
                      label: isSaved ? 'Άνοιγμα ξανά' : 'Ξανά δουλειά',
                      icon: Icons.refresh_rounded,
                      onPressed: () => _convertToJob(ev),
                    )
                  : AppButton(
                      label: 'Μετατροπή σε νέα δουλειά',
                      icon: Icons.add_road_rounded,
                      color: Colors.amber,
                      fg: Colors.black,
                      onPressed: () => _convertToJob(ev),
                    ),
            ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Σβήσιμο σήμανσης (admin/master) — με επιβεβαίωση.
  Future<void> _clearMark(CalendarEvent ev) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Αφαίρεση σήμανσης;'),
        content: const Text(
            'Το συμβάν θα εμφανίζεται ξανά σαν να μην έχει μετατραπεί. '
            'Οι δουλειές που τυχόν έχεις ήδη φτιάξει ΔΕΝ διαγράφονται.'),
        actions: [
          AppButtonTonal(label: 'Άκυρο', onPressed: () => Navigator.pop(ctx, false)),
          AppButton(label: 'Αφαίρεση', color: _purple, onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
    );
    if (ok != true) return;
    await ConvertedEventsStore.instance.unmark(ev.id);
    _convertStates = await ConvertedEventsStore.instance.statesMap();
    if (mounted) setState(() {});
  }

  String _formatDayHeader(DateTime d) {
    const months = [
      'Ιαν', 'Φεβ', 'Μαρ', 'Απρ', 'Μάι', 'Ιουν',
      'Ιουλ', 'Αυγ', 'Σεπ', 'Οκτ', 'Νοε', 'Δεκ'
    ];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }
}
