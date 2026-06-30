// lib/jobs/job_shared_widgets.dart
// Κοινά widgets που χρησιμοποιούνται σε πολλά αρχεία του jobs module

import 'package:flutter/material.dart';
import 'job_service.dart';

// ─── SheetHandle ──────────────────────────────────────────────────────────────
//
// Το γκρι «χερούλι» (drag handle) που μπαίνει στην κορυφή των bottom sheets.
// Πέρα από διακοσμητικό, είναι ΕΝΕΡΓΟ: σύροντάς το προς τα κάτω (ή με γρήγορη
// κίνηση swipe-down) κλείνει το sheet — έτσι ο χρήστης το πιάνει από το χερούλι,
// όχι μόνο από το σώμα. Tap πάνω του δεν κάνει τίποτα (αποφυγή κατά λάθος).
//
// Χρήση: αντικατέστησε το παλιό `Container(width: 40, height: 4, ...)` με
//        `const SheetHandle()`.
class SheetHandle extends StatelessWidget {
  /// Κάθετο περιθώριο κάτω από το χερούλι (default 14).
  final double bottomMargin;
  const SheetHandle({super.key, this.bottomMargin = 14});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // Σύρσιμο προς τα κάτω → κλείσιμο του sheet.
      onVerticalDragUpdate: (d) {
        if (d.primaryDelta != null && d.primaryDelta! > 6) {
          if (Navigator.of(context).canPop()) Navigator.of(context).pop();
        }
      },
      onVerticalDragEnd: (d) {
        if ((d.primaryVelocity ?? 0) > 250) {
          if (Navigator.of(context).canPop()) Navigator.of(context).pop();
        }
      },
      // Μεγαλύτερη περιοχή αφής γύρω από τη λεπτή μπάρα ώστε να πιάνεται εύκολα.
      child: Container(
        color: Colors.transparent,
        padding: EdgeInsets.only(top: 4, bottom: bottomMargin),
        alignment: Alignment.center,
        child: Container(
          width: 40, height: 4,
          decoration: BoxDecoration(
            color: Colors.grey[300],
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}


// ─── Empty state ──────────────────────────────────────────────────────────────

Widget jobEmpty(String label) => Center(child: Padding(
  padding: const EdgeInsets.all(40),
  child: Column(mainAxisSize: MainAxisSize.min, children: [
    Icon(Icons.work_off_rounded, size: 64, color: Colors.grey[300]),
    const SizedBox(height: 16),
    Text(label, style: TextStyle(color: Colors.grey[400], fontSize: 16)),
  ]),
));

// ─── Confirm Cancel/Reopen Dialog ─────────────────────────────────────────────

/// Επιστρέφει `true` αν έγινε ακύρωση ή επανέκδοση (ώστε ο caller να
/// ανανεώσει αμέσως τη λίστα), `false` αν ο χρήστης πάτησε «Πίσω».
Future<bool> showCancelDialog(
  BuildContext context, {
  required String  from,
  required String  to,
  required String  jobId,
  String?          takenByName,
  bool             allowReopen = true,
}) async {
  final choice = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Row(children: [
        Icon(Icons.cancel_rounded, color: Colors.red, size: 24),
        SizedBox(width: 10),
        Text('Ακύρωση Δουλειάς',
            style: TextStyle(fontWeight: FontWeight.bold)),
      ]),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('$from → $to',
            style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        if (takenByName != null)
          Text('Ο οδηγός $takenByName δεν θα χρεωθεί τίποτα.',
              style: TextStyle(fontSize: 12, color: Colors.grey[600])),
        const SizedBox(height: 16),
        const Text('Τι θέλεις να κάνεις;',
            style: TextStyle(fontWeight: FontWeight.w600)),
      ]),
      actions: [
        AppButtonTonal(
          label: 'Πίσω',
          onPressed: () => Navigator.pop(ctx, null),
        ),
        if (allowReopen)
          AppButton(
            label: 'Ξανά για Διεκδίκηση',
            icon: Icons.replay_rounded,
            color: const Color(0xFF1E8E3E),
            onPressed: () => Navigator.pop(ctx, 'reopen'),
          ),
        AppButton(
          label: 'Ακύρωση',
          icon: Icons.cancel_rounded,
          color: Colors.red,
          onPressed: () => Navigator.pop(ctx, 'cancel'),
        ),
      ],
    ),
  );
  if (choice == 'cancel') {
    await JobService.cancelJob(jobId);
    return true;
  }
  if (choice == 'reopen') {
    await JobService.reopenJob(jobId);
    return true;
  }
  return false;
}

