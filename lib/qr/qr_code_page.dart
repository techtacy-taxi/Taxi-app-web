// lib/qr/qr_code_page.dart
//
// Νέα λειτουργία: QR code της online φόρμας/link, ανά tenant (ή "default"
// για τον master). Δύο κομμάτια:
//   1) showQrLinkEditDialog() — μικρό dialog: βάζεις το link, Αποθήκευση.
//   2) QrCodePage — full-screen: πάνω το όνομα επιχείρησης (+ λογότυπο αν
//      υπάρχει), στη μέση μεγάλο QR code, από κάτω τηλέφωνο & email.
//
// Πηγή δεδομένων: οι ΗΔΗ υπάρχουσες Cloud Functions
// updateTenantBusinessInfo / getTenantBusinessInfo (ίδιες που τροφοδοτούν
// την «Ρυθμίσεις Online Φόρμας» — businessName/logoUrl/contactPhone/
// contactEmail). Προστέθηκε μόνο ένα νέο πεδίο: qrLinkUrl.
//
// Δικαιώματα αποθήκευσης: ίδια με τα υπόλοιπα στοιχεία επιχείρησης —
// super-admin (master) ή ο tenant-owner του συγκεκριμένου tenant.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:qr_flutter/qr_flutter.dart';

const String _kBizInfoUrl =
    'https://us-central1-my-taxi-app-bbc7c.cloudfunctions.net/getTenantBusinessInfo';

/// Βρίσκει το tenantId του τρέχοντος χρήστη — ίδια λογική με το
/// VivaSettingsPage: master (techtacy@gmail.com) → 'default', αλλιώς
/// διαβάζεται από presence/{uid}.tenantId.
Future<String> _resolveMyTenantId() async {
  final email = FirebaseAuth.instance.currentUser?.email;
  if (email == 'techtacy@gmail.com') return 'default';
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null) return 'default';
  try {
    final doc =
        await FirebaseFirestore.instance.collection('presence').doc(uid).get();
    return (doc.data()?['tenantId'] as String?) ?? 'default';
  } catch (_) {
    return 'default';
  }
}

class _BizInfo {
  final String? businessName;
  final String? logoUrl;
  final String? contactPhone;
  final String? contactEmail;
  final String? qrLinkUrl;
  const _BizInfo({
    this.businessName,
    this.logoUrl,
    this.contactPhone,
    this.contactEmail,
    this.qrLinkUrl,
  });
}

Future<_BizInfo> _fetchBizInfo(String tenantId) async {
  final res = await http.post(
    Uri.parse(_kBizInfoUrl),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({'tenantId': tenantId}),
  );
  final j = jsonDecode(res.body) as Map<String, dynamic>;
  return _BizInfo(
    businessName: j['businessName'] as String?,
    logoUrl:      j['logoUrl'] as String?,
    contactPhone: j['contactPhone'] as String?,
    contactEmail: j['contactEmail'] as String?,
    qrLinkUrl:    j['qrLinkUrl'] as String?,
  );
}

// ─── 1) Dialog επεξεργασίας του link ───────────────────────────────────────

/// Ανοίγει dialog όπου μπαίνει/επεξεργάζεται το link του QR. Αποθηκεύει μέσω
/// του ΗΔΗ υπάρχοντος callable updateTenantBusinessInfo (νέο πεδίο qrLinkUrl).
Future<void> showQrLinkEditDialog(BuildContext context) async {
  String tenantId = 'default';
  String current = '';
  bool loading = true;
  bool saving = false;
  String? error;

  final ctrl = TextEditingController();

  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        if (loading) {
          // Φόρτωση αρχικών δεδομένων μία φορά.
          () async {
            try {
              tenantId = await _resolveMyTenantId();
              final bi = await _fetchBizInfo(tenantId);
              current = bi.qrLinkUrl ?? '';
              ctrl.text = current;
            } catch (_) {
              // Αγνόησε — ξεκινά απλά από κενό.
            } finally {
              loading = false;
              if (ctx.mounted) setState(() {});
            }
          }();
        }
        return AlertDialog(
          title: const Text('Link για QR code'),
          content: SizedBox(
            width: 380,
            child: loading
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Βάλε το link που θα ανοίγει όταν κάποιος '
                        'σκανάρει το QR (π.χ. η σελίδα κράτησης).',
                        style: TextStyle(fontSize: 13, color: Colors.grey),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: ctrl,
                        keyboardType: TextInputType.url,
                        autofocus: true,
                        decoration: const InputDecoration(
                          labelText: 'Link',
                          hintText: 'https://taxiathenstransfers.com/booking.html',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                      if (error != null) ...[
                        const SizedBox(height: 8),
                        Text(error!,
                            style: const TextStyle(
                                color: Colors.red, fontSize: 12.5)),
                      ],
                    ],
                  ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(ctx),
              child: const Text('Άκυρο'),
            ),
            FilledButton(
              onPressed: (loading || saving)
                  ? null
                  : () async {
                      final link = ctrl.text.trim();
                      if (link.isNotEmpty &&
                          !(link.startsWith('http://') ||
                              link.startsWith('https://'))) {
                        setState(() =>
                            error = 'Το link πρέπει να ξεκινά με https://');
                        return;
                      }
                      setState(() { saving = true; error = null; });
                      try {
                        await FirebaseFunctions.instance
                            .httpsCallable('updateTenantBusinessInfo')
                            .call({
                          'tenantId':  tenantId,
                          'qrLinkUrl': link,
                        });
                        if (ctx.mounted) Navigator.pop(ctx);
                      } catch (e) {
                        setState(() {
                          saving = false;
                          error = 'Αποτυχία αποθήκευσης: $e';
                        });
                      }
                    },
              child: saving
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Αποθήκευση'),
            ),
          ],
        );
      },
    ),
  );
}

