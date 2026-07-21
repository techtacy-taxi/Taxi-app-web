// lib/voice/voice_inbox.dart

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';

import 'voice_models.dart';
import 'voice_recorder.dart';
import 'voice_service.dart';
import '../jobs/job_shared_widgets.dart';
import '../app_theme.dart';

/// Ανοίγει το ίδιο inbox sheet απευθείας (π.χ. από το chip «Μηνύματα» στην
/// κύρια οθόνη) — χωρίς να χρειάζεται το FAB widget στο ίδιο σημείο.
void openVoiceInboxSheet({
  required BuildContext context,
  required String       uid,
  String displayName = '',
  String lastName    = '',
}) {
  showModalBottomSheet(
    context:            context,
    isScrollControlled: true,
    backgroundColor:    Colors.transparent,
    builder: (_) => StreamBuilder<List<VoiceMessage>>(
      stream: VoiceService.messagesFor(uid),
      builder: (context, snap) => _InboxSheet(
        uid:      uid,
        messages: snap.data ?? const [],
        displayName: displayName,
        lastName:    lastName,
      ),
    ),
  );
}

class VoiceInboxButton extends StatefulWidget {
  final String uid;

  const VoiceInboxButton({super.key, required this.uid});

  @override
  State<VoiceInboxButton> createState() => _VoiceInboxButtonState();
}

class _VoiceInboxButtonState extends State<VoiceInboxButton> {
  Stream<List<VoiceMessage>>? _stream;

