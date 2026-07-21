// lib/profile_form.dart
//
// REDESIGN (εγκεκριμένο mockup «Στοιχεία οδηγού 3/4»):
//  • Μπάρα προόδου onboarding (βήμα 3/4)
//  • Οχήματα ως κάρτες: Ταξί / Βαν (επιλογή ενός) + Λεωφορείο ως ΕΠΙΠΛΕΟΝ
//    ικανότητα (το υπάρχον hasBus — καμία αλλαγή στο μοντέλο δεδομένων)
//  • Πινακίδα: ΤΑ σταθερό + 1 γράμμα (auto-κεφαλαίο) + 4 ψηφία — ίδιοι κανόνες
//  • Home Owner με επιλογή καταλύματος + έλεγχο μοναδικότητας — ίδια λογική
//  • Πλήρες Dark mode (AppColors)
//
// Η ΛΟΓΙΚΗ (φόρτωση από Firestore, validation, toProperCase, +30, signature
// του onSaved) παραμένει ΙΔΙΑ με πριν — μόνο το UI άλλαξε.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'models.dart';

/// Μετατρέπει "ΓΙΩΡΓΟΣ" / "γιωργοσ" / "ΓιΩρΓοΣ" → "Γιώργος" (πρώτο γράμμα
/// κάθε λέξης κεφαλαίο, τα υπόλοιπα πεζά). Λειτουργεί με ελληνικά/λατινικά.
String toProperCase(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return trimmed;
  return trimmed
      .split(RegExp(r'\s+'))
      .map((word) {
        if (word.isEmpty) return word;
        final lower = word.toLowerCase();
        return lower[0].toUpperCase() + lower.substring(1);
      })
      .join(' ');
}

/// Callback που επιστρέφεται μετά το αποθήκευση.
/// homeOwner / ownerOfClientId / ownerOfClientName — για τον ρόλο
/// «Home Owner» (ιδιοκτήτης καταλύματος). Όταν homeOwner==true, τα
/// vehicleModel/plateNumber/vehicleType αγνοούνται (ο owner δεν έχει όχημα).
typedef OnProfileSaved = void Function({
  required String name,
  required String lastName,
  required String phone,
  required String vehicleModel,
  required String referredBy,
  required String plateNumber,
  required VehicleType vehicleType,
  required bool hasBus,
  required bool homeOwner,
  required String? ownerOfClientId,
  required String? ownerOfClientName,
});

