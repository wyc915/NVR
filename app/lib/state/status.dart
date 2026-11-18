import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/api.dart';
import '../core/models.dart';

/// Raw server events from the WebSocket (`{"type": ..., "ts": ..., ...}`),
/// so other providers (e.g. recording/snapshot lists) can react to them.
final serverEventsProvider = Provider<StreamController<Map<String, dynamic>>>((ref) {
  final c = StreamController<Map<String, dynamic>>.broadcast();
  ref.onDispose(c.close);
  return c;
});

/// Whether the event WebSocket is currently connected.
final eventsConnectedProvider = NotifierProvider<_Flag, bool>(_Flag.new);

/// When the PC was last reachable (WebSocket up), for the "offline since" notice.
final lastConnectedProvider = NotifierProvider<_Time, DateTime?>(_Time.new);

class _Time extends Notifier<DateTime?> {
  @override
  DateTime? build() => null;
  void set(DateTime v) => state = v;
}

class _Flag extends Notifier<bool> {
  @override
  bool build() => false;
  void set(bool v) => state = v;
}

/// Live server status: loaded via REST, then kept up to date by WebSocket events.
/// On every (re)connect the server sends a fresh `hello` status, so missed events
/// while offline are not a problem.
class StatusNotifier extends AsyncNotifier<ServerStatus> {
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _retry;
  var _backoff = const Duration(seconds: 1);
  var _disposed = false;

  @override
  Future<ServerStatus> build() async {
    final api = ref.watch(apiProvider);
    if (api == null) throw StateError('not configured');
    _disposed = false;
    ref.onDispose(() {
      _disposed = true;
      _retry?.cancel();
      _sub?.cancel();
      _channel?.sink.close();
    });
    _connect(api);
    return api.status();
  }

  void _connect(NvrApi api) {
    if (_disposed) return;
    final ch = WebSocketChannel.connect(api.eventsUri);
    _channel = ch;
    ch.ready.then((_) {
      if (_disposed) return;
      _backoff = const Duration(seconds: 1);
      ref.read(eventsConnectedProvider.notifier).set(true);
      ref.read(lastConnectedProvider.notifier).set(DateTime.now());
    }, onError: (_) {});
    _sub = ch.stream.listen(
      _onMessage,
      onError: (_) => _reconnect(api),
      onDone: () => _reconnect(api),
      cancelOnError: true,
    );
  }

  void _reconnect(NvrApi api) {
    if (_disposed) return;
    if (ref.read(eventsConnectedProvider)) ref.read(lastConnectedProvider.notifier).set(DateTime.now());
    ref.read(eventsConnectedProvider.notifier).set(false);
    _sub?.cancel();
    _retry?.cancel();
    final delay = _backoff;
    _backoff = Duration(seconds: (_backoff.inSeconds * 2).clamp(1, 30));
    _retry = Timer(delay, () => _connect(api));
  }

  void _onMessage(dynamic raw) {
    if (_disposed) return;
    final ev = jsonDecode(raw as String) as Map<String, dynamic>;
    ref.read(serverEventsProvider).add(ev);

    final cur = state.value;
    switch (ev['type']) {
      case 'hello':
        state = AsyncData(ServerStatus.fromJson(ev['status'] as Map<String, dynamic>));
      case 'camera.online' when cur != null:
        state = AsyncData(cur.copyWith(camera: CameraState.live));
      case 'camera.offline' when cur != null:
        state = AsyncData(cur.copyWith(camera: CameraState.offline));
      case 'camera.starting' when cur != null:
        state = AsyncData(cur.copyWith(camera: CameraState.starting));
      case 'camera.idle' when cur != null:
        state = AsyncData(cur.copyWith(camera: CameraState.idle));
      case 'preset.changed' when cur != null:
        state = AsyncData(cur.copyWith(preset: ev['preset'] as String));
      case 'recording.started' when cur != null:
        state = AsyncData(
          cur.copyWith(
            recording: RecordingStatus(
              active: true,
              sessionId: ev['sessionId'] as String?,
              startedAt: DateTime.fromMillisecondsSinceEpoch((ev['startedAt'] as num).toInt()),
              stopAt: ev['stopAt'] is num ? DateTime.fromMillisecondsSinceEpoch((ev['stopAt'] as num).toInt()) : null,
            ),
          ),
        );
      case 'recording.stopped' when cur != null:
        state = AsyncData(cur.copyWith(recording: RecordingStatus.idle));
    }
  }

  /// Apply a recording status returned by start/stop right away (don't wait for the event).
  void setRecording(RecordingStatus r) {
    final cur = state.value;
    if (cur != null) state = AsyncData(cur.copyWith(recording: r));
  }

  void setPreset(String preset) {
    final cur = state.value;
    if (cur != null) state = AsyncData(cur.copyWith(preset: preset));
  }
}

final statusProvider = AsyncNotifierProvider<StatusNotifier, ServerStatus>(StatusNotifier.new);
