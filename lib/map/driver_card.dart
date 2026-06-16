// lib/map/driver_card.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models.dart';
import '../voice/voice_models.dart' show VoiceGroup;
import '../voice/groups_admin.dart' show GroupBadge;
import '../jobs/job_shared_widgets.dart';

// ─── Driver Card (άλλου οδηγού) ──────────────────────────────────────────────

void showDriverCard({
  required BuildContext          context,
  required Map<String, dynamic>  data,
  required VehicleType           vehicle,
  required String                driverUid,
  required List<VoiceGroup>      allGroups,
}) {
  final firstName    = (data['displayName'] as String?)?.trim() ?? '';
  final lastName     = (data['lastName']    as String?)?.trim() ?? '';
  final fullName     = '$firstName $lastName'.trim();
  final phone        = (data['phone']        as String?) ?? '';
  final plateNumber  = (data['plateNumber']  as String?) ?? '';
  final vehicleModel = (data['vehicleModel'] as String?) ?? '';
  final driverVer    = (data['appVersion']   as String?) ?? '—';
  final online       = (data['online']       as bool?) ?? false;
  final available    = (data['available']    as bool?) ?? false;
  final lastSeen     = _formatTimestamp(data['updatedAt']);
  final sc           = statusColor(online: online, available: available);
  final statusLabel  = !online ? 'Offline' : available ? 'Διαθέσιμος' : 'Μη διαθέσιμος';
  final waPhone      = phone.replaceAll('+', '').replaceAll(' ', '');
  final driverMuted  = (data['muted'] as bool?) ?? false;
  final driverGroups = allGroups.where((g) => g.memberUids.contains(driverUid)).toList();

  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    builder: (ctx) => Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: EdgeInsets.fromLTRB(24, 12, 24, 32 + MediaQuery.of(ctx).padding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _handle(),
          Stack(alignment: Alignment.bottomRight, children: [
            CircleAvatar(
              radius: 40,
              backgroundColor: Colors.amber.shade50,
              child: Icon(
                vehicle == VehicleType.van
                    ? Icons.airport_shuttle_rounded
                    : Icons.local_taxi_rounded,
                size: 44, color: Colors.amber.shade700,
              ),
            ),
            _statusDot(sc),
          ]),
          const SizedBox(height: 12),
          Text(fullName.isEmpty ? 'Άγνωστος οδηγός' : fullName,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF1A1A1A)),
              textAlign: TextAlign.center),
          const SizedBox(height: 4),
          Text(vehicleModel, style: TextStyle(color: Colors.grey[600], fontSize: 14)),
          const SizedBox(height: 4),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 6, runSpacing: 4,
            children: [
              _vehicleBadge(vehicle),
              ...driverGroups.map((g) => GroupBadge(name: g.name, color: g.color)),
            ],
          ),
          const SizedBox(height: 12),
          _statusChip(sc, statusLabel),
          if (driverMuted) ...[
            const SizedBox(height: 8),
            _muteBadge(),
          ],
          const SizedBox(height: 16),
          Divider(color: Colors.grey[200], height: 1),
          const SizedBox(height: 16),
          _infoRow(Icons.update_rounded,          'Τελ. ενημέρωση',   lastSeen),
          const SizedBox(height: 10),
          _infoRow(Icons.smartphone_rounded,      'Έκδοση εφαρμογής', 'v$driverVer'),
          if (phone.isNotEmpty) ...[
            const SizedBox(height: 10),
            _infoRow(Icons.phone_rounded,         'Τηλέφωνο',         phone),
          ],
          if (plateNumber.isNotEmpty) ...[
            const SizedBox(height: 10),
            _infoRow(Icons.directions_car_rounded, 'Πινακίδα',         plateNumber),
          ],
          const SizedBox(height: 20),
          if (phone.isNotEmpty)
            Row(children: [
              Expanded(child: _actionButton(
                icon: Icons.phone_rounded, label: 'Κλήση',
                color: const Color(0xFF1E8E3E),
                onTap: () => _launch('tel:$phone'),
              )),
              const SizedBox(width: 12),
              Expanded(child: _actionButton(
                icon: Icons.message_rounded, label: 'WhatsApp',
                color: const Color(0xFF25D366),
                onTap: () => _launch('https://wa.me/$waPhone'),
              )),
            ]),
        ],
      ),
    ),
  );
}

// ─── My Card ──────────────────────────────────────────────────────────────────