// ─── Info Chip ────────────────────────────────────────────────────────────────

Widget jobChip(IconData icon, String label, Color color) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
  decoration: BoxDecoration(
    color:        color.withValues(alpha: 0.1),
    borderRadius: BorderRadius.circular(8),
    border:       Border.all(color: color.withValues(alpha: 0.3)),
  ),
  child: Row(mainAxisSize: MainAxisSize.min, children: [
    Icon(icon, size: 12, color: color),
    const SizedBox(width: 4),
    Flexible(child: Text(label,
        style: TextStyle(fontSize: 11, color: color,
            fontWeight: FontWeight.w600))),
  ]),
);

// ─── Picker Sheet ─────────────────────────────────────────────────────────────

class JobPickerSheet extends StatelessWidget {
  final String   title;
  final IconData icon;
  final List<Map<String, dynamic>> items;
  final String?  selectedId;
  final void Function(String? id, String name) onSelected;

  const JobPickerSheet({
    super.key,
    required this.title,
    required this.icon,
    required this.items,
    required this.selectedId,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.fromLTRB(
          16, 12, 16, 16 + MediaQuery.of(context).padding.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 40, height: 4,
          margin: const EdgeInsets.only(bottom: 14),
          decoration: BoxDecoration(
              color: Colors.grey[300],
              borderRadius: BorderRadius.circular(2)),
        ),
        Row(children: [
          Icon(icon, size: 20),
          const SizedBox(width: 10),
          Text(title, style: const TextStyle(
              fontSize: 16, fontWeight: FontWeight.bold)),
        ]),
        const SizedBox(height: 12),
        ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.5),
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: items.length,
            separatorBuilder: (_, _) =>
                Divider(height: 1, color: Colors.grey[100]),
            itemBuilder: (_, i) {
              final item       = items[i];
              final id         = item['id'] as String?;
              final name       = item['name'] as String;
              final isSelected = id == selectedId;
              return ListTile(
                dense: true,
                leading: isSelected
                    ? const Icon(Icons.check_circle_rounded, color: Colors.amber)
                    : Icon(icon, size: 18, color: Colors.grey[400]),
                title: Text(name, style: TextStyle(
                    fontWeight: isSelected
                        ? FontWeight.bold : FontWeight.normal)),
                onTap: () {
                  Navigator.pop(context);
                  onSelected(id, name);
                },
              );
            },
          ),
        ),
      ]),
    );
  }
}


/// Κεντραρισμένο popup μήνυμα που εμφανίζεται για [duration] και χάνεται μόνο του.
void showCenterToast(BuildContext context, String message,
    {Duration duration = const Duration(seconds: 3)}) {
  final overlay = Overlay.of(context);
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 40),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check_circle_rounded, color: Color(0xFF4ADE80)),
              const SizedBox(width: 12),
              Flexible(
                child: Text(message,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  overlay.insert(entry);
  Future.delayed(duration, () {
    try { entry.remove(); } catch (_) {}
  });
}

// ─── FadeSlideIn ──────────────────────────────────────────────────────────────
// Ελαφρύ one-shot entrance animation (fade + μικρό slide από κάτω).
// Τρέχει ΜΙΑ φορά όταν πρωτοεμφανίζεται το widget (240ms) και μετά
// δεν κοστίζει τίποτα. Προαιρετικό stagger ανά index για λίστες.
class FadeSlideIn extends StatefulWidget {
  final Widget child;
  final int    index;          // για κλιμακωτή εμφάνιση σε λίστες
  const FadeSlideIn({super.key, required this.child, this.index = 0});

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double>   _fade;
  late final Animation<Offset>   _slide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 240),
    );
    final curved = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
    _fade  = curved;
    _slide = Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero)
        .animate(curved);

    // Stagger: μέγιστο 5 βήματα ώστε οι μακριές λίστες να μην αργούν.
    final delayMs = (widget.index.clamp(0, 5)) * 45;
    if (delayMs == 0) {
      _ctrl.forward();
    } else {
      Future.delayed(Duration(milliseconds: delayMs), () {
        if (mounted) _ctrl.forward();
      });
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}

