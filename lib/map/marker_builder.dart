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
  final iconData = type == VehicleType.taxi
      ? Icons.local_taxi_rounded
      : Icons.airport_shuttle_rounded;

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
