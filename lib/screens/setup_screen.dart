import 'package:beszel_pro/screens/login_screen.dart';
import 'package:beszel_pro/services/pocketbase_service.dart';
import 'package:beszel_pro/services/tls/trusted_certs.dart';
import 'package:beszel_pro/widgets/language_menu.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:easy_localization/easy_localization.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _urlController = TextEditingController();
  bool _isLoading = false;
  String? _error;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  /// Returns candidate base URLs for the user input. Any hostname is
  /// accepted (`.internal`, `.lan`, `.home.arpa`, bare IPs, ports, sub-paths).
  List<Uri> _candidates(String input) {
    var text = input.trim();
    while (text.endsWith('/')) {
      text = text.substring(0, text.length - 1);
    }
    final hasScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(text);
    final schemes = hasScheme ? [''] : ['https://', 'http://'];
    final result = <Uri>[];
    for (final scheme in schemes) {
      final uri = Uri.tryParse('$scheme$text');
      if (uri == null ||
          uri.host.isEmpty ||
          !(uri.scheme == 'http' || uri.scheme == 'https')) {
        continue;
      }
      result.add(uri.replace(query: null, fragment: null));
    }
    return result;
  }

  String _baseUrl(Uri uri) {
    var s = uri.toString();
    if (s.endsWith('?')) s = s.substring(0, s.length - 1);
    if (s.endsWith('#')) s = s.substring(0, s.length - 1);
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  Future<void> _connect() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    final candidates = _candidates(_urlController.text);
    if (candidates.isEmpty) {
      setState(() {
        _isLoading = false;
        _error = tr('enter_valid_url');
      });
      return;
    }

    String? errorKey;
    Object? lastError;
    for (final uri in candidates) {
      final url = _baseUrl(uri);
      try {
        await _check(url);
        await _onConnected(url);
        return;
      } catch (e) {
        lastError = e;
        debugPrint('Connection error ($url): $e');
        final reason = classifyConnectionError(e);
        final cert = lastRejectedCertificate(uri.host);
        if (reason == 'tls' && cert != null && mounted) {
          final trusted = await _askTrust(cert);
          if (trusted) {
            await PocketBaseService().trustCertificate(uri.host, cert.sha256);
            try {
              await _check(url);
              await _onConnected(url);
              return;
            } catch (e2) {
              lastError = e2;
              errorKey = 'error_${classifyConnectionError(e2)}';
            }
          } else {
            errorKey = 'error_tls';
          }
          // The user decided about TLS - don't silently fall back to http.
          break;
        }
        errorKey ??= 'error_$reason';
        // Only try plain http when https could not be reached at all.
        if (reason == 'dns') break;
      }
    }

    if (mounted) {
      setState(() {
        _isLoading = false;
        final key = errorKey ?? 'error_unknown';
        _error = '${tr('url_incorrect')}\n${tr(key)}';
        if (key == 'error_unknown' && lastError != null) {
          _error = '$_error\n$lastError';
        }
      });
    }
  }

  Future<void> _check(String url) async {
    await PocketBaseService().connect(url);
    await PocketBaseService().pb.health.check().timeout(
      const Duration(seconds: 15),
    );
  }

  Future<void> _onConnected(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pb_url', url);
    if (!mounted) return;
    setState(() => _isLoading = false);
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  Future<bool> _askTrust(UntrustedCertificate cert) async {
    final fmt = DateFormat('yyyy-MM-dd');
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.gpp_maybe, color: Colors.orange, size: 36),
        title: Text(tr('untrusted_cert_title')),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(tr('untrusted_cert_body', args: [cert.host])),
              const SizedBox(height: 12),
              _certRow(tr('cert_subject'), cert.subject),
              _certRow(tr('cert_issuer'), cert.issuer),
              _certRow(
                tr('cert_valid'),
                '${fmt.format(cert.startValidity)} → ${fmt.format(cert.endValidity)}',
              ),
              _certRow('SHA-256', cert.sha256, mono: true),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('trust_cert')),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Widget _certRow(String label, String value, {bool mono = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          SelectableText(
            value,
            style: TextStyle(
              fontSize: 12,
              fontFamily: mono ? 'monospace' : null,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('setup_title'.tr()),
        actions: const [LanguageMenuButton()],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'enter_url'.tr(),
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _urlController,
                  decoration: InputDecoration(
                    labelText: 'server_url'.tr(),
                    hintText: 'https://beszel.home.internal:8090',
                    helperText: 'server_url_hint'.tr(),
                    helperMaxLines: 3,
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.link),
                  ),
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  textCapitalization: TextCapitalization.none,
                  onSubmitted: (_) => _isLoading ? null : _connect(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _error!,
                    style: const TextStyle(color: Colors.red),
                    textAlign: TextAlign.center,
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _isLoading ? null : _connect,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: _isLoading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text('connect'.tr()),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
