import 'package:flutter/material.dart';
import '../notifications_service.dart';

/// Οθόνη διαγνωστικών για τις υπενθυμίσεις ραντεβού (30′/10′).
/// Δουλεύει ΧΩΡΙΣ adb / developer mode — δείχνει το log, την κατάσταση των
/// alarms, και προγραμματίζει δοκιμαστική υπενθύμιση 1 λεπτό μπροστά.
class ReminderDebugPage extends StatefulWidget {
  const ReminderDebugPage({super.key});

  @override
  State<ReminderDebugPage> createState() => _ReminderDebugPageState();
}

class _ReminderDebugPageState extends State<ReminderDebugPage> {
  String _diag = 'Φόρτωση…';
  List<String> _log = const [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final diag = await NotificationsService.buildReminderDiagnostics();
    final log  = await NotificationsService.getDebugLog();
    if (!mounted) return;
    setState(() {
      _diag = diag;
      _log = log.reversed.toList(); // νεότερα πάνω
      _loading = false;
    });
  }

  Future<void> _test() async {
    await NotificationsService.scheduleTestReminder();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Δοκιμαστική υπενθύμιση σε 1 λεπτό. '
            'Κλείσε την οθόνη και περίμενε.'),
        duration: Duration(seconds: 4),
      ),
    );
    await _refresh();
  }

  Future<void> _clear() async {
    await NotificationsService.clearDebugLog();
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Διαγνωστικά Υπενθυμίσεων'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _refresh,
          ),
        ],
      ),
      // SafeArea ώστε το κάτω κουμπί να μην κρύβεται από το navigation bar.
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: double.infinity,
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blueGrey.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.blueGrey.shade200),
              ),
              child: SelectableText(
                _diag,
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 13, height: 1.4),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      icon: const Icon(Icons.alarm),
                      label: const Text('Δοκιμή σε 1΄'),
                      onPressed: _test,
                    ),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Καθαρισμός'),
                    onPressed: _clear,
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(14, 14, 14, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Log (νεότερα πάνω):',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
            Expanded(
              child: _log.isEmpty
                  ? const Center(
                      child: Text('Κενό — άνοιξε/κλείσε την app ή πάτησε '
                          '«Δοκιμή σε 1΄».'))
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      itemCount: _log.length,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1),
                      itemBuilder: (_, i) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: SelectableText(
                          _log[i],
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 12),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
