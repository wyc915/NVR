import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

bool shareSupported() => true;

/// Must be called directly from a tap (Safari needs a user gesture for the share sheet).
/// Falls back to a plain download where files can't be shared (e.g. desktop browsers).
Future<void> shareFile(Uint8List bytes, String name, String mime) async {
  final file = web.File([bytes.toJS].toJS, name, web.FilePropertyBag(type: mime));
  final data = web.ShareData(files: [file].toJS);
  final nav = web.window.navigator;
  if (nav.canShare(data)) {
    await nav.share(data).toDart;
    return;
  }
  final url = web.URL.createObjectURL(file);
  final a = web.HTMLAnchorElement()
    ..href = url
    ..download = name;
  web.document.body!.append(a);
  a.click();
  a.remove();
  // Give the browser a moment to start the download before freeing the blob.
  Future<void>.delayed(const Duration(seconds: 30), () => web.URL.revokeObjectURL(url));
}
