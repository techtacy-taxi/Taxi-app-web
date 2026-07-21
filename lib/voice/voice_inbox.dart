// lib/voice/voice_inbox.dart

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';

import 'voice_models.dart';
import 'voice_service.dart';
import '../jobs/job_shared_widgets.dart';

/// Ανοίγει το ίδιο inbox sheet απευθείας (π.χ. από το chip «Μηνύματα» στην
/// κύρια οθόνη) — χωρίς να χρειάζεται το FAB widget στο ίδιο σημείο.
void openVoiceInboxSheet({
  required BuildContext context,
  required String       uid,
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
            FloatingActionButton(
              heroTag:         'voice_inbox',
              onPressed:       () => _openInbox(context, messages),
              backgroundColor: Colors.amber, // <-- ΝΕΟ: Κίτρινο φόντο
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  const Icon(Icons.folder_rounded, color: Colors.white, size: 26), // <-- ΝΕΟ: Άσπρο εικονίδιο
                  Positioned(
                    bottom: -2, right: -4,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.sync_rounded, color: Colors.amber, size: 14),
                    ),
                  ),
                ],
              ),
            ),
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

  const _InboxSheet({required this.uid, required this.messages});

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
    final bottomPad = MediaQuery.of(context).padding.bottom;

    // Εισερχόμενα — μηνύματα που έστειλαν ΑΛΛΟΙ σε εμένα (max 10)
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
      decoration: const BoxDecoration(
        color:        Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: EdgeInsets.fromLTRB(0, 12, 0, bottomPad + 20),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.75,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          const SheetHandle(bottomMargin: 16),

          // Tabs
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Container(
              decoration: BoxDecoration(
                color:        Colors.grey[100],
                borderRadius: BorderRadius.circular(12),
              ),
              child: TabBar(
                controller:          _tabController,
                indicator:           BoxDecoration(
                  color:        Colors.amber,
                  borderRadius: BorderRadius.circular(10),
                ),
                indicatorSize:       TabBarIndicatorSize.tab,
                dividerColor:        Colors.transparent,
                labelColor:          Colors.white,
                unselectedLabelColor: Colors.grey[600],
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
                            decoration: BoxDecoration(
                              color:        Colors.red,
                              borderRadius: BorderRadius.circular(10),
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
          Divider(color: Colors.grey[200], height: 1),

          // Content
          Flexible(
            child: TabBarView(
              controller: _tabController,
              children: [
                // ── Εισερχόμενα ──────────────────────────────────────────
                inbox.isEmpty
                    ? const _EmptyState(
                  icon:  Icons.move_to_inbox_rounded,
                  label: 'Δεν υπάρχουν εισερχόμενα',
                )
                    : ListView.separated(
                  shrinkWrap:       true,
                  itemCount:        inbox.length,
                  separatorBuilder: (_, _) =>
                      Divider(color: Colors.grey[100], height: 1),
                  itemBuilder: (ctx, i) => _MessageTile(
                    message:  inbox[i],
                    uid:      widget.uid,
                    isOutbox: false,
                  ),
                ),

                // ── Εξερχόμενα ───────────────────────────────────────────
                outbox.isEmpty
                    ? const _EmptyState(
                  icon:  Icons.send_rounded,
                  label: 'Δεν υπάρχουν εξερχόμενα',
                )
                    : ListView.separated(
                  shrinkWrap:       true,
                  itemCount:        outbox.length,
                  separatorBuilder: (_, _) =>
                      Divider(color: Colors.grey[100], height: 1),
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

    // Εισερχόμενα: αποστολέας | Εξερχόμενα: παραλήπτης
    final displayName = widget.isOutbox
        ? '→ ${msg.toLabel}'
        : msg.fromFullName;

    final avatarLetter = widget.isOutbox
        ? msg.toLabel[0].toUpperCase()
        : (msg.fromName.isNotEmpty ? msg.fromName[0].toUpperCase() : '?');

    final avatarBg = widget.isOutbox
        ? Colors.blue.shade100
        : Colors.amber.shade100;

    final avatarFg = widget.isOutbox
        ? Colors.blue.shade700
        : Colors.amber.shade700;

    return Container(
      color: isUnread ? Colors.amber.shade50 : Colors.transparent,
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
                      fontSize: 14),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value:           _progress,
                    backgroundColor: Colors.grey[200],
                    valueColor:      AlwaysStoppedAnimation<Color>(
                        _isPlaying ? Colors.amber : Colors.grey.shade400),
                    minHeight: 3,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(_formatDuration(msg.duration),
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey[500])),
                    const Spacer(),
                    Text(_formatTime(msg.timestamp),
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey[400])),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _isLoading
              ? const SizedBox(
            width: 40, height: 40,
            child: Padding(
              padding: EdgeInsets.all(10),
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.amber),
            ),
          )
              : GestureDetector(
            onTap: _togglePlay,
            child: Container(
              width: 40, height: 40,
              decoration: BoxDecoration(
                color:  _isPlaying ? Colors.amber : Colors.amber.shade100,
                shape: BoxShape.circle,
              ),
              child: Icon(
                _isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                color: _isPlaying ? Colors.white : Colors.amber.shade700,
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
    return Padding(
      padding: const EdgeInsets.all(40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 64, color: Colors.grey[300]),
          const SizedBox(height: 16),
          Text(label,
              style: TextStyle(color: Colors.grey[400], fontSize: 16)),
        ],
      ),
    );
  }
}