// ─── Κοινά κουμπιά (συμμετρικά, γεμάτα) ───────────────────────────────────────
// AppButton       → γεμάτο κουμπί με χρώμα (κύρια ενέργεια)
// AppButtonTonal  → αχνό background (δευτερεύον, π.χ. «Ακύρωση») — όχι σκέτα γράμματα

class AppButton extends StatelessWidget {
  final String        label;
  final VoidCallback? onPressed;
  final IconData?     icon;
  final Color         color;
  final Color         fg;

  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.color = const Color(0xFF1E8E3E),
    this.fg    = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    final style = FilledButton.styleFrom(
      backgroundColor: color,
      foregroundColor: fg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      minimumSize: const Size(0, 44),
    );
    final Widget btn = icon != null
        ? FilledButton.icon(
            onPressed: onPressed,
            style: style,
            icon: Icon(icon, size: 18),
            label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          )
        : FilledButton(
            onPressed: onPressed,
            style: style,
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          );
    // Micro-bounce μόνο όταν το κουμπί είναι ενεργό.
    return onPressed == null ? btn : PressableScale(child: btn);
  }
}

class AppButtonTonal extends StatelessWidget {
  final String        label;
  final VoidCallback? onPressed;
  final IconData?     icon;
  final Color?        fg; // προαιρετικά χρωματιστό κείμενο/εικονίδιο

  const AppButtonTonal({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.fg,
  });

  @override
  Widget build(BuildContext context) {
    final style = FilledButton.styleFrom(
      backgroundColor: const Color(0xFFE8E8E8),
      foregroundColor: fg ?? Colors.black87,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      minimumSize: const Size(0, 44),
    );
    final Widget btn = icon != null
        ? FilledButton.icon(
            onPressed: onPressed,
            style: style,
            icon: Icon(icon, size: 18),
            label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          )
        : FilledButton(
            onPressed: onPressed,
            style: style,
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          );
    return onPressed == null ? btn : PressableScale(child: btn);
  }
}

// ─── PressableScale ───────────────────────────────────────────────────────────
//
// Wrapper που δίνει αισθητό «micro-bounce» (scale 0.96 + ελαφριά διαφάνεια)
// όταν πατιέται το παιδί του. Χρήση: τύλιξε ένα AppButton/AppButtonTonal ή
// οποιοδήποτε tappable. Το ίδιο το onPressed/onTap του παιδιού παραμένει — το
// PressableScale ΔΕΝ καταναλώνει το tap, μόνο ανιχνεύει press/release για το
// εφέ. Σεβάσου το reduce-motion (MediaQuery.disableAnimations).
class PressableScale extends StatefulWidget {
  final Widget child;
  final double pressedScale;
  const PressableScale({
    super.key,
    required this.child,
    this.pressedScale = 0.96,
  });

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v && mounted) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final scale = (_down && !reduceMotion) ? widget.pressedScale : 1.0;
    return Listener(
      onPointerDown:   (_) => _set(true),
      onPointerUp:     (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale:    scale,
        duration: const Duration(milliseconds: 90),
        curve:    Curves.easeOut,
        child: AnimatedOpacity(
          opacity:  _down && !reduceMotion ? 0.92 : 1.0,
          duration: const Duration(milliseconds: 90),
          child: widget.child,
        ),
      ),
    );
  }
}

// ─── PulseRingDot ─────────────────────────────────────────────────────────────
//
// Κουκκίδα «ραντάρ»: σταθερό κέντρο + ΔΥΟ διαδοχικά rings που εκπέμπουν προς τα
// έξω και σβήνουν, δίνοντας την αίσθηση ενεργού σήματος (π.χ. ανοιχτή δουλειά
// σε αναμονή). Αντικαθιστά την παλιά απλή «άλω που φουσκώνει». Μηδενικό κόστος
// (μόνο τοπικό repaint). Το χρώμα δίνεται από έξω — ΔΕΝ αλλάζει το φόντο της
// κάρτας (το χρώμα φόντου έχει δική του σημασία: κόκκινο=εκκρεμεί κ.λπ.).
class PulseRingDot extends StatefulWidget {
  final Color  color;
  final double size;       // διάμετρος σταθερής κουκκίδας
  final double ringMax;    // πόσο μεγαλώνει το ring (συνολική διάμετρος box)
  const PulseRingDot({
    super.key,
    required this.color,
    this.size    = 7,
    this.ringMax = 18,
  });

