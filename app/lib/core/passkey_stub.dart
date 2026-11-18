bool passkeySupported() => false;

String defaultDeviceName() => '裝置';

Future<String> passkeyCreate(String optionsJson) => throw UnsupportedError('passkeys need the web app');

Future<String> passkeyGet(String optionsJson) => throw UnsupportedError('passkeys need the web app');

/// True if the error means the user cancelled / dismissed the Face ID sheet.
bool isPasskeyCancel(Object e) => false;
