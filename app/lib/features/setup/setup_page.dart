import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/settings.dart';

/// Server address + token. Shown on first launch and from the settings button.
class SetupPage extends ConsumerStatefulWidget {
  const SetupPage({super.key, this.initial});

  final ServerSettings? initial;

  @override
  ConsumerState<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends ConsumerState<SetupPage> {
  final _form = GlobalKey<FormState>();
  // On the web build served by the PC over HTTPS, the page's own address is the server.
  late final ServerSettings? _start = widget.initial ?? ServerSettings.fromPageOrigin();
  late final _host = TextEditingController(text: _start?.address ?? '');
  late final _port = TextEditingController(text: '${_start?.secure == false ? _start!.port : 8080}');
  late final _token = TextEditingController(text: widget.initial?.token ?? '');
  var _testing = false;
  var _showToken = false;
  String? _error;

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final s = _parse();
    setState(() {
      _testing = true;
      _error = null;
    });
    try {
      await NvrApi(s).status(); // verifies address and token
      await ref.read(settingsProvider.notifier).save(s);
      if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
    } catch (e) {
      setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  /// "https://pc.tailnet.ts.net" (via tailscale serve) or a plain host/IP + API port.
  bool get _isUrl => _host.text.trim().contains('://');

  ServerSettings _parse() {
    final token = _token.text.trim();
    if (_isUrl) {
      final u = Uri.parse(_host.text.trim());
      return ServerSettings(host: u.host, port: u.port, token: token, secure: u.scheme == 'https');
    }
    return ServerSettings(host: _host.text.trim(), port: int.parse(_port.text.trim()), token: token);
  }

  Future<void> _logout() async {
    await ref.read(settingsProvider.notifier).clear();
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.initial != null;
    return Scaffold(
      appBar: AppBar(title: Text(editing ? '伺服器設定' : '連線到監控電腦')),
      body: SafeArea(
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (!editing)
                const Padding(
                  padding: EdgeInsets.only(bottom: 16),
                  child: Text('輸入電腦的 IP（在外面請用 Tailscale IP）和 server/config.json 裡的 token。'),
                ),
              TextFormField(
                controller: _host,
                decoration: const InputDecoration(
                  labelText: '電腦位址',
                  hintText: '例如 100.101.102.103 或 https://電腦.xxx.ts.net',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.url,
                autocorrect: false,
                validator: (v) {
                  final s = v?.trim() ?? '';
                  if (s.isEmpty) return '請輸入位址';
                  if (s.contains('://')) {
                    final u = Uri.tryParse(s);
                    if (u == null || u.host.isEmpty || !(u.scheme == 'https' || u.scheme == 'http')) return '網址不正確';
                  }
                  return null;
                },
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 16),
              if (!_isUrl) TextFormField(
                controller: _port,
                decoration: const InputDecoration(labelText: 'API 埠', border: OutlineInputBorder()),
                keyboardType: TextInputType.number,
                validator: (v) {
                  final n = int.tryParse(v?.trim() ?? '');
                  return (n == null || n < 1 || n > 65535) ? '埠號不正確' : null;
                },
              ),
              if (!_isUrl) const SizedBox(height: 16),
              TextFormField(
                controller: _token,
                decoration: InputDecoration(
                  labelText: 'Token',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(_showToken ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _showToken = !_showToken),
                  ),
                ),
                obscureText: !_showToken,
                autocorrect: false,
                enableSuggestions: false,
                validator: (v) => (v == null || v.trim().isEmpty) ? '請輸入 token' : null,
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text('連線失敗：$_error', style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
              const SizedBox(height: 24),
              FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                onPressed: _testing ? null : _save,
                child: _testing
                    ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('測試連線並儲存'),
              ),
              if (editing) ...[
                const SizedBox(height: 12),
                TextButton(onPressed: _logout, child: const Text('清除設定')),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
