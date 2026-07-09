// ==========================================
// FILE: ./lib/jobs/clients_admin_tab.dart
// ==========================================
//
// Καρτέλα "Πελάτες" (admin / master).
//   • Admin βλέπει μόνο τους δικούς του πελάτες, Master όλους.
//   • Αναζήτηση με όνομα.
//   • Κάθε πελάτης: όνομα + πραγματική διεύθυνση-βάση ("Από" με συντεταγμένες)
//     + λίστα αποθηκευμένων διαδρομών (προορισμός + τιμή + πηγή).
//   • Tap σε αποθηκευμένη διαδρομή → ανοίγει ΝΕΑ ΔΟΥΛΕΙΑ με προσυμπληρωμένα
//     Από / Προς / Τιμή / Πηγή. Ο χρήστης αλλάζει τα υπόλοιπα.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'client_model.dart';
import 'job_form.dart';
import 'job_model.dart';
import 'job_service.dart';
import 'job_shared_widgets.dart';
import 'places_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// ClientsTab
// ─────────────────────────────────────────────────────────────────────────────

class ClientsTab extends StatefulWidget {
  final String adminUid;
  final String adminName;
  final bool   isMaster;
  const ClientsTab({
    super.key,
    required this.adminUid,
    this.adminName = '',
    this.isMaster  = false,
  });

  @override
  State<ClientsTab> createState() => _ClientsTabState();
}

class _ClientsTabState extends State<ClientsTab> {
  String _query = '';
  String? _tenantId;
  bool _tenantLoaded = false;
  // ── Μόνο για master: προσωπική προτίμηση «να μη βλέπω πελάτες άλλων».
  // Αποθηκεύεται στο δικό του presence — δεν επηρεάζει κανέναν άλλον admin.
  bool _hideOthers = false;

  @override
  void initState() {
    super.initState();
    _loadTenant();
  }

  Future<void> _loadTenant() async {
    if (widget.isMaster) {
      try {
        final doc = await FirebaseFirestore.instance
            .collection('presence').doc(widget.adminUid).get();
        _hideOthers = doc.data()?['masterHideOtherClients'] == true;
      } catch (_) {}
      if (mounted) setState(() => _tenantLoaded = true);
      return;
    }
    final tid = await JobService.myTenantId();
    if (mounted) setState(() { _tenantId = tid; _tenantLoaded = true; });
  }

  Future<void> _toggleHideOthers(bool v) async {
    setState(() => _hideOthers = v);
    try {
      await FirebaseFirestore.instance.collection('presence')
          .doc(widget.adminUid).set(
              {'masterHideOtherClients': v}, SetOptions(merge: true));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (!_tenantLoaded) {
      return const Center(child: CircularProgressIndicator());
    }
    // Master + hideOthers ενεργό → συμπεριφέρεται σαν να φιλτράρει μόνο τους
    // δικούς του πελάτες (ίδια λογική με τον απλό admin).
    final effectiveCreatedBy =
        (widget.isMaster && !_hideOthers) ? null : widget.adminUid;
    return StreamBuilder<List<Client>>(
      stream: JobService.clients(
          createdBy: effectiveCreatedBy,
          tenantId:  widget.isMaster ? null : _tenantId),
      builder: (context, snap) {
        var clients = snap.data ?? [];
        final q = _query.trim().toLowerCase();
        if (q.isNotEmpty) {
          clients = clients.where((c) =>
              c.name.toLowerCase().contains(q) ||
              c.fromName.toLowerCase().contains(q)).toList();
        }
        return Column(children: [
          // Αναζήτηση
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(children: [
              Expanded(
                child: TextField(
                  decoration: InputDecoration(
                    hintText:   'Αναζήτηση πελάτη...',
                    prefixIcon: const Icon(Icons.search_rounded),
                    filled:     true,
                    fillColor:  Colors.white,
                    isDense:    true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: Colors.grey.shade300),
                    ),
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
              // ── Μόνο για master: κρύψε/δείξε πελάτες άλλων διαχειριστών.
              if (widget.isMaster) ...[
                const SizedBox(width: 8),
                Tooltip(
                  message: _hideOthers
                      ? 'Βλέπεις ΜΟΝΟ τους δικούς σου πελάτες — πάτα για να δεις όλους'
                      : 'Βλέπεις όλους τους πελάτες — πάτα για να δεις ΜΟΝΟ τους δικούς σου',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => _toggleHideOthers(!_hideOthers),
                    child: Container(
                      padding: const EdgeInsets.all(11),
                      decoration: BoxDecoration(
                        color: _hideOthers
                            ? Colors.amber.shade100
                            : Colors.white,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: _hideOthers
                                ? Colors.amber.shade400
                                : Colors.grey.shade300),
                      ),
                      child: Icon(
                        _hideOthers
                            ? Icons.visibility_off_rounded
                            : Icons.visibility_rounded,
                        size: 20,
                        color: _hideOthers
                            ? Colors.amber.shade900
                            : Colors.grey.shade600,
                      ),
                    ),
                  ),
                ),
              ],
            ]),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
              children: [
                if (clients.isEmpty)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(40),
                      child: Text(
                          _query.isEmpty
                              ? 'Δεν υπάρχουν πελάτες ακόμα'
                              : 'Κανένας πελάτης',
                          style: const TextStyle(color: Colors.grey)),
                    ),
                  ),
                ...clients.map((c) => _ClientCard(
                      client:    c,
                      adminUid:  widget.adminUid,
                      adminName: widget.adminName,
                      isMaster:  widget.isMaster,
                    )),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () => _openEditor(context),
                  style: FilledButton.styleFrom(
                      backgroundColor: Colors.amber,
                      foregroundColor: Colors.black),
                  icon:  const Icon(Icons.person_add_rounded),
                  label: const Text('Νέος Πελάτης',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
        ]);
      },
    );
  }

