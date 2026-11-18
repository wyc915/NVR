import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/passkey.dart';
import 'core/settings.dart';
import 'features/home/home_shell.dart';
import 'features/setup/login_page.dart';
import 'features/setup/setup_page.dart';

class NvrApp extends ConsumerWidget {
  const NvrApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    return MaterialApp(
      title: '監控',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.teal, brightness: Brightness.light),
      darkTheme: ThemeData(colorSchemeSeed: Colors.teal, brightness: Brightness.dark),
      locale: const Locale('zh', 'TW'),
      supportedLocales: const [Locale('zh', 'TW'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: switch (settings) {
        AsyncData(value: null) || AsyncError() => _loginPage(),
        AsyncData() => const HomeShell(),
        _ => const Scaffold(body: Center(child: CircularProgressIndicator())),
      },
    );
  }

  /// Web app with passkey support (iPhone Safari over https): Face ID login.
  static Widget _loginPage() => kIsWeb && passkeySupported() ? const LoginPage() : const SetupPage();
}
