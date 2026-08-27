// lib/calendar/google_calendar_page.dart
//
// Οθόνη Google Calendar — ΝΕΑ διάταξη:
//  • Το ημερολόγιο του μήνα πιάνει σχεδόν ΟΛΗ την οθόνη (shouldFillViewport)
//  • Τα events της ημέρας ζουν σε ΣΥΡΤΑΡΙ (DraggableScrollableSheet) κάτω:
//      - κλειστό: φαίνεται μικρό (τίτλος ημέρας + πρώτα events)
//      - τραβάς πάνω: ανεβαίνει σχεδόν μέχρι την κορυφή, αφήνοντας ορατό
//        ένα μικρό κομμάτι του ημερολογίου
//  • Κουκκίδες: μέχρι 4, μεγαλύτερες (7px), με «+Ν» όταν υπάρχουν περισσότερα
//    (κίτρινη = ΔΕΝ έχει μετατραπεί, πράσινη = έχει μετατραπεί)
//  • Safe-area κάτω: η λίστα αφήνει χώρο για το navigation bar του Android
//
// Read-only προς το Google Calendar (καμία εγγραφή). Χρησιμοποιεί τα
// υπάρχοντα GoogleCalendarService και ConvertedEventsStore — καμία αλλαγή
// στη λογική τους. Δουλεύει ίδια σε Android και Web.

import 'package:flutter/material.dart';
import 'package:table_calendar/table_calendar.dart';

import '../app_theme.dart';
import '../jobs/job_form.dart';
import '../jobs/places_service.dart';
import 'calendar_event_parser.dart';
import 'converted_events_store.dart';
import 'google_calendar_service.dart';

class GoogleCalendarPage extends StatefulWidget {
  final String adminUid;
  final String adminName;
  final bool   isMaster;

  const GoogleCalendarPage({
    super.key,
    required this.adminUid,
    this.adminName = '',
    this.isMaster   = false,
  });

  @override
  State<GoogleCalendarPage> createState() => _GoogleCalendarPageState();
}

class _GoogleCalendarPageState extends State<GoogleCalendarPage> {
  DateTime _focusedMonth = DateTime.now();
  DateTime _selectedDay  = DateTime.now();

  bool _loading = true;
  bool _connected = false;
  String? _error;
  List<CalendarEvent> _monthEvents = [];
  final Map<String, bool> _convertedCache = {};

  // ── Μαζική μετατροπή ──────────────────────────────────────────────────────
  // Λειτουργία επιλογής: διαλέγεις πολλά events (ακόμη και από διαφορετικές
  // ημέρες — τα ids κρατιούνται για όλο τον μήνα) και μετά ανοίγει η φόρμα
  // δουλειάς μία-μία, στο καπάκι: σώζεις τη μία → ανοίγει αμέσως η επόμενη.
  bool _selectMode = false;
  final Set<String> _selectedIds = {};
  bool _converting = false;

  // Μεγέθη συρταριού (ποσοστά ύψους οθόνης).
  static const double _sheetMin = 0.30;
  static const double _sheetMax = 0.92;

