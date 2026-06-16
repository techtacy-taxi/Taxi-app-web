## Live θέση & “βλέπει ο ένας τον άλλον”

### Τι κάνει τώρα η εφαρμογή
- **Δείχνει την πραγματική σου θέση** στο χάρτη (GPS / browser geolocation).
- **Στέλνει την τοποθεσία σου** σε Firebase Firestore (`presence/{uid}`) με ανώνυμο login.
- **Δείχνει άλλες συσκευές** σαν markers (άλλο χρώμα για taxi/van).

### Απαραίτητο setup (Firebase)
1. Δημιούργησε Firebase project.
2. Πρόσθεσε apps:
   - Android: package id `com.example.my_taxi_app` (ή άλλαξέ το στο `android/app/build.gradle.kts` και στο Firebase).
   - Web: πρόσθεσε web app.
3. Ενεργοποίησε **Authentication → Sign-in method → Anonymous**.
4. Δημιούργησε Firestore database (Production ή Test).
5. Τρέξε:
   - `dart pub global activate flutterfire_cli`
   - `flutterfire configure`
6. Το `flutterfire configure` θα δημιουργήσει/ενημερώσει:
   - `lib/firebase_options.dart` (αντί για το placeholder)
   - αρχεία Firebase για Android/Web.

### Firestore rules (απλό demo)
Για γρήγορο demo μπορείς προσωρινά να χρησιμοποιήσεις rules που επιτρέπουν σε signed-in χρήστες να διαβάζουν/γράφουν presence.
Μετά τις δοκιμές, κλείδωσέ τα πιο σωστά.