void showMyCard({
  required BuildContext     context,
  required String           displayName,
  required String           lastName,
  required String           phone,
  required String           vehicleModel,
  required String           plateNumber,
  required String           appVersion,
  required VehicleType      vehicleType,
  required bool             isOnline,
  required bool             isAvailable,
  required bool             isMuted,
  required String?          uid,
  required List<VoiceGroup> allGroups,
  required String           updateUrl,
}) {
  final myGroups = uid != null
      ? allGroups.where((g) => g.memberUids.contains(uid)).toList()
      : <VoiceGroup>[];

  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    builder: (ctx) => Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: EdgeInsets.fromLTRB(24, 12, 24, 32 + MediaQuery.of(ctx).padding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _handle(),
          Stack(alignment: Alignment.bottomRight, children: [
            CircleAvatar(
              radius: 40,
              backgroundColor: Colors.amber.shade50,
              child: Icon(
                vehicleType == VehicleType.van
                    ? Icons.airport_shuttle_rounded
                    : Icons.local_taxi_rounded,
                size: 44, color: Colors.amber.shade700,
              ),
            ),
            _statusDot(statusColor(online: isOnline, available: isAvailable)),
          ]),
          const SizedBox(height: 12),
          Text('$displayName $lastName'.trim(),
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF1A1A1A)),
              textAlign: TextAlign.center),
          const SizedBox(height: 4),
          Text(vehicleModel.isNotEmpty ? vehicleModel : 'Άγνωστο μοντέλο',
              style: TextStyle(color: Colors.grey[600], fontSize: 14)),
          const SizedBox(height: 4),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 6, runSpacing: 4,
            children: [
              _vehicleBadge(vehicleType),
              ...myGroups.map((g) => GroupBadge(name: g.name, color: g.color)),
            ],
          ),
          if (isMuted) ...[
            const SizedBox(height: 8),
            _muteBadge(),
          ],
          const SizedBox(height: 20),
          Divider(color: Colors.grey[200], height: 1),
          const SizedBox(height: 16),
          _infoRow(Icons.smartphone_rounded,      'Έκδοση εφαρμογής', 'v$appVersion'),
          if (phone.isNotEmpty) ...[
            const SizedBox(height: 10),
            _infoRow(Icons.phone_rounded,         'Τηλέφωνο',         phone),
          ],
          if (plateNumber.isNotEmpty) ...[
            const SizedBox(height: 10),
            _infoRow(Icons.directions_car_rounded, 'Πινακίδα',         plateNumber),
          ],
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: _actionButton(
              icon:  Icons.system_update_alt_rounded,
              label: 'Έλεγχος για ενημέρωση',
              color: Colors.amber.shade700,
              onTap: () => _launch(updateUrl),
            ),
          ),
        ],
      ),
    ),
  );
}

// ─── Shared helpers ───────────────────────────────────────────────────────────

String _formatTimestamp(dynamic ts) {
  if (ts == null || ts is! Timestamp) return 'Άγνωστο';
  final dt  = ts.toDate().toLocal();
  final d   = dt.day.toString().padLeft(2, '0');
  final m   = dt.month.toString().padLeft(2, '0');
  final h   = dt.hour.toString().padLeft(2, '0');
  final min = dt.minute.toString().padLeft(2, '0');
  return '$d/$m/${dt.year} $h:$min';
}

Future<void> _launch(String url) async {
  final uri = Uri.parse(url);
  if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
}

Widget _handle() => const SheetHandle(bottomMargin: 20);

Widget _statusDot(Color sc) => Container(
  width: 18, height: 18,
  decoration: BoxDecoration(
    color: sc, shape: BoxShape.circle,
    border: Border.all(color: Colors.white, width: 2),
  ),
);

Widget _vehicleBadge(VehicleType v) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
  decoration: BoxDecoration(
    color:        Colors.amber.shade50,
    borderRadius: BorderRadius.circular(20),
    border:       Border.all(color: Colors.amber.shade200),
  ),
  child: Text(v.name.toUpperCase(),
      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.amber.shade800)),
);

Widget _statusChip(Color sc, String label) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
  decoration: BoxDecoration(color: sc.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
  child: Row(mainAxisSize: MainAxisSize.min, children: [
    Container(width: 8, height: 8, decoration: BoxDecoration(color: sc, shape: BoxShape.circle)),
    const SizedBox(width: 6),
    Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: sc)),
  ]),
);

Widget _muteBadge() => Container(
  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
  decoration: BoxDecoration(
    color:        Colors.grey.shade100,
    borderRadius: BorderRadius.circular(20),
    border:       Border.all(color: Colors.grey.shade300),
  ),
  child: Row(mainAxisSize: MainAxisSize.min, children: [
    Icon(Icons.volume_off_rounded, size: 14, color: Colors.grey[600]),
    const SizedBox(width: 6),
    Text('Σίγαση ενεργή', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
  ]),
);

Widget _infoRow(IconData icon, String label, String value) => Row(children: [
  Container(
    width: 36, height: 36,
    decoration: BoxDecoration(color: Colors.grey[100], borderRadius: BorderRadius.circular(10)),
    child: Icon(icon, size: 18, color: Colors.grey[600]),
  ),
  const SizedBox(width: 12),
  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(label, style: TextStyle(fontSize: 11, color: Colors.grey[500])),
    Text(value,  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
  ]),
]);

Widget _actionButton({
  required IconData     icon,
  required String       label,
  required Color        color,
  required VoidCallback onTap,
}) {
  return GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(14)),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, color: Colors.white, size: 20),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15)),
      ]),
    ),
  );
}
