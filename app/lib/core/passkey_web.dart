import 'dart:js_interop';

import 'package:web/web.dart' as web;

@JS('nvrPasskey')
external _NvrPasskey? get _passkey;

extension type _NvrPasskey(JSObject _) implements JSObject {
  external bool supported();
  external JSPromise<JSString> create(String json);
  external JSPromise<JSString> get(String json);
}

bool passkeySupported() {
  try {
    return _passkey?.supported() ?? false;
  } catch (_) {
    return false;
  }
}

String defaultDeviceName() {
  final ua = web.window.navigator.userAgent;
  if (ua.contains('iPhone')) return 'iPhone';
  if (ua.contains('iPad')) return 'iPad';
  if (ua.contains('Android')) return 'Android';
  if (ua.contains('Macintosh')) return 'Mac';
  if (ua.contains('Windows')) return 'Windows';
  return '瀏覽器';
}

// The JS call happens synchronously (before the first await), so calling these from a
// tap handler keeps Safari's user-gesture requirement satisfied.
Future<String> passkeyCreate(String optionsJson) async => (await _passkey!.create(optionsJson).toDart).toDart;

Future<String> passkeyGet(String optionsJson) async => (await _passkey!.get(optionsJson).toDart).toDart;

bool isPasskeyCancel(Object e) {
  final s = e.toString();
  return s.contains('NotAllowedError') || s.contains('AbortError');
}
