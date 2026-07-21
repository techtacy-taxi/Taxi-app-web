// lib/voice/messages_recorder_chip.dart
//
// Το chip «Μηνύματα» πάνω στον χάρτη έχει ΔΙΠΛΗ συμπεριφορά, ίδια λογική
// με το WhatsApp/Telegram:
//   • Απλό TAP        → ανοίγει το inbox sheet (Εισερχόμενα/Εξερχόμενα).
//   • ΚΡΑΤΑ πατημένο  → ξεκινάει ΑΜΕΣΩΣ ηχογράφηση εδώ, πάνω στον χάρτη
//                       (αν δεν έχεις παραλήπτη ακόμη, πρώτα ανοίγει ο
//                       picker παραλήπτη — ίδιο μοτίβο με το παλιό
//                       VoiceRecorderButton μέσα στο sheet).
//   • Κρατώντας        → το chip μεταμορφώνεται σε ζωντανή κατάσταση
//                       εγγραφής με χρονόμετρο + κυματομορφή που
//                       αναπνέει, ίδιο σχεδιαστικά με το popup «Νέα
//                       δουλειά».
//   • Αφήνεις          → σταματάει η εγγραφή και ΑΜΕΣΩΣ ανοίγει ο
//                       επιλογέας παραλήπτη (αν δεν είχε ήδη επιλεγεί
//                       πριν), μετά στέλνεται.
//   • Σύρε πάνω ενώ κρατάς → ακύρωση εγγραφής (ίδιο με πριν).
//
// Καμία αλλαγή στη λογική εγγραφής/αποστολής/recipient picker — όλα
// έρχονται από το VoiceService/RecipientSelection, ίδια με πριν.

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

class MessagesRecorderChip extends StatefulWidget {
  final String fromUid;
  final String fromName;
  final String fromLastName;
  final String label;       // π.χ. "Μηνύματα" ή "3 νέα"
  final Color  iconColor;
  final VoidCallback onTapOpenInbox;

  const MessagesRecorderChip({
    super.key,
    required this.fromUid,
    required this.fromName,
    required this.fromLastName,
    required this.label,
    required this.iconColor,
    required this.onTapOpenInbox,
  });

  @override
  State<MessagesRecorderChip> createState() => _MessagesRecorderChipState();
}

