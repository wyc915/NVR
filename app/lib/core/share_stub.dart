import 'dart:typed_data';

bool shareSupported() => false;

/// Opens the share sheet (or downloads the file where sharing files isn't available).
Future<void> shareFile(Uint8List bytes, String name, String mime) =>
    throw UnsupportedError('sharing needs the web app');
