import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/models.dart';
import '../../core/settings.dart';
import '../../state/status.dart';
import '../../state/ui.dart';
import '../live/live_page.dart';
import '../recordings/recordings_page.dart';
import '../settings/settings_page.dart';
import '../snapshots/snapshots_page.dart';

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  var _tab = 0;
  StreamSubscription<Map<String, dynamic>>? _events;

  static const _titles = ['即時影像', '錄影', '截圖'];

  @override
  void initState() {
    super.initState();
    _events = ref.read(serverEventsProvider).stream.listen(_onEvent);
  }

  @override
  void dispose() {
    _events?.cancel();
    super.dispose();
  }

  void _openSettings() => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsPage()));

  /// Security alert: another device logged in / was added, or the API token was used from a new address.
  void _onEvent(Map<String, dynamic> raw) {
    if (!AuthEvent.types.contains(raw['type']) || !mounted) return;
    final me = ref.read(settingsProvider).value;
    final e = AuthEvent.fromJson(raw);
    if (e.deviceId != null && e.deviceId == me?.deviceId) return; // that was us
    if (e.type == 'auth.token' && me?.session == false) return; // most likely this device itself
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(e.description),
          persist: false,
          duration: const Duration(seconds: 8),
          action: SnackBarAction(label: '查看', onPressed: _openSettings),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final fullscreen = ref.watch(fullscreenProvider);
    final connected = ref.watch(eventsConnectedProvider);
    final status = ref.watch(statusProvider).value;

    // Pages are rebuilt when switching tabs on purpose: leaving the live tab
    // closes the WebRTC stream so it doesn't use data in the background.
    final body = switch (_tab) {
      0 => const LivePage(),
      1 => const RecordingsPage(),
      _ => const SnapshotsPage(),
    };

    if (fullscreen) return Scaffold(backgroundColor: Colors.black, body: body);
    final withBanner = Column(
      children: [
        _OfflineBanner(connected: connected),
        Expanded(child: body),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_tab]),
        actions: [
          if (status?.recording.active == true)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Icon(Icons.fiber_manual_record, color: Colors.red, size: 16),
            ),
          Tooltip(
            message: connected ? '已連線到電腦' : '與電腦的連線中斷',
            child: Icon(
              connected ? Icons.cloud_done : Icons.cloud_off,
              color: connected ? null : Theme.of(context).colorScheme.error,
            ),
          ),
          IconButton(tooltip: '設定', icon: const Icon(Icons.settings), onPressed: _openSettings),
        ],
      ),
      body: withBanner,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.videocam_outlined), selectedIcon: Icon(Icons.videocam), label: '即時'),
          NavigationDestination(
            icon: Icon(Icons.video_library_outlined),
            selectedIcon: Icon(Icons.video_library),
            label: '錄影',
          ),
          NavigationDestination(
            icon: Icon(Icons.photo_library_outlined),
            selectedIcon: Icon(Icons.photo_library),
            label: '截圖',
          ),
        ],
      ),
    );
  }
}

/// "Can't reach the PC" notice; waits a few seconds so a quick reconnect (e.g. after the
/// app comes back from the background) doesn't flash it.
class _OfflineBanner extends ConsumerStatefulWidget {
  const _OfflineBanner({required this.connected});

  final bool connected;

  @override
  ConsumerState<_OfflineBanner> createState() => _OfflineBannerState();
}

class _OfflineBannerState extends ConsumerState<_OfflineBanner> {
  Timer? _delay;
  var _show = false;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_OfflineBanner old) {
    super.didUpdateWidget(old);
    if (old.connected != widget.connected) _sync();
  }

  void _sync() {
    _delay?.cancel();
    if (widget.connected) {
      _show = false;
    } else {
      _delay = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => _show = true);
      });
    }
  }

  @override
  void dispose() {
    _delay?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_show) return const SizedBox.shrink();
    final last = ref.watch(lastConnectedProvider);
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: ListTile(
        dense: true,
        leading: Icon(Icons.cloud_off, color: scheme.onErrorContainer),
        title: Text('連不到監控電腦，重試中…', style: TextStyle(color: scheme.onErrorContainer)),
        subtitle: Text(
          last == null ? '電腦可能關機、睡眠，或 Tailscale 沒有連線' : '最後連線 ${DateFormat('M/d HH:mm').format(last)} · 電腦可能關機或睡眠',
          style: TextStyle(color: scheme.onErrorContainer),
        ),
      ),
    );
  }
}
