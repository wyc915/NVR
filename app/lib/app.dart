import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/app_update.dart';
import 'core/passkey.dart';
import 'core/settings.dart';
import 'features/home/home_shell.dart';
import 'features/setup/login_page.dart';
import 'features/setup/setup_page.dart';

class NvrApp extends ConsumerStatefulWidget {
  const NvrApp({super.key});

  @override
  ConsumerState<NvrApp> createState() => _NvrAppState();
}

class _NvrAppState extends ConsumerState<NvrApp> {
  late final AppLifecycleListener _lifecycle;
  Timer? _updateCheck;

  @override
  void initState() {
    super.initState();
    // Web: pick up a new build when the app starts, comes back to the foreground, and
    // every 15 minutes while open (home-screen web apps stay in memory for days).
    if (kIsWeb) {
      reloadIfOutdated();
      _lifecycle = AppLifecycleListener(onShow: reloadIfOutdated, onResume: reloadIfOutdated);
      _updateCheck = Timer.periodic(const Duration(minutes: 15), (_) => reloadIfOutdated());
    } else {
      _lifecycle = AppLifecycleListener();
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _updateCheck?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    return MaterialApp(
      title: '監控',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
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

  /// Taller app bar so titles sit a little lower, away from the iPhone status bar.
  static ThemeData _theme(Brightness b) {
    final base = ThemeData(colorSchemeSeed: Colors.teal, brightness: b);
    return base.copyWith(
      appBarTheme: AppBarTheme(
        toolbarHeight: 72,
        titleSpacing: 20,
        titleTextStyle: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
          color: base.colorScheme.onSurface,
        ),
      ),
    );
  }

  /// Web app with passkey support (iPhone Safari over https): Face ID login.
  static Widget _loginPage() => kIsWeb && passkeySupported() ? const LoginPage() : const SetupPage();
}
