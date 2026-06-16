// lib/profile_form.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'models.dart';

/// Callback που επιστρέφεται μετά το αποθήκευση
typedef OnProfileSaved = void Function({
  required String name,
  required String lastName,
  required String phone,
  required String vehicleModel,
  required String referredBy,
  required String plateNumber,
  required VehicleType vehicleType,
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

  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => PopScope(
      canPop: false,
      child: StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Column(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.asset('assets/app_icon.png', width: 72, height: 72),
              ),
              const SizedBox(height: 8),
              const Text('Στοιχεία Οδηγού', style: TextStyle(fontSize: 20)),
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
                const SizedBox(height: 10),
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
            FilledButton(
              onPressed: () {
                final rawPhone    = phoneController.text.trim();
                final plateLetter = plateLetterController.text.trim().isEmpty
                    ? 'Α'
                    : plateLetterController.text.trim().toUpperCase();

                if (nameController.text.trim().isEmpty ||
                    lastNameController.text.trim().isEmpty ||
                    rawPhone.length < 10 ||
                    plateNumberController.text.trim().length < 4 ||
                    vehicleModelController.text.trim().isEmpty) {
                  setDialogState(() => errorMessage =
                      'Συμπληρώστε όλα τα υποχρεωτικά πεδία (*)!');
                } else {
                  Navigator.of(ctx).pop();
                  onSaved(
                    name:         nameController.text.trim(),
                    lastName:     lastNameController.text.trim(),
                    phone:        '+30$rawPhone',
                    vehicleModel: vehicleModelController.text.trim(),
                    referredBy:   referredByController.text.trim(),
                    plateNumber:  'ΤΑ$plateLetter-${plateNumberController.text.trim()}',
                    vehicleType:  selectedVehicle,
                  );
                }
              },
              child: const Text('Αποθήκευση'),
            ),
          ],
        ),
      ),
    ),
  );
}
