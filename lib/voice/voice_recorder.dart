// lib/voice/voice_recorder.dart

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'voice_service.dart';
import 'recipient_picker.dart';

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

  bool   _canSend      = true;
  bool   _isRecording  = false;
  bool   _isSending    = false;
  bool   _recorderReady = false;
  int    _seconds      = 0;
  Timer? _timer;

  RecipientSelection? _recipient;

  late AnimationController _pulseController;
  late Animation<double>   _pulseAnimation;

  static const int _maxSeconds = 30;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.15)
        .animate(CurvedAnimation(
            parent: _pulseController, curve: Curves.easeInOut));
    _checkCanSend();
    _initRecorder();
  }

  @override
  void dispose() {
    _pulseController.dispose();
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

  // ─── Recording ────────────────────────────────────────────────────────────

  Future<void> _startRecording() async {
    if (!_recorderReady) return;

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
      bitRate:     64000,        // ↑ από 32k για πιο καθαρή φωνή
      sampleRate:  44100,        // ρητό sampleRate ώστε να μην ακούγεται «βαρελίσιο»
      numChannels: 1,            // mono — αρκεί για φωνή, μικρότερο αρχείο
      // Ενεργοποιεί echo cancellation + noise suppression + auto-gain σε
      // επίπεδο OS. Αυτό διώχνει την αντήχηση «σαν τούνελ».
      enableVoiceProcessing: true,
    );

    _seconds = 0;
    _timer   = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() => _seconds++);
      if (_seconds >= _maxSeconds) _stopAndSend();
    });

    if (mounted) setState(() => _isRecording = true);
  }

  Future<void> _cancelRecording() async {
    _timer?.cancel();
    await _recorder.stopRecorder();
    if (mounted) setState(() { _isRecording = false; _seconds = 0; });
  }

  Future<void> _stopAndSend() async {
    _timer?.cancel();
    final path = await _recorder.stopRecorder();
    if (!mounted) return;
    setState(() { _isRecording = false; _isSending = true; });

    if (path == null || _recipient == null) {
      setState(() => _isSending = false);
      return;
    }

    try {
      await VoiceService.sendMessage(
        fromUid:     widget.fromUid,
        fromName:    widget.fromName,
        fromLastName: widget.fromLastName,
        toType:      _recipient!.toType,
        toGroupId:   _recipient!.toGroupId,
        toGroupName: _recipient!.toGroupName,
        toUid:       _recipient!.toUid,
        toName:      _recipient!.toName,
        audioFile:   File(path),
        duration:    _seconds,
        visibleTo:   _recipient!.visibleTo,
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
        setState(() => _recipient = null);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Σφάλμα αποστολής: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() { _isSending = false; _seconds = 0; });
    }
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  String get _timerLabel => '${_maxSeconds - _seconds}s';

  @override
  Widget build(BuildContext context) {
    if (!_canSend) return const SizedBox.shrink();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [

        // Recipient chip
        if (_recipient != null && !_isRecording)
          GestureDetector(
            onTap: _pickRecipient,
            child: Container(
              margin: const EdgeInsets.only(bottom: 8, right: 4),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color:      Colors.black.withValues(alpha: 0.1),
                    blurRadius: 6,
                    offset:     const Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.person_rounded,
                      size: 14, color: Colors.amber.shade700),
                  const SizedBox(width: 4),
                  Text(_recipient!.toLabel,
                      style: TextStyle(
                          fontSize:   12,
                          fontWeight: FontWeight.w600,
                          color:      Colors.amber.shade800)),
                  const SizedBox(width: 4),
                  Icon(Icons.edit_rounded, size: 12, color: Colors.grey[400]),
                ],
              ),
            ),
          ),

        // Timer bar
        if (_isRecording)
          Container(
            margin: const EdgeInsets.only(bottom: 8, right: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color:  Colors.red.shade50,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.red.shade200),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.fiber_manual_record_rounded,
                    size: 10, color: Colors.red.shade600),
                const SizedBox(width: 6),
                Text('REC  $_timerLabel',
                    style: TextStyle(
                        fontSize:   12,
                        fontWeight: FontWeight.w700,
                        color:      Colors.red.shade700)),
              ],
            ),
          ),

        Row(
          mainAxisSize: MainAxisSize.min,
          children: [

            // Cancel κουμπί
            if (_isRecording)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FloatingActionButton.small(
                  heroTag:         'voice_cancel',
                  onPressed:       _cancelRecording,
                  backgroundColor: Colors.grey[200],
                  child: const Icon(Icons.close_rounded, color: Colors.black54),
                ),
              ),

            // Κύριο κουμπί
            _isSending
                ? Container(
                    width: 56, height: 56,
                    decoration: const BoxDecoration(
                        color: Colors.amber, shape: BoxShape.circle),
                    child: const Padding(
                      padding: EdgeInsets.all(16),
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    ),
                  )
                : _isRecording
                    ? ScaleTransition(
                        scale: _pulseAnimation,
                        child: FloatingActionButton(
                          heroTag:         'voice_stop',
                          onPressed:       _stopAndSend,
                          backgroundColor: Colors.red,
                          child: const Icon(Icons.stop_rounded,
                              color: Colors.white, size: 28),
                        ),
                      )
                    : FloatingActionButton(
                        heroTag:         'voice_record',
                        onPressed:       _recipient == null
                            ? _pickRecipient
                            : _startRecording,
                        backgroundColor: Colors.amber,
                        child: Icon(
                          _recipient == null
                              ? Icons.record_voice_over_rounded
                              : Icons.mic_rounded,
                          color: Colors.white,
                          size:  28,
                        ),
                      ),
          ],
        ),
      ],
    );
  }
}
