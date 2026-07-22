// lib/widgets/vehicle_type_icon.dart
//
// Ενιαίο widget για το εικονίδιο τύπου οχήματος σε ΟΛΗ την εφαρμογή.
// Πριν, το "any"/"" (= δουλειά διαθέσιμη σε ΟΛΟΥΣ τους τύπους οχήματος)
// έδειχνε ένα γενικό Icons.directions_car_rounded και η ετικέτα έλεγε
// «Taxi / Van» — παραπλανητικό τώρα που υπάρχει και Λεωφορείο/Shuttle, αφού
// χτυπάει ΚΑΙ σε αυτά. Το "any" δείχνει πλέον το custom εικονίδιο
// «Ταξί + Van + Λεωφορείο» (assets/icons/all_vehicles.svg) και η ετικέτα
// είναι «All» (βλ. Job.vehicleLabel στο job_model.dart).
//
// Χρήση: VehicleTypeIcon(vehicleType: job.vehicleType, size: 18, color: ...)

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Επιστρέφει true αν το vehicleType σημαίνει «όλοι οι τύποι οχήματος»
/// (κενό, null, ή ρητά "any").
bool isAnyVehicleType(String? vehicleType) {
  final v = (vehicleType ?? '').trim();
  return v.isEmpty || v == 'any';
}

class VehicleTypeIcon extends StatelessWidget {
  final String? vehicleType; // 'taxi' | 'van' | 'bus' | 'shuttle' | 'any'/null
  final double  size;
  final Color?  color;

  const VehicleTypeIcon({
    super.key,
    required this.vehicleType,
    this.size = 18,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final v = (vehicleType ?? '').trim();
    if (isAnyVehicleType(v)) {
      return SvgPicture.asset(
        'assets/icons/all_vehicles.svg',
        width:  size,
        height: size * (72 / 120), // ίδια αναλογία με το viewBox του SVG
        colorFilter: color != null
            ? ColorFilter.mode(color!, BlendMode.srcIn)
            : null,
      );
    }
    IconData icon;
    switch (v) {
      case 'van':
        icon = Icons.airport_shuttle_rounded;
        break;
      case 'bus':
        icon = Icons.directions_bus_filled_rounded;
        break;
      case 'shuttle':
        icon = Icons.directions_bus_rounded;
        break;
      case 'taxi':
      default:
        icon = Icons.local_taxi_rounded;
    }
    return Icon(icon, size: size, color: color);
  }
}
