import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../core/api.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/web_audio.dart';
import '../../state/status.dart';
import '../../state/ui.dart';
import '../snapshots/snapshot_viewer_page.dart';
import 'live_controller.dart';

class LivePage extends ConsumerStatefulWidget {
  const LivePage({super.key});

  @override
  ConsumerState<LivePage> createState() => _LivePageState();
}

class _LivePageState extends ConsumerState<LivePage> {
  final _live = LiveController();
  late final AppLifecycleListener _lifecycle;
  var _ready = false;
  var _busyRecord = false;
  var _busySnapshot = false;
  var _busyPreset = false;
  var _fullscreen = false;

  @override
  void initState() {
    super.initState();
    _live.setMuted(ref.read(mutedProvider));
    _live.init().then((_) {
      _ready = true;
      _startIfPossible();
    });
    // Save bandwidth/battery: hang up in background, reconnect when back.
    _lifecycle = AppLifecycleListener(
      onHide: () => _live.stop(),
      onShow: _startIfPossible,
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _live.dispose();
    if (_fullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations([]);
    }
    super.dispose();
  }

  void _startIfPossible() {
    if (!_ready || !mounted) return;
    final api = ref.read(apiProvider);
    final status = ref.read(statusProvider).value;
    if (api != null && status != null) _live.start(api.whepUri(status), headers: api.authHeaders);
  }

  Future<void> _toggleRecording(ServerStatus s) async {
    final api = ref.read(apiProvider)!;
    setState(() => _busyRecord = true);
    try {
      final r = s.recording.active ? await api.stopRecording() : await api.startRecording();
      ref.read(statusProvider.notifier).setRecording(r);
      if (!r.active) _toast('錄影已停止，檔案整理中…');
    } catch (e) {
      _toast('錄影操作失敗：${describeError(e)}');
    } finally {
      if (mounted) setState(() => _busyRecord = false);
    }
  }

  Future<void> _snapshot() async {
    final api = ref.read(apiProvider)!;
    setState(() => _busySnapshot = true);
    try {
      final snap = await api.takeSnapshot();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: const Text('已截圖'),
          // SnackBars with an action stay until dismissed by default; auto-hide this one.
          persist: false,
          duration: const Duration(seconds: 4),
          action: SnackBarAction(
            label: '查看',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => SnapshotViewerPage(snapshot: snap)),
            ),
          ),
        ));
    } catch (e) {
      _toast('截圖失敗：${describeError(e)}');
    } finally {
      if (mounted) setState(() => _busySnapshot = false);
    }
  }

  Future<void> _setPreset(String preset) async {
    final api = ref.read(apiProvider)!;
    setState(() => _busyPreset = true);
    try {
      await api.setPreset(preset);
      ref.read(statusProvider.notifier).setPreset(preset);
      // The server restarts the stream; reconnect right away instead of waiting
      // several seconds for WebRTC to notice the old session died.
      _live.restartSoon();
    } catch (e) {
      _toast('切換畫質失敗：${describeError(e)}');
    } finally {
      if (mounted) setState(() => _busyPreset = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _enterFullscreen() async {
    setState(() => _fullscreen = true);
    ref.read(fullscreenProvider.notifier).set(true);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  }

  Future<void> _exitFullscreen() async {
    if (mounted) {
      setState(() => _fullscreen = false);
      ref.read(fullscreenProvider.notifier).set(false);
    }
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await SystemChrome.setPreferredOrientations([]);
  }

  @override
  Widget build(BuildContext context) => Listener(
        // Web (iPhone Safari): any tap unlocks audio playback blocked by autoplay rules.
        // pointerup is the "user activation" event for touch, pointerdown for mouse.
        onPointerDown: (_) => resumeWebAudio(),
        onPointerUp: (_) => resumeWebAudio(),
        child: _body(context),
      );

  Widget _body(BuildContext context) {
    // Connect when status first arrives; reconnect when the camera comes back.
    ref.listen(statusProvider, (prev, next) {
      final was = prev?.value;
      final now = next.value;
      if (now == null) return;
      if (was == null) {
        _startIfPossible();
      } else if (!was.cameraOnline && now.cameraOnline && _live.state != LiveState.playing) {
        _live.reconnect();
      }
    });

    ref.listen(mutedProvider, (_, muted) => _live.setMuted(muted));

    final status = ref.watch(statusProvider);
    final toggleMute = ref.read(mutedProvider.notifier).toggle;

    final video = _VideoView(
      live: _live,
      status: status.value,
      fullscreen: _fullscreen,
      onToggleFullscreen: _fullscreen ? _exitFullscreen : _enterFullscreen,
      onToggleMute: toggleMute,
    );

    if (_fullscreen) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _exitFullscreen();
        },
        child: ColoredBox(color: Colors.black, child: Center(child: video)),
      );
    }

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        video,
        Padding(
          padding: const EdgeInsets.all(16),
          child: switch (status) {
            AsyncData(:final value) => _Controls(
                status: value,
                busyRecord: _busyRecord,
                busySnapshot: _busySnapshot,
                busyPreset: _busyPreset,
                onToggleRecording: () => _toggleRecording(value),
                onSnapshot: _snapshot,
                onPreset: _setPreset,
              ),
            AsyncError(:final error) => _ErrorCard(
                message: describeError(error),
                onRetry: () => ref.invalidate(statusProvider),
              ),
            _ => const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              ),
          },
        ),
      ],
    );
  }
}

class _VideoView extends StatelessWidget {
  const _VideoView({
    required this.live,
    required this.status,
    required this.fullscreen,
    required this.onToggleFullscreen,
    required this.onToggleMute,
  });

