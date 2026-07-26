// lib/web/web_settings_page.dart
//
// «Ρυθμίσεις» ΓΙΑ WEB — χρησιμοποιεί το ΙΔΙΟ SettingsPage με το κινητό
// (ίδιο design: bottom sheets, AppColors/dark mode, επιλογή οχήματος,
// «Εμφάνιση εφαρμογής» dark/light/auto κ.λπ.). Αυτό εδώ είναι απλά ένα
// λεπτό wrapper που φορτώνει/αποθηκεύει τα πεδία (vehicleType, hasBus,
// muted, στοιχεία προφίλ) από/προς το Firestore presence doc — στο κινητό
// αυτό γίνεται μέσα στο map_page.dart, εδώ γίνεται εδώ γιατί το web admin
// shell δεν έχει τη δική του state διαχείριση οχήματος/θέματος.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../models.dart';
import '../profile_form.dart';
import '../settings_page.dart';

class WebSettingsPage extends StatefulWidget {
  final String uid;
  final bool   isAdmin;
  final bool   isMaster;
  const WebSettingsPage({
    super.key,
    required this.uid,
    required this.isAdmin,
    required this.isMaster,
  });

  @override
  State<WebSettingsPage> createState() => _WebSettingsPageState();
}

class _WebSettingsPageState extends State<WebSettingsPage> {
  bool _loaded = false;

  VehicleType _vehicleType = VehicleType.taxi;
  bool _hasBus = false;
  bool _muted  = false;

  // Cache στοιχείων προφίλ — μόνο για να ανοίγει το showProfileForm με
  // αρχικές τιμές· η ίδια η φόρμα ξαναφορτώνει φρέσκα από Firestore.
  String _displayName  = '';
  String _lastName     = '';
  String _phone        = '';
  String _vehicleModel = '';
  String _referredBy   = '';
  String _plateNumber  = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('presence').doc(widget.uid).get();
      final data = doc.data();
      if (!mounted) return;
      if (data == null) {
        setState(() => _loaded = true);
        return;
      }
      final vt = (data['vehicleType'] as String?) ?? 'taxi';
      setState(() {
        _vehicleType = VehicleType.values.firstWhere(
            (v) => v.name == vt, orElse: () => VehicleType.taxi);
        _hasBus       = data['hasBus'] == true;
        _muted        = data['muted']  == true;
        _displayName  = (data['displayName']  as String?) ?? '';
        _lastName     = (data['lastName']     as String?) ?? '';
        _phone        = (data['phone']        as String?) ?? '';
        _vehicleModel = (data['vehicleModel'] as String?) ?? '';
        _referredBy   = (data['referredBy']   as String?) ?? '';
        _plateNumber  = (data['plateNumber']  as String?) ?? '';
        _loaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  Future<void> _applyVehicleChange(VehicleType type, bool hasBus) async {
    setState(() { _vehicleType = type; _hasBus = hasBus; });
    await FirebaseFirestore.instance
        .collection('presence').doc(widget.uid)
        .set({'vehicleType': type.name, 'hasBus': hasBus}, SetOptions(merge: true));
  }

  Future<void> _toggleMuted(bool v) async {
    setState(() => _muted = v);
    await FirebaseFirestore.instance
        .collection('presence').doc(widget.uid)
        .set({'muted': v}, SetOptions(merge: true));
  }

  Future<void> _openEditProfile() async {
    await showProfileForm(
      context: context,
      uid: widget.uid,
      appVersion: 'web',
      displayName: _displayName,
      lastName: _lastName,
      phone: _phone,
      vehicleModel: _vehicleModel,
      referredBy: _referredBy,
      plateNumber: _plateNumber,
      vehicleType: _vehicleType,
      initialHasBus: _hasBus,
      isAlreadyApproved: true, // ήδη μέσα στο web panel = ήδη εγκεκριμένος
      onSaved: ({
        required name, required lastName, required phone,
        required vehicleModel, required referredBy, required plateNumber,
        required vehicleType, required hasBus,
        required homeOwner, required ownerOfClientId, required ownerOfClientName,
      }) async {
        if (mounted) {
          setState(() {
            _displayName = name; _lastName = lastName; _phone = phone;
            _vehicleModel = vehicleModel; _referredBy = referredBy;
            _plateNumber = plateNumber; _vehicleType = vehicleType; _hasBus = hasBus;
          });
        }
        await FirebaseFirestore.instance.collection('presence').doc(widget.uid).set({
          'displayName':  name,
          'lastName':     lastName,
          'phone':        phone,
          'vehicleModel': vehicleModel,
          'referredBy':   referredBy,
          'plateNumber':  plateNumber,
          'vehicleType':  vehicleType.name,
          'hasBus':       hasBus,
        }, SetOptions(merge: true));
      },
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      final c = AppColors.of(context);
      return Scaffold(
        backgroundColor: c.scaffold,
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return SettingsPage(
      uid:      widget.uid,
      isAdmin:  widget.isAdmin,
      isMaster: widget.isMaster,
      muted:    _muted,
      onMuteChanged: _toggleMuted,
      vehicleType: _vehicleType,
      hasBus:      _hasBus,
      onVehicleChanged: (v) => _applyVehicleChange(v.type, v.hasBus),
      onEditProfile: _openEditProfile,
      // Web: δεν υπάρχει APK να ελέγξει, οπότε δεν κάνει τίποτα εδώ.
      onCheckUpdate: () {},
      onSignOut: () async {
        await FirebaseAuth.instance.signOut();
      },
    );
  }
}
