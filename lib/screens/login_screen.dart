import 'package:beszel_pro/services/pocketbase_service.dart';
import 'package:beszel_pro/widgets/language_menu.dart';
import 'package:flutter/material.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:beszel_pro/screens/appearance_screen.dart';

enum _Step { credentials, otp }

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _otpController = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassword = true;
  String? _error;
  String? _info;

  _Step _step = _Step.credentials;
  String? _mfaId;
  String? _otpId;

  AuthMethodsList? _methods;

  RecordService get _users => PocketBaseService().pb.collection('users');

  bool get _passwordEnabled => _methods?.password.enabled ?? true;
  bool get _otpEnabled => _methods?.otp.enabled ?? false;
  List<AuthMethodProvider> get _providers =>
      _methods?.oauth2.enabled == true ? _methods!.oauth2.providers : const [];

  @override
  void initState() {
    super.initState();
    _loadAuthMethods();
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _otpController.dispose();
    super.dispose();
  }

  Future<void> _loadAuthMethods() async {
    try {
      final methods = await _users.listAuthMethods();
      if (mounted) setState(() => _methods = methods);
    } catch (e) {
      debugPrint('listAuthMethods failed: $e');
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (!mounted) return;
      final mfaId = _extractMfaId(e);
      if (mfaId != null) {
        // Password / OAuth2 succeeded, but the hub requires a second factor.
        _mfaId = mfaId;
        await _startOtp(silent: true);
        return;
      }
      setState(() => _error = _describe(e));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String? _extractMfaId(Object e) {
    if (e is ClientException && e.statusCode == 401) {
      final id = e.response['mfaId'];
      if (id is String && id.isNotEmpty) return id;
    }
    return null;
  }

  String _describe(Object e) {
    if (e is ClientException) {
      final msg = e.response['message']?.toString();
      if (e.statusCode == 0) return tr('error_refused');
      if (e.statusCode == 400 && _step == _Step.credentials) {
        return tr('login_failed');
      }
      if (msg != null && msg.isNotEmpty) return msg;
    }
    return e.toString();
  }

  Future<void> _loginWithPassword() => _run(() async {
    await _users.authWithPassword(
      _emailController.text.trim(),
      _passwordController.text,
    );
    _onAuthenticated();
  });

  Future<void> _loginWithOAuth2(AuthMethodProvider provider) => _run(() async {
    await _users.authWithOAuth2(provider.name, (url) async {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    });
    _onAuthenticated();
  });

  /// Sends a one-time code to the user's email. Used both for MFA
  /// (after a successful first factor) and for password-less OTP login.
  Future<void> _startOtp({bool silent = false}) async {
    final email = _emailController.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() {
        _error = tr('otp_email_required');
        _isLoading = false;
      });
      return;
    }
    Future<void> send() async {
      final res = await _users.requestOTP(email);
      if (!mounted) return;
      setState(() {
        _otpId = res.otpId;
        _step = _Step.otp;
        _otpController.clear();
        _info = tr(
          _mfaId != null ? 'mfa_code_sent' : 'otp_code_sent',
          args: [email],
        );
      });
    }

    if (silent) {
      try {
        await send();
      } catch (e) {
        if (mounted) setState(() => _error = _describe(e));
      } finally {
        if (mounted) setState(() => _isLoading = false);
      }
    } else {
      await _run(send);
    }
  }

  Future<void> _verifyOtp() => _run(() async {
    final otpId = _otpId;
    if (otpId == null) return;
    await _users.authWithOTP(
      otpId,
      _otpController.text.trim(),
      body: {if (_mfaId != null) 'mfaId': _mfaId},
    );
    _onAuthenticated();
  });

  void _backToCredentials() {
    setState(() {
      _step = _Step.credentials;
      _mfaId = null;
      _otpId = null;
      _info = null;
      _error = null;
    });
  }

  void _onAuthenticated() {
    if (!mounted) return;
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const AppearanceScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('login'.tr()),
        actions: const [LanguageMenuButton()],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  _step == _Step.otp ? Icons.password : Icons.security,
                  size: 80,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 32),
                ...(_step == _Step.otp ? _buildOtpStep() : _buildCredentials()),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _error!,
                    style: const TextStyle(color: Colors.red),
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _loadingOr(String label) => _isLoading
      ? const SizedBox(
          height: 20,
          width: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        )
      : Text(label);

  List<Widget> _buildCredentials() {
    return [
      TextField(
        controller: _emailController,
        decoration: InputDecoration(
          labelText: 'email_username'.tr(),
          prefixIcon: const Icon(Icons.person),
          border: const OutlineInputBorder(),
        ),
        keyboardType: TextInputType.emailAddress,
        autofillHints: const [AutofillHints.email, AutofillHints.username],
        autocorrect: false,
        textCapitalization: TextCapitalization.none,
      ),
      if (_passwordEnabled) ...[
        const SizedBox(height: 16),
        TextField(
          controller: _passwordController,
          decoration: InputDecoration(
            labelText: 'password'.tr(),
            prefixIcon: const Icon(Icons.lock),
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: Icon(
                _obscurePassword ? Icons.visibility : Icons.visibility_off,
              ),
              onPressed: () =>
                  setState(() => _obscurePassword = !_obscurePassword),
            ),
          ),
          obscureText: _obscurePassword,
          autofillHints: const [AutofillHints.password],
          onSubmitted: (_) => _isLoading ? null : _loginWithPassword(),
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _isLoading ? null : _loginWithPassword,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
          child: _loadingOr('login'.tr()),
        ),
      ],
      if (_otpEnabled) ...[
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _isLoading ? null : () => _startOtp(),
          icon: const Icon(Icons.mail_outline),
          label: Text('login_with_code'.tr()),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
      ],
      if (_providers.isNotEmpty) ...[
        const SizedBox(height: 20),
        Row(
          children: [
            const Expanded(child: Divider()),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text('or'.tr(), style: const TextStyle(color: Colors.grey)),
            ),
            const Expanded(child: Divider()),
          ],
        ),
        const SizedBox(height: 12),
        for (final p in _providers)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: OutlinedButton.icon(
              onPressed: _isLoading ? null : () => _loginWithOAuth2(p),
              icon: const Icon(Icons.open_in_new, size: 18),
              label: Text(
                tr('login_with', args: [p.displayName.isNotEmpty ? p.displayName : p.name]),
              ),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
      ],
    ];
  }

  List<Widget> _buildOtpStep() {
    return [
      Text(
        _mfaId != null ? 'mfa_title'.tr() : 'otp_title'.tr(),
        style: Theme.of(context).textTheme.titleLarge,
        textAlign: TextAlign.center,
      ),
      if (_info != null) ...[
        const SizedBox(height: 8),
        Text(_info!, textAlign: TextAlign.center),
      ],
      const SizedBox(height: 24),
      TextField(
        controller: _otpController,
        autofocus: true,
        decoration: InputDecoration(
          labelText: 'otp_code'.tr(),
          prefixIcon: const Icon(Icons.pin),
          border: const OutlineInputBorder(),
        ),
        keyboardType: TextInputType.number,
        autofillHints: const [AutofillHints.oneTimeCode],
        onSubmitted: (_) => _isLoading ? null : _verifyOtp(),
      ),
      const SizedBox(height: 24),
      FilledButton(
        onPressed: _isLoading ? null : _verifyOtp,
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 16),
        ),
        child: _loadingOr('verify'.tr()),
      ),
      const SizedBox(height: 8),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          TextButton(
            onPressed: _isLoading ? null : _backToCredentials,
            child: Text('back'.tr()),
          ),
          TextButton(
            onPressed: _isLoading ? null : () => _startOtp(),
            child: Text('resend_code'.tr()),
          ),
        ],
      ),
    ];
  }
}
