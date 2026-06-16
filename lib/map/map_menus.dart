// lib/map/map_menus.dart

import 'package:flutter/material.dart';
import '../models.dart';

Future<VehicleType?> showVehicleTypeMenu({
  required BuildContext context,
  required BuildContext itemCtx,
  required VehicleType  currentType,
}) async {
  final RenderBox box    = itemCtx.findRenderObject() as RenderBox;
  final Offset    offset = box.localToGlobal(Offset.zero);
  final screenW          = MediaQuery.of(context).size.width;
  const menuW            = 220.0;
  final left             = (offset.dx + menuW > screenW)
      ? screenW - menuW - 8
      : offset.dx;

  return showGeneralDialog<VehicleType>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '',
    barrierColor: Colors.black.withValues(alpha: 0.25),
    transitionDuration: const Duration(milliseconds: 150),
    transitionBuilder: (ctx, anim, _, child) => FadeTransition(
      opacity: anim,
      child: ScaleTransition(
        scale: Tween(begin: 0.92, end: 1.0).animate(
            CurvedAnimation(parent: anim, curve: Curves.easeOut)),
        alignment: Alignment.topRight,
        child: child,
      ),
    ),
    pageBuilder: (ctx, _, _) => Stack(children: [
      Positioned(
        left: left, top: offset.dy - 8, width: menuW,
        child: Material(
          color: Colors.transparent,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.amber.shade50,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 20, offset: const Offset(0, 6))],
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                child: Row(children: [
                  const Icon(Icons.directions_car_rounded, size: 16, color: Colors.black87),
                  const SizedBox(width: 8),
                  const Text('Επιλογή Οχήματος',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                          color: Colors.black87, letterSpacing: 0.5)),
                ]),
              ),
              const Divider(height: 1, color: Colors.black12),
              _subMenuItem(ctx: ctx, icon: Icons.local_taxi_rounded, label: 'Taxi',
                  selected: currentType == VehicleType.taxi, activeColor: Colors.black,
                  onTap: () => Navigator.pop(ctx, VehicleType.taxi)),
              _subMenuItem(ctx: ctx, icon: Icons.airport_shuttle_rounded, label: 'Van',
                  selected: currentType == VehicleType.van, activeColor: Colors.black,
                  onTap: () => Navigator.pop(ctx, VehicleType.van)),
              const SizedBox(height: 6),
            ]),
          ),
        ),
      ),
    ]),
  );
}

Future<bool?> showMuteStateMenu({
  required BuildContext context,
  required BuildContext itemCtx,
  required bool         isMuted,
}) async {
  final RenderBox box    = itemCtx.findRenderObject() as RenderBox;
  final Offset    offset = box.localToGlobal(Offset.zero);
  final screenW          = MediaQuery.of(context).size.width;
  const menuW            = 220.0;
  final left             = (offset.dx + menuW > screenW)
      ? screenW - menuW - 8
      : offset.dx;

  return showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '',
    barrierColor: Colors.black.withValues(alpha: 0.25),
    transitionDuration: const Duration(milliseconds: 150),
    transitionBuilder: (ctx, anim, _, child) => FadeTransition(
      opacity: anim,
      child: ScaleTransition(
        scale: Tween(begin: 0.92, end: 1.0).animate(
            CurvedAnimation(parent: anim, curve: Curves.easeOut)),
        alignment: Alignment.topRight,
        child: child,
      ),
    ),
    pageBuilder: (ctx, _, _) => Stack(children: [
      Positioned(
        left: left, top: offset.dy - 8, width: menuW,
        child: Material(
          color: Colors.transparent,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.amber.shade50,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 20, offset: const Offset(0, 6))],
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                child: Row(children: [
                  const Icon(Icons.volume_up_rounded, size: 16, color: Colors.black87),
                  const SizedBox(width: 8),
                  const Text('Ηχητικά Μηνύματα',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                          color: Colors.black87, letterSpacing: 0.5)),
                ]),
              ),
              const Divider(height: 1, color: Colors.black12),
              _subMenuItem(ctx: ctx, icon: Icons.volume_up_rounded, label: 'Ενεργά',
                  selected: !isMuted, activeColor: Colors.green.shade900,
                  onTap: () => Navigator.pop(ctx, false)),
              _subMenuItem(ctx: ctx, icon: Icons.volume_off_rounded, label: 'Σίγαση',
                  selected: isMuted, activeColor: Colors.red.shade900,
                  onTap: () => Navigator.pop(ctx, true)),
              const SizedBox(height: 6),
            ]),
          ),
        ),
      ),
    ]),
  );
}

Widget _subMenuItem({
  required BuildContext ctx,
  required IconData     icon,
  required String       label,
  required bool         selected,
  required Color        activeColor,
  required VoidCallback onTap,
}) {
  return InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(10),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: selected
            ? BoxDecoration(
                color: Colors.black.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.black26, width: 1.5),
              )
            : null,
        child: Row(children: [
          Icon(icon, color: selected ? activeColor : Colors.black45, size: 20),
          const SizedBox(width: 12),
          Text(label, style: TextStyle(
            fontWeight: selected ? FontWeight.bold : FontWeight.w600,
            color:      selected ? activeColor : Colors.black87,
          )),
          if (selected) ...[
            const Spacer(),
            Icon(Icons.check_circle_rounded, color: activeColor, size: 16),
          ],
        ]),
      ),
    ),
  );
}
