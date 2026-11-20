import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'app_update.dart';

/// Compares this build's ID with `build_id.txt` on the server and reloads the page if they
/// differ. Returns true if a reload was started.
Future<bool> reloadIfOutdated() async {
  if (buildId.isEmpty) return false; // local/dev build without an ID
  try {
    final url = 'build_id.txt?t=${DateTime.now().millisecondsSinceEpoch}';
    final res = await web.window.fetch(url.toJS, web.RequestInit(cache: 'no-store')).toDart;
    if (!res.ok) return false;
    final latest = (await res.text().toDart).toDart.trim();
    if (latest.isEmpty || latest == buildId) return false;
    web.window.location.reload();
    return true;
  } catch (_) {
    return false; // offline: try again next time
  }
}
