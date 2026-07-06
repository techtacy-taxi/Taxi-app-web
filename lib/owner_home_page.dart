// lib/owner_home_page.dart
//
// Περιορισμένη home οθόνη για τον ρόλο «Home Owner» (ιδιοκτήτης καταλύματος).
// Δουλεύει ΚΑΙ στο Android app ΚΑΙ στο web app (ίδιο Flutter codebase).
//
// Ο Home Owner ΔΕΝ βλέπει χάρτη ούτε καμία άλλη λειτουργία διαχείρισης —
// βλέπει ΜΟΝΟ 3 tabs, φιλτραρισμένα ΑΥΣΤΗΡΑ στο δικό του κατάλυμα/πελάτη
// (το όνομά του πρέπει να εμφανίζεται μέσα στο Από Ή στο Προς της δουλειάς):
//   1) Ανοιχτές δουλειές (open/taken/boarded)
//   2) Αποθηκευμένες δουλειές (saved_jobs)
//   3) Ιστορικό (done) — με τζίρο + αριθμό δουλειών για τον πελάτη του

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'jobs/job_model.dart';
import 'jobs/job_details_sheet.dart';
import 'jobs/saved_job_service.dart';

class OwnerHomePage extends StatefulWidget {
  final String uid;
  final String displayName;
  final String ownerOfClientId;
  final String ownerOfClientName;

  const OwnerHomePage({
    super.key,
    required this.uid,
    required this.displayName,
    required this.ownerOfClientId,
    required this.ownerOfClientName,
  });

  @override
  State<OwnerHomePage> createState() => _OwnerHomePageState();
}

class _OwnerHomePageState extends State<OwnerHomePage> {
  String _myTenantId = 'default';
  bool _tenantLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadMyTenantId();
  }

  Future<void> _loadMyTenantId() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('presence').doc(widget.uid).get();
      final tid = (doc.data()?['tenantId'] as String?) ?? 'default';
      if (mounted) setState(() { _myTenantId = tid; _tenantLoaded = true; });
    } catch (_) {
      if (mounted) setState(() { _myTenantId = 'default'; _tenantLoaded = true; });
    }
  }

  // Ταιριάζει αν το όνομα του πελάτη εμφανίζεται μέσα στο Από Ή στο Προς
  // (case-insensitive substring match).
  bool _matchesClient(String from, String to) {
    final name = widget.ownerOfClientName.trim().toLowerCase();
    if (name.isEmpty) return false;
    return from.toLowerCase().contains(name) || to.toLowerCase().contains(name);
  }

  @override
  Widget build(BuildContext context) {
    if (!_tenantLoaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.ownerOfClientName),
          actions: [
            IconButton(
              icon: const Icon(Icons.logout_rounded),
              tooltip: 'Αποσύνδεση',
              onPressed: () => FirebaseAuth.instance.signOut(),
            ),
          ],
          bottom: const TabBar(tabs: [
            Tab(icon: Icon(Icons.work_rounded), text: 'Ανοιχτές'),
            Tab(icon: Icon(Icons.bookmark_rounded), text: 'Αποθηκευμένες'),
            Tab(icon: Icon(Icons.history_rounded), text: 'Ιστορικό'),
          ]),
        ),
        // SafeArea ώστε το περιεχόμενο να μην κρύβεται πίσω από το κάτω
        // navigation bar σε Android συσκευές με gesture bar.
        body: SafeArea(
          child: TabBarView(children: [
            _OpenJobsTab(tenantId: _myTenantId, matches: _matchesClient),
            _SavedJobsOwnerTab(tenantId: _myTenantId, matches: _matchesClient),
            _HistoryTab(tenantId: _myTenantId, matches: _matchesClient),
          ]),
        ),
      ),
    );
  }
}

// ─── Tab 1: Ανοιχτές δουλειές ───────────────────────────────────────────────
class _OpenJobsTab extends StatelessWidget {
  final String tenantId;
  final bool Function(String from, String to) matches;
  const _OpenJobsTab({required this.tenantId, required this.matches});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('jobs')
          .where('tenantId', isEqualTo: tenantId)
          .where('status', whereIn: ['open', 'taken', 'boarded'])
          .snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(child: Text('Σφάλμα: ${snap.error}'));
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final jobs = snap.data!.docs
            .map((d) => Job.fromDoc(d))
            .where((j) => matches(j.from, j.to))
            .toList()
          ..sort((a, b) => (a.scheduledAt ?? a.createdAt)
              .compareTo(b.scheduledAt ?? b.createdAt));

