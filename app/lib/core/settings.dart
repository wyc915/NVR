import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where the PC server is and how to authenticate.
class ServerSettings {
  const ServerSettings({required this.host, required this.port, required this.token, this.secure = false});

  /// Hostname or IP of the PC (LAN IP, or Tailscale IP / MagicDNS name).
  final String host;

  /// Control API port (server/config.json "port"), or 443 behind `tailscale serve`.
  final int port;

  /// API token (server/config.json "token").
  final String token;

  /// HTTPS (e.g. https://pc.tailnet.ts.net via `tailscale serve`).
  final bool secure;

  Uri get apiBase => Uri(scheme: secure ? 'https' : 'http', host: host, port: port);

  /// "https://host" / "host" as shown in the setup form.
  String get address => secure ? 'https://$host${port == 443 ? '' : ':$port'}' : host;

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

  @override
  Future<ServerSettings?> build() async {
    final host = await _storage.read(key: 'host');
    final port = int.tryParse(await _storage.read(key: 'port') ?? '');
    final token = await _storage.read(key: 'token');
    if (kIsWeb) return token == null ? null : ServerSettings.fromPageOrigin(token: token);
    final secure = await _storage.read(key: 'secure') == '1';
    if (host == null || port == null || token == null) return null;
    return ServerSettings(host: host, port: port, token: token, secure: secure);
  }

  Future<void> save(ServerSettings s) async {
    await _storage.write(key: 'host', value: s.host);
    await _storage.write(key: 'port', value: '${s.port}');
    await _storage.write(key: 'token', value: s.token);
    await _storage.write(key: 'secure', value: s.secure ? '1' : '0');
    state = AsyncData(s);
  }

  Future<void> clear() async {
    await _storage.deleteAll();
    state = const AsyncData(null);
  }
}

final settingsProvider = AsyncNotifierProvider<SettingsNotifier, ServerSettings?>(SettingsNotifier.new);