  @override
  void initState() {
    super.initState();
    _stream = VoiceService.messagesFor(widget.uid);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<VoiceMessage>>(
      stream: _stream,
      builder: (context, snap) {
        final messages = snap.data ?? [];
        final unread   = messages
            .where((m) => m.fromUid != widget.uid && m.isUnread(widget.uid))
            .length;

        return Stack(
          clipBehavior: Clip.none,
          children: [
            Builder(builder: (context) {
              final c = AppColors.of(context);
              return FloatingActionButton(
                heroTag:         'voice_inbox',
                onPressed:       () => _openInbox(context, messages),
                backgroundColor: c.amber,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Icon(Icons.folder_rounded, color: c.onAmber, size: 26),
                    Positioned(
                      bottom: -2, right: -4,
                      child: Container(
                        decoration: BoxDecoration(
                          color: c.onAmber,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.sync_rounded, color: c.amber, size: 14),
                      ),
                    ),
                  ],
                ),
              );
            }),
            if (unread > 0)
              Positioned(
                top:   -4,
                right: -4,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(
                      color: Colors.red, shape: BoxShape.circle),
                  child: Text(
                    unread > 9 ? '9+' : '$unread',
                    style: const TextStyle(
                        color:      Colors.white,
                        fontSize:   10,
                        fontWeight: FontWeight.bold),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  void _openInbox(BuildContext context, List<VoiceMessage> messages) {
    showModalBottomSheet(
      context:            context,
      isScrollControlled: true,
      backgroundColor:    Colors.transparent,
      builder: (_) => _InboxSheet(
        uid:      widget.uid,
        messages: messages,
      ),
    );
  }
}

// ─── Inbox Sheet ──────────────────────────────────────────────────────────────

class _InboxSheet extends StatefulWidget {
  final String             uid;
  final List<VoiceMessage> messages;
  final String             displayName;
  final String             lastName;

  const _InboxSheet({
    required this.uid,
    required this.messages,
    this.displayName = '',
    this.lastName    = '',
  });

  @override
  State<_InboxSheet> createState() => _InboxSheetState();
}

class _InboxSheetState extends State<_InboxSheet>
    with SingleTickerProviderStateMixin {

  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    // Ύψος Android navigation bar — να μη σκεπάζει ΠΟΤΕ το τελευταίο
    // μήνυμα της λίστας (viewPadding πιάνει και τα 3-button nav bars).
    final bottomPad = MediaQuery.of(context).viewPadding.bottom;

    // Εισερχόμενα — μηνύματα που έστειλαν ΑΛΛΟΙ σε εμένα (max 20)
    final inbox = widget.messages
        .where((m) => m.fromUid != widget.uid)
        .take(20)
        .toList();

    // Εξερχόμενα — μηνύματα που έστειλα ΕΓΩ (max 10)
    final outbox = widget.messages
        .where((m) => m.fromUid == widget.uid)
        .take(10)
        .toList();

    final unreadCount = inbox.where((m) => m.isUnread(widget.uid)).length;

    return Container(
      decoration: BoxDecoration(
        color:        c.card,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border:       Border.all(color: c.cardBorder, width: 0.8),
      ),
      padding: EdgeInsets.fromLTRB(0, 12, 0, bottomPad + 20),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.75,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SheetHandle(bottomMargin: 12),

          // Header: τίτλος + «Νέο μήνυμα» (εγγραφή) — έτσι η εγγραφή μένει
          // προσβάσιμη από το ίδιο σημείο με τα μηνύματα, χωρίς ξεχωριστό
          // floating κουμπί μικροφώνου πάνω στον χάρτη.
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 16, 12),
            child: Row(children: [
              Text('Μηνύματα',
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600,
                      color: c.textMain)),
              const Spacer(),
              _NewMessageButton(
                uid: widget.uid,
                displayName: widget.displayName,
                lastName: widget.lastName,
              ),
            ]),
          ),

          // Tabs
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Container(
              decoration: BoxDecoration(
                color:        c.scaffold,
                borderRadius: BorderRadius.circular(12),
              ),
              child: TabBar(
                controller:          _tabController,
                indicator:           BoxDecoration(
                  color:        c.amber,
                  borderRadius: BorderRadius.circular(10),
                ),
                indicatorSize:       TabBarIndicatorSize.tab,
                dividerColor:        Colors.transparent,
                labelColor:          c.onAmber,
                unselectedLabelColor: c.textFaint,
                labelStyle: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 14),
                tabs: [
                  Tab(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.move_to_inbox_rounded, size: 16),
                        const SizedBox(width: 6),
                        const Text('Εισερχόμενα'),
                        if (unreadCount > 0) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: const BoxDecoration(
                              color:        Color(0xFFE24B4A),
                              borderRadius: BorderRadius.all(Radius.circular(10)),
                            ),
                            child: Text(
                              '$unreadCount',
                              style: const TextStyle(
                                  fontSize:   10,
                                  color:      Colors.white,
                                  fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const Tab(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.send_rounded, size: 16),
                        SizedBox(width: 6),
                        Text('Εξερχόμενα'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 8),
          Divider(color: c.divider, height: 1),

          // Content
          Flexible(
            child: TabBarView(
              controller: _tabController,
              children: [
                // ── Εισερχόμενα ──────────────────────────────────────────
                inbox.isEmpty
                    ? _EmptyState(
                  icon:  Icons.move_to_inbox_rounded,
                  label: 'Δεν υπάρχουν εισερχόμενα',
                )
                    : ListView.separated(
                  shrinkWrap:       true,
                  itemCount:        inbox.length,
                  separatorBuilder: (_, _) => Divider(color: c.divider, height: 1),
                  itemBuilder: (ctx, i) => _MessageTile(
                    message:  inbox[i],
                    uid:      widget.uid,
                    isOutbox: false,
                  ),
                ),

                // ── Εξερχόμενα ───────────────────────────────────────────
                outbox.isEmpty
                    ? _EmptyState(
                  icon:  Icons.send_rounded,
                  label: 'Δεν υπάρχουν εξερχόμενα',
                )
                    : ListView.separated(
                  shrinkWrap:       true,
                  itemCount:        outbox.length,
                  separatorBuilder: (_, _) => Divider(color: c.divider, height: 1),
                  itemBuilder: (ctx, i) => _MessageTile(
                    message:  outbox[i],
                    uid:      widget.uid,
                    isOutbox: true,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Message Tile ─────────────────────────────────────────────────────────────

class _MessageTile extends StatefulWidget {
  final VoiceMessage message;
  final String       uid;
  final bool         isOutbox;

  const _MessageTile({
    required this.message,
    required this.uid,
    required this.isOutbox,
  });

  @override
  State<_MessageTile> createState() => _MessageTileState();
}

class _MessageTileState extends State<_MessageTile> {
  final AudioPlayer _player = AudioPlayer();
  bool   _isPlaying = false;
  bool   _isLoading = false;
  double _progress  = 0;
  bool   _audioCtxSet = false;
  StreamSubscription? _posSub;
  StreamSubscription? _stateSub;

  @override
  void dispose() {
    _posSub?.cancel();
    _stateSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  /// Ρητά AndroidAudioAttributes: αντιμετωπίζει το μήνυμα ως ΦΩΝΗ (speech),
  /// όχι ως μουσική. Σε μερικές συσκευές (π.χ. Xiaomi) το default «media»
  /// routing εφαρμόζει εφέ που ακούγεται σαν «τούνελ». Το speech/voice
  /// attribute δίνει καθαρή, στεγνή αναπαραγωγή φωνής.
  Future<void> _ensureAudioContext() async {
    if (_audioCtxSet) return;
    try {
      await _player.setAndroidAudioAttributes(AndroidAudioAttributes(
        contentType: AndroidAudioContentType.speech,
        usage:       AndroidAudioUsage.media,
        flags:       AndroidAudioFlags.audibilityEnforced,
      ));
      _audioCtxSet = true;
    } catch (e) {
      // Αν το API διαφέρει στην εγκατεστημένη έκδοση, αγνόησε —
      // η αναπαραγωγή συνεχίζει κανονικά.
      debugPrint('setAndroidAudioAttributes not applied: $e');
      _audioCtxSet = true;
    }
  }

  Future<void> _togglePlay() async {
    if (_isPlaying) {
      await _player.pause();
      if (mounted) setState(() => _isPlaying = false);
      return;
    }

    setState(() => _isLoading = true);

    try {
      await _ensureAudioContext();

      String? localFile = await VoiceService.loadLocal(widget.message.id);
      localFile ??= await VoiceService.saveLocally(widget.message);

      await _player.setFilePath(localFile);

      _posSub?.cancel();
      _posSub = _player.positionStream.listen((pos) {
        if (!mounted) return;
        final total = widget.message.duration;
        if (total > 0) setState(() => _progress = pos.inSeconds / total);
      });

      _stateSub?.cancel();
      _stateSub = _player.playerStateStream.listen((state) {
        if (!mounted) return;
        if (state.processingState == ProcessingState.completed) {
          setState(() { _isPlaying = false; _progress = 0; });
        }
      });

      await _player.play();

      if (widget.message.isUnread(widget.uid)) {
        await VoiceService.markRead(widget.message.id, widget.uid);
      }

      if (mounted) setState(() { _isPlaying = true; _isLoading = false; });
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _formatDuration(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds  % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String _formatTime(DateTime dt) {
    final now  = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1)  return 'Μόλις τώρα';
    if (diff.inMinutes < 60) return '${diff.inMinutes}λ πριν';
    if (diff.inHours   < 24) return '${diff.inHours}ω πριν';
    return '${dt.day}/${dt.month}';
  }

  @override
  Widget build(BuildContext context) {
    final msg      = widget.message;
    final isUnread = !widget.isOutbox && msg.isUnread(widget.uid);

    final c = AppColors.of(context);

    // Εισερχόμενα: αποστολέας | Εξερχόμενα: παραλήπτης
    final displayName = widget.isOutbox
        ? '→ ${msg.toLabel}'
        : msg.fromFullName;

    final avatarLetter = widget.isOutbox
        ? msg.toLabel[0].toUpperCase()
        : (msg.fromName.isNotEmpty ? msg.fromName[0].toUpperCase() : '?');

    final avatarBg = widget.isOutbox ? c.blueSoft  : c.amberSoft;
    final avatarFg = widget.isOutbox ? c.blueDeep  : c.amberDeep;

    return Container(
      color: isUnread ? c.amberSoft.withValues(alpha: 0.5) : Colors.transparent,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          CircleAvatar(
            radius:          22,
            backgroundColor: avatarBg,
            child: Text(avatarLetter,
                style: TextStyle(
                    fontWeight: FontWeight.bold, color: avatarFg)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName,
                  style: TextStyle(
                      fontWeight: isUnread
                          ? FontWeight.bold
                          : FontWeight.w500,
                      fontSize: 14,
                      color: c.textMain),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value:           _progress,
                    backgroundColor: c.divider,
                    valueColor:      AlwaysStoppedAnimation<Color>(
                        _isPlaying ? c.amber : c.textFaint),
                    minHeight: 3,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(_formatDuration(msg.duration),
                        style: TextStyle(fontSize: 11, color: c.textFaint)),
                    const Spacer(),
                    Text(_formatTime(msg.timestamp),
                        style: TextStyle(fontSize: 11, color: c.textFaint)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _isLoading
              ? SizedBox(
            width: 40, height: 40,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: CircularProgressIndicator(strokeWidth: 2, color: c.amber),
            ),
          )
              : GestureDetector(
            onTap: _togglePlay,
            child: Container(
              width: 40, height: 40,
              decoration: BoxDecoration(
                color:  _isPlaying ? c.amber : c.amberSoft,
                shape: BoxShape.circle,
              ),
              child: Icon(
                _isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                color: _isPlaying ? c.onAmber : c.amberDeep,
                size:  22,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Empty state ──────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String   label;

  const _EmptyState({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.all(40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 64, color: c.textFaint.withValues(alpha: 0.5)),
          const SizedBox(height: 16),
          Text(label, style: TextStyle(color: c.textFaint, fontSize: 16)),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// «Νέο μήνυμα» — κουμπί μέσα στο header του inbox sheet. Ανοίγει ένα
// μικρό bottom sheet με το ΙΔΙΟ VoiceRecorderButton (hold-to-record,
// recipient picker με αναζήτηση) — έτσι η εγγραφή μένει προσβάσιμη από
// το ίδιο μέρος με τα μηνύματα, χωρίς ξεχωριστό floating κουμπί πάνω
// στον χάρτη.
// ─────────────────────────────────────────────────────────────────
class _NewMessageButton extends StatelessWidget {
  final String uid;
  final String displayName;
  final String lastName;

  const _NewMessageButton({
    required this.uid,
    required this.displayName,
    required this.lastName,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return TextButton.icon(
      onPressed: () => showModalBottomSheet(
        context: context,
        backgroundColor: Colors.transparent,
        builder: (sheetCtx) {
          final c2 = AppColors.of(sheetCtx);
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color:        c2.card,
                borderRadius: const BorderRadius.all(Radius.circular(24)),
                border:       Border.all(color: c2.cardBorder, width: 0.8),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text('Νέο μήνυμα φωνής',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600,
                          color: c2.textMain)),
                  const SizedBox(height: 16),
                  // Χρησιμοποιεί το ΙΔΙΟ VoiceRecorderButton — δεν αγγίζουμε
                  // καθόλου τη λογική εγγραφής/αποστολής/recipient picker.
                  _VoiceRecorderInline(uid: uid, displayName: displayName, lastName: lastName),
                ],
              ),
            ),
          );
        },
      ),
      icon: Icon(Icons.mic_none_rounded, size: 18, color: c.amberDeep),
      label: Text('Νέο μήνυμα',
          style: TextStyle(color: c.amberDeep, fontWeight: FontWeight.w600)),
    );
  }
}

class _VoiceRecorderInline extends StatelessWidget {
  final String uid;
  final String displayName;
  final String lastName;
  const _VoiceRecorderInline({
    required this.uid, required this.displayName, required this.lastName,
  });

  @override
  Widget build(BuildContext context) {
    return VoiceRecorderButton(
      fromUid: uid, fromName: displayName, fromLastName: lastName,
    );
  }
}