// lib/map/marker_builder.dart

import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../models.dart';

Future<MarkerAsset> buildMarkerAsset({
  required String      name,
  required VehicleType type,
  required Color       color,
  required double      currentZoom,
  List<Color>          groupColors = const [],
}) async {
  final iconData = switch (type) {
    VehicleType.taxi => Icons.local_taxi_rounded,
    VehicleType.van  => Icons.airport_shuttle_rounded,
    VehicleType.bus  => Icons.directions_bus_rounded,
  };

  // offline = χρώμα statusColor(online:false) = σχεδόν μαύρο (0xFF111111).
  // Το κίτρινο περίγραμμα μπαίνει ΜΟΝΟ τότε — πράσινο/κόκκινο (online) ήδη
  // ξεχωρίζουν αρκετά πάνω σε οποιοδήποτε φόντο, δεν χρειάζονται περίγραμμα.
  final isOfflineColor = color == const Color(0xFF111111);

  final scale      = ((currentZoom - 8) / 10).clamp(0.13, 0.26);
  final canvasH    = kBaseCanvasHeight * scale;
  final iconSize   = 150.0 * scale;
  final nameFontSz = 58.0  * scale;

  final finalTextColor = groupColors.isNotEmpty
      ? (groupColors.first.computeLuminance() > 0.5 ? Colors.black : Colors.white)
      : Colors.black87;

  final textPainter = TextPainter(
    text: TextSpan(
      text:  name,
      style: TextStyle(
        color:      finalTextColor,
        fontSize:   nameFontSz,
        fontWeight: FontWeight.w700,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();

  final iconPainter = TextPainter(
    text: TextSpan(
      text:  String.fromCharCode(iconData.codePoint),
      style: TextStyle(
        fontSize:   iconSize,
        fontFamily: iconData.fontFamily,
        package:    iconData.fontPackage,
        color:      color,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();

  // ── Κίτρινο περίγραμμα γύρω από το ΣΧΗΜΑ του οχήματος ──────────────────
  // Λύνει το πρόβλημα ορατότητας σε σκούρο χάρτη (offline = σχεδόν μαύρο
  // εικονίδιο, αόρατο πάνω σε μαύρο φόντο) ΧΩΡΙΣ να αλλάζει το ίδιο το
  // χρώμα κατάστασης: ζωγραφίζουμε το ΙΔΙΟ glyph λίγο μεγαλύτερο σε
  // κίτρινο ΠΡΩΤΑ (από κάτω), μετά το κανονικό glyph στο πραγματικό
  // μέγεθος/χρώμα ΠΑΝΩ του — το αποτέλεσμα μοιάζει με λεπτό contour.
  final outlinePainter = TextPainter(
    text: TextSpan(
      text:  String.fromCharCode(iconData.codePoint),
      style: TextStyle(
        fontSize:   iconSize + 5 * scale, // λίγο μεγαλύτερο → φαίνεται σαν στρώμα περιγράμματος
        fontFamily: iconData.fontFamily,
        package:    iconData.fontPackage,
        color:      const Color(0xFFEF9F27), // amber — ορατό σε κάθε φόντο
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();

  final hPad   = 16.0 * scale;
  final canvasW = [iconPainter.width, textPainter.width]
      .reduce((a, b) => a > b ? a : b) + hPad * 2;

  final recorder   = ui.PictureRecorder();
  final canvas     = Canvas(recorder);
  final centerX    = canvasW / 2;
  final carCenterY = canvasH * kCarCenterFraction;

  final textX = (canvasW - textPainter.width) / 2;
  final textY = carCenterY -
      (iconPainter.height / 2) -
      textPainter.height -
      4 * scale;

  if (groupColors.isNotEmpty) {
    for (var i = groupColors.length - 1; i >= 0; i--) {
      final padding = (8 + (i * 6)) * scale;
      final borderRect = RRect.fromLTRBR(
        textX - padding,
        textY - padding / 2,
        textX + textPainter.width + padding,
        textY + textPainter.height + padding / 2,
        Radius.circular(8 * scale),
      );
      if (i == 0) {
        canvas.drawRRect(borderRect, Paint()
          ..color = groupColors[0]
          ..style = PaintingStyle.fill);
      } else {
        canvas.drawRRect(borderRect, Paint()
          ..color = groupColors[i]
          ..style = PaintingStyle.stroke
          ..strokeWidth = 12 * scale);
      }
    }
  } else {
    final shadowPainter = TextPainter(
      text: TextSpan(
        text:  name,
        style: TextStyle(
          color:      Colors.white,
          fontSize:   nameFontSz,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    shadowPainter.paint(canvas, Offset(textX + 1.5, textY + 1.5));
    shadowPainter.paint(canvas, Offset(textX - 1.5, textY + 1.5));
    shadowPainter.paint(canvas, Offset(textX + 1.5, textY - 1.5));
    shadowPainter.paint(canvas, Offset(textX - 1.5, textY - 1.5));
  }

  textPainter.paint(canvas, Offset(textX, textY));
  // Στρώση περιγράμματος (κίτρινο, ελαφρώς μεγαλύτερο) — ΜΟΝΟ όταν ο
  // οδηγός είναι offline (αλλιώς πράσινο/κόκκινο ήδη ξεχωρίζουν αρκετά).
  if (isOfflineColor) {
    outlinePainter.paint(canvas, Offset(
      centerX - (outlinePainter.width / 2),
      carCenterY - (outlinePainter.height / 2),
    ));
  }
  // Το πραγματικό εικονίδιο (χρώμα κατάστασης) πάντα από ΠΑΝΩ.
  iconPainter.paint(canvas, Offset(
    centerX - (iconPainter.width / 2),
    carCenterY - (iconPainter.height / 2),
  ));

  final image = await recorder
      .endRecording()
      .toImage(canvasW.ceil(), canvasH.ceil());
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  final bytes    = byteData!.buffer.asUint8List();

  return (
    icon:   BitmapDescriptor.bytes(bytes),
    anchor: const Offset(0.5, kCarCenterFraction),
  );
}