Future<void> showProfileForm({
  required BuildContext context,
  required String? uid,
  required String appVersion,
  required String displayName,
  required String lastName,
  required String phone,
  required String vehicleModel,
  required String referredBy,
  required String plateNumber,
  required VehicleType vehicleType,
  required bool initialHasBus, // συμβατότητα κλήσης — φορτώνεται φρέσκο από Firestore
  required OnProfileSaved onSaved,
}) async {
  // Φορτώνουμε πάντα φρέσκα δεδομένα από Firestore πριν ανοίξει η φόρμα
  String fsName     = displayName;
  String fsLast     = lastName;
  String fsPhone    = phone;
  String fsModel    = vehicleModel;
  String fsRef      = referredBy;
  String fsPlate    = plateNumber;
  VehicleType fsVehicle = vehicleType;
  bool   fsHasBus    = false;
  bool   fsHomeOwner = false;
  String? fsOwnerClientId;
  String? fsOwnerClientName;

  if (uid != null) {
    final doc = await FirebaseFirestore.instance
        .collection('presence')
        .doc(uid)
        .get();
    if (doc.exists) {
      final data = doc.data();
      if (data != null) {
        if ((data['displayName']  as String?)?.isNotEmpty == true) fsName  = data['displayName'];
        if ((data['lastName']     as String?)?.isNotEmpty == true) fsLast  = data['lastName'];
        if ((data['phone']        as String?)?.isNotEmpty == true) fsPhone = data['phone'];
        if ((data['vehicleModel'] as String?)?.isNotEmpty == true) fsModel = data['vehicleModel'];
        if ((data['referredBy']   as String?)?.isNotEmpty == true) fsRef   = data['referredBy'];
        if ((data['plateNumber']  as String?)?.isNotEmpty == true) fsPlate = data['plateNumber'];
        if ((data['vehicleType']  as String?) == VehicleType.van.name) {
          fsVehicle = VehicleType.van;
        }
        fsHasBus          = data['hasBus'] == true;
        // Το «Λεωφορείο» είναι πλέον 3η ΙΣΟΤΙΜΗ επιλογή στο UI (Ταξί/Van/
        // Λεωφορείο — επιλέγεις ένα). Στο backend/data model ΔΕΝ αλλάζει
        // τίποτα: εξακολουθεί να αποθηκεύεται σαν vehicleType taxi/van +
        // hasBus=true, ώστε η δρομολόγηση δουλειών (functions/index.js) να
        // συνεχίσει να δουλεύει ακριβώς όπως πριν, χωρίς καμία αλλαγή εκεί.
        if (fsHasBus) fsVehicle = VehicleType.bus;
        fsHomeOwner       = data['homeOwner'] == true;
        fsOwnerClientId   = data['ownerOfClientId'] as String?;
        fsOwnerClientName = data['ownerOfClientName'] as String?;
      }
    }
  }

  // Controllers
  final nameController         = TextEditingController(
      text: fsName == 'Driver' ? '' : fsName);
  final lastNameController     = TextEditingController(text: fsLast);
  final phoneController        = TextEditingController(
      text: fsPhone.replaceFirst('+30', ''));
  final vehicleModelController = TextEditingController(text: fsModel);
  final referredByController   = TextEditingController(text: fsRef);
  final plateLetterController  = TextEditingController(
    text: fsPlate.length >= 3 ? fsPlate[2] : '',
  );
  final plateNumberController  = TextEditingController(
    text: fsPlate.length >= 7 ? fsPlate.substring(4) : '',
  );

  VehicleType selectedVehicle = fsVehicle;
  bool hasBus = fsHasBus;
  String? errorMessage;
  bool isHomeOwner = fsHomeOwner;
  String? selectedClientId = fsOwnerClientId;
  String? selectedClientName = fsOwnerClientName;
  bool clientsLoading = true;
  bool saving = false;
  List<Map<String, String>> clients = []; // [{id:..., name:...}]

  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => PopScope(
      canPop: false,
      child: StatefulBuilder(
        builder: (context, setDialogState) {
          final c = AppColors.of(context);

          // Φόρτωση πελατών (clients) — μία φορά, την πρώτη φορά που χτίζεται.
          if (clientsLoading && clients.isEmpty) {
            FirebaseFirestore.instance
                .collection('clients')
                .orderBy('name')
                .get()
                .then((snap) {
              final loaded = snap.docs
                  .map((d) => {
                        'id': d.id,
                        'name': (d.data()['name'] as String?) ?? '(χωρίς όνομα)',
                      })
                  .toList();
              setDialogState(() {
                clients = loaded;
                clientsLoading = false;
              });
            }).catchError((_) {
              setDialogState(() => clientsLoading = false);
            });
          }

          // ── Μικρά UI helpers (μέσα στο builder για πρόσβαση στην παλέτα) ──

          InputDecoration deco(String label, {String? hint, String? prefix}) {
            return InputDecoration(
              labelText:  label,
              hintText:   hint,
              prefixText: prefix,
              filled:     true,
              fillColor:  c.card,
              labelStyle: TextStyle(fontSize: 13, color: c.textFaint),
              hintStyle:  TextStyle(color: c.textFaint.withValues(alpha: 0.6)),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide:   BorderSide(color: c.cardBorder, width: 0.8),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide:   BorderSide(color: c.cardBorder, width: 0.8),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide:   BorderSide(color: c.amber, width: 2),
              ),
            );
          }

          // Κάρτα επιλογής οχήματος (Ταξί/Βαν — επιλογή ενός)
          Widget vehicleCard({
            required VehicleType type,
            required IconData icon,
            required String label,
          }) {
            final selected = selectedVehicle == type;
            return Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => setDialogState(() => selectedVehicle = type),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: selected ? c.amberSoft : c.card,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: selected ? c.amber : c.cardBorder,
                      width: selected ? 2 : 0.8,
                    ),
                  ),
                  child: Column(children: [
                    Icon(icon,
                        size: 22,
                        color: selected ? c.amberDeep : c.textFaint),
                    const SizedBox(height: 3),
                    Text(label,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.w500,
                            color: selected
                                ? (c.isDark
                                    ? c.amberDeep
                                    : const Color(0xFF633806))
                                : c.textFaint)),
                  ]),
                ),
              ),
            );
          }

          return Dialog(
            backgroundColor: c.scaffold,
            insetPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 26),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24)),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(mainAxisSize: MainAxisSize.min, children: [

                // ── Header: τίτλος + βήμα + μπάρα προόδου (3/4) ──
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
                  child: Column(children: [
                    Row(children: [
                      Expanded(
                        child: Text('Τα στοιχεία σου',
                            style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                                color: c.textMain)),
                      ),
                      Text('3 / 4',
                          style: TextStyle(
                              fontSize: 12, color: c.textFaint)),
                    ]),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: 0.75,
                        minHeight: 5,
                        backgroundColor: c.divider,
                        color: c.amber,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(children: [
                      Expanded(
                        child: Text(
                            'Θα τα δει ο διαχειριστής για να σε εγκρίνει',
                            style: TextStyle(
                                fontSize: 12, color: c.textFaint)),
                      ),
                      Text('v$appVersion',
                          style: TextStyle(
                              fontSize: 10.5, color: c.textFaint)),
                    ]),
                  ]),
                ),

                // ── Scrollable πεδία ──
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(18, 12, 18, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Expanded(
                            child: TextField(
                              controller: nameController,
                              textCapitalization: TextCapitalization.words,
                              style: TextStyle(
                                  fontSize: 14, color: c.textMain),
                              decoration: deco('Όνομα *'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: lastNameController,
                              textCapitalization: TextCapitalization.words,
                              style: TextStyle(
                                  fontSize: 14, color: c.textMain),
                              decoration: deco('Επίθετο *'),
                            ),
                          ),
                        ]),
                        const SizedBox(height: 10),
                        TextField(
                          controller: phoneController,
                          keyboardType: TextInputType.phone,
                          style: TextStyle(fontSize: 14, color: c.textMain),
                          decoration: deco('Τηλέφωνο *',
                              hint: '6900000000', prefix: '+30 '),
                        ),

                        const SizedBox(height: 12),

                        // ── Home Owner (ιδιοκτήτης καταλύματος) ──
                        Container(
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                          decoration: BoxDecoration(
                            color: isHomeOwner ? c.bluePale : c.card,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: isHomeOwner ? c.blue : c.cardBorder,
                              width: isHomeOwner ? 1.5 : 0.8,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              CheckboxListTile(
                                contentPadding: EdgeInsets.zero,
                                dense: true,
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                value: isHomeOwner,
                                activeColor: c.blue,
                                title: Text(
                                    'Είμαι ιδιοκτήτης καταλύματος (Home Owner)',
                                    style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: isHomeOwner
                                            ? c.blueDeep
                                            : c.textMain)),
                                onChanged: (v) => setDialogState(() {
                                  isHomeOwner = v ?? false;
                                  if (!isHomeOwner) {
                                    selectedClientId = null;
                                    selectedClientName = null;
                                  }
                                }),
                              ),
                              Text(
                                'Επίλεξέ το ΜΟΝΟ αν είσαι ο διαχειριστής του '
                                'καταλύματος — όχι απλός οδηγός.',
                                style: TextStyle(
                                    fontSize: 11, color: c.textFaint),
                              ),
                              if (isHomeOwner) ...[
                                const SizedBox(height: 10),
                                if (clientsLoading)
                                  const Padding(
                                    padding:
                                        EdgeInsets.symmetric(vertical: 8),
                                    child: Center(
                                        child: SizedBox(
                                            width: 20, height: 20,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2))),
                                  )
                                else
                                  DropdownButtonFormField<String>(
                                    initialValue: selectedClientId,
                                    isExpanded: true,
                                    dropdownColor: c.card,
                                    style: TextStyle(
                                        fontSize: 14, color: c.textMain),
                                    decoration:
                                        deco('Κατάλυμα / Πελάτης *'),
                                    items: clients
                                        .map((cl) => DropdownMenuItem<String>(
                                              value: cl['id'],
                                              child: Text(cl['name'] ?? '',
                                                  overflow:
                                                      TextOverflow.ellipsis),
                                            ))
                                        .toList(),
                                    onChanged: (v) => setDialogState(() {
                                      selectedClientId = v;
                                      selectedClientName = clients
                                          .firstWhere(
                                              (cl) => cl['id'] == v)['name'];
                                    }),
                                  ),
                              ],
                            ],
                          ),
                        ),

                        // ── Στοιχεία οχήματος — ΜΟΝΟ αν ΔΕΝ είναι Home Owner ──
                        if (!isHomeOwner) ...[
                          const SizedBox(height: 14),
                          Text('Όχημα *',
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: c.textFaint)),
                          const SizedBox(height: 7),
                          Row(children: [
                            vehicleCard(
                              type:  VehicleType.taxi,
                              icon:  Icons.local_taxi_rounded,
                              label: 'Ταξί',
                            ),
                            const SizedBox(width: 8),
                            vehicleCard(
                              type:  VehicleType.van,
                              icon:  Icons.airport_shuttle_rounded,
                              label: 'Βαν',
                            ),
                            const SizedBox(width: 8),
                            // Λεωφορείο: ΙΣΟΤΙΜΗ 3η επιλογή — επιλέγεις ένα
                            // από τα τρία, όπως Ταξί/Βαν. Από πίσω συνεχίζει
                            // να αποθηκεύεται σαν vehicleType taxi/van +
                            // hasBus=true, ώστε η δρομολόγηση δουλειών να
                            // μη χρειαστεί ΚΑΜΙΑ αλλαγή στο backend.
                            vehicleCard(
                              type:  VehicleType.bus,
                              icon:  Icons.directions_bus_rounded,
                              label: 'Λεωφορείο',
                            ),
                          ]),
                          Padding(
                            padding: const EdgeInsets.only(top: 5),
                            child: Text(
                              selectedVehicle == VehicleType.bus
                                  ? 'Θα λαμβάνεις δουλειές Shuttle/Λεωφορείου πολλών ατόμων'
                                  : 'Επίλεξε το όχημα με το οποίο δουλεύεις',
                              style: TextStyle(
                                  fontSize: 10.5, color: c.textFaint),
                            ),
                          ),

                          const SizedBox(height: 12),
                          TextField(
                            controller: vehicleModelController,
                            textCapitalization: TextCapitalization.words,
                            style:
                                TextStyle(fontSize: 14, color: c.textMain),
                            decoration: deco('Μοντέλο Αυτοκινήτου *',
                                hint: 'π.χ. Toyota Prius'),
                          ),

                          const SizedBox(height: 12),
                          Text('Πινακίδα *',
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: c.textFaint)),
                          const SizedBox(height: 7),
                          Row(children: [
                            // ΤΑ (σταθερό)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 13),
                              decoration: BoxDecoration(
                                color: c.isDark
                                    ? const Color(0xFF2E2E2A)
                                    : const Color(0xFFF1EFE8),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                    color: c.cardBorder, width: 0.8),
                              ),
                              child: Text('ΤΑ',
                                  style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                      color: c.textFaint)),
                            ),
                            const SizedBox(width: 8),
                            // Γράμμα (auto-κεφαλαίο)
                            SizedBox(
                              width: 54,
                              child: TextField(
                                controller: plateLetterController,
                                maxLength: 1,
                                textCapitalization:
                                    TextCapitalization.characters,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                    color: c.textMain),
                                decoration:
                                    deco('', hint: 'Α').copyWith(
                                  counterText: '',
                                  labelText: null,
                                ),
                                onChanged: (v) {
                                  plateLetterController.text =
                                      v.toUpperCase();
                                  plateLetterController.selection =
                                      TextSelection.fromPosition(TextPosition(
                                          offset: plateLetterController
                                              .text.length));
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            // Αριθμός (4 ψηφία)
                            Expanded(
                              child: TextField(
                                controller: plateNumberController,
                                maxLength: 4,
                                keyboardType: TextInputType.number,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 3,
                                    color: c.textMain),
                                decoration:
                                    deco('', hint: '1234').copyWith(
                                  counterText: '',
                                  labelText: null,
                                ),
                              ),
                            ),
                          ]),
                          Padding(
                            padding: const EdgeInsets.only(top: 5),
                            child: Text(
                                'Το «ΤΑ» είναι σταθερό · 1 γράμμα · 4 ψηφία',
                                style: TextStyle(
                                    fontSize: 10.5, color: c.textFaint)),
                          ),

                          const SizedBox(height: 12),
                          TextField(
                            controller: referredByController,
                            textCapitalization: TextCapitalization.words,
                            style:
                                TextStyle(fontSize: 14, color: c.textMain),
                            decoration: deco(
                                'Ποιος σε πρότεινε (προαιρετικό)',
                                hint: 'Όνομα συναδέλφου'),
                          ),
                        ] else ...[
                          const SizedBox(height: 10),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: c.card,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                  color: c.cardBorder, width: 0.8),
                            ),
                            child: Row(children: [
                              Icon(Icons.no_transfer_rounded,
                                  size: 16, color: c.textFaint),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Χωρίς όχημα — δεν χρειάζεται μοντέλο/πινακίδα (Μη Διαθέσιμος).',
                                  style: TextStyle(
                                      fontSize: 11.5, color: c.textFaint),
                                ),
                              ),
                            ]),
                          ),
                        ],

                        if (errorMessage != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Text(errorMessage!,
                                style: const TextStyle(
                                    color: Colors.red,
                                    fontWeight: FontWeight.bold)),
                          ),
                      ],
                    ),
                  ),
                ),

                // ── Κουμπιά (SafeArea για το κάτω navigation bar) ──
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 8, 18, 14),
                    child: Column(children: [
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: saving
                              ? null
                              : () async {
                                  final rawPhone =
                                      phoneController.text.trim();
                                  final plateLetter = plateLetterController
                                          .text
                                          .trim()
                                          .isEmpty
                                      ? 'Α'
                                      : plateLetterController.text
                                          .trim()
                                          .toUpperCase();

                                  if (nameController.text.trim().isEmpty ||
                                      lastNameController.text
                                          .trim()
                                          .isEmpty ||
                                      rawPhone.length < 10) {
                                    setDialogState(() => errorMessage =
                                        'Συμπληρώστε όλα τα υποχρεωτικά πεδία (*)!');
                                    return;
                                  }

                                  if (isHomeOwner) {
                                    if (selectedClientId == null) {
                                      setDialogState(() => errorMessage =
                                          'Επίλεξε το κατάλυμα/πελάτη σου!');
                                      return;
                                    }
                                  } else {
                                    if (plateNumberController.text
                                                .trim()
                                                .length <
                                            4 ||
                                        vehicleModelController.text
                                            .trim()
                                            .isEmpty) {
                                      setDialogState(() => errorMessage =
                                          'Συμπληρώστε όλα τα υποχρεωτικά πεδία (*)!');
                                      return;
                                    }
                                  }

                                  // ── Μοναδικότητα: 1 owner ανά πελάτη ──
                                  if (isHomeOwner) {
                                    setDialogState(() {
                                      saving = true;
                                      errorMessage = null;
                                    });
                                    try {
                                      final existing =
                                          await FirebaseFirestore.instance
                                              .collection('presence')
                                              .where('homeOwner',
                                                  isEqualTo: true)
                                              .where('ownerOfClientId',
                                                  isEqualTo:
                                                      selectedClientId)
                                              .get();
                                      final conflict = existing.docs
                                          .any((d) => d.id != uid);
                                      if (conflict) {
                                        setDialogState(() {
                                          saving = false;
                                          errorMessage =
                                              'Υπάρχει ήδη owner για τον/την "$selectedClientName".';
                                        });
                                        return;
                                      }
                                    } catch (e) {
                                      setDialogState(() {
                                        saving = false;
                                        errorMessage =
                                            'Σφάλμα ελέγχου — δοκιμάστε ξανά.';
                                      });
                                      return;
                                    }
                                  }

                                  Navigator.of(ctx).pop();
                                  // Το «Λεωφορείο» είναι επιλογή ΜΟΝΟ στο UI
                                  // (VehicleType.bus). Το backend/data model
                                  // δεν το ξέρει — συνεχίζει να αποθηκεύει
                                  // taxi/van + hasBus=true, όπως πριν, ώστε η
                                  // δρομολόγηση δουλειών να μη χρειαστεί
                                  // ΚΑΜΙΑ αλλαγή.
                                  final isBusSelected =
                                      selectedVehicle == VehicleType.bus;
                                  onSaved(
                                    name: toProperCase(nameController.text),
                                    lastName:
                                        toProperCase(lastNameController.text),
                                    phone: '+30$rawPhone',
                                    vehicleModel: isHomeOwner
                                        ? ''
                                        : toProperCase(
                                            vehicleModelController.text),
                                    referredBy: toProperCase(
                                        referredByController.text),
                                    plateNumber: isHomeOwner
                                        ? ''
                                        : 'ΤΑ$plateLetter-${plateNumberController.text.trim()}',
                                    vehicleType: isBusSelected
                                        ? VehicleType.van
                                        : selectedVehicle,
                                    hasBus: isBusSelected || hasBus,
                                    homeOwner: isHomeOwner,
                                    ownerOfClientId:
                                        isHomeOwner ? selectedClientId : null,
                                    ownerOfClientName: isHomeOwner
                                        ? selectedClientName
                                        : null,
                                  );
                                },
                          child: saving
                              ? const SizedBox(
                                  width: 18, height: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2))
                              : const Text('Αποστολή για έγκριση'),
                        ),
                      ),
                      const SizedBox(height: 4),
                      TextButton.icon(
                        onPressed: saving
                            ? null
                            : () async {
                                final confirmed = await showDialog<bool>(
                                  context: ctx,
                                  builder: (dctx) => AlertDialog(
                                    title: const Text('Αποσύνδεση'),
                                    content: const Text(
                                      'Θα αποσυνδεθείς από τον λογαριασμό Google — '
                                      'θα χρειαστεί να ξανακάνεις σύνδεση για να μπεις ξανά.',
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.of(dctx).pop(false),
                                        child: const Text('Άκυρο'),
                                      ),
                                      FilledButton(
                                        style: FilledButton.styleFrom(
                                            backgroundColor: Colors.red,
                                            foregroundColor: Colors.white),
                                        onPressed: () =>
                                            Navigator.of(dctx).pop(true),
                                        child: const Text('Αποσύνδεση'),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirmed == true) {
                                  await FirebaseAuth.instance.signOut();
                                  if (ctx.mounted) Navigator.of(ctx).pop();
                                }
                              },
                        icon: const Icon(Icons.logout_rounded,
                            color: Colors.red, size: 18),
                        label: const Text('Αποσύνδεση',
                            style:
                                TextStyle(color: Colors.red, fontSize: 13)),
                      ),
                    ]),
                  ),
                ),
              ]),
            ),
          );
        },
      ),
    ),
  );
}
