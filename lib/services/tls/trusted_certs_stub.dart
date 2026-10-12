/// Web / unsupported platforms: the browser handles certificates.
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

void installTrustedCertificates(Map<String, String> trusted) {}

UntrustedCertificate? lastRejectedCertificate(String host) => null;

void clearRejectedCertificate(String host) {}

String classifyConnectionError(Object error) {
  final s = error.toString();
  if (s.contains('TimeoutException')) return 'timeout';
  return 'unknown';
}
