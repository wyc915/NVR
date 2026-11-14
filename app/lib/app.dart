import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/settings.dart';
import 'features/home/home_shell.dart';
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
        AsyncData(value: null) => const SetupPage(),
        AsyncData() => const HomeShell(),
        AsyncError() => const SetupPage(),
        _ => const Scaffold(body: Center(child: CircularProgressIndicator())),
      },
    );
  }
}