  @override
  State<PulseRingDot> createState() => _PulseRingDotState();
}

class _PulseRingDotState extends State<PulseRingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  // Ένα ring: t∈[0,1] → διάμετρος size→ringMax, διαφάνεια 0.40→0.
  Widget _ring(double t) {
    final d = widget.size + (widget.ringMax - widget.size) * t;
    return Container(
      width: d, height: d,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: widget.color.withValues(alpha: 0.40 * (1 - t)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion) {
      // Χωρίς animation: απλή σταθερή κουκκίδα.
      return SizedBox(
        width: widget.ringMax, height: widget.ringMax,
        child: Center(
          child: Container(
            width: widget.size, height: widget.size,
            decoration: BoxDecoration(
                color: widget.color, shape: BoxShape.circle),
          ),
        ),
      );
    }
    return SizedBox(
      width: widget.ringMax, height: widget.ringMax,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, _) {
          final t1 = _ctrl.value;                 // πρώτο ring
          final t2 = (_ctrl.value + 0.5) % 1.0;   // δεύτερο, μισό κύκλο πίσω
          return Stack(alignment: Alignment.center, children: [
            _ring(t1),
            _ring(t2),
            Container(
              width: widget.size, height: widget.size,
              decoration: BoxDecoration(
                  color: widget.color, shape: BoxShape.circle),
            ),
          ]);
        },
      ),
    );
  }
}

// ─── Shimmer skeleton ─────────────────────────────────────────────────────────
//
// Placeholder φόρτωσης με «λάμψη» που περνά διαγώνια — αντί για στρογγυλό
// CircularProgressIndicator. Δίνει αίσθηση ταχύτητας. ShimmerBox = ένα
// μεμονωμένο γκρι ορθογώνιο που λάμπει· χτίσε με αυτό το σχήμα του περιεχομένου
// που έρχεται (π.χ. JobRouteSkeleton πιο κάτω).
class ShimmerBox extends StatefulWidget {
  final double width;
  final double height;
  final double radius;
  const ShimmerBox({
    super.key,
    required this.width,
    required this.height,
    this.radius = 6,
  });

  @override
  State<ShimmerBox> createState() => _ShimmerBoxState();
}

class _ShimmerBoxState extends State<ShimmerBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 1300),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final base = Colors.grey.shade300;
    final hi   = Colors.grey.shade100;
    if (reduceMotion) {
      return Container(
        width:  widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: base,
          borderRadius: BorderRadius.circular(widget.radius),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: SizedBox(
        width:  widget.width,
        height: widget.height,
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (_, _) {
            final t = _ctrl.value;
            final begin = -1.0 + 3.0 * t; // λάμψη -1 → 2
            return DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment(begin, 0),
                  end:   Alignment(begin + 1, 0),
                  colors: [base, hi, base],
                  stops: const [0.35, 0.5, 0.65],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

// Skeleton στο σχήμα μιας διαδρομής (τιμή + 2 γραμμές διεύθυνσης) — για όσο
// φορτώνει η διεύθυνση/τιμή μιας δουλειάς.
class JobRouteSkeleton extends StatelessWidget {
  const JobRouteSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: const [
        ShimmerBox(width: 90,  height: 18, radius: 6),
        SizedBox(height: 10),
        ShimmerBox(width: 160, height: 13, radius: 5),
        SizedBox(height: 7),
        ShimmerBox(width: 120, height: 13, radius: 5),
      ],
    );
  }
}

// Λίστα από shimmer «κάρτες» — αντικαθιστά το CircularProgressIndicator όταν
// φορτώνει μια λίστα δουλειών. Δώσε πόσες ψεύτικες κάρτες θες (default 4).
class JobListSkeleton extends StatelessWidget {
  final int count;
  const JobListSkeleton({super.key, this.count = 4});

  Widget _card() {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          Row(children: [
            ShimmerBox(width: 70, height: 22, radius: 20),
            Spacer(),
            ShimmerBox(width: 60, height: 22, radius: 8),
          ]),
          SizedBox(height: 12),
          ShimmerBox(width: 140, height: 14, radius: 6),
          SizedBox(height: 8),
          ShimmerBox(width: 110, height: 14, radius: 6),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(top: 6),
      children: [for (int i = 0; i < count; i++) _card()],
    );
  }
}
