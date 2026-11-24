/// iPhone home-screen web app: status bar / home indicator insets, which Flutter web
/// doesn't report in MediaQuery.padding.
library;

export 'safe_area_stub.dart' if (dart.library.js_interop) 'safe_area_web.dart';
