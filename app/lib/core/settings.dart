import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where the PC server is and how to authenticate.
class ServerSettings {
  const ServerSettings({
    required this.host,
    required this.port,
    required this.token,
    this.secure = false,
    this.session = false,
    this.expiresAt,
    this.deviceName,
  });

  /// Hostname or IP of the PC (LAN IP, or Tailscale IP / MagicDNS name).
  final String host;

  /// Control API port (server/config.json "port"), or 443 behind `tailscale serve`.
  final int port;

  /// API token (server/config.json "token"), or a passkey session token (`s1.…`).
  final String token;

  /// HTTPS (e.g. https://pc.tailnet.ts.net via `tailscale serve`).
  final bool secure;

  /// [token] is a short-lived session from a passkey (Face ID) login.
  final bool session;
  final DateTime? expiresAt;

  /// Name this device registered its passkey under.
  final String? deviceName;

  Uri get apiBase => Uri(scheme: secure ? 'https' : 'http', host: host, port: port);

  /// "https://host" / "host" as shown in the setup form.
  String get address => secure ? 'https://$host${port == 443 ? '' : ':$port'}' : host;

  ServerSettings withToken(String token, {bool session = false, DateTime? expiresAt, String? deviceName}) =>
      ServerSettings(
        host: host,
        port: port,
        token: token,
        secure: secure,
        session: session,
        expiresAt: expiresAt,
        deviceName: deviceName,
      );

  /// Web build: the server is always the origin the page was loaded from
  /// (any other address would be cross-origin and blocked by the browser).
  static ServerSettings? fromPageOrigin({String token = ''}) {
    if (!kIsWeb) return null;
    final u = Uri.base;
    return ServerSettings(host: u.host, port: u.port, token: token, secure: u.scheme == 'https');
  }
}

class SettingsNotifier extends AsyncNotifier<ServerSettings?> {
  static const _storage = FlutterSecureStorage();
  static const _keys = ['host', 'port', 'token', 'secure', 'session', 'expires', 'device'];

  /// Survives logout/expiry: this device has a passkey, so offer Face ID first.
  static const _passkeyKey = 'has_passkey';

  @override
  Future<ServerSettings?> build() async {
    final token = await _storage.read(key: 'token');
    if (token == null) return null;
    final session = await _storage.read(key: 'session') == '1';
    final expiresMs = int.tryParse(await _storage.read(key: 'expires') ?? '');
    final expiresAt = expiresMs == null ? null : DateTime.fromMillisecondsSinceEpoch(expiresMs);
    if (session && (expiresAt == null || expiresAt.isBefore(DateTime.now()))) {
      await _clearLogin();
      return null; // expired: log in with Face ID again
    }
    final deviceName = await _storage.read(key: 'device');

    final ServerSettings base;
    if (kIsWeb) {
      base = ServerSettings.fromPageOrigin()!;
    } else {
      final host = await _storage.read(key: 'host');
      final port = int.tryParse(await _storage.read(key: 'port') ?? '');
      if (host == null || port == null) return null;
      base = ServerSettings(
        host: host,
        port: port,
        token: '',
        secure: await _storage.read(key: 'secure') == '1',
      );
    }
    return base.withToken(token, session: session, expiresAt: expiresAt, deviceName: deviceName);
  }

  Future<bool> hasPasskey() async => await _storage.read(key: _passkeyKey) == '1';

  Future<void> save(ServerSettings s) async {
    await _storage.write(key: 'host', value: s.host);
    await _storage.write(key: 'port', value: '${s.port}');
    await _storage.write(key: 'token', value: s.token);
    await _storage.write(key: 'secure', value: s.secure ? '1' : '0');
    await _storage.write(key: 'session', value: s.session ? '1' : '0');
    if (s.expiresAt != null) {
      await _storage.write(key: 'expires', value: '${s.expiresAt!.millisecondsSinceEpoch}');
    } else {
      await _storage.delete(key: 'expires');
    }
    if (s.deviceName != null) {
      await _storage.write(key: 'device', value: s.deviceName!);
    } else {
      await _storage.delete(key: 'device');
    }
    if (s.session) await _storage.write(key: _passkeyKey, value: '1');
    state = AsyncData(s);
  }

  /// Session expired or was revoked: back to the login screen (Face ID stays offered).
  Future<void> expire() async {
    if (state.value == null) return;
    await _clearLogin();
    state = const AsyncData(null);
  }

  /// Log out / forget this server.
  Future<void> clear({bool forgetPasskey = false}) async {
    await _clearLogin();
    if (forgetPasskey) await _storage.delete(key: _passkeyKey);
    state = const AsyncData(null);
  }

  Future<void> _clearLogin() async {
    for (final k in _keys) {
      await _storage.delete(key: k);
    }
  }
}

final settingsProvider = AsyncNotifierProvider<SettingsNotifier, ServerSettings?>(SettingsNotifier.new);
