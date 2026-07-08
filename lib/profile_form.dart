// lib/profile_form.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

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
/// ΝΕΟ: homeOwner / ownerOfClientId / ownerOfClientName — για τον νέο ρόλο
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

          return AlertDialog(
            title: Column(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.asset('assets/app_icon.png', width: 72, height: 72),
                ),
                const SizedBox(height: 8),
                const Text('Στοιχεία Χρήστη', style: TextStyle(fontSize: 20)),
                Text('Έκδοση εφαρμογής: v$appVersion',
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Παρακαλώ συμπληρώστε τα στοιχεία σας:'),
                  const SizedBox(height: 12),
                  TextField(
                    controller: nameController,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                        labelText: 'Όνομα *', border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: lastNameController,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                        labelText: 'Επίθετο *', border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: phoneController,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: 'Τηλέφωνο *',
                      prefixText: '+30 ',
                      border: OutlineInputBorder(),
                      hintText: '6900000000',
                    ),
                  ),

                  const SizedBox(height: 16),
                  const Divider(height: 1),
                  const SizedBox(height: 10),

                  // ── Home Owner (ιδιοκτήτης καταλύματος) — ΝΕΟ ──────────
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: isHomeOwner
                          ? Colors.indigo.withValues(alpha: 0.08)
                          : Colors.grey.shade50,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isHomeOwner
                            ? Colors.indigo.withValues(alpha: 0.4)
                            : Colors.grey.shade300,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: isHomeOwner,
                          activeColor: Colors.indigo,
                          title: const Text('Είμαι Home Owner (ιδιοκτήτης καταλύματος)',
                              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold)),
                          onChanged: (v) => setDialogState(() {
                            isHomeOwner = v ?? false;
                            if (!isHomeOwner) {
                              selectedClientId = null;
                              selectedClientName = null;
                            }
                          }),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(left: 4, bottom: 4),
                          child: Text(
                            'Σημείωση: επίλεξε αυτό ΜΟΝΟ αν είσαι ο διαχειριστής '
                            'του καταλύματος — όχι απλός οδηγός.',
                            style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                          ),
                        ),
                        if (isHomeOwner) ...[
                          const SizedBox(height: 8),
                          if (clientsLoading)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 8),
                              child: Center(
                                  child: SizedBox(
                                      width: 20, height: 20,
                                      child: CircularProgressIndicator(strokeWidth: 2))),
                            )
                          else
                            DropdownButtonFormField<String>(
                              initialValue: selectedClientId,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText: 'Κατάλυμα / Πελάτης *',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              items: clients
                                  .map((c) => DropdownMenuItem<String>(
                                        value: c['id'],
                                        child: Text(c['name'] ?? '',
                                            overflow: TextOverflow.ellipsis),
                                      ))
                                  .toList(),
                              onChanged: (v) => setDialogState(() {
                                selectedClientId = v;
                                selectedClientName =
                                    clients.firstWhere((c) => c['id'] == v)['name'];
                              }),
                            ),
                        ],
                      ],
                    ),
                  ),

                  // ── Στοιχεία οχήματος — ΜΟΝΟ αν ΔΕΝ είναι Home Owner ────
                  if (!isHomeOwner) ...[
                    const SizedBox(height: 14),
                    TextField(
                      controller: vehicleModelController,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Μοντέλο Αυτοκινήτου *',
                        border: OutlineInputBorder(),
                        hintText: 'π.χ. Toyota Prius',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: referredByController,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Ποιος σε πρότεινε (προαιρετικό)',
                        border: OutlineInputBorder(),
                        hintText: 'Όνομα συναδέλφου',
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text('Πινακίδα *'),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        // ΤΑ (σταθερό)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 16),
                          decoration: BoxDecoration(
                            color: Colors.grey[200],
                            borderRadius: const BorderRadius.only(
                              topLeft: Radius.circular(4),
                              bottomLeft: Radius.circular(4),
                            ),
                            border: Border.all(color: Colors.grey),
                          ),
                          child: const Text('ΤΑ',
                              style: TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.bold)),
                        ),
                        // Γράμμα πινακίδας (π.χ. Α)
                        SizedBox(
                          width: 52,
                          child: TextField(
                            controller: plateLetterController,
                            maxLength: 1,
                            textCapitalization: TextCapitalization.characters,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.bold),
                            decoration: const InputDecoration(
                              counterText: '',
                              border: OutlineInputBorder(
                                  borderRadius: BorderRadius.zero),
                              hintText: 'Α',
                            ),
                            onChanged: (v) {
                              plateLetterController.text = v.toUpperCase();
                              plateLetterController.selection =
                                  TextSelection.fromPosition(TextPosition(
                                      offset: plateLetterController.text.length));
                            },
                          ),
                        ),
                        // Διαχωριστής "-"
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 16),
                          decoration: BoxDecoration(
                            color: Colors.grey[200],
                            border: Border.all(color: Colors.grey),
                          ),
                          child: const Text('-',
                              style: TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.bold)),
                        ),
                        // Αριθμός πινακίδας (4 ψηφία)
                        Expanded(
                          child: TextField(
                            controller: plateNumberController,
                            maxLength: 4,
                            keyboardType: TextInputType.number,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.bold),
                            decoration: const InputDecoration(
                              counterText: '',
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.only(
                                  topRight: Radius.circular(4),
                                  bottomRight: Radius.circular(4),
                                ),
                              ),
                              hintText: '1234',
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    // Τύπος οχήματος
                    RadioGroup<VehicleType>(
                      groupValue: selectedVehicle,
                      onChanged: (v) =>
                          setDialogState(() => selectedVehicle = v!),
                      child: Row(
                        children: [
                          Radio<VehicleType>(
                            value: VehicleType.taxi,
                          ),
                          const Icon(Icons.local_taxi_rounded),
                          const Text(' Taxi'),
                          const SizedBox(width: 20),
                          Radio<VehicleType>(
                            value: VehicleType.van,
                          ),
                          const Icon(Icons.airport_shuttle_rounded),
                          const Text(' Van'),
                        ],
                      ),
                    ),
                  ] else ...[
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(children: [
                        Icon(Icons.no_transfer_rounded, size: 16, color: Colors.grey[600]),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Χωρίς όχημα — δεν χρειάζεται μοντέλο/πινακίδα (Μη Διαθέσιμος).',
                            style: TextStyle(fontSize: 11.5, color: Colors.grey[700]),
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
            actions: [
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
                                onPressed: () => Navigator.of(dctx).pop(false),
                                child: const Text('Άκυρο'),
                              ),
                              FilledButton(
                                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                                onPressed: () => Navigator.of(dctx).pop(true),
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
                icon: const Icon(Icons.logout_rounded, color: Colors.red),
                label: const Text('Αποσύνδεση', style: TextStyle(color: Colors.red)),
              ),
              FilledButton(
                onPressed: saving
                    ? null
                    : () async {
                        final rawPhone = phoneController.text.trim();
                        final plateLetter = plateLetterController.text.trim().isEmpty
                            ? 'Α'
                            : plateLetterController.text.trim().toUpperCase();

                        if (nameController.text.trim().isEmpty ||
                            lastNameController.text.trim().isEmpty ||
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
                          if (plateNumberController.text.trim().length < 4 ||
                              vehicleModelController.text.trim().isEmpty) {
                            setDialogState(() => errorMessage =
                                'Συμπληρώστε όλα τα υποχρεωτικά πεδία (*)!');
                            return;
                          }
                        }

                        // ── Έλεγχος μοναδικότητας: 1 owner ανά πελάτη ──────
                        if (isHomeOwner) {
                          setDialogState(() { saving = true; errorMessage = null; });
                          try {
                            final existing = await FirebaseFirestore.instance
                                .collection('presence')
                                .where('homeOwner', isEqualTo: true)
                                .where('ownerOfClientId', isEqualTo: selectedClientId)
                                .get();
                            final conflict = existing.docs.any((d) => d.id != uid);
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
                              errorMessage = 'Σφάλμα ελέγχου — δοκιμάστε ξανά.';
                            });
                            return;
                          }
                        }

                        Navigator.of(ctx).pop();
                        onSaved(
                          name: toProperCase(nameController.text),
                          lastName: toProperCase(lastNameController.text),
                          phone: '+30$rawPhone',
                          vehicleModel: isHomeOwner
                              ? ''
                              : toProperCase(vehicleModelController.text),
                          referredBy: toProperCase(referredByController.text),
                          plateNumber: isHomeOwner
                              ? ''
                              : 'ΤΑ$plateLetter-${plateNumberController.text.trim()}',
                          vehicleType: selectedVehicle,
                          homeOwner: isHomeOwner,
                          ownerOfClientId: isHomeOwner ? selectedClientId : null,
                          ownerOfClientName: isHomeOwner ? selectedClientName : null,
                        );
                      },
                child: saving
                    ? const SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Αποθήκευση'),
              ),
            ],
          );
        },
      ),
    ),
  );
}
