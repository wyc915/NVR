import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/settings.dart';
import '../../state/status.dart';
import '../../state/ui.dart';
import '../live/live_page.dart';
import '../recordings/recordings_page.dart';
import '../setup/setup_page.dart';
import '../snapshots/snapshots_page.dart';

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  var _tab = 0;

  static const _titles = ['即時影像', '錄影', '截圖'];

  @override
  Widget build(BuildContext context) {
    final fullscreen = ref.watch(fullscreenProvider);
    final connected = ref.watch(eventsConnectedProvider);
    final status = ref.watch(statusProvider).value;

    // Pages are rebuilt when switching tabs on purpose: leaving the live tab
    // closes the WebRTC stream so it doesn't use data in the background.
    final body = switch (_tab) {
      0 => const LivePage(),
      1 => const RecordingsPage(),
      _ => const SnapshotsPage(),
    };

    if (fullscreen) return Scaffold(backgroundColor: Colors.black, body: body);

    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_tab]),
        actions: [
          if (status?.recording.active == true)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Icon(Icons.fiber_manual_record, color: Colors.red, size: 16),
            ),
          Tooltip(
            message: connected ? '已連線到電腦' : '與電腦的連線中斷',
            child: Icon(connected ? Icons.cloud_done : Icons.cloud_off,
                color: connected ? null : Theme.of(context).colorScheme.error),
          ),
          IconButton(
            tooltip: '伺服器設定',
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => SetupPage(initial: ref.read(settingsProvider).value),
            )),
          ),
        ],
      ),
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.videocam_outlined), selectedIcon: Icon(Icons.videocam), label: '即時'),
          NavigationDestination(
              icon: Icon(Icons.video_library_outlined), selectedIcon: Icon(Icons.video_library), label: '錄影'),
          NavigationDestination(
              icon: Icon(Icons.photo_library_outlined), selectedIcon: Icon(Icons.photo_library), label: '截圖'),
        ],
      ),
    );
  }
}
