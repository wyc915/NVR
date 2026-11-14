// Safari (iPhone) blocks autoplay of the live stream's <audio> element until the
// user interacts with the page. Calling play() inside a tap handler unlocks it.
export 'web_audio_stub.dart' if (dart.library.js_interop) 'web_audio_web.dart';