        if (jobs.isEmpty) {
          return const Center(child: Text('Καμία ανοιχτή δουλειά αυτή τη στιγμή.'));
        }
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: jobs.length,
          itemBuilder: (c, i) => _JobCard(job: jobs[i]),
        );
      },
    );
  }
}

// ─── Tab 2: Αποθηκευμένες δουλειές ──────────────────────────────────────────
class _SavedJobsOwnerTab extends StatelessWidget {
  final String tenantId;
  final bool Function(String from, String to) matches;
  const _SavedJobsOwnerTab({required this.tenantId, required this.matches});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('saved_jobs')
          .where('tenantId', isEqualTo: tenantId)
          .snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(child: Text('Σφάλμα: ${snap.error}'));
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final saved = snap.data!.docs
            .map((d) => SavedJob.fromDoc(d))
            .where((s) => matches(s.job.from, s.job.to))
            .toList()
          ..sort((a, b) => b.savedAt.compareTo(a.savedAt));

        if (saved.isEmpty) {
          return const Center(child: Text('Καμία αποθηκευμένη δουλειά.'));
        }
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: saved.length,
          itemBuilder: (c, i) => _JobCard(job: saved[i].job),
        );
      },
    );
  }
}

// ─── Tab 3: Ιστορικό (done) — με τζίρο + αριθμό δουλειών ───────────────────
class _HistoryTab extends StatelessWidget {
  final String tenantId;
  final bool Function(String from, String to) matches;
  const _HistoryTab({required this.tenantId, required this.matches});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('jobs')
          .where('tenantId', isEqualTo: tenantId)
          .where('status', isEqualTo: 'done')
          .snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(child: Text('Σφάλμα: ${snap.error}'));
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final jobs = snap.data!.docs
            .map((d) => Job.fromDoc(d))
            .where((j) => matches(j.from, j.to))
            .toList()
          ..sort((a, b) => (b.doneAt ?? b.createdAt).compareTo(a.doneAt ?? a.createdAt));

        final turnover = jobs.fold<double>(0, (sum, j) => sum + j.price);

        return Column(children: [
          Container(
            width: double.infinity,
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF1E8E3E).withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF1E8E3E).withValues(alpha: 0.3)),
            ),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${turnover.toStringAsFixed(2)}€',
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold,
                          color: Color(0xFF1E8E3E))),
                  const Text('Συνολικός τζίρος', style: TextStyle(fontSize: 12)),
                ]),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('${jobs.length}',
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                const Text('Δουλειές', style: TextStyle(fontSize: 12)),
              ]),
            ]),
          ),
          Expanded(
            child: jobs.isEmpty
                ? const Center(child: Text('Δεν υπάρχει ιστορικό ακόμα.'))
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    itemCount: jobs.length,
                    itemBuilder: (c, i) => _JobCard(job: jobs[i], showDone: true),
                  ),
          ),
        ]);
      },
    );
  }
}

// ─── Κοινή κάρτα δουλειάς (απλή, μόνο-για-προβολή) ─────────────────────────
class _JobCard extends StatelessWidget {
  final Job job;
  final bool showDone;
  const _JobCard({required this.job, this.showDone = false});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        onTap: () => showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          builder: (_) => JobDetailsSheet(
            job: job,
            parentContext: context,
            hideComplete: true,
            historyMode: true,
          ),
        ),
        title: Text('${job.from} → ${job.to}',
            maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(job.scheduledAt != null
            ? '${job.scheduledAt!.day}/${job.scheduledAt!.month}/${job.scheduledAt!.year} '
              '${job.scheduledAt!.hour.toString().padLeft(2, "0")}:'
              '${job.scheduledAt!.minute.toString().padLeft(2, "0")}'
            : 'Άμεση'),
        trailing: Text('${job.price.toStringAsFixed(2)}€',
            style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF1E8E3E))),
      ),
    );
  }
}
