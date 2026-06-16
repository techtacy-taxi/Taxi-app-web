import 'dart:io';

void main() async {
    final outputFile = File('all_my_code.txt');
    final libDir = Directory('./lib');

    if (!await libDir.exists()) {
        print('Ο φάκελος lib δεν βρέθηκε! Σιγουρέψου ότι τρέχεις το script στον σωστό φάκελο.');
        return;
    }

    final sink = outputFile.openWrite(mode: FileMode.write);

    try {
        await for (final entity in libDir.list(recursive: true)) {
            if (entity is File && entity.path.endsWith('.dart')) {
                sink.write('\n\n// ==========================================\n');
                sink.write('// FILE: ${entity.path}\n');
                sink.write('// ==========================================\n\n');

                sink.write(await entity.readAsString());
            }
        }
        print('Επιτυχία! Όλος ο κώδικας ενώθηκε στο αρχείο: all_my_code.txt');
    } catch (e) {
        print('Προέκυψε σφάλμα: $e');
    } finally {
        await sink.close();
    }
}