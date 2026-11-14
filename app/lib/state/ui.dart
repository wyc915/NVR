import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// True while the live view is fullscreen: the home shell hides its app bar and tabs.
final fullscreenProvider = NotifierProvider<FullscreenNotifier, bool>(FullscreenNotifier.new);

class FullscreenNotifier extends Notifier<bool> {
  @override
  bool build() => false;
  void set(bool v) => state = v;
}

/// Live-view audio muted? Remembered across app restarts.
final mutedProvider = NotifierProvider<MutedNotifier, bool>(MutedNotifier.new);

class MutedNotifier extends Notifier<bool> {
  static const _storage = FlutterSecureStorage();
  static const _key = 'live_muted';

  @override
  bool build() {
    _storage.read(key: _key).then((v) {
      if (v != null && ref.mounted) state = v == 'true';
    });
    return false;
  }

  void set(bool muted) {
    state = muted;
    _storage.write(key: _key, value: '$muted');
  }

  void toggle() => set(!state);
}
