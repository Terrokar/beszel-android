import 'dart:async';
import 'dart:convert';
import 'package:pocketbase/pocketbase.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:beszel_pro/services/tls/trusted_certs.dart';

class PocketBaseService {
  static final PocketBaseService _instance = PocketBaseService._internal();

  factory PocketBaseService() {
    return _instance;
  }

  PocketBaseService._internal();

  static const _trustedCertsKey = 'trusted_certs';

  PocketBase? _pb;

  /// Returns the PocketBase instance. Throws if not connected.
  PocketBase get pb {
    if (_pb == null) {
      throw Exception("PocketBase not initialized. Call connect() first.");
    }
    return _pb!;
  }

  /// Checks if PocketBase is initialized
  bool get isInitialized => _pb != null;

  /// Connects to the PocketBase instance at [url] and initializes the AuthStore.
  Future<void> connect(String url) async {
    final prefs = await SharedPreferences.getInstance();

    installTrustedCertificates(await trustedCertificates());

    final store = AsyncAuthStore(
      save: (String data) async => await prefs.setString('pb_auth', data),
      initial: prefs.getString('pb_auth'),
      clear: () async => await prefs.remove('pb_auth'),
    );

    _pb = PocketBase(url, authStore: store);
  }

  /// Host -> SHA-256 fingerprint of certificates the user chose to trust.
  Future<Map<String, String>> trustedCertificates() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_trustedCertsKey);
    if (raw == null) return {};
    try {
      return Map<String, String>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  Future<void> trustCertificate(String host, String sha256) async {
    final prefs = await SharedPreferences.getInstance();
    final certs = await trustedCertificates();
    certs[host.toLowerCase()] = sha256;
    await prefs.setString(_trustedCertsKey, jsonEncode(certs));
    clearRejectedCertificate(host);
    installTrustedCertificates(certs);
  }

  /// Signs out, drops realtime subscriptions and forgets the server.
  Future<void> logout() async {
    final pb = _pb;
    if (pb != null) {
      try {
        await pb.realtime.unsubscribe().timeout(const Duration(seconds: 3));
      } catch (_) {}
      pb.authStore.clear();
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('pb_auth');
    await prefs.remove('pb_url');
    _pb = null;
  }
}
