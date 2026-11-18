/// Passkey (WebAuthn / Face ID) calls; only available in the web build (web/passkey.js).
library;

export 'passkey_stub.dart' if (dart.library.js_interop) 'passkey_web.dart';
