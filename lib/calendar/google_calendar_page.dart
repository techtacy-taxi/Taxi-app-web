// lib/calendar/google_calendar_page.dart
//
// Οθόνη Google Calendar (εγκεκριμένο mockup «Φωτο 2»):
//  • Header: λογαριασμός συνδεδεμένος + refresh
//  • Μήνας με κουκκίδες: κίτρινη = event ΔΕΝ έχει μετατραπεί ακόμη,
//    πράσινη = έχει ήδη μετατραπεί
//  • Λίστα events της επιλεγμένης ημέρας:
//      - Μη μετατραπέν + μοιάζει με μεταφορά → κίτρινο κουμπί «Μετατροπή σε δουλειά»
//      - Ήδη μετατραπέν → αχνό, πράσινο ✓ «Έχει μετατραπεί σε δουλειά»
//      - Δεν μοιάζει με μεταφορά → αχνό κείμενο + «Μετατροπή ούτως ή άλλως»
//
// Read-only προς το Google Calendar (καμία εγγραφή). Χρησιμοποιεί το
// υπάρχον GoogleCalendarService (server-side refresh token) και
// ConvertedEventsStore (τοπικό tracking, 4μηνο auto-cleanup) — καμία αλλαγή
// στη λογική τους.

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

    // Σημείωση: το from/to του parser είναι ελεύθερο κείμενο (διεύθυνση),
    // ενώ η φόρμα περιμένει PlacePick (με συντεταγμένες Google Places) —
    // γι' αυτό αφήνουμε τον χρήστη να τα επιλέξει μέσα στη φόρμα με
    // αυτόματη συμπλήρωση διεύθυνσης, βάζοντάς τα ως αρχικό κείμενο
    // αναζήτησης. Όλα τα υπόλοιπα (τηλέφωνο, τιμή, πτήση, άτομα κ.λπ.)
    // προσυμπληρώνονται κανονικά.
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

  Widget _content(AppColors c) {
    final byDay = <DateTime, List<CalendarEvent>>{};
    for (final e in _monthEvents) {
      (byDay[e.dayKey] ??= []).add(e);
    }
    final selKey = DateTime(_selectedDay.year, _selectedDay.month, _selectedDay.day);
    final dayEvents = byDay[selKey] ?? const <CalendarEvent>[];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.badge_rounded, size: 20, color: c.textFaint),
            const SizedBox(width: 10),
            Expanded(
              child: Text('Λογαριασμός συνδεδεμένος',
                  style: TextStyle(fontSize: 13, color: c.textFaint)),
            ),
            IconButton(
              onPressed: _load,
              icon: Icon(Icons.refresh_rounded, color: c.textFaint),
              tooltip: 'Ανανέωση',
            ),
          ]),
          const SizedBox(height: 6),

          Container(
            decoration: BoxDecoration(
              color:        c.card,
              borderRadius: BorderRadius.circular(16),
              border:       Border.all(color: c.cardBorder, width: 0.8),
            ),
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: TableCalendar<CalendarEvent>(
              firstDay:   DateTime.utc(2023, 1, 1),
              lastDay:    DateTime.utc(2035, 12, 31),
              focusedDay: _focusedMonth,
              currentDay: DateTime.now(),
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
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: c.textMain),
                leftChevronIcon:  Icon(Icons.chevron_left_rounded,  color: c.textFaint, size: 20),
                rightChevronIcon: Icon(Icons.chevron_right_rounded, color: c.textFaint, size: 20),
              ),
              daysOfWeekStyle: DaysOfWeekStyle(
                weekdayStyle: TextStyle(fontSize: 11, color: c.textFaint),
                weekendStyle: TextStyle(fontSize: 11, color: c.textFaint),
              ),
              calendarStyle: CalendarStyle(
                outsideDaysVisible: false,
                defaultTextStyle:   TextStyle(fontSize: 13, color: c.textMain),
                weekendTextStyle:   const TextStyle(fontSize: 13, color: Color(0xFF993C1D)),
                todayDecoration: BoxDecoration(color: c.amberSoft, shape: BoxShape.circle),
                todayTextStyle: TextStyle(
                    color: c.isDark ? c.amberDeep : const Color(0xFF633806),
                    fontWeight: FontWeight.w600),
                selectedDecoration: BoxDecoration(color: c.textMain, shape: BoxShape.circle),
                selectedTextStyle: TextStyle(color: c.scaffold, fontWeight: FontWeight.w600),
                markersMaxCount: 3,
                markerSize: 5,
              ),
              calendarBuilders: CalendarBuilders<CalendarEvent>(
                markerBuilder: (context, day, events) {
                  if (events.isEmpty) return null;
                  return Positioned(
                    bottom: 3,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: events.take(3).map((e) {
                        final converted = _convertedCache[e.id] ?? false;
                        return Container(
                          width: 5, height: 5,
                          margin: const EdgeInsets.symmetric(horizontal: 1),
                          decoration: BoxDecoration(
                            color: converted
                                ? const Color(0xFF97C459)
                                : c.amber,
                            shape: BoxShape.circle,
                          ),
                        );
                      }).toList(),
                    ),
                  );
                },
              ),
            ),
          ),

          const SizedBox(height: 14),
          Text(
            '${_weekdayDate(_selectedDay)} · ${dayEvents.length} '
            '${dayEvents.length == 1 ? "event" : "events"}',
            style: TextStyle(
                fontSize: 14, fontWeight: FontWeight.w600, color: c.textMain),
          ),
          const SizedBox(height: 10),

          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),

          if (dayEvents.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: Text('Κανένα event αυτή την ημέρα',
                    style: TextStyle(fontSize: 13, color: c.textFaint)),
              ),
            )
          else
            ...dayEvents.map((e) => _eventCard(c, e)),
        ],
      ),
    );
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
            color: c.card,
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
