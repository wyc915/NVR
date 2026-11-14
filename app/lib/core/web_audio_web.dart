import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// (Re)start every paused <audio>/<video> element. Must run inside a user gesture.
void resumeWebAudio() {
  final els = web.document.querySelectorAll('audio, video');
  for (var i = 0; i < els.length; i++) {
    final el = els.item(i) as web.HTMLMediaElement?;
    if (el != null && el.paused) {
      el.play().toDart.then((_) {}, onError: (_) {});
    }
  }
}
