// lib/jobs/ics_export_platform.dart
//
// Επιλέγει την υλοποίηση αποθήκευσης/ανοίγματος .ics ανά πλατφόρμα.
//   • Mobile/Desktop → ics_export_io.dart  (προσωρινό αρχείο + system intent)
//   • Web            → ics_export_web.dart (blob download)

export 'ics_export_io.dart'
    if (dart.library.html) 'ics_export_web.dart';
