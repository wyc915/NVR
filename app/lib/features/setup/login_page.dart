import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/passkey.dart';
import '../../core/settings.dart';

/// Web app login: Face ID (passkey) for devices that set it up, otherwise a one-time
/// setup with a pairing code (from a signed-in device) or the API token.
///
/// Safari only shows Face ID when the WebAuthn call happens directly in a tap handler,
/// so options are always fetched *before* the tap that triggers Face ID.
class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

enum _Mode { login, setup }

class _LoginPageState extends ConsumerState<LoginPage> {
  final _origin = ServerSettings.fromPageOrigin()!;
  late final _auth = AuthApi(_origin.apiBase);
  final _form = GlobalKey<FormState>();
  final _secret = TextEditingController();
  final _name = TextEditingController(text: defaultDeviceName());

  var _mode = _Mode.login;
  var _loading = true;
  var _busy = false;
  var _showSecret = false;
  String? _error;
  String? _hint;
  PasskeyFlow? _loginFlow;
  PasskeyFlow? _regFlow;
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final has = await ref.read(settingsProvider.notifier).hasPasskey();
    if (!mounted) return;
    setState(() {
      _mode = has ? _Mode.login : _Mode.setup;
      _loading = false;
    });
    await _prefetchLogin();
    // Options expire after 5 minutes; keep a fresh set ready for the tap.
    _refresh = Timer.periodic(const Duration(minutes: 4), (_) => _prefetchLogin());
  }

  @override
  void dispose() {
    _refresh?.cancel();
    _secret.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _prefetchLogin() async {
    try {
      final f = await _auth.loginOptions();
      if (mounted) setState(() => _loginFlow = f);
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    }
  }

  // ------------------------------------------------------------------ login

  void _loginTap() {
    final f = _loginFlow;
    if (f == null || !f.fresh) {
      setState(() => _hint = '準備中，請再按一次');
      _prefetchLogin();
      return;
    }
    _loginFlow = null;
    // Called synchronously inside the tap handler (user gesture for Safari).
    _finish(passkeyGet(f.optionsJson).then((r) => _auth.loginVerify(f, r)));
  }

  // ------------------------------------------------------------------ setup

  bool get _isPairCode => RegExp(r'^\d{6}$').hasMatch(_secret.text.trim());

  /// Step 1: check the pairing code / token and get registration options.
  Future<void> _setupNext() async {
    if (!_form.currentState!.validate()) return;
    final secret = _secret.text.trim();
    await _run(() async {
      final flow = await _auth.registerOptions(
        _name.text.trim(),
        pairCode: _isPairCode ? secret : null,
        bearer: _isPairCode ? null : secret,
      );
      setState(() => _regFlow = flow);
    });
  }

  /// Step 2: create the passkey (Face ID).
  void _createTap() {
    final f = _regFlow;
    if (f == null || !f.fresh) {
      setState(() {
        _regFlow = null;
        _error = '逾時，請再按一次「下一步」';
      });
      return;
    }
    _finish(passkeyCreate(f.optionsJson).then((r) => _auth.registerVerify(f, r)));
  }

  /// For browsers where Face ID isn't wanted (e.g. the PC itself): keep using the API token.
  Future<void> _tokenOnly() async {
    if (!_form.currentState!.validate()) return;
    final s = _origin.withToken(_secret.text.trim());
    await _run(() async {
      await NvrApi(s).status();
      await ref.read(settingsProvider.notifier).save(s);
    });
  }

  // ------------------------------------------------------------------ shared

  void _finish(Future<LoginResult> login) {
    setState(() {
      _busy = true;
      _error = null;
      _hint = null;
    });
    login
        .then((r) async {
          await ref
              .read(settingsProvider.notifier)
              .save(_origin.withToken(r.token, session: true, expiresAt: r.expiresAt, deviceName: r.deviceName));
          // The app switches to the home screen when settings change.
        })
        .catchError((Object e) {
          if (!mounted) return;
          setState(() {
            _busy = false;
            _regFlow = null;
            _error = isPasskeyCancel(e) ? '已取消' : describeError(e);
          });
          _prefetchLogin();
        });
  }

  Future<void> _run(Future<void> Function() fn) async {
    setState(() {
      _busy = true;
      _error = null;
      _hint = null;
    });
    try {
      await fn();
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('監控')),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.computer),
                    title: const Text('監控電腦'),
                    subtitle: Text(_origin.address),
                  ),
                  const SizedBox(height: 16),
                  if (_mode == _Mode.login) ..._loginView(theme) else ..._setupView(theme),
                  if (_hint != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(_hint!, textAlign: TextAlign.center),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  List<Widget> _loginView(ThemeData theme) => [
    FilledButton.icon(
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
      onPressed: _busy ? null : _loginTap,
      icon: _busy
          ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.face),
      label: const Text('使用 Face ID 登入'),
    ),
    const SizedBox(height: 32),
    TextButton(
      onPressed: _busy ? null : () => setState(() => _mode = _Mode.setup),
      child: const Text('這台裝置還沒設定過 Face ID？'),
    ),
  ];

  List<Widget> _setupView(ThemeData theme) {
    final step2 = _regFlow != null;
    return [
      Text('第一次在這台裝置使用', style: theme.textTheme.titleMedium),
      const SizedBox(height: 8),
      Text(
        '輸入已登入裝置「設定 → 產生配對碼」顯示的 6 位數，或電腦 server/config.json 裡的 token。'
        '設定好 Face ID 之後，這台裝置不會保存 token。',
        style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
      ),
      const SizedBox(height: 16),
      Form(
        key: _form,
        child: Column(
          children: [
            TextFormField(
              controller: _secret,
              enabled: !step2,
              decoration: InputDecoration(
                labelText: '配對碼或 token',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(_showSecret ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _showSecret = !_showSecret),
                ),
              ),
              obscureText: !_showSecret && !_isPairCode,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (_) => setState(() {}),
              validator: (v) => (v == null || v.trim().isEmpty) ? '請輸入配對碼或 token' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _name,
              enabled: !step2,
              decoration: const InputDecoration(
                labelText: '裝置名稱',
                helperText: '在裝置列表中顯示，例如「我的 iPhone」',
                border: OutlineInputBorder(),
              ),
              maxLength: 40,
              validator: (v) => (v == null || v.trim().isEmpty) ? '請輸入裝置名稱' : null,
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      if (!step2)
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: _busy ? null : _setupNext,
          child: _busy
              ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('下一步'),
        )
      else
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
          onPressed: _busy ? null : _createTap,
          icon: _busy
              ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.face),
          label: const Text('建立 Face ID 登入'),
        ),
      if (step2) TextButton(onPressed: _busy ? null : () => setState(() => _regFlow = null), child: const Text('返回')),
      if (!step2 && _secret.text.trim().isNotEmpty && !_isPairCode)
        TextButton(onPressed: _busy ? null : _tokenOnly, child: const Text('不設定 Face ID，只用 token 登入')),
      const SizedBox(height: 16),
      TextButton(
        onPressed: _busy
            ? null
            : () => setState(() {
                _mode = _Mode.login;
                _regFlow = null;
                _error = null;
              }),
        child: const Text('已經設定過 Face ID？直接登入'),
      ),
    ];
  }
}