class _MessagesRecorderChipState extends State<MessagesRecorderChip>
    with SingleTickerProviderStateMixin {
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();

  bool   _recorderReady = false;
  bool   _isRecording   = false;
  bool   _isSending     = false;
  int    _seconds       = 0;
  Timer? _timer;

  RecipientSelection? _recipient;

  late final AnimationController _waveController;

  static const int    _maxSeconds          = 30;
  static const double _cancelDragThreshold = -70; // px προς τα πάνω → ακύρωση

  double _dragOffset = 0;
  bool   _willCancel = false;

  @override
  void initState() {
    super.initState();
    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
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

  Future<void> _pickRecipient() async {
    final result = await showRecipientPicker(
      context: context,
      fromUid: widget.fromUid,
    );
    if (result != null && mounted) {
      setState(() => _recipient = result);
    }
  }

  // ─── Εγγραφή (κράτα πατημένο) ─────────────────────────────────────────────

  Future<void> _onPressStart() async {
    if (!_recorderReady || _isRecording || _isSending) return;

    if (_recipient == null) {
      await _pickRecipient();
      if (_recipient == null) return; // ακύρωσε τον picker → καμία εγγραφή
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
    final path = '${dir.path}/voice_temp_chip.aac';

    await _recorder.startRecorder(
      toFile: path,
      codec: Codec.aacADTS,
      bitRate: 64000,
      sampleRate: 44100,
      numChannels: 1,
      enableVoiceProcessing: true,
    );

    HapticFeedback.mediumImpact();

    _seconds    = 0;
    _dragOffset = 0;
    _willCancel = false;
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
        setState(() {
          _isRecording = false;
          _seconds = 0;
          _dragOffset = 0;
          _willCancel = false;
        });
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
          SnackBar(content: Text('Σφάλμα αποστολής: $e'),
              backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() { _isSending = false; _seconds = 0; });
    }
  }

  String get _timerLabel {
    final m = _seconds ~/ 60;
    final s = _seconds  % 60;
    return '${m > 0 ? "$m:" : ""}${s.toString().padLeft(m > 0 ? 2 : 1, "0")}';
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    if (_isRecording) return _recordingChip(c);
    if (_isSending)   return _sendingChip(c);
    return _idleChip(c);
  }

  // ── Κατάσταση ηρεμίας: ίδιο chip με πριν, TAP ανοίγει sheet, LONG-PRESS
  //    ξεκινάει εγγραφή ─────────────────────────────────────────────────────
  Widget _idleChip(AppColors c) {
    return GestureDetector(
      onTap: widget.onTapOpenInbox,
      onLongPressStart:      (_) => _onPressStart(),
      onLongPressMoveUpdate: (d) => _onDragUpdate(d.offsetFromOrigin.dy),
      onLongPressEnd:        (_) => _onPressEnd(),
      onLongPressCancel:     _onPressEnd,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color:        c.card.withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(14),
          border:       Border.all(color: c.cardBorder, width: 0.8),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.mic_rounded, size: 19, color: widget.iconColor),
          const SizedBox(width: 7),
          Flexible(
            child: Text(widget.label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600,
                    color: c.textMain)),
          ),
        ]),
      ),
    );
  }

  // ── Ζωντανή εγγραφή: χρονόμετρο + κυματομορφή, ίδιο σχεδιαστικά με το
  //    popup «Νέα δουλειά» ─────────────────────────────────────────────────
  Widget _recordingChip(AppColors c) {
    final bg     = _willCancel ? const Color(0xFFF6D5D5) : const Color(0xFFFBEAF0);
    final border = _willCancel ? const Color(0xFFE24B4A) : const Color(0xFFED93B1);
    final fg     = _willCancel ? const Color(0xFFA32D2D) : const Color(0xFF72243E);
    final wave   = _willCancel ? const Color(0xFFA32D2D) : const Color(0xFFD4537E);

    return GestureDetector(
      onLongPressMoveUpdate: (d) => _onDragUpdate(d.offsetFromOrigin.dy),
      onLongPressEnd:        (_) => _onPressEnd(),
      onLongPressCancel:     _onPressEnd,
      child: Transform.translate(
        offset: Offset(0, _dragOffset),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color:        bg,
            borderRadius: BorderRadius.circular(14),
            border:       Border.all(color: border, width: 2),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.fiber_manual_record_rounded, size: 14, color: fg),
            const SizedBox(width: 7),
            Text(_timerLabel,
                style: TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w700, color: fg)),
            const SizedBox(width: 9),
            AnimatedBuilder(
              animation: _waveController,
              builder: (_, _) => SizedBox(
                height: 16,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: List.generate(5, (i) {
                    final phase = (_waveController.value + i * 0.17) % 1.0;
                    final h = 5 + 11 * (0.5 + 0.5 * (1 - (phase - 0.5).abs() * 2));
                    return Container(
                      width: 2.5, height: h,
                      margin: const EdgeInsets.symmetric(horizontal: 1.2),
                      decoration: BoxDecoration(
                        color: wave,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    );
                  }),
                ),
              ),
            ),
            const SizedBox(width: 9),
            Flexible(
              child: Text(
                _willCancel ? 'Άσε για ακύρωση' : 'Σύρε πάνω για ακύρωση',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10.5, color: fg.withValues(alpha: 0.85)),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  // ── Αποστολή σε εξέλιξη ───────────────────────────────────────────────────
  Widget _sendingChip(AppColors c) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color:        c.card.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(14),
        border:       Border.all(color: c.cardBorder, width: 0.8),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 16, height: 16,
          child: CircularProgressIndicator(strokeWidth: 2, color: c.amber),
        ),
        const SizedBox(width: 8),
        Text('Αποστολή…',
            style: TextStyle(
                fontSize: 14, fontWeight: FontWeight.w600, color: c.textMain)),
      ]),
    );
  }
}
