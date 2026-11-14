import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models.dart';
import 'settings.dart';

/// REST client for the PC control service.
class NvrApi {
  NvrApi(this.settings)
      : _dio = Dio(BaseOptions(
          baseUrl: settings.apiBase.toString(),
          connectTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 20),
          headers: {'Authorization': 'Bearer ${settings.token}'},
        )),
        _urlKey = Hmac(sha256, utf8.encode(settings.token)).convert(utf8.encode('nvr-media-url-v1')).bytes;

  final ServerSettings settings;
  final Dio _dio;
  final List<int> _urlKey;

  /// Headers for requests made outside this client (e.g. WebRTC/WHEP).
  Map<String, String> get authHeaders => {'Authorization': 'Bearer ${settings.token}'};

  Future<ServerStatus> status() async {
    final r = await _dio.get<Map<String, dynamic>>('/api/status');
    return ServerStatus.fromJson(r.data!);
  }

  Future<void> setPreset(String preset) => _dio.post<void>('/api/stream/preset', data: {'preset': preset});

  Future<RecordingStatus> startRecording() async {
    final r = await _dio.post<Map<String, dynamic>>('/api/record/start');
    return RecordingStatus.fromJson(r.data!);
  }

  Future<RecordingStatus> stopRecording() async {
    final r = await _dio.post<Map<String, dynamic>>('/api/record/stop');
    return RecordingStatus.fromJson(r.data!);
  }

  Future<Snapshot> takeSnapshot() async {
    final r = await _dio.post<Map<String, dynamic>>('/api/snapshot');
    return Snapshot.fromJson(r.data!);
  }

  Future<List<Recording>> recordings({DateTime? before, int limit = 30}) async {
    final r = await _dio.get<List<dynamic>>('/api/recordings', queryParameters: {
      'limit': limit,
      if (before != null) 'before': before.millisecondsSinceEpoch,
    });
    return r.data!.map((e) => Recording.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<Snapshot>> snapshots({DateTime? before, int limit = 60}) async {
    final r = await _dio.get<List<dynamic>>('/api/snapshots', queryParameters: {
      'limit': limit,
      if (before != null) 'before': before.millisecondsSinceEpoch,
    });
    return r.data!.map((e) => Snapshot.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> deleteRecording(String id) => _dio.delete<void>('/api/recordings/$id');

  Future<void> deleteSnapshot(String id) => _dio.delete<void>('/api/snapshots/$id');

  /// Signed query (`exp`, `sig`) for GET URLs that can't carry an Authorization header
  /// (image/video widgets, WebSocket on web). The token itself never goes into a URL.
  /// Server side: server/src/security.ts (UrlSigner).
  ///
  /// `exp` is rounded to the hour so the same file keeps the same URL for a while
  /// (otherwise image caches would miss on every rebuild). Valid for 12–13h.
  Map<String, String> _signedQuery(String path) {
    final nowS = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final exp = (nowS ~/ 3600 + 13) * 3600;
    final sig = base64Url
        .encode(Hmac(sha256, _urlKey).convert(utf8.encode('$path\n$exp')).bytes)
        .replaceAll('=', '');
    return {'exp': '$exp', 'sig': sig};
  }

  /// Full signed URL for a media path from the API (fileUrl / thumbUrl).
  String mediaUrl(String path) =>
      settings.apiBase.replace(path: path, queryParameters: _signedQuery(path)).toString();

  Uri get eventsUri => Uri(
        scheme: settings.secure ? 'wss' : 'ws',
        host: settings.host,
        port: settings.port,
        path: '/api/ws',
        queryParameters: _signedQuery('/api/ws'),
      );

  /// WebRTC (WHEP) signaling endpoint for the live view (proxied to MediaMTX by the server).
  Uri whepUri(ServerStatus s) => settings.apiBase.replace(path: s.whepPath);
}

final apiProvider = Provider<NvrApi?>((ref) {
  final s = ref.watch(settingsProvider).value;
  return s == null ? null : NvrApi(s);
});

/// Human-readable (Traditional Chinese) message for an API error.
String describeError(Object e) {
  if (e is DioException) {
    final code = e.response?.statusCode;
    if (code == 401) return 'Token 錯誤';
    if (code == 403) return '此網路不在伺服器允許清單內';
    if (code == 429) return '驗證失敗太多次，請 15 分鐘後再試';
    if (code == 503) return '鏡頭離線';
    if (code != null) {
      final data = e.response?.data;
      final msg = data is Map ? data['message'] ?? data['error'] : null;
      return '伺服器錯誤 $code${msg != null ? '：$msg' : ''}';
    }
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
        return '連線逾時';
      case DioExceptionType.connectionError:
        return '連不到伺服器';
      default:
        return e.message ?? '網路錯誤';
    }
  }
  return e.toString();
}
