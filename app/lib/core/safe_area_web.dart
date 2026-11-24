import 'dart:js_interop';

import 'package:flutter/widgets.dart';

@JS('nvrSafeArea')
external JSArray<JSNumber>? _nvrSafeArea();

/// Top/bottom safe-area insets from CSS `env(safe-area-inset-*)` (see web/index.html).
EdgeInsets webSafeArea() {
  try {
    final v = _nvrSafeArea()?.toDart;
    if (v == null || v.length < 2) return EdgeInsets.zero;
    return EdgeInsets.only(top: v[0].toDartDouble, bottom: v[1].toDartDouble);
  } catch (_) {
    return EdgeInsets.zero; // helper script missing
  }
}
