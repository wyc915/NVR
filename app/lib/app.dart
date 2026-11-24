import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/app_update.dart';
import 'core/passkey.dart';
import 'core/safe_area.dart';
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
      builder: kIsWeb ? _withWebSafeArea : null,
      home: switch (settings) {
        AsyncData(value: null) || AsyncError() => _loginPage(),
        AsyncData() => const HomeShell(),
        _ => const Scaffold(body: Center(child: CircularProgressIndicator())),
      },
    );
  }

  /// Web: keep app bars below the iPhone status bar (which blurs whatever is under it) and
  /// the tab bar above the home indicator. Re-read on every metrics change (rotation, etc.).
  static Widget _withWebSafeArea(BuildContext context, Widget? child) => _WebSafeArea(child: child!);

  /// Taller, solid app bar so titles sit a little lower, away from the phone status bar.
  static ThemeData _theme(Brightness b) {
    final base = ThemeData(colorSchemeSeed: Colors.teal, brightness: b);
    return base.copyWith(
      // Solid header: no tint/shadow when a list scrolls under it, so the status bar area
      // never looks translucent or blurred (web and Android).
      appBarTheme: AppBarTheme(
        backgroundColor: base.colorScheme.surface,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
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

/// Adds the CSS safe-area insets to MediaQuery padding. They are read again on every size
/// change (rotation) and a few times after start, since iOS applies viewport-fit=cover a
/// moment after the page sets it.
class _WebSafeArea extends StatefulWidget {
  const _WebSafeArea({required this.child});

  final Widget child;

  @override
  State<_WebSafeArea> createState() => _WebSafeAreaState();
}

class _WebSafeAreaState extends State<_WebSafeArea> with WidgetsBindingObserver {
  var _insets = webSafeArea();
  final _timers = <Timer>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    for (final ms in const [100, 500, 1500, 4000]) {
      _timers.add(Timer(Duration(milliseconds: ms), _refresh));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final t in _timers) {
      t.cancel();
    }
    super.dispose();
  }

  @override
  void didChangeMetrics() => _refresh();

  void _refresh() {
    final v = webSafeArea();
    if (mounted && v != _insets) setState(() => _insets = v);
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    EdgeInsets merge(EdgeInsets p) =>
        p.copyWith(top: math.max(p.top, _insets.top), bottom: math.max(p.bottom, _insets.bottom));
    return MediaQuery(
      data: mq.copyWith(padding: merge(mq.padding), viewPadding: merge(mq.viewPadding)),
      child: widget.child,
    );
  }
}
