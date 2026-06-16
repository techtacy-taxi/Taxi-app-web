// ============================================================================
// FILE: ./lib/web/ics_upload_web.dart
// ============================================================================
//
// Εισαγωγή κράτησης από αρχείο .ics ΓΙΑ WEB.
//
// Ροή (ίδια λογική με το κινητό, χωρίς το Android intent):
//   1) Ο χρήστης ανεβάζει .ics (κουμπί ή drag & drop)
//   2) IcsIntent.parseIcs(content)  → IcsBooking   (κοινός parser — web-safe)
//   3) Άνοιγμα JobFormPage με JobPrefill προ-συμπληρωμένο
//
// Δεν χρειάζεται extra dependency: χρησιμοποιεί <input type=file> μέσω
// package:web (διαθέσιμο στο Flutter web).

import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import '../ics_intent.dart';
import '../jobs/job_form.dart';
import '../jobs/places_service.dart';

const Color _kAmber = Color(0xFFFFB300);

class IcsUploadPage extends StatefulWidget {
  final String adminUid;
  final String adminName;
  final bool   isMaster;
  const IcsUploadPage({
    super.key,
    required this.adminUid,
    this.adminName = '',
    this.isMaster = false,
  });

  @override
  State<IcsUploadPage> createState() => _IcsUploadPageState();
}

class _IcsUploadPageState extends State<IcsUploadPage> {
  String? _error;
  String? _lastFileName;

  Future<void> _pickFile() async {
    setState(() => _error = null);
    final input = web.HTMLInputElement()
      ..type = 'file'
      ..accept = '.ics,text/calendar';
    input.click();

    input.onchange = (web.Event _) {
      final files = input.files;
      if (files == null || files.length == 0) return;
      final file = files.item(0);
      if (file == null) return;
      _readAndParse(file);
    }.toJS;
  }

  void _readAndParse(web.File file) {
    final reader = web.FileReader();
    reader.onload = (web.ProgressEvent _) {
      final result = reader.result;
      String? content;
      if (result.isA<JSString>()) {
        content = (result as JSString).toDart;
      }
      if (content == null || content.isEmpty) {
        setState(() => _error = 'Το αρχείο ήταν κενό ή δεν διαβάστηκε.');
        return;
      }
      _handleContent(content, file.name);
    }.toJS;
    reader.onerror = (web.ProgressEvent _) {
      setState(() => _error = 'Σφάλμα ανάγνωσης αρχείου.');
    }.toJS;
    reader.readAsText(file);
  }

  void _handleContent(String content, String fileName) {
    final booking = IcsIntent.parseIcs(content);
    if (booking == null || booking.isEmpty) {
      setState(() {
        _lastFileName = fileName;
        _error = 'Δεν αναγνωρίστηκε κράτηση στο «$fileName».\n'
            'Βεβαιώσου ότι είναι έγκυρο αρχείο .ics με στοιχεία κράτησης.';
      });
      return;
    }
    setState(() { _lastFileName = fileName; _error = null; });
    _openForm(booking);
  }

  void _openForm(IcsBooking b) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => JobFormPage(
        adminUid:  widget.adminUid,
        adminName: widget.adminName,
        isMaster:  widget.isMaster,
        prefill: JobPrefill(
          from: (b.from != null && b.from!.isNotEmpty)
              ? PlacePick(description: b.from!)
              : null,
          to: (b.to != null && b.to!.isNotEmpty)
              ? PlacePick(description: b.to!)
              : null,
          clientName:     b.name,
          clientPhone:    b.phone,
          persons:        b.persons,
          luggage:        b.luggage,
          scheduledAt:    b.scheduledAt,
          price:          b.price,
          vehicleType:    b.vehicleType,
          childSeatCount: b.childSeats,
          flightOrShip:   b.flightOrShip,
          note:           b.noteForComments,
        ),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.upload_file_rounded,
                    size: 56, color: Colors.amber.shade700),
                const SizedBox(height: 16),
                const Text('Εισαγωγή κράτησης από .ics',
                    style:
                        TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text(
                  'Ανέβασε ένα αρχείο .ics και θα ανοίξει η φόρμα νέας '
                  'δουλειάς προ-συμπληρωμένη.',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(color: Colors.grey[600], fontSize: 14, height: 1.4),
                ),
                const SizedBox(height: 28),
                _UploadBox(onTap: _pickFile),
                if (_lastFileName != null && _error == null) ...[
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.check_circle_rounded,
                          size: 18, color: Colors.green.shade600),
                      const SizedBox(width: 6),
                      Flexible(child: Text(_lastFileName!,
                          style: TextStyle(color: Colors.grey[700]))),
                    ],
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 18),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade50,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(_error!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: Colors.orange.shade900,
                            fontSize: 13.5,
                            height: 1.4)),
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

class _UploadBox extends StatelessWidget {
  final VoidCallback onTap;
  const _UploadBox({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _kAmber, width: 1.5),
        ),
        child: Column(
          children: [
            Icon(Icons.file_upload_outlined,
                size: 38, color: Colors.amber.shade700),
            const SizedBox(height: 12),
            const Text('Επιλογή αρχείου .ics',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            const SizedBox(height: 4),
            Text('Πάτησε εδώ για να επιλέξεις',
                style: TextStyle(color: Colors.grey[500], fontSize: 13)),
          ],
        ),
      ),
    );
  }
}
