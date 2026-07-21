// lib/voice/voice_recorder.dart
//
// REDESIGN (εγκεκριμένο mockup): hold-to-record αντί για tap-to-toggle —
// κρατάς πατημένο το κουμπί για εγγραφή, αφήνεις για αποστολή (σαν
// WhatsApp). Παραλήπτης επιλέγεται ΠΡΩΤΑ (μέσω recipient_picker με
// αναζήτηση) — αν δεν έχει ήδη επιλεγεί, το πρώτο πάτημα ανοίγει τον
// picker αντί να ξεκινήσει εγγραφή.
//
// Η ΛΟΓΙΚΗ εγγραφής/timer/αποστολής/recorder lifecycle παραμένει ΙΔΙΑ
// με πριν — άλλαξε μόνο η αλληλεπίδραση (hold αντί tap) και το UI
// (ροζ ζωντανή κατάσταση με κύματα ήχου, όπως στο mockup).

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_sound/flutter_sound.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../app_theme.dart';
import 'recipient_picker.dart';
import 'voice_service.dart';

class VoiceRecorderButton extends StatefulWidget {
  final String fromUid;
  final String fromName;
  final String fromLastName;

  const VoiceRecorderButton({
    super.key,
    required this.fromUid,
    required this.fromName,
    required this.fromLastName,
  });

  @override
  State<VoiceRecorderButton> createState() => _VoiceRecorderButtonState();
}

