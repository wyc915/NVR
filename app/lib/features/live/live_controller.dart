import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

enum LiveState { idle, connecting, playing, error }

/// Receive-only WebRTC session with MediaMTX using WHEP
/// (POST SDP offer → 201 + SDP answer; DELETE the session URL to hang up).
/// Reconnects automatically, e.g. after a quality switch restarts the stream.
class LiveController extends ChangeNotifier {
  final renderer = RTCVideoRenderer();

  LiveState state = LiveState.idle;
  String? error;
  bool get muted => _muted;

  final _http = Dio(BaseOptions(connectTimeout: const Duration(seconds: 5)));
  RTCPeerConnection? _pc;
  MediaStream? _stream;
  final _audioTracks = <MediaStreamTrack>{};
  String? _sessionUrl;
  Uri? _whep;
  Map<String, String> _headers = const {};
  Timer? _retry;
  var _muted = false;
  var _gen = 0; // bumps on every (re)connect/stop so stale callbacks are ignored
  var _disposed = false;
  var _initialized = false;

  Future<void> init() async {
    await renderer.initialize();
    _initialized = true;
  }

  /// Connect (or reconnect if the URL changed / not playing).
  /// [headers] carries the API token (`Authorization: Bearer …`); MediaMTX asks the
  /// server to verify it before allowing the stream to be read.
  Future<void> start(Uri whep, {Map<String, String> headers = const {}}) async {
    if (!_initialized || _disposed) return;
    _headers = headers;
    if (_whep == whep && (state == LiveState.playing || state == LiveState.connecting)) return;
    _whep = whep;
    await _connect();
  }

  /// Force a reconnect now (e.g. camera just came back online).
  Future<void> reconnect() async {
    if (_whep != null && state != LiveState.connecting) await _connect();
  }

  /// The server is restarting the stream (quality switch): drop the old session now
  /// and reconnect once the new stream has had a moment to come up. If it's not ready
  /// yet, WHEP returns 404 and the normal retry loop takes over.
  Future<void> restartSoon() async {
    if (_whep == null) return;
    final gen = ++_gen;
    _retry?.cancel();
    await _close();
    if (gen != _gen || _disposed) return;
    _set(LiveState.connecting);
    _retry = Timer(const Duration(milliseconds: 1500), () {
      if (gen == _gen) _connect();
    });
  }

  Future<void> stop() async {
    _gen++;
    _retry?.cancel();
    await _close();
    _set(LiveState.idle);
  }

  void setMuted(bool muted) {
    if (_muted == muted) return;
    _muted = muted;
    _applyMute();
    notifyListeners();
  }

  /// Mute by disabling the remote audio track(s). Called on every track event, when
  /// the connection comes up, and once more shortly after: track events can arrive
  /// in either order (the stream may not list its audio track yet when the first
  /// one fires), and on Android `enabled` is applied via an async platform call.
  void _applyMute() {
    final tracks = {..._audioTracks, ...?_stream?.getAudioTracks()};
    for (final t in tracks) {
      t.enabled = !_muted;
    }
    // Web: the renderer plays audio through its own <audio> element; mute that too.
    // (Native renderers don't support muting remote audio and would throw.)
    if (kIsWeb && _stream != null) renderer.muted = _muted;
  }

  Future<void> _connect() async {
    final gen = ++_gen;
    _retry?.cancel();
    await _close();
    if (gen != _gen || _disposed) return;
    _set(LiveState.connecting);

    try {
      final pc = await createPeerConnection({'sdpSemantics': 'unified-plan'});
      _pc = pc;
      for (final kind in [RTCRtpMediaType.RTCRtpMediaTypeVideo, RTCRtpMediaType.RTCRtpMediaTypeAudio]) {
        await pc.addTransceiver(
          kind: kind,
          init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
        );
      }
      pc.onTrack = (e) {
        if (gen != _gen) return;
        if (e.track.kind == 'audio') _audioTracks.add(e.track);
        if (e.streams.isNotEmpty) {
          _stream = e.streams.first;
          renderer.srcObject = _stream;
        }
        _applyMute();
      };
      pc.onConnectionState = (s) {
        if (gen != _gen) return;
        switch (s) {
          case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
            _set(LiveState.playing);
            _applyMute();
            Timer(const Duration(milliseconds: 500), () {
              if (gen == _gen) _applyMute();
            });
          case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
            _scheduleRetry(gen, '串流中斷，重新連線中…');
          default:
            break;
        }
      };

      final offer = await pc.createOffer({});
      await pc.setLocalDescription(offer);
      await _waitIceGathering(pc);
      final local = await pc.getLocalDescription();
      if (gen != _gen) return;

      final res = await _http.postUri<String>(
        _whep!,
        data: local!.sdp,
        options: Options(
          contentType: 'application/sdp',
          responseType: ResponseType.plain,
          headers: _headers,
          validateStatus: (_) => true,
        ),
      );
      if (gen != _gen) return;
      if (res.statusCode == 404 || res.statusCode == 400) {
        throw _LiveError('鏡頭離線');
      }
      if (res.statusCode == 503) throw _LiveError('鏡頭無法啟動');
      if (res.statusCode == 401) throw _LiveError('串流驗證失敗（token 錯誤）');
      if (res.statusCode != 201) throw _LiveError('串流伺服器錯誤 ${res.statusCode}');

      final location = res.headers.value('location');
      if (location != null) _sessionUrl = _whep!.resolve(location).toString();
      await pc.setRemoteDescription(RTCSessionDescription(res.data, 'answer'));
    } catch (e) {
      if (gen != _gen) return;
      final msg = switch (e) {
        _LiveError(:final message) => message,
        DioException() => '連不到串流伺服器',
        _ => '連線失敗',
      };
      _scheduleRetry(gen, msg);
    }
  }

  /// Non-trickle WHEP: send the offer once ICE candidates are gathered (max 2s).
  Future<void> _waitIceGathering(RTCPeerConnection pc) async {
    if (pc.iceGatheringState == RTCIceGatheringState.RTCIceGatheringStateComplete) return;
    final done = Completer<void>();
    pc.onIceGatheringState = (s) {
      if (s == RTCIceGatheringState.RTCIceGatheringStateComplete && !done.isCompleted) done.complete();
    };
    await done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
  }

  void _scheduleRetry(int gen, String message) {
    if (gen != _gen || _disposed) return;
    error = message;
    _set(LiveState.error);
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 2), () {
      if (gen == _gen) _connect();
    });
  }

  Future<void> _close() async {
    final pc = _pc;
    final session = _sessionUrl;
    _pc = null;
    _sessionUrl = null;
    _stream = null;
    _audioTracks.clear();
    if (_initialized) renderer.srcObject = null;
    if (session != null) {
      unawaited(_http
          .delete<void>(session, options: Options(headers: _headers))
          .then((_) {}, onError: (_) {}));
    }
    if (pc != null) {
      pc.onConnectionState = null;
      pc.onTrack = null;
      await pc.close();
    }
  }

  void _set(LiveState s) {
    if (_disposed) return;
    if (s != LiveState.error) error = null;
    state = s;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _gen++;
    _retry?.cancel();
    unawaited(_close().whenComplete(renderer.dispose));
    super.dispose();
  }
}

class _LiveError implements Exception {
  _LiveError(this.message);
  final String message;
}