  // Ύψος της κάτω μπάρας ενεργειών — για padding στη λίστα ώστε να μην
  // κρύβεται η τελευταία κάρτα από κάτω.
  static const double _actionBarH = 74;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    final connected = await GoogleCalendarService.instance.isConnected();
    if (!connected) {
      if (mounted) setState(() { _connected = false; _loading = false; });
      return;
    }
    try {
      final start = DateTime(_focusedMonth.year, _focusedMonth.month, 1);
      final end   = DateTime(_focusedMonth.year, _focusedMonth.month + 1, 1);
      final events = await GoogleCalendarService.instance
          .fetchEvents(from: start, to: end);

      for (final e in events) {
        _convertedCache[e.id] =
            await ConvertedEventsStore.instance.isConverted(e.id);
      }

      if (!mounted) return;
      setState(() {
        _connected   = true;
        _monthEvents = events;
        _loading     = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _connected = true;
        _error     = 'Δεν ήταν δυνατή η φόρτωση events — δοκίμασε refresh.';
        _loading   = false;
      });
    }
  }

  Future<void> _connect() async {
    setState(() => _loading = true);
    final ok = await GoogleCalendarService.instance.connect();
    if (!ok) {
      if (mounted) {
        setState(() { _loading = false; _error = 'Η σύνδεση απέτυχε.'; });
      }
      return;
    }
    await _load();
  }

  // Απλή αναγνώριση «μοιάζει με μεταφορά» — βέλος/λέξεις-κλειδί/πτήση.
  bool _looksLikeTransfer(CalendarEvent e) {
    final text = '${e.title} ${e.description ?? ""} ${e.location ?? ""}'
        .toLowerCase();
    const keywords = [
      '→', '->', '-', 'airport', 'αεροδρ', 'transfer', 'μεταφορ',
      'pickup', 'παραλαβ', 'flight', 'πτήση', 'πτηση',
    ];
    return keywords.any(text.contains);
  }

  /// Επιστρέφει true αν όντως δημιουργήθηκε δουλειά (χρειάζεται για την ουρά).
  Future<bool> _openConvertForm(CalendarEvent e) async {
    final parsed = CalendarEventParser.parse(
      title: e.title, description: e.description, location: e.location,
    );

    // Το from/to του parser είναι ελεύθερο κείμενο (χωρίς συντεταγμένες).
    // Το βάζουμε ΚΑΤΕΥΘΕΙΑΝ στα πεδία «Από»/«Προς» ως PlacePick χωρίς lat/lng
    // — πριν πήγαινε μόνο στη σημείωση και έπρεπε να το ξαναγράψεις με το
    // χέρι. Ο χρήστης πατάει το πεδίο και διαλέγει την ακριβή διεύθυνση από
    // το autocomplete όποτε χρειάζεται υπολογισμό διαδρομής.
    final created = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => JobFormPage(
        adminUid:  widget.adminUid,
        adminName: widget.adminName,
        isMaster:  widget.isMaster,
        calendarEventId: e.id,
        // Εναλλακτικό «σήμα» μετατροπής: αν η φόρμα χρειαστεί να κλείσει
        // ενώ έχει ανοίξει popup διεκδίκησης από πάνω της (αποστολή στον
        // εαυτό μου), η τιμή επιστροφής χάνεται. Το onCreated καλείται
        // ΠΑΝΤΑ μετά την επιτυχή δημιουργία, οπότε το event μαρκάρεται
        // σωστά και στις δύο περιπτώσεις.
        onCreated: () async {
          await ConvertedEventsStore.instance.markConverted(e.id);
          if (mounted) setState(() => _convertedCache[e.id] = true);
        },
        prefill: JobPrefill(
          from: (parsed.from != null && parsed.from!.trim().isNotEmpty)
              ? PlacePick(description: parsed.from!.trim())
              : null,
          to: (parsed.to != null && parsed.to!.trim().isNotEmpty)
              ? PlacePick(description: parsed.to!.trim())
              : null,
          clientName:   parsed.name,
          clientPhone:  parsed.phone,
          price:        parsed.price,
          scheduledAt:  e.start,
          persons:      parsed.persons,
          luggage:      parsed.luggage,
          // Το από/προς ΔΕΝ ξαναγράφεται στη σημείωση — μπήκε στα πεδία.
          note: parsed.note,
          flightOrShip:   parsed.flightOrShip,
          vehicleType:    parsed.vehicleType,
          childSeatCount: parsed.childSeat,
        ),
      ),
    ));

    if (created == true) {
      await ConvertedEventsStore.instance.markConverted(e.id);
      if (mounted) setState(() => _convertedCache[e.id] = true);
      return true;
    }
    return false;
  }

  // ── Λειτουργία επιλογής ───────────────────────────────────────────────────

  void _enterSelectMode([String? firstId]) {
    setState(() {
      _selectMode = true;
      if (firstId != null) _selectedIds.add(firstId);
    });
  }

  void _exitSelectMode() {
    setState(() { _selectMode = false; _selectedIds.clear(); });
  }

  void _toggleSelect(String id) {
    setState(() {
      if (!_selectedIds.remove(id)) _selectedIds.add(id);
      // Αν άδειασε η επιλογή, μένουμε σε select mode — ο χρήστης βγαίνει με ✕.
    });
  }

  void _toggleSelectAllDay(List<CalendarEvent> dayEvents) {
    final ids = dayEvents.map((e) => e.id).toList();
    final allSelected = ids.every(_selectedIds.contains);
    setState(() {
      if (allSelected) {
        _selectedIds.removeAll(ids);
      } else {
        _selectedIds.addAll(ids);
      }
    });
  }

  // ── Η ουρά: μία-μία οι φόρμες, στο καπάκι ────────────────────────────────

  Future<void> _runConvertQueue() async {
    final queue = _monthEvents
        .where((e) => _selectedIds.contains(e.id))
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    if (queue.isEmpty) return;

    setState(() { _selectMode = false; _converting = true; });

    int done = 0;
    int index = 0;
    for (final e in queue) {
      index++;
      if (!mounted) break;
      final ok = await _openConvertForm(e);
      if (ok) {
        done++;
        continue;
      }
      // Βγήκε χωρίς αποθήκευση — ρωτάμε αν συνεχίζουμε στο επόμενο.
      if (index >= queue.length) break;
      if (!mounted) break;
      final cont = await _askContinue(index, queue.length);
      if (!cont) break;
    }

    if (!mounted) return;
    setState(() { _converting = false; _selectedIds.clear(); });
    await _showQueueSummary(done, queue.length);
  }

  Future<bool> _askContinue(int index, int total) async {
    final c = AppColors.of(context);
    final res = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: c.card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.pause_circle_outline_rounded, size: 34, color: c.amberDeep),
            const SizedBox(height: 10),
            Text('Δεν αποθηκεύτηκε',
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700, color: c.textMain)),
            const SizedBox(height: 4),
            Text('Απομένουν ${total - index} από $total events.',
                style: TextStyle(fontSize: 13, color: c.textFaint)),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: c.amber,
                  foregroundColor: c.onAmber,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Παράλειψη και συνέχεια',
                    style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: c.textFaint,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Διακοπή'),
              ),
            ),
          ]),
        ),
      ),
    );
    return res ?? false;
  }

  Future<void> _showQueueSummary(int done, int total) async {
    if (!mounted) return;
    final c = AppColors.of(context);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 14),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(
              done == total
                  ? Icons.check_circle_rounded
                  : Icons.info_outline_rounded,
              size: 38,
              color: done == total ? const Color(0xFF97C459) : c.amberDeep,
            ),
            const SizedBox(height: 10),
            Text(
              done == 0
                  ? 'Δεν μετατράπηκε καμία'
                  : 'Μετατράπηκαν $done από $total',
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w700, color: c.textMain),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: c.amber,
                  foregroundColor: c.onAmber,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('ΟΚ',
                    style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  /// Επεξηγηματικό popup: τα χρώματα του Google Calendar + η κατάσταση
  /// «μετατράπηκε σε δουλειά».
  void _showColorLegend(BuildContext context, AppColors c) {
    showDialog(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: c.card,
        title: Text('Χρώματα ημερολογίου',
            style: TextStyle(color: c.textMain, fontWeight: FontWeight.w800)),
        content: SizedBox(
          width: 320,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Η ΔΙΚΗ ΣΟΥ σύμβαση χρωμάτων ──
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: c.amberSoft,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Container(
                          width: 14, height: 14,
                          decoration: const BoxDecoration(
                            color: Color(0xFF0B8043), // Basil
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text('Πράσινο (Βασιλικός) = Βαν',
                              style: TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w700,
                                  color: c.textMain)),
                        ),
                      ]),
                      const SizedBox(height: 8),
                      Row(children: [
                        Container(
                          width: 14, height: 14,
                          decoration: const BoxDecoration(
                            color: Color(0xFF039BE5), // Peacock
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text('Μπλε (Peacock/Blueberry) = Ταξί',
                              style: TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w700,
                                  color: c.textMain)),
                        ),
                      ]),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // ── Κατάσταση μετατροπής ──
                Row(children: [
                  Container(
                    width: 14, height: 14,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: c.textFaint, width: 2),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                        'Δαχτυλίδι (τρύπα στη μέση) = έχει ήδη '
                        'μετατραπεί σε δουλειά',
                        style: TextStyle(fontSize: 13.5, color: c.textMain)),
                  ),
                ]),
                const SizedBox(height: 14),
                Text('Όλα τα χρώματα Google Calendar',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: c.textFaint)),
                const SizedBox(height: 4),
                Text(
                    'Το Google Calendar αναγνωρίζει ΜΟΝΟ αυτά τα 11 επίσημα '
                    'χρώματα. Αν το Samsung Calendar δείχνει μια απόχρωση '
                    'πιο κοντά σε κοβάλτιο, στο παρασκήνιο είναι ΠΑΛΙ ένα '
                    'από τα παρακάτω — το Samsung απλώς το ζωγραφίζει λίγο '
                    'διαφορετικά.',
                    style: TextStyle(fontSize: 12, color: c.textFaint)),
                const SizedBox(height: 10),
                for (final entry in _googleEventColors.entries)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(children: [
                      Container(
                        width: 16, height: 16,
                        decoration: BoxDecoration(
                          color: entry.value,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(_googleColorNames[entry.key] ?? '',
                          style:
                              TextStyle(fontSize: 13, color: c.textMain)),
                    ]),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(),
            child: Text('Κατάλαβα',
                style:
                    TextStyle(color: c.amberDeep, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Scaffold(
      backgroundColor: c.scaffold,
      appBar: _selectMode
          ? AppBar(
              backgroundColor: c.amberSoft,
              foregroundColor: c.amberDeep,
              elevation: 0,
              leading: IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: _exitSelectMode,
                tooltip: 'Άκυρο',
              ),
              title: Text(
                _selectedIds.isEmpty
                    ? 'Επίλεξε events'
                    : '${_selectedIds.length} επιλεγμένα',
                style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: c.amberDeep),
              ),
              actions: [
                TextButton(
                  onPressed: () => _toggleSelectAllDay(_currentDayEvents()),
                  style: TextButton.styleFrom(foregroundColor: c.amberDeep),
                  child: const Text('Όλα της ημέρας',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                ),
              ],
            )
          : AppBar(
              title: const Text('Google Calendar'),
              backgroundColor: c.scaffold,
              foregroundColor: c.textMain,
              elevation: 0,
              actions: [
                IconButton(
                  tooltip: 'Τι σημαίνει κάθε χρώμα',
                  icon: Icon(Icons.info_outline_rounded, color: c.textFaint),
                  onPressed: () => _showColorLegend(context, c),
                ),
                if (_connected && _monthEvents.isNotEmpty)
                  IconButton(
                    onPressed: _converting ? null : () => _enterSelectMode(),
                    icon: Icon(Icons.checklist_rounded, color: c.textFaint),
                    tooltip: 'Μαζική μετατροπή',
                  ),
                if (_connected)
                  IconButton(
                    onPressed: _load,
                    icon: Icon(Icons.refresh_rounded, color: c.textFaint),
                    tooltip: 'Ανανέωση',
                  ),
              ],
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : !_connected
              ? _connectPrompt(c)
              : _content(c),
    );
  }

  Widget _connectPrompt(AppColors c) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.calendar_month_rounded, size: 48, color: c.textFaint),
          const SizedBox(height: 16),
          Text('Σύνδεσε το Google Calendar',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: c.textMain)),
          const SizedBox(height: 6),
          Text(
            'Read-only πρόσβαση — βλέπεις τα events σου\nκαι τα μετατρέπεις σε δουλειές όποτε θες.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: c.textFaint),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _connect,
            icon: const Icon(Icons.link_rounded),
            label: const Text('Σύνδεση'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Colors.red)),
          ],
        ]),
      ),
    );
  }

  // ── Νέα διάταξη: full-screen ημερολόγιο + συρτάρι events ─────────────────

  Widget _content(AppColors c) {
    final byDay = <DateTime, List<CalendarEvent>>{};
    for (final e in _monthEvents) {
      (byDay[e.dayKey] ??= []).add(e);
    }
    final selKey = DateTime(_selectedDay.year, _selectedDay.month, _selectedDay.day);
    final dayEvents = byDay[selKey] ?? const <CalendarEvent>[];

    return LayoutBuilder(builder: (context, constraints) {
      final h = constraints.maxHeight;
      return Stack(children: [
        // Ημερολόγιο: πιάνει τον χώρο ΠΑΝΩ από το κλειστό συρτάρι.
        Positioned(
          left: 0, right: 0, top: 0,
          height: h * (1 - _sheetMin) + 8,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
            child: Container(
              decoration: BoxDecoration(
                color:        c.card,
                borderRadius: BorderRadius.circular(16),
                border:       Border.all(color: c.cardBorder, width: 0.8),
              ),
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: TableCalendar<CalendarEvent>(
                // Η εβδομάδα ξεκινά ΔΕΥΤΕΡΑ (προεπιλογή είναι Κυριακή).
                startingDayOfWeek: StartingDayOfWeek.monday,
                firstDay:   DateTime.utc(2023, 1, 1),
                lastDay:    DateTime.utc(2035, 12, 31),
                focusedDay: _focusedMonth,
                currentDay: DateTime.now(),
                shouldFillViewport: true, // γεμίζει όλο το διαθέσιμο ύψος
                selectedDayPredicate: (d) => isSameDay(d, _selectedDay),
                eventLoader: (day) {
                  final key = DateTime(day.year, day.month, day.day);
                  return byDay[key] ?? const [];
                },
                onDaySelected: (selected, focused) => setState(() {
                  _selectedDay  = selected;
                  _focusedMonth = focused;
                }),
                onPageChanged: (focused) {
                  setState(() => _focusedMonth = focused);
                  _load();
                },
                headerStyle: HeaderStyle(
                  formatButtonVisible: false,
                  titleCentered:       true,
                  titleTextStyle: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: c.textMain),
                  leftChevronIcon:  Icon(Icons.chevron_left_rounded,  color: c.textFaint, size: 22),
                  rightChevronIcon: Icon(Icons.chevron_right_rounded, color: c.textFaint, size: 22),
                ),
                daysOfWeekStyle: DaysOfWeekStyle(
                  weekdayStyle: TextStyle(fontSize: 11, color: c.textFaint),
                  weekendStyle: TextStyle(fontSize: 11, color: c.textFaint),
                ),
                calendarStyle: CalendarStyle(
                  outsideDaysVisible: false,
                  defaultTextStyle:   TextStyle(fontSize: 14, color: c.textMain),
                  weekendTextStyle:   const TextStyle(fontSize: 14, color: Color(0xFF993C1D)),
                ),
                calendarBuilders: CalendarBuilders<CalendarEvent>(
                  selectedBuilder: (ctx, day, _) =>
                      _dayCellBox(c, day, selected: true),
                  todayBuilder: (ctx, day, _) =>
                      _dayCellBox(c, day, selected: false),
                  // Έως 8 κουκκίδες σε ΔΥΟ σειρές (4+4), μεγαλύτερες (8px)·
                  // «+Ν» αν υπάρχουν κι άλλες.
                  markerBuilder: (context, day, events) {
                    if (events.isEmpty) return null;
                    final shown = events.take(8).toList();
                    final extra = events.length - shown.length;
                    return Positioned(
                      bottom: 3,
                      child: SizedBox(
                        width: 46,
                        child: Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 2.5, runSpacing: 2.5,
                          children: [
                            ...shown.map((e) {
                              final converted = _convertedCache[e.id] ?? false;
                              final col = _eventColor(e, c);
                              // Το ΧΡΩΜΑ δηλώνει πλέον το ημερολόγιο Google.
                              // Το «έγινε δουλειά» το δείχνει το ΣΧΗΜΑ:
                              // γεμάτη κουκκίδα = εκκρεμεί, δαχτυλίδι
                              // (κούφια) = έχει ήδη μετατραπεί.
                              return Container(
                                width: 8, height: 8,
                                decoration: BoxDecoration(
                                  color: converted ? Colors.transparent : col,
                                  border: converted
                                      ? Border.all(color: col, width: 2)
                                      : null,
                                  shape: BoxShape.circle,
                                ),
                              );
                            }),
                            if (extra > 0)
                              Text('+$extra',
                                  style: TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.w700,
                                      color: c.textFaint)),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),

        // Συρτάρι events — τραβιέται μέχρι σχεδόν την κορυφή.
        DraggableScrollableSheet(
          minChildSize:     _sheetMin,
          initialChildSize: _sheetMin,
          maxChildSize:     _sheetMax,
          snap: true,
          snapSizes: const [_sheetMin, _sheetMax],
          builder: (context, scrollCtrl) {
            final safeBottom = MediaQuery.of(context).padding.bottom;
            return Container(
              decoration: BoxDecoration(
                color: c.card,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(22)),
                border: Border.all(color: c.cardBorder, width: 0.8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.10),
                    blurRadius: 14,
                    offset: const Offset(0, -3),
                  ),
                ],
              ),
              child: ListView(
                controller: scrollCtrl,
                padding: EdgeInsets.fromLTRB(
                    14,
                    8,
                    14,
                    16 +
                        (safeBottom > 0 ? safeBottom : 10) +
                        // Χώρος για την μπάρα «Μετατροπή N σε δουλειές», ώστε
                        // να μην κρύβεται η τελευταία κάρτα από κάτω.
                        (_selectMode ? _actionBarH : 0)),
                children: [
                  // Χερούλι
                  Center(
                    child: Container(
                      width: 42, height: 5,
                      margin: const EdgeInsets.only(bottom: 10),
                      decoration: BoxDecoration(
                        color: c.textFaint.withValues(alpha: 0.45),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                  Text(
                    '${_weekdayDate(_selectedDay)} · ${dayEvents.length} '
                    '${dayEvents.length == 1 ? "event" : "events"}',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: c.textMain),
                  ),
                  const SizedBox(height: 10),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(_error!,
                          style: const TextStyle(color: Colors.red)),
                    ),
                  if (dayEvents.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      child: Center(
                        child: Text('Κανένα event αυτή την ημέρα',
                            style:
                                TextStyle(fontSize: 13, color: c.textFaint)),
                      ),
                    )
                  else
                    ...dayEvents.map((e) => _eventCard(c, e)),
                ],
              ),
            );
          },
        ),

        // ── Κάτω μπάρα: «Μετατροπή N σε δουλειές» ──────────────────────────
        // Μπαίνει ΤΕΛΕΥΤΑΙΑ στο Stack ώστε να είναι πάνω από το συρτάρι, και
        // σέβεται το navigation bar του Android μέσω SafeArea.
        if (_selectMode)
          Positioned(
            left: 0, right: 0, bottom: 0,
            child: SafeArea(
              top: false,
              child: Container(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                decoration: BoxDecoration(
                  color: c.card,
                  border: Border(top: BorderSide(color: c.cardBorder, width: 0.8)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.12),
                      blurRadius: 16,
                      offset: const Offset(0, -4),
                    ),
                  ],
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _selectedIds.isEmpty ? null : _runConvertQueue,
                    icon: const Icon(Icons.compare_arrows_rounded, size: 18),
                    label: Text(
                      _selectedIds.isEmpty
                          ? 'Επίλεξε τουλάχιστον ένα event'
                          : 'Μετατροπή ${_selectedIds.length} '
                            '${_selectedIds.length == 1 ? "σε δουλειά" : "σε δουλειές"}',
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: c.amber,
                      foregroundColor: c.onAmber,
                      disabledBackgroundColor: c.cardBorder,
                      disabledForegroundColor: c.textFaint,
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24)),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ]);
    });
  }

  // ── Χρώμα event = το χρώμα του Google Calendar ────────────────────────────
  // Η επίσημη παλέτα «event colors» του Google (colorId 1–11). Αν το event
  // δεν έχει δικό του colorId, κληρονομεί το χρώμα του ημερολογίου — εκεί
  // πέφτουμε στο amber της εφαρμογής.
  static const Map<String, Color> _googleEventColors = {
    '1':  Color(0xFF7986CB), // Lavender
    '2':  Color(0xFF33B679), // Sage
    '3':  Color(0xFF8E24AA), // Grape
    '4':  Color(0xFFE67C73), // Flamingo
    '5':  Color(0xFFF6BF26), // Banana
    '6':  Color(0xFFF4511E), // Tangerine
    '7':  Color(0xFF039BE5), // Peacock
    '8':  Color(0xFF616161), // Graphite
    '9':  Color(0xFF3F51B5), // Blueberry
    '10': Color(0xFF0B8043), // Basil
    '11': Color(0xFFD50000), // Tomato
  };

  /// Ίδια σειρά με το _googleEventColors — ονόματα όπως τα δίνει η Google.
  static const Map<String, String> _googleColorNames = {
    '1':  'Lavender',
    '2':  'Sage',
    '3':  'Grape',
    '4':  'Flamingo',
    '5':  'Banana',
    '6':  'Tangerine',
    '7':  'Peacock',
    '8':  'Graphite',
    '9':  'Blueberry',
    '10': 'Basil',
    '11': 'Tomato',
  };

  Color _eventColor(CalendarEvent e, AppColors c) =>
      _googleEventColors[e.colorId ?? ''] ?? c.amber;


  // ── Κελί ημέρας: ΟΛΟ το κουτί επιλέγεται, όχι μόνο ο αριθμός ─────────────
  // Πριν το selected/today ήταν κύκλος γύρω από τον αριθμό και οι κουκκίδες
  // έμεναν απ' έξω. Τώρα το φόντο γεμίζει το κελί (radius 12), οπότε μπαίνουν
  // ΜΕΣΑ και η ημερομηνία και οι τελίτσες. Όλα τα χρώματα είναι theme-aware
  // (amberSoft / amber / amberDeep) → δουλεύει σε ανοιχτό και σκούρο.
  static Widget _dayCellBox(AppColors c, DateTime day,
      {required bool selected}) {
    return Container(
      margin: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: c.amberSoft,
        borderRadius: BorderRadius.circular(12),
        border: selected ? Border.all(color: c.amber, width: 1.6) : null,
      ),
      // ⚠️ Ο αριθμός ΚΕΝΤΡΑΡΙΣΜΕΝΟΣ, ακριβώς όπως στα κανονικά κελιά. Με
      // topCenter «πηδούσε» ψηλότερα μόνο στο επιλεγμένο/σημερινό κελί και
      // η γραμμή έδειχνε στραβή (φαίνεται έντονα στο web, όπου τα κελιά
      // είναι ψηλά). Οι κουκκίδες μπαίνουν από πάνω με Positioned bottom.
      alignment: Alignment.center,
      child: Text(
        '${day.day}',
        style: TextStyle(
          fontSize: 14,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
          color: c.amberDeep,
        ),
      ),
    );
  }

  List<CalendarEvent> _currentDayEvents() {
    final key = DateTime(_selectedDay.year, _selectedDay.month, _selectedDay.day);
    return _monthEvents.where((e) => e.dayKey == key).toList();
  }

  String _weekdayDate(DateTime d) {
    const days = ['Δευτέρα','Τρίτη','Τετάρτη','Πέμπτη','Παρασκευή','Σάββατο','Κυριακή'];
    return '${days[d.weekday - 1]} '
        '${d.day.toString().padLeft(2, "0")}/${d.month.toString().padLeft(2, "0")}';
  }

  Widget _eventCard(AppColors c, CalendarEvent e) {
    final converted = _convertedCache[e.id] ?? false;
    final looksTransfer = _looksLikeTransfer(e);
    final time = '${e.start.hour.toString().padLeft(2, "0")}:'
        '${e.start.minute.toString().padLeft(2, "0")}';

    final picked = _selectedIds.contains(e.id);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Opacity(
        opacity: converted && !_selectMode ? 0.72 : 1,
        child: GestureDetector(
          // Παρατεταμένο πάτημα → μπαίνει σε λειτουργία επιλογής με αυτό το
          // event ήδη τσεκαρισμένο. Σε λειτουργία επιλογής, το απλό πάτημα
          // οπουδήποτε στην κάρτα κάνει toggle.
          onLongPress: _selectMode ? null : () => _enterSelectMode(e.id),
          onTap: _selectMode ? () => _toggleSelect(e.id) : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: picked ? c.amberSoft : c.scaffold,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: picked ? c.amber : c.cardBorder,
                width: picked ? 1.4 : 0.8,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  if (_selectMode) ...[
                    Icon(
                      picked
                          ? Icons.check_circle_rounded
                          : Icons.radio_button_unchecked_rounded,
                      size: 22,
                      color: picked ? c.amberDeep : c.textFaint,
                    ),
                    const SizedBox(width: 10),
                  ],
                // Λωρίδα με το χρώμα του ημερολογίου Google.
                Container(
                  width: 4, height: 22,
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    color: _eventColor(e, c),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color:        c.blueSoft,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(time,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: c.blueDeep)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(e.title,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: converted ? c.textFaint : c.textMain)),
                ),
                if (converted)
                  const Icon(Icons.check_circle_rounded,
                      size: 20, color: Color(0xFF97C459)),
              ]),
              if (!converted && e.description != null &&
                  e.description!.trim().isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(e.description!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: c.textFaint)),
              ],
              const SizedBox(height: 10),
              // Σε λειτουργία επιλογής τα κουμπιά ενέργειας κρύβονται — η
              // μετατροπή γίνεται μαζικά από την κάτω μπάρα.
              if (_selectMode)
                Text(
                  converted
                      ? 'Έχει ήδη μετατραπεί — θα ξαναγίνει αν το επιλέξεις'
                      : (looksTransfer
                          ? 'Έτοιμο για μετατροπή'
                          : 'Δεν μοιάζει με μεταφορά'),
                  style: TextStyle(
                      fontSize: 11.5,
                      color: picked ? c.amberDeep : c.textFaint),
                )
              else if (converted)
                // Κουμπί (ίδιο στυλ με «Μετατροπή σε δουλειά») που δηλώνει
                // ότι έγινε ήδη — με πάτημα μπορείς να τη βγάλεις ξανά.
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () => _openConvertForm(e),
                    icon: const Icon(Icons.check_circle_rounded, size: 17),
                    label: const Text('Έχει μετατραπεί σε δουλειά'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF97C459),
                      foregroundColor: const Color(0xFF23400A),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24)),
                    ),
                  ),
                )
              else if (looksTransfer)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () => _openConvertForm(e),
                    icon: const Icon(Icons.compare_arrows_rounded, size: 17),
                    label: const Text('Μετατροπή σε δουλειά'),
                  ),
                )
              else ...[
                Text('Δεν μοιάζει με μεταφορά',
                    style: TextStyle(fontSize: 11, color: c.textFaint)),
                const SizedBox(height: 6),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () => _openConvertForm(e),
                    child: const Text('Μετατροπή ούτως ή άλλως'),
                  ),
                ),
              ],
            ],
            ),
          ),
        ),
      ),
    );
  }
}
