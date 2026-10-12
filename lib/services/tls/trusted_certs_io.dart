import 'dart:io';

import 'package:crypto/crypto.dart';

/// Details of a certificate that failed the platform trust check.
class UntrustedCertificate {
  final String host;
  final String subject;
  final String issuer;
  final DateTime startValidity;
  final DateTime endValidity;
  final String sha256;

  UntrustedCertificate({
    required this.host,
    required this.subject,
    required this.issuer,
    required this.startValidity,
    required this.endValidity,
    required this.sha256,
  });
}

String _fingerprint(List<int> der) {
  final hex = sha256.convert(der).toString().toUpperCase();
  final buf = StringBuffer();
  for (var i = 0; i < hex.length; i += 2) {
    if (i > 0) buf.write(':');
    buf.write(hex.substring(i, i + 2));
  }
  return buf.toString();
}

/// Accepts self-signed / private-CA certificates (mkcert, internal CAs,
/// `.internal` / `.lan` hosts, ...) only when the user explicitly trusted
/// the exact certificate fingerprint for that host.
class _TrustOverrides extends HttpOverrides {
  final Map<String, String> trusted; // host -> sha256 fingerprint
  final Map<String, UntrustedCertificate> lastRejected = {};

  _TrustOverrides(this.trusted);

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.connectionTimeout = const Duration(seconds: 15);
    client.badCertificateCallback = (X509Certificate cert, String host, int port) {
      final fp = _fingerprint(cert.der);
      if (trusted[host.toLowerCase()] == fp) return true;
      lastRejected[host.toLowerCase()] = UntrustedCertificate(
        host: host,
        subject: cert.subject,
        issuer: cert.issuer,
        startValidity: cert.startValidity,
        endValidity: cert.endValidity,
        sha256: fp,
      );
      return false;
    };
    return client;
  }
}

_TrustOverrides? _overrides;

void installTrustedCertificates(Map<String, String> trusted) {
  _overrides = _TrustOverrides(
    trusted.map((k, v) => MapEntry(k.toLowerCase(), v)),
  );
  HttpOverrides.global = _overrides;
}

UntrustedCertificate? lastRejectedCertificate(String host) =>
    _overrides?.lastRejected[host.toLowerCase()];

void clearRejectedCertificate(String host) =>
    _overrides?.lastRejected.remove(host.toLowerCase());

/// Classifies a connection error into a short machine readable reason.
String classifyConnectionError(Object error) {
  final s = error.toString();
  if (s.contains('CERTIFICATE_VERIFY_FAILED') ||
      s.contains('HandshakeException') ||
      s.contains('certificate')) {
    return 'tls';
  }
  if (s.contains('Failed host lookup') || s.contains('No address associated')) {
    return 'dns';
  }
  if (s.contains('TimeoutException') || s.contains('timed out')) {
    return 'timeout';
  }
  if (s.contains('Connection refused') || s.contains('SocketException')) {
    return 'refused';
  }
  return 'unknown';
}
