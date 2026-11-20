/// Web build: reload when the PC serves a newer build (a home-screen web app can stay in
/// memory for days and would otherwise keep running the old version).
library;

export 'app_update_stub.dart' if (dart.library.js_interop) 'app_update_web.dart';

/// Set at build time: `flutter build web --dart-define=BUILD_ID=...` (see scripts/build-web.ps1).
const buildId = String.fromEnvironment('BUILD_ID');
