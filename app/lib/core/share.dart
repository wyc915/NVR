/// Save / share a media file (iPhone: share sheet → "儲存影片" / "儲存影像"). Web build only.
library;

export 'share_stub.dart' if (dart.library.js_interop) 'share_web.dart';
