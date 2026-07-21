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

  // Μεγέθη συρταριού (ποσοστά ύψους οθόνης).
  static const double _sheetMin = 0.30;
  static const double _sheetMax = 0.92;

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

  Future<void> _openConvertForm(CalendarEvent e) async {
    final parsed = CalendarEventParser.parse(
      title: e.title, description: e.description, location: e.location,
    );

    // Το from/to του parser είναι ελεύθερο κείμενο — μπαίνει στη σημείωση
    // και ο χρήστης επιλέγει διευθύνσεις με autocomplete μέσα στη φόρμα.
    final created = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => JobFormPage(
        adminUid:  widget.adminUid,
        adminName: widget.adminName,
        isMaster:  widget.isMaster,
        calendarEventId: e.id,
        prefill: JobPrefill(
          clientName:   parsed.name,
          clientPhone:  parsed.phone,
          price:        parsed.price,
          scheduledAt:  e.start,
          persons:      parsed.persons,
          luggage:      parsed.luggage,
          note: [
            if (parsed.from != null) 'Από: ${parsed.from}',
            if (parsed.to   != null) 'Προς: ${parsed.to}',
            if (parsed.note != null) parsed.note!,
          ].join('\n'),
          flightOrShip:   parsed.flightOrShip,
          vehicleType:    parsed.vehicleType,
          childSeatCount: parsed.childSeat,
        ),
      ),
    ));

    if (created == true) {
      await ConvertedEventsStore.instance.markConverted(e.id);
      if (mounted) setState(() => _convertedCache[e.id] = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Scaffold(
      backgroundColor: c.scaffold,
      appBar: AppBar(
        title: const Text('Google Calendar'),
        backgroundColor: c.scaffold,
        foregroundColor: c.textMain,
        elevation: 0,
        actions: [
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
                  cellAlignment: const Alignment(0, -0.4),
                  todayDecoration: BoxDecoration(color: c.amberSoft, shape: BoxShape.circle),
                  todayTextStyle: TextStyle(
                      color: c.isDark ? c.amberDeep : const Color(0xFF633806),
                      fontWeight: FontWeight.w600),
                  selectedDecoration: BoxDecoration(color: c.textMain, shape: BoxShape.circle),
                  selectedTextStyle: TextStyle(color: c.scaffold, fontWeight: FontWeight.w600),
                ),
                calendarBuilders: CalendarBuilders<CalendarEvent>(
                  markerBuilder: (context, day, events) {
                    if (events.isEmpty) return null;
                    final shown = events.take(4).toList();
                    final extra = events.length - shown.length;
                    return Positioned(
                      bottom: 6,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ...shown.map((e) {
                            final converted = _convertedCache[e.id] ?? false;
                            return Container(
                              width: 7, height: 7,
                              margin: const EdgeInsets.symmetric(horizontal: 1.3),
                              decoration: BoxDecoration(
                                color: converted
                                    ? const Color(0xFF97C459)
                                    : c.amber,
                                shape: BoxShape.circle,
                              ),
                            );
                          }),
                          if (extra > 0)
                            Padding(
                              padding: const EdgeInsets.only(left: 1),
                              child: Text('+$extra',
                                  style: TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.w700,
                                      color: c.textFaint)),
                            ),
                        ],
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
                    14, 8, 14, 16 + (safeBottom > 0 ? safeBottom : 10)),
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
      ]);
    });
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

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Opacity(
        opacity: converted ? 0.72 : 1,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: c.scaffold,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: c.cardBorder, width: 0.8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
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
              if (converted)
                Text('Έχει μετατραπεί σε δουλειά ✓',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF3B6D11)))
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
    );
  }
}
