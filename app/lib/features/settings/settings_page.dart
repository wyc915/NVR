import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/api.dart';
import '../../core/app_update.dart';
import '../../core/models.dart';
import '../../core/passkey.dart';
import '../../core/settings.dart';
import '../setup/setup_page.dart';
import 'system_page.dart';

/// Signed-in devices (revoke), pairing codes for new devices, Face ID setup, logout.
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late Future<List<Device>> _devices = _load();
  PasskeyFlow? _regFlow;
  var _busy = false;

  Future<List<Device>> _load() => ref.read(apiProvider)!.devices();

  late Future<List<AuthEvent>> _history = ref.read(apiProvider)!.loginHistory();
  var _historyAll = false;

  void _reload() => setState(() {
    _devices = _load();
    _history = ref.read(apiProvider)!.loginHistory();
  });

  void _toast(String msg) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _revoke(Device d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('撤銷「${d.name}」？'),
        content: Text(d.current ? '這是目前這台裝置，撤銷後會立刻登出，要重新用配對碼或 token 設定。' : '這台裝置會立刻被登出，它的 Face ID 登入也會失效。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('撤銷')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref.read(apiProvider)!.revokeDevice(d.id);
      if (d.current) {
        await ref.read(settingsProvider.notifier).clear(forgetPasskey: true);
        if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
        return;
      }
      _toast('已撤銷「${d.name}」');
      _reload();
    } catch (e) {
      _toast('撤銷失敗：${describeError(e)}');
    }
  }

  Future<void> _pairCode() async {
    try {
      final (code, expiresAt) = await ref.read(apiProvider)!.pairCode();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => _PairCodeDialog(code: code, expiresAt: expiresAt),
      );
    } catch (e) {
      _toast('無法產生配對碼：${describeError(e)}');
    }
  }

  /// Token-signed-in web app → add Face ID (step 1: options, step 2: tap to create).
  Future<void> _setupFaceIdNext(ServerSettings s) async {
    setState(() => _busy = true);
    try {
      final flow = await AuthApi(s.apiBase).registerOptions(defaultDeviceName(), bearer: s.token);
      if (mounted) setState(() => _regFlow = flow);
    } catch (e) {
      _toast('無法設定 Face ID：${describeError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _setupFaceIdCreate(ServerSettings s) {
    final f = _regFlow;
    if (f == null || !f.fresh) {
      setState(() => _regFlow = null);
      return;
    }
    setState(() => _busy = true);
    passkeyCreate(f.optionsJson)
        .then((r) => AuthApi(s.apiBase).registerVerify(f, r))
        .then((r) async {
          // From now on this device uses Face ID sessions; the API token is no longer stored.
          await ref.read(settingsProvider.notifier).save(r.applyTo(s));
          if (!mounted) return;
          setState(() {
            _busy = false;
            _regFlow = null;
          });
          _toast('已設定 Face ID，這台裝置不再保存 token');
          _reload();
        })
        .catchError((Object e) {
          if (!mounted) return;
          setState(() {
            _busy = false;
            _regFlow = null;
          });
          _toast(isPasskeyCancel(e) ? '已取消' : '設定失敗：${describeError(e)}');
        });
  }

  Future<void> _logout() async {
    final s = ref.read(settingsProvider).value;
    if (s?.session == true) {
      try {
        await ref.read(apiProvider)!.logout();
      } catch (_) {
        // Logged out locally anyway; the session expires on its own.
      }
    }
    await ref.read(settingsProvider.notifier).clear();
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider).value;
    if (s == null) return const Scaffold();
    final theme = Theme.of(context);
    final fmt = DateFormat('M/d HH:mm');
    final canFaceId = kIsWeb && passkeySupported() && !s.session;

    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.computer),
            title: const Text('監控電腦'),
            subtitle: Text(s.address),
            trailing: kIsWeb ? null : const Icon(Icons.chevron_right),
            onTap: kIsWeb
                ? null
                : () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SetupPage(initial: s))),
          ),
          ListTile(
            leading: Icon(s.session ? Icons.face : Icons.key),
            title: Text(s.session ? 'Face ID 登入（${s.deviceName ?? '此裝置'}）' : '使用 token 登入'),
            subtitle: Text(
              s.session && s.expiresAt != null
                  ? '${fmt.format(s.expiresAt!)} 前有效，之後再用 Face ID 登入'
                  : '這台裝置保存著 API token',
            ),
          ),
          if (canFaceId)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: _regFlow == null
                  ? OutlinedButton.icon(
                      onPressed: _busy ? null : () => _setupFaceIdNext(s),
                      icon: const Icon(Icons.face),
                      label: const Text('改用 Face ID 登入'),
                    )
                  : FilledButton.icon(
                      onPressed: _busy ? null : () => _setupFaceIdCreate(s),
                      icon: const Icon(Icons.face),
                      label: const Text('按這裡建立 Face ID'),
                    ),
            ),
          const Divider(),
          ListTile(
            title: Text('已設定 Face ID 的裝置', style: theme.textTheme.titleSmall),
            trailing: IconButton(tooltip: '重新整理', icon: const Icon(Icons.refresh), onPressed: _reload),
          ),
          FutureBuilder(
            future: _devices,
            builder: (context, snap) {
              if (snap.hasError) {
                return ListTile(title: Text('無法載入：${describeError(snap.error!)}'));
              }
              final list = snap.data;
              if (list == null) return const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator());
              if (list.isEmpty) return const ListTile(title: Text('還沒有裝置設定 Face ID'));
              return Column(
                children: [
                  for (final d in list)
                    ListTile(
                      leading: Icon(
                        d.name.contains('iPhone') || d.name.contains('Android') ? Icons.smartphone : Icons.devices,
                      ),
                      title: Text(d.current ? '${d.name}（這台）' : d.name),
                      subtitle: Text(
                        [
                          if (d.lastSeenAt != null) '最近使用 ${fmt.format(d.lastSeenAt!)}',
                          if (d.lastIp != null) d.lastIp!,
                          '加入於 ${DateFormat('y/M/d').format(d.createdAt)}',
                        ].join(' · '),
                      ),
                      trailing: IconButton(
                        tooltip: '撤銷',
                        icon: Icon(Icons.block, color: theme.colorScheme.error),
                        onPressed: () => _revoke(d),
                      ),
                    ),
                ],
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: OutlinedButton.icon(
              onPressed: _pairCode,
              icon: const Icon(Icons.add_to_home_screen),
              label: const Text('產生配對碼（加入新裝置）'),
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.monitor_heart_outlined),
            title: const Text('系統狀態'),
            subtitle: const Text('鏡頭、串流伺服器、最近事件，可重新啟動鏡頭'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SystemPage())),
          ),
          const Divider(),
          ListTile(title: Text('登入紀錄', style: theme.textTheme.titleSmall)),
          FutureBuilder(
            future: _history,
            builder: (context, snap) {
              if (snap.hasError) return ListTile(title: Text('無法載入：${describeError(snap.error!)}'));
              final list = snap.data;
              if (list == null) return const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator());
              if (list.isEmpty) return const ListTile(title: Text('還沒有紀錄'));
              final shown = _historyAll ? list : list.take(8).toList();
              return Column(
                children: [
                  for (final e in shown)
                    ListTile(
                      dense: true,
                      leading: Icon(switch (e.type) {
                        'device.added' => Icons.add_moderator,
                        'device.revoked' => Icons.block,
                        'auth.token' => Icons.key,
                        _ => Icons.face,
                      }, size: 20),
                      title: Text(e.description),
                      subtitle: Text(DateFormat('y/M/d HH:mm').format(e.ts)),
                    ),
                  if (!_historyAll && list.length > shown.length)
                    TextButton(onPressed: () => setState(() => _historyAll = true), child: const Text('顯示全部')),
                ],
              );
            },
          ),
          const Divider(),
          ListTile(
            leading: Icon(Icons.logout, color: theme.colorScheme.error),
            title: Text('登出', style: TextStyle(color: theme.colorScheme.error)),
            subtitle: Text(s.session ? '下次用 Face ID 登入' : '會清除這台裝置保存的 token'),
            onTap: _logout,
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.info_outline),
            title: Text('版本 ${buildId.isEmpty ? '開發版' : buildId}'),
            subtitle: const Text('電腦更新後，App 回到前景時會自動重新載入'),
          ),
        ],
      ),
    );
  }
}

class _PairCodeDialog extends StatefulWidget {
  const _PairCodeDialog({required this.code, required this.expiresAt});

  final String code;
  final DateTime expiresAt;

  @override
  State<_PairCodeDialog> createState() => _PairCodeDialogState();
}

class _PairCodeDialogState extends State<_PairCodeDialog> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final left = widget.expiresAt.difference(DateTime.now());
    final expired = left.isNegative;
    final mmss = expired ? '0:00' : '${left.inMinutes}:${(left.inSeconds % 60).toString().padLeft(2, '0')}';
    return AlertDialog(
      title: const Text('配對碼'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SelectableText(
            '${widget.code.substring(0, 3)} ${widget.code.substring(3)}',
            style: Theme.of(context).textTheme.displaySmall?.copyWith(letterSpacing: 4),
          ),
          const SizedBox(height: 12),
          Text(expired ? '已過期，請重新產生' : '在新裝置的登入頁輸入，$mmss 內有效，只能使用一次。', textAlign: TextAlign.center),
        ],
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('關閉'))],
    );
  }
}