// ─── 2) Full-screen οθόνη QR ────────────────────────────────────────────────

class QrCodePage extends StatefulWidget {
  const QrCodePage({super.key});

  @override
  State<QrCodePage> createState() => _QrCodePageState();
}

class _QrCodePageState extends State<QrCodePage> {
  late Future<_BizInfo> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_BizInfo> _load() async {
    final tenantId = await _resolveMyTenantId();
    return _fetchBizInfo(tenantId);
  }

  Future<void> _refresh() async {
    setState(() => _future = _load());
  }

  @override
  Widget build(BuildContext context) {
    // Πάντα λευκό φόντο — ανεξάρτητα από dark/light θέμα εφαρμογής, ώστε
    // το QR να σαρώνεται αξιόπιστα και να είναι έτοιμο για εκτύπωση.
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
        title: const Text('QR Code'),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_rounded),
            tooltip: 'Επεξεργασία link',
            onPressed: () async {
              await showQrLinkEditDialog(context);
              await _refresh();
            },
          ),
        ],
      ),
      body: SafeArea(
        child: FutureBuilder<_BizInfo>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return Center(
                child: Text('Σφάλμα φόρτωσης: ${snap.error}',
                    style: const TextStyle(color: Colors.red)),
              );
            }
            final bi = snap.data ?? const _BizInfo();
            final link = bi.qrLinkUrl?.trim() ?? '';

            if (link.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.qr_code_2_rounded,
                          size: 64, color: Colors.grey.shade400),
                      const SizedBox(height: 12),
                      const Text(
                        'Δεν έχει οριστεί ακόμα link για το QR.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 15, color: Colors.black87),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        icon: const Icon(Icons.edit_rounded),
                        label: const Text('Ορισμός link'),
                        onPressed: () async {
                          await showQrLinkEditDialog(context);
                          await _refresh();
                        },
                      ),
                    ],
                  ),
                ),
              );
            }

            return Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                    horizontal: 28, vertical: 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (bi.logoUrl != null && bi.logoUrl!.isNotEmpty) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: Image.network(
                          bi.logoUrl!,
                          height: 72,
                          errorBuilder: (_, _, _) => const SizedBox.shrink(),
                        ),
                      ),
                      const SizedBox(height: 14),
                    ],
                    Text(
                      (bi.businessName?.trim().isNotEmpty == true)
                          ? bi.businessName!.trim()
                          : 'Online Booking',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 28),
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.grey.shade300),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.06),
                            blurRadius: 18,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: QrImageView(
                        data: link,
                        version: QrVersions.auto,
                        size: 260,
                        backgroundColor: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 26),
                    if (bi.contactPhone != null &&
                        bi.contactPhone!.isNotEmpty)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.phone_rounded,
                              size: 17, color: Colors.black54),
                          const SizedBox(width: 6),
                          Text(bi.contactPhone!,
                              style: const TextStyle(
                                  fontSize: 15, color: Colors.black87)),
                        ],
                      ),
                    if (bi.contactEmail != null &&
                        bi.contactEmail!.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.email_rounded,
                              size: 17, color: Colors.black54),
                          const SizedBox(width: 6),
                          Text(bi.contactEmail!,
                              style: const TextStyle(
                                  fontSize: 15, color: Colors.black87)),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