  void _openEditor(BuildContext context, {Client? client}) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ClientEditorPage(
        adminUid:  widget.adminUid,
        adminName: widget.adminName,
        isMaster:  widget.isMaster,
        client:    client,
      ),
    ));
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _ClientCard
// ─────────────────────────────────────────────────────────────────────────────

class _ClientCard extends StatefulWidget {
  final Client client;
  final String adminUid;
  final String adminName;
  final bool   isMaster;
  const _ClientCard({
    required this.client,
    required this.adminUid,
    required this.adminName,
    required this.isMaster,
  });

  @override
  State<_ClientCard> createState() => _ClientCardState();
}

class _ClientCardState extends State<_ClientCard>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 360),
  );

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    if (_expanded) {
      _ctrl.forward(from: 0);
    } else {
      _ctrl.reverse();
    }
  }

  Client get client    => widget.client;
  String get adminUid  => widget.adminUid;
  String get adminName => widget.adminName;
  bool   get isMaster  => widget.isMaster;

  // Χρώμα avatar βάσει ονόματος — σταθερό ανά πελάτη, ώστε να ξεχωρίζουν.
  Color get _avatarColor {
    const palette = [
      Color(0xFFEF8E3A), // πορτοκαλί
      Color(0xFF4C84C4), // μπλε
      Color(0xFF5BAE7C), // πράσινο
      Color(0xFFB06AB3), // μωβ
      Color(0xFFD9534F), // κόκκινο
      Color(0xFF3FA9A0), // teal
      Color(0xFFC9A227), // χρυσό
    ];
    if (client.name.isEmpty) return palette.first;
    return palette[client.name.codeUnitAt(0) % palette.length];
  }

  String get _initials {
    final parts = client.name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final color = _avatarColor;
    final routeCount = client.routes.length;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: _expanded ? color.withValues(alpha: 0.5) : Colors.grey.shade200,
            width: _expanded ? 1.4 : 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: _expanded ? 0.06 : 0.03),
            blurRadius: _expanded ? 14 : 6,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        // ── Κεφαλίδα επαφής (μόνο όνομα + αριθμός διαδρομών) ──
        InkWell(
          onTap: routeCount == 0 ? null : _toggle,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
            child: Row(children: [
              // Avatar με αρχικά
              Container(
                width: 46, height: 46,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft, end: Alignment.bottomRight,
                    colors: [color, color.withValues(alpha: 0.78)],
                  ),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(_initials,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 17)),
              ),
              const SizedBox(width: 13),
              // Όνομα + μετρητής
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(client.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16.5)),
                    const SizedBox(height: 2),
                    Row(children: [
                      Icon(Icons.route_rounded,
                          size: 13, color: Colors.grey.shade500),
                      const SizedBox(width: 4),
                      Text(
                          routeCount == 0
                              ? 'Καμία διαδρομή'
                              : routeCount == 1
                                  ? '1 διαδρομή'
                                  : '$routeCount διαδρομές',
                          style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w500,
                              color: Colors.grey[600])),
                    ]),
                  ],
                ),
              ),
              // Επεξεργασία / Διαγραφή — διακριτικά
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Επεξεργασία',
                icon: Icon(Icons.edit_rounded,
                    size: 19, color: Colors.grey.shade500),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ClientEditorPage(
                    adminUid: adminUid, adminName: adminName,
                    isMaster: isMaster, client: client,
                  ),
                )),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Διαγραφή',
                icon: Icon(Icons.delete_outline_rounded,
                    size: 19, color: Colors.red.shade300),
                onPressed: () => _confirmDelete(context),
              ),
              // Chevron expand
              if (routeCount > 0)
                AnimatedRotation(
                  duration: const Duration(milliseconds: 200),
                  turns: _expanded ? 0.5 : 0,
                  child: Icon(Icons.expand_more_rounded,
                      color: Colors.grey.shade500),
                )
              else
                const SizedBox(width: 8),
            ]),
          ),
        ),
        // ── Διαδρομές (expand με animation) ──
        AnimatedSize(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeInOutCubic,
          alignment: Alignment.topCenter,
          child: _expanded
              ? _routesList(context, color)
              : const SizedBox(width: double.infinity),
        ),
      ]),
    );
  }

  Widget _routesList(BuildContext context, Color accent) {
    return Column(children: [
      Divider(height: 1, color: Colors.grey.shade200),
      if (client.fromName.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Row(children: [
            Icon(Icons.trip_origin_rounded,
                size: 14, color: Colors.grey.shade500),
            const SizedBox(width: 8),
            Expanded(
              child: Text(client.fromName,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12.5,
                      fontStyle: FontStyle.italic,
                      color: Colors.grey.shade600)),
            ),
          ]),
        ),
      ...client.routes.asMap().entries.map((entry) {
        final i = entry.key;
        final r = entry.value;
        // Staggered: κάθε διαδρομή μπαίνει λίγο μετά την προηγούμενη.
        final n = client.routes.length;
        final start = (n <= 1) ? 0.0 : (i / n) * 0.5;
        final anim = CurvedAnimation(
          parent: _ctrl,
          curve: Interval(start, (start + 0.6).clamp(0.0, 1.0),
              curve: Curves.easeOutCubic),
        );
        return FadeTransition(
          opacity: anim,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.12, 0),
              end: Offset.zero,
            ).animate(anim),
            child: Column(children: [
          if (i > 0)
            Divider(height: 1, indent: 16, endIndent: 16,
                color: Colors.grey.shade100),
          InkWell(
            onTap: () => _startJob(context, r),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 11, 12, 11),
              child: Row(children: [
                Icon(Icons.place_rounded, size: 18, color: Colors.red.shade400),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(r.toName,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 14)),
                      const SizedBox(height: 2),
                      Row(children: [
                        if (r.price > 0)
                          Text('${r.price.toStringAsFixed(2)}€',
                              style: TextStyle(
                                  color: Colors.green.shade700,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13)),
                        if (r.price > 0 && (r.sourceName ?? '').isNotEmpty)
                          const Text('  •  ',
                              style: TextStyle(
                                  color: Colors.grey, fontSize: 12)),
                        if ((r.sourceName ?? '').isNotEmpty)
                          Flexible(
                            child: Text(r.sourceName!,
                                maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: Colors.orange.shade800,
                                    fontSize: 12.5)),
                          ),
                      ]),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 11, vertical: 6),
                  decoration: BoxDecoration(
                      color: Colors.amber.shade50,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.amber.shade200)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.bolt_rounded,
                        size: 15, color: Colors.amber.shade800),
                    const SizedBox(width: 2),
                    Text('Δουλειά',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Colors.amber.shade900)),
                  ]),
                ),
              ]),
            ),
          ),
        ]),
          ),
        );
      }),
      const SizedBox(height: 4),
    ]);
  }

  void _startJob(BuildContext context, ClientRoute r) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => JobFormPage(
        adminUid:  adminUid,
        adminName: adminName,
        isMaster:  isMaster,
        prefill: JobPrefill(
          from: PlacePick(
              description: client.fromName.isNotEmpty
                  ? client.fromName
                  : client.name,
              lat: client.fromLat, lng: client.fromLng),
          to: PlacePick(
              description: r.toName, lat: r.toLat, lng: r.toLng),
          price:       r.price > 0 ? r.price : null,
          sourceId:    r.sourceId,
          clientName:  client.name,
          clientPhone: client.phone,
        ),
      ),
    ));
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Διαγραφή πελάτη'),
        content: Text('Να διαγραφεί ο πελάτης "${client.name}" '
            'και όλες οι διαδρομές του;'),
        actions: [
          AppButtonTonal(label: 'Άκυρο', onPressed: () => Navigator.pop(ctx, false)),
          AppButton(label: 'Διαγραφή', color: Colors.red, onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
    );
    if (ok == true) await JobService.deleteClient(client.id);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ClientEditorPage — δημιουργία / επεξεργασία πελάτη
// ─────────────────────────────────────────────────────────────────────────────

class ClientEditorPage extends StatefulWidget {
  final String  adminUid;
  final String  adminName;
  final bool    isMaster;
  final Client? client;
  const ClientEditorPage({
    super.key,
    required this.adminUid,
    this.adminName = '',
    this.isMaster  = false,
    this.client,
  });

  @override
  State<ClientEditorPage> createState() => _ClientEditorPageState();
}

class _ClientEditorPageState extends State<ClientEditorPage> {
  final _nameCtrl  = TextEditingController();
  final _phoneCtrl = TextEditingController();
  PlacePick? _fromPick;
  List<_EditableRoute> _routes = [];
  List<JobSource> _sources = [];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadSources();
    final c = widget.client;
    if (c != null) {
      _nameCtrl.text  = c.name;
      _phoneCtrl.text = c.phone ?? '';
      _fromPick = PlacePick(
          description: c.fromName, lat: c.fromLat, lng: c.fromLng);
      _routes = c.routes.map((r) => _EditableRoute(
            to: PlacePick(
                description: r.toName, lat: r.toLat, lng: r.toLng),
            price: r.price,
            sourceId: r.sourceId,
            sourceName: r.sourceName,
          )).toList();
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    for (final r in _routes) {
      r.priceCtrl.dispose();
    }
    super.dispose();
  }

  Future<void> _loadSources() async {
    final list = await JobService.clientsSourcesHelper(
        isMaster: widget.isMaster, adminUid: widget.adminUid);
    if (!mounted) return;
    setState(() => _sources = list);
  }

  void _addRoute() {
    setState(() => _routes.add(_EditableRoute()));
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      _err('Συμπλήρωσε όνομα πελάτη');
      return;
    }
    final fromName = (_fromPick?.description ?? '').trim();
    if (fromName.isEmpty) {
      _err('Συμπλήρωσε τη διεύθυνση «Από» του πελάτη');
      return;
    }
    setState(() => _saving = true);

    final routes = <ClientRoute>[];
    for (final r in _routes) {
      final toName = (r.to?.description ?? '').trim();
      if (toName.isEmpty) continue; // αγνόησε κενές γραμμές
      routes.add(ClientRoute(
        toName:     toName,
        toLat:      r.to?.lat,
        toLng:      r.to?.lng,
        price:      double.tryParse(
                r.priceCtrl.text.trim().replaceAll(',', '.')) ??
            0,
        sourceId:   r.sourceId,
        sourceName: r.sourceName,
      ));
    }

    final client = Client(
      id:            widget.client?.id ?? '',
      name:          name,
      fromName:      fromName,
      fromLat:       _fromPick?.lat,
      fromLng:       _fromPick?.lng,
      phone:         _phoneCtrl.text.trim().isNotEmpty
          ? _phoneCtrl.text.trim()
          : null,
      routes:        routes,
      createdBy:     widget.client?.createdBy.isNotEmpty == true
          ? widget.client!.createdBy
          : widget.adminUid,
      createdByName: widget.client?.createdByName.isNotEmpty == true
          ? widget.client!.createdByName
          : widget.adminName,
      createdAt:     widget.client?.createdAt,
    );

    try {
      if (widget.client == null) {
        await JobService.createClient(client);
      } else {
        await JobService.updateClient(widget.client!.id, client);
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        _err('Σφάλμα: $e');
        setState(() => _saving = false);
      }
    }
  }

  void _err(String m) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(m), backgroundColor: Colors.red));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F8F8),
      appBar: AppBar(
        title: Text(widget.client == null ? 'Νέος Πελάτης' : 'Επεξεργασία',
            style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.amber,
        foregroundColor: Colors.black,
        elevation: 0,
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                  width: 20, height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.black)),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: AppButton(
                label: 'Αποθήκευση',
                icon: Icons.check_rounded,
                color: Colors.black,
                fg: Colors.amber,
                onPressed: _save,
              ),
            ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
        children: [
          _section('Στοιχεία Πελάτη'),
          TextField(
            controller: _nameCtrl,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              labelText:  'Όνομα (π.χ. Χίλτον) *',
              prefixIcon: const Icon(Icons.business_rounded),
              filled:     true, fillColor: Colors.white,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _phoneCtrl,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(
              labelText:  'Τηλέφωνο (προαιρετικό)',
              prefixIcon: const Icon(Icons.phone_rounded),
              filled:     true, fillColor: Colors.white,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 20),
          _section('Διεύθυνση «Από» (βάση πελάτη)'),
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
                'Η πραγματική διεύθυνση του πελάτη — από εδώ ξεκινούν οι '
                'διαδρομές και υπολογίζονται τα χιλιόμετρα.',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ),
          PlaceField(
            label:    'Από *',
            icon:     Icons.trip_origin_rounded,
            value:    _fromPick,
            onPicked: (p) => setState(() => _fromPick = p),
          ),
          const SizedBox(height: 20),
          _section('Αποθηκευμένες Διαδρομές'),
          ..._routes.asMap().entries.map((e) =>
              _routeEditor(e.key, e.value)),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _addRoute,
            icon:  const Icon(Icons.add_road_rounded),
            label: const Text('Προσθήκη διαδρομής'),
            style: OutlinedButton.styleFrom(
                foregroundColor: Colors.black87,
                side: BorderSide(color: Colors.amber.shade400)),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _routeEditor(int index, _EditableRoute r) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(children: [
        Row(children: [
          Text('Διαδρομή ${index + 1}',
              style: const TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 13)),
          const Spacer(),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close_rounded,
                size: 18, color: Colors.red),
            onPressed: () => setState(() => _routes.removeAt(index)),
          ),
        ]),
        PlaceField(
          label:    'Προς *',
          icon:     Icons.place_rounded,
          value:    r.to,
          onPicked: (p) => setState(() => r.to = p),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: TextField(
              controller: r.priceCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText:  'Τιμή (€)',
                prefixIcon: const Icon(Icons.euro_rounded),
                filled:     true, fillColor: Colors.grey.shade50,
                isDense:    true,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: DropdownButtonFormField<String?>(
              initialValue: r.sourceId,
              isExpanded: true,
              decoration: InputDecoration(
                labelText:  'Πηγή',
                prefixIcon: const Icon(Icons.handshake_rounded),
                filled:     true, fillColor: Colors.grey.shade50,
                isDense:    true,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              items: [
                const DropdownMenuItem<String?>(
                    value: null, child: Text('—')),
                ..._sources.map((s) => DropdownMenuItem<String?>(
                      value: s.id,
                      child: Text(s.name, overflow: TextOverflow.ellipsis),
                    )),
              ],
              onChanged: (v) => setState(() {
                r.sourceId = v;
                r.sourceName = v == null
                    ? null
                    : _sources
                        .firstWhere((s) => s.id == v,
                            orElse: () => _sources.first)
                        .name;
              }),
            ),
          ),
        ]),
      ]),
    );
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 10, top: 4),
        child: Row(children: [
          Container(width: 4, height: 18,
              decoration: BoxDecoration(
                  color: Colors.amber,
                  borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 8),
          Text(t, style: const TextStyle(
              fontSize: 15, fontWeight: FontWeight.bold)),
        ]),
      );
}

// Επεξεργάσιμη γραμμή διαδρομής στη φόρμα πελάτη.
class _EditableRoute {
  PlacePick? to;
  final TextEditingController priceCtrl;
  String? sourceId;
  String? sourceName;
  _EditableRoute({
    this.to,
    double price = 0,
    this.sourceId,
    this.sourceName,
  }) : priceCtrl = TextEditingController(
            text: price > 0 ? price.toStringAsFixed(2) : '');
}