  final LiveController live;
  final ServerStatus? status;
  final bool fullscreen;
  final VoidCallback onToggleFullscreen;
  final VoidCallback onToggleMute;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: ColoredBox(
        color: Colors.black,
        child: ListenableBuilder(
          listenable: live,
          builder: (context, _) => Stack(
            fit: StackFit.expand,
            children: [
              RTCVideoView(live.renderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain),
              if (live.state != LiveState.playing)
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (live.state == LiveState.connecting)
                        const CircularProgressIndicator(color: Colors.white70)
                      else
                        const Icon(Icons.videocam_off, color: Colors.white54, size: 40),
                      const SizedBox(height: 12),
                      Text(
                        switch (live.state) {
                          LiveState.connecting => '連線中…',
                          LiveState.error => live.error ?? '連線失敗',
                          _ => status?.cameraOnline == false ? '鏡頭離線' : '',
                        },
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ],
                  ),
                ),
              Positioned(
                top: 8,
                left: 8,
                child: _Badge(
                  color: live.state == LiveState.playing ? Colors.green : Colors.grey,
                  text: live.state == LiveState.playing ? '即時 · ${status?.preset ?? ''}' : '未連線',
                ),
              ),
              if (status?.recording.active == true)
                Positioned(top: 8, right: 8, child: _RecBadge(startedAt: status!.recording.startedAt)),
              Positioned(
                bottom: 8,
                right: 8,
                child: Row(
                  children: [
                    _OverlayButton(
                      tooltip: live.muted ? '開啟聲音' : '靜音',
                      icon: live.muted ? Icons.volume_off : Icons.volume_up,
                      highlight: live.muted,
                      onPressed: onToggleMute,
                    ),
                    const SizedBox(width: 8),
                    _OverlayButton(
                      tooltip: fullscreen ? '離開全螢幕' : '全螢幕',
                      icon: fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                      onPressed: onToggleFullscreen,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Round button with a dark backdrop so it stays visible on bright video.
class _OverlayButton extends StatelessWidget {
  const _OverlayButton({required this.tooltip, required this.icon, required this.onPressed, this.highlight = false});

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return IconButton.filled(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon),
      style: IconButton.styleFrom(
        backgroundColor: highlight ? Colors.red.shade700.withValues(alpha: 0.85) : Colors.black.withValues(alpha: 0.6),
        foregroundColor: Colors.white,
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.color, required this.text});

  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.circle, size: 10, color: color),
            const SizedBox(width: 6),
            Text(text, style: const TextStyle(color: Colors.white, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

/// Red "REC 00:12" badge with a ticking timer.
class _RecBadge extends StatefulWidget {
  const _RecBadge({required this.startedAt});

  final DateTime? startedAt;

  @override
  State<_RecBadge> createState() => _RecBadgeState();
}

class _RecBadgeState extends State<_RecBadge> {
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
    final start = widget.startedAt;
    final elapsed = start == null ? Duration.zero : DateTime.now().difference(start);
    return DecoratedBox(
      decoration: BoxDecoration(color: Colors.red.shade700, borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          'REC ${formatDuration(elapsed.isNegative ? Duration.zero : elapsed)}',
          style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.status,
    required this.busyRecord,
    required this.busySnapshot,
    required this.busyPreset,
    required this.onToggleRecording,
    required this.onSnapshot,
    required this.onPreset,
  });

  final ServerStatus status;
  final bool busyRecord;
  final bool busySnapshot;
  final bool busyPreset;
  final VoidCallback onToggleRecording;
  final VoidCallback onSnapshot;
  final ValueChanged<String> onPreset;

  @override
  Widget build(BuildContext context) {
    final recording = status.recording.active;
    final online = status.cameraOnline;
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(56),
                  backgroundColor: recording ? Colors.red.shade700 : null,
                ),
                onPressed: busyRecord || (!online && !recording) ? null : onToggleRecording,
                icon: busyRecord
                    ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(recording ? Icons.stop : Icons.fiber_manual_record),
                label: Text(recording ? '停止錄影' : '開始錄影'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                onPressed: busySnapshot || !online ? null : onSnapshot,
                icon: busySnapshot
                    ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.photo_camera),
                label: const Text('截圖'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Text('畫質', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: [
            for (final p in status.presets)
              ButtonSegment(
                value: p,
                label: Text(switch (p) {
                  '1080p' => '1080p · 30fps',
                  '720p' => '720p · 15fps',
                  _ => p,
                }),
              ),
          ],
          selected: {status.preset},
          onSelectionChanged: busyPreset ? null : (s) => onPreset(s.first),
          showSelectedIcon: false,
        ),
        if (recording)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '錄影中切換畫質會自動分成新的檔案',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
            ),
          ),
        const SizedBox(height: 24),
        _InfoRow(
          icon: online ? Icons.videocam : Icons.videocam_off,
          text: online ? '鏡頭在線' : '鏡頭離線',
          color: online ? Colors.green : scheme.error,
        ),
        _InfoRow(
          icon: Icons.storage,
          text: '硬碟剩餘 ${formatBytes(status.diskFree)} / ${formatBytes(status.diskTotal)}',
        ),
        _InfoRow(icon: Icons.memory, text: '編碼器：${status.encoder == 'nvenc' ? 'NVIDIA NVENC' : 'CPU (x264)'}'),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.text, this.color});

  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Icon(icon, size: 18, color: c),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: TextStyle(color: c))),
      ]),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          Icon(Icons.cloud_off, color: Theme.of(context).colorScheme.error, size: 40),
          const SizedBox(height: 8),
          Text('無法取得伺服器狀態：$message', textAlign: TextAlign.center),
          const SizedBox(height: 8),
          FilledButton.tonal(onPressed: onRetry, child: const Text('重試')),
        ]),
      ),
    );
  }
}