class _VoiceRecorderButtonState extends State<VoiceRecorderButton>
    with SingleTickerProviderStateMixin {

  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();

  bool   _canSend       = true;
  bool   _isRecording   = false;
  bool   _isSending     = false;
  bool   _recorderReady = false;
  int    _seconds       = 0;
  Timer? _timer;

  RecipientSelection? _recipient;

  late AnimationController _waveController;

  static const int _maxSeconds = 30;
  static const double _cancelDragThreshold = -70; // px προς τα πάνω → ακύρωση

  double _dragOffset = 0;
  bool   _willCancel = false;

  @override
  void initState() {
    super.initState();
    _waveController = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
    _checkCanSend();
    _initRecorder();
  }

  @override
  void dispose() {
    _waveController.dispose();
    _timer?.cancel();
    _recorder.closeRecorder();
    super.dispose();
  }

  Future<void> _initRecorder() async {
    await _recorder.openRecorder();
    if (mounted) setState(() => _recorderReady = true);
  }

  Future<void> _checkCanSend() async {
    final can = await VoiceService.canSend(widget.fromUid);
    if (mounted) setState(() => _canSend = can);
  }

  // ─── Recipient ────────────────────────────────────────────────────────────

  Future<void> _pickRecipient() async {
    final result = await showRecipientPicker(
      context: context,
      fromUid: widget.fromUid,
    );
    if (result != null && mounted) {
      setState(() => _recipient = result);
    }
  }

  // ─── Recording (hold-to-record) ────────────────────────────────────────────

  Future<void> _onPressStart() async {
    if (!_recorderReady || _isRecording || _isSending) return;

    if (_recipient == null) {
      await _pickRecipient();
      if (_recipient == null) return;
    }

    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Δεν υπάρχει άδεια μικροφώνου')),
        );
      }
      return;
    }

    final dir  = await getApplicationDocumentsDirectory();
    final path = '${dir.path}/voice_temp.aac';

    await _recorder.startRecorder(
      toFile:      path,
      codec:       Codec.aacADTS,
      bitRate:     64000,
      sampleRate:  44100,
      numChannels: 1,
      enableVoiceProcessing: true,
    );

    HapticFeedback.mediumImpact();

    _seconds     = 0;
    _dragOffset  = 0;
    _willCancel  = false;
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() => _seconds++);
      if (_seconds >= _maxSeconds) _onPressEnd();
    });

    if (mounted) setState(() => _isRecording = true);
  }

  void _onDragUpdate(double dy) {
    if (!_isRecording) return;
    setState(() {
      _dragOffset = dy.clamp(_cancelDragThreshold * 1.4, 0);
      _willCancel = _dragOffset <= _cancelDragThreshold;
    });
  }

  Future<void> _onPressEnd() async {
    if (!_isRecording) return;
    _timer?.cancel();

    if (_willCancel) {
      await _recorder.stopRecorder();
      HapticFeedback.lightImpact();
      if (mounted) {
        setState(() { _isRecording = false; _seconds = 0; _dragOffset = 0; _willCancel = false; });
      }
      return;
    }

    final path = await _recorder.stopRecorder();
    if (!mounted) return;
    setState(() { _isRecording = false; _isSending = true; _dragOffset = 0; });

    if (path == null || _recipient == null || _seconds < 1) {
      setState(() => _isSending = false);
      return;
    }

    try {
      await VoiceService.sendMessage(
        fromUid:      widget.fromUid,
        fromName:     widget.fromName,
        fromLastName: widget.fromLastName,
        toType:       _recipient!.toType,
        toGroupId:    _recipient!.toGroupId,
        toGroupName:  _recipient!.toGroupName,
        toUid:        _recipient!.toUid,
        toName:       _recipient!.toName,
        audioFile:    File(path),
        duration:     _seconds,
        visibleTo:    _recipient!.visibleTo,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(children: [
              const Icon(Icons.check_circle_rounded, color: Colors.white),
              const SizedBox(width: 8),
              Text('Εστάλη σε: ${_recipient!.toLabel}'),
            ]),
            backgroundColor: const Color(0xFF1E8E3E),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Σφάλμα αποστολής: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() { _isSending = false; _seconds = 0; });
    }
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  String get _timerLabel {
    final m = _seconds ~/ 60;
    final s = _seconds  % 60;
    return '${m > 0 ? "$m:" : ""}${s.toString().padLeft(m > 0 ? 2 : 1, "0")}';
  }

  @override
  Widget build(BuildContext context) {
    if (!_canSend) return const SizedBox.shrink();
    final c = AppColors.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [

        // ── Chip παραλήπτη (idle state) ──
        if (_recipient != null && !_isRecording && !_isSending)
          GestureDetector(
            onTap: _pickRecipient,
            child: Container(
              margin: const EdgeInsets.only(bottom: 10, right: 4),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color:        c.card,
                borderRadius: BorderRadius.circular(20),
                border:       Border.all(color: c.cardBorder, width: 0.8),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.person_rounded, size: 14, color: c.amberDeep),
                const SizedBox(width: 5),
                Text(_recipient!.toLabel,
                    style: TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600, color: c.amberDeep)),
                const SizedBox(width: 4),
                Icon(Icons.edit_rounded, size: 12, color: c.textFaint),
              ]),
            ),
          ),

        // ── Ζωντανή κατάσταση εγγραφής (ροζ, με κύματα) ──
        if (_isRecording)
          Transform.translate(
            offset: Offset(0, _dragOffset),
            child: Container(
              margin: const EdgeInsets.only(bottom: 12, right: 4),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: _willCancel ? const Color(0xFFF6D5D5) : const Color(0xFFFBEAF0),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: _willCancel ? const Color(0xFFE24B4A) : const Color(0xFFED93B1),
                  width: 2,
                ),
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(_timerLabel,
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: _willCancel
                            ? const Color(0xFFA32D2D)
                            : const Color(0xFF72243E))),
                const SizedBox(height: 6),
                AnimatedBuilder(
                  animation: _waveController,
                  builder: (_, _) => SizedBox(
                    height: 20,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: List.generate(6, (i) {
                        final phase = (_waveController.value + i * 0.15) % 1.0;
                        final h = 6 + 14 * (0.5 + 0.5 * (1 - (phase - 0.5).abs() * 2));
                        return Container(
                          width: 3, height: h,
                          margin: const EdgeInsets.symmetric(horizontal: 1.5),
                          decoration: BoxDecoration(
                            color: _willCancel
                                ? const Color(0xFFA32D2D)
                                : const Color(0xFFD4537E),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        );
                      }),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _willCancel ? 'Άσε για ακύρωση' : 'Σύρε πάνω για ακύρωση',
                  style: TextStyle(
                      fontSize: 11,
                      color: _willCancel
                          ? const Color(0xFFA32D2D)
                          : const Color(0xFF993556)),
                ),
              ]),
            ),
          ),

        // ── Κύριο κουμπί ──
        GestureDetector(
          onLongPressStart:  (_) => _onPressStart(),
          onLongPressMoveUpdate: (d) => _onDragUpdate(d.offsetFromOrigin.dy),
          onLongPressEnd:    (_) => _onPressEnd(),
          onLongPressCancel: _onPressEnd,
          // Tap απλός: αν δεν έχει recipient ακόμη, άνοιξε τον picker.
          onTap: _recipient == null ? _pickRecipient : null,
          child: _isSending
              ? Container(
                  width: 64, height: 64,
                  decoration: BoxDecoration(color: c.amber, shape: BoxShape.circle),
                  padding: const EdgeInsets.all(18),
                  child: const CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : Container(
                  width: 64, height: 64,
                  decoration: BoxDecoration(
                    color: _isRecording
                        ? (_willCancel ? const Color(0xFFA32D2D) : const Color(0xFFD4537E))
                        : c.amberSoft,
                    shape: BoxShape.circle,
                    border: _isRecording
                        ? Border.all(
                            color: _willCancel
                                ? const Color(0xFFF09595)
                                : const Color(0xFFED93B1),
                            width: 3)
                        : null,
                  ),
                  child: Icon(
                    _isRecording ? Icons.mic_rounded : Icons.mic_none_rounded,
                    color: _isRecording ? Colors.white : c.amberDeep,
                    size: 30,
                  ),
                ),
        ),
        if (!_isRecording && !_isSending)
          Padding(
            padding: const EdgeInsets.only(top: 6, right: 2),
            child: Text(
              _recipient == null ? 'Πάτα για παραλήπτη' : 'Κράτα πατημένο',
              style: TextStyle(fontSize: 10.5, color: c.textFaint),
            ),
          ),
      ],
    );
  }
}
