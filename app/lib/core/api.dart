import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models.dart';
import 'settings.dart';

/// REST client for the PC control service.
class NvrApi {
  /// [onUnauthorized] runs when the server rejects the credentials (e.g. the Face ID
  /// session expired or this device was revoked).
  NvrApi(this.settings, {void Function()? onUnauthorized})
    : _dio = Dio(
        BaseOptions(
          baseUrl: settings.apiBase.toString(),
          connectTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 20),
          headers: {'Authorization': 'Bearer ${settings.token}'},
        ),
      ),
      _urlKey = Hmac(sha256, utf8.encode(settings.token)).convert(utf8.encode('nvr-media-url-v1')).bytes,
      // Session tokens are "s1.<session id>.<secret>"; signed URLs name the session.
      _sid = settings.token.startsWith('s1.') ? settings.token.split('.')[1] : null {
    if (onUnauthorized != null) {
      _dio.interceptors.add(
        InterceptorsWrapper(
          onError: (e, handler) {
            if (e.response?.statusCode == 401) onUnauthorized();
            handler.next(e);
          },
        ),
      );
    }
  }

  final ServerSettings settings;
  final Dio _dio;
  final List<int> _urlKey;
  final String? _sid;

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
    final r = await _dio.get<List<dynamic>>(
      '/api/recordings',
      queryParameters: {'limit': limit, if (before != null) 'before': before.millisecondsSinceEpoch},
    );
    return r.data!.map((e) => Recording.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<Snapshot>> snapshots({DateTime? before, int limit = 60}) async {
    final r = await _dio.get<List<dynamic>>(
      '/api/snapshots',
      queryParameters: {'limit': limit, if (before != null) 'before': before.millisecondsSinceEpoch},
    );
    return r.data!.map((e) => Snapshot.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> deleteRecording(String id) => _dio.delete<void>('/api/recordings/$id');

  Future<void> deleteSnapshot(String id) => _dio.delete<void>('/api/snapshots/$id');

  // --- login / devices ---
  Future<List<Device>> devices() async {
    final r = await _dio.get<List<dynamic>>('/api/devices');
    return r.data!.map((e) => Device.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> revokeDevice(String id) => _dio.delete<void>('/api/devices/$id');

  /// 6-digit code another device can use (within 5 minutes) to set up Face ID.
  Future<(String, DateTime)> pairCode() async {
    final r = await _dio.post<Map<String, dynamic>>('/api/auth/pair-code');
    return (r.data!['code'] as String, DateTime.fromMillisecondsSinceEpoch((r.data!['expiresAt'] as num).toInt()));
  }

  Future<void> logout() => _dio.post<void>('/api/auth/logout');

  /// Signed query (`exp`, `sig`) for GET URLs that can't carry an Authorization header
  /// (image/video widgets, WebSocket on web). The token itself never goes into a URL.
  /// Server side: server/src/security.ts (UrlSigner).
  ///
  /// `exp` is rounded to the hour so the same file keeps the same URL for a while
  /// (otherwise image caches would miss on every rebuild). Valid for 12–13h.
  Map<String, String> _signedQuery(String path) {
    final nowS = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final exp = (nowS ~/ 3600 + 13) * 3600;
    final sig = base64Url.encode(Hmac(sha256, _urlKey).convert(utf8.encode('$path\n$exp')).bytes).replaceAll('=', '');
    return {'exp': '$exp', 'sig': sig, if (_sid != null) 'sid': _sid};
  }

  /// Full signed URL for a media path from the API (fileUrl / thumbUrl).
  String mediaUrl(String path) => settings.apiBase.replace(path: path, queryParameters: _signedQuery(path)).toString();

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
  if (s == null) return null;
  // A rejected session means "log in with Face ID again"; a wrong API token is shown as an error.
  return NvrApi(s, onUnauthorized: s.session ? () => ref.read(settingsProvider.notifier).expire() : null);
});

/// Result of a passkey login/registration.
class LoginResult {
  const LoginResult(this.token, this.expiresAt, this.deviceName);
  final String token;
  final DateTime expiresAt;
  final String deviceName;
}

/// Passkey (Face ID) endpoints, usable before logging in.
/// Each step is split in two (`…Options` then the Face ID call): Safari only shows Face ID
/// when it's called directly from a tap, so options are fetched before that tap.
class AuthApi {
  AuthApi(Uri base)
    : _dio = Dio(
        BaseOptions(
          baseUrl: base.toString(),
          connectTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 20),
        ),
      );

  final Dio _dio;

  /// [bearer]: API token or current session (adding Face ID to a signed-in device);
  /// otherwise [pairCode] from another signed-in device.
  Future<PasskeyFlow> registerOptions(String name, {String? pairCode, String? bearer}) async {
    final r = await _dio.post<Map<String, dynamic>>(
      '/api/auth/public/register/options',
      data: {'name': name, 'pairCode': ?pairCode},
      options: Options(headers: {if (bearer != null) 'Authorization': 'Bearer $bearer'}),
    );
    return PasskeyFlow.fromJson(r.data!);
  }

  Future<LoginResult> registerVerify(PasskeyFlow flow, String responseJson) =>
      _verify('/api/auth/public/register/verify', flow, responseJson);

  Future<PasskeyFlow> loginOptions() async {
    final r = await _dio.post<Map<String, dynamic>>('/api/auth/public/login/options');
    return PasskeyFlow.fromJson(r.data!);
  }

  Future<LoginResult> loginVerify(PasskeyFlow flow, String responseJson) =>
      _verify('/api/auth/public/login/verify', flow, responseJson);

  Future<LoginResult> _verify(String path, PasskeyFlow flow, String responseJson) async {
    final r = await _dio.post<Map<String, dynamic>>(
      path,
      data: {'flowId': flow.flowId, 'response': jsonDecode(responseJson)},
    );
    final d = r.data!;
    return LoginResult(
      d['token'] as String,
      DateTime.fromMillisecondsSinceEpoch((d['expiresAt'] as num).toInt()),
      (d['device'] as Map<String, dynamic>)['name'] as String,
    );
  }
}

/// Server-issued WebAuthn options, valid for 5 minutes.
class PasskeyFlow {
  PasskeyFlow(this.flowId, this.optionsJson) : fetchedAt = DateTime.now();

  factory PasskeyFlow.fromJson(Map<String, dynamic> j) => PasskeyFlow(j['flowId'] as String, jsonEncode(j['options']));

  final String flowId;
  final String optionsJson;
  final DateTime fetchedAt;

  bool get fresh => DateTime.now().difference(fetchedAt) < const Duration(minutes: 4);
}

/// Human-readable (Traditional Chinese) message for an API error.
String describeError(Object e) {
  if (e is DioException) {
    final code = e.response?.statusCode;
    if (code == 401) {
      final data = e.response?.data;
      final err = data is Map ? data['error'] : null;
      return switch (err) {
        'invalid pairing code' => '配對碼錯誤或已過期',
        'unknown passkey' => '這個密碼金鑰已被撤銷，請重新設定',
        'passkey login failed' => 'Face ID 驗證失敗',
        _ => 'Token 錯誤',
      };
    }
    if (code == 400) {
      final data = e.response?.data;
      final err = data is Map ? '${data['error']}' : '';
      if (err.startsWith('expired')) return '逾時，請再試一次';
      if (err.startsWith('passkeys are not available')) return '這個網址不能使用 Face ID，請用 https://…ts.net 網址';
    }
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
