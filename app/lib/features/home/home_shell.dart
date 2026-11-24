import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/models.dart';
import '../../core/settings.dart';
import '../../state/status.dart';
import '../../state/ui.dart';
import '../../widgets/app_logo.dart';
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
        title: _tab == 0 ? const AppLogo() : Text(_titles[_tab]),
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
      bottomNavigationBar: _Dock(index: _tab, onSelect: (i) => setState(() => _tab = i)),
    );
  }
}

/// Floating capsule tab bar: rounded, bordered, soft shadow, with a small bar above the
/// selected tab that slides over with a slight overshoot.
class _Dock extends StatelessWidget {
  const _Dock({required this.index, required this.onSelect});

  final int index;
  final ValueChanged<int> onSelect;

  static const _items = [
    (Icons.videocam_outlined, Icons.videocam, '即時'),
    (Icons.video_library_outlined, Icons.video_library, '錄影'),
    (Icons.photo_library_outlined, Icons.photo_library, '截圖'),
  ];
  static const _radius = BorderRadius.all(Radius.circular(26));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final bottom = MediaQuery.paddingOf(context).bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 6, 16, bottom > 12 ? bottom : 14),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: dark ? scheme.surfaceContainerHigh : scheme.surfaceContainerLowest,
              borderRadius: _radius,
              border: Border.all(color: scheme.outlineVariant.withValues(alpha: dark ? .5 : .7)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: dark ? .55 : .16),
                  blurRadius: 32,
                  spreadRadius: -10,
                  offset: const Offset(0, 12),
                ),
                BoxShadow(
                  color: Colors.black.withValues(alpha: dark ? .2 : .06),
                  blurRadius: 8,
                  spreadRadius: -4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: SizedBox(
              height: 64,
              child: LayoutBuilder(
                builder: (context, box) {
                  final w = (box.maxWidth - 16) / _items.length;
                  return Stack(
                    children: [
                      AnimatedPositioned(
                        duration: const Duration(milliseconds: 500),
                        curve: Curves.easeOutBack,
                        top: 4,
                        left: 8 + w * index + (w - 24) / 2,
                        child: Container(
                          width: 24,
                          height: 4,
                          decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(4)),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Row(
                          children: [
                            for (final (i, (icon, selectedIcon, label)) in _items.indexed)
                              Expanded(
                                child: _DockTab(
                                  icon: i == index ? selectedIcon : icon,
                                  label: label,
                                  selected: i == index,
                                  onTap: () => onSelect(i),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DockTab extends StatefulWidget {
  const _DockTab({required this.icon, required this.label, required this.selected, required this.onTap});

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_DockTab> createState() => _DockTabState();
}

class _DockTabState extends State<_DockTab> {
  var _pressed = false;

  void _press(bool v) => setState(() => _pressed = v);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = widget.selected ? scheme.primary : scheme.onSurfaceVariant;
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _press(true),
        onTapUp: (_) => _press(false),
        onTapCancel: () => _press(false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? .9 : 1,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(widget.icon, size: 24, color: color),
              const SizedBox(height: 3),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: .2,
                  fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w500,
                  color: widget.selected ? scheme.onSurface : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
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
