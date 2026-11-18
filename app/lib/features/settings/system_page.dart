import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/api.dart';
import '../../core/format.dart';
import '../../core/models.dart';

/// What the PC is doing: camera / streaming processes, uptime, disk, recent events.
class SystemPage extends ConsumerStatefulWidget {
  const SystemPage({super.key});

  @override
  ConsumerState<SystemPage> createState() => _SystemPageState();
}

class _SystemPageState extends ConsumerState<SystemPage> {
  late Future<SystemInfo> _info = _load();
  var _restarting = false;

  Future<SystemInfo> _load() => ref.read(apiProvider)!.system();

  Future<void> _refresh() async {
    final f = _load();
    setState(() => _info = f);
    await f.catchError((_) => const SystemInfo({}));
  }

  Future<void> _restartCamera() async {
    setState(() => _restarting = true);
    try {
      await ref.read(apiProvider)!.restartCamera();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('鏡頭已重新啟動')));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('重新啟動失敗：${describeError(e)}')));
      }
    } finally {
      if (mounted) setState(() => _restarting = false);
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('系統狀態'),
        actions: [IconButton(tooltip: '重新整理', icon: const Icon(Icons.refresh), onPressed: _refresh)],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder(
          future: _info,
          builder: (context, snap) {
            if (snap.hasError) {
              return ListView(children: [ListTile(title: Text('無法載入：${describeError(snap.error!)}'))]);
            }
            final info = snap.data;
            if (info == null) return const Center(child: CircularProgressIndicator());
            return _content(context, info);
          },
        ),
      ),
    );
  }

  Widget _content(BuildContext context, SystemInfo info) {
    final theme = Theme.of(context);
    final cam = info.camera;
    final mtx = info.mediamtx;
    final fmt = DateFormat('M/d HH:mm:ss');
    String since(Object? ms) => ms is num ? '${fmt.format(DateTime.fromMillisecondsSinceEpoch(ms.toInt()))} 起' : '';
    final crashes = (cam['crashes'] as num? ?? 0).toInt();
    final mtxCrashes = (mtx['crashes'] as num? ?? 0).toInt();

    return ListView(
      children: [
        _Section('鏡頭'),
        ListTile(
          leading: Icon(
            switch (info.cameraState) {
              CameraState.live => Icons.videocam,
              CameraState.starting => Icons.hourglass_top,
              CameraState.idle => Icons.videocam_off,
              CameraState.offline => Icons.error_outline,
            },
            color: switch (info.cameraState) {
              CameraState.live => Colors.green,
              CameraState.offline => theme.colorScheme.error,
              _ => null,
            },
          ),
          title: Text(switch (info.cameraState) {
            CameraState.live => '開啟中 · ${cam['preset']}',
            CameraState.starting => '啟動中…',
            CameraState.idle => '待機（沒人使用時關閉）',
            CameraState.offline => '離線',
          }),
          subtitle: Text(
            [
              if (cam['running'] == true) since(cam['since']),
              cam['onDemand'] == true ? '有人使用時才開啟' : '常時開啟',
            ].where((s) => s.isNotEmpty).join(' · '),
          ),
        ),
        ListTile(
          leading: Icon(Icons.restart_alt, color: crashes > 0 ? theme.colorScheme.error : null),
          title: Text('擷取程式異常結束 $crashes 次'),
          subtitle: cam['lastError'] != null ? Text('最後錯誤：${cam['lastError']}') : const Text('從服務啟動後計算'),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: OutlinedButton.icon(
            onPressed: _restarting || cam['running'] != true ? null : _restartCamera,
            icon: _restarting
                ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.restart_alt),
            label: Text(cam['running'] == true ? '重新啟動鏡頭' : '鏡頭待機中，不需重新啟動'),
          ),
        ),
        _Section('伺服器'),
        ListTile(
          leading: const Icon(Icons.dns),
          title: const Text('NVR 服務'),
          subtitle: Text('${since(info.raw['serverStartedAt'])} · Node ${info.node}'),
        ),
        ListTile(
          leading: Icon(
            mtx['running'] == true ? Icons.check_circle : Icons.error,
            color: mtx['running'] == true ? Colors.green : theme.colorScheme.error,
          ),
          title: Text('串流伺服器（MediaMTX）${mtx['running'] == true ? '運作中' : '未運作'}'),
          subtitle: Text([since(mtx['since']), if (mtxCrashes > 0) '異常結束 $mtxCrashes 次'].join(' · ')),
        ),
        ListTile(
          leading: const Icon(Icons.storage),
          title: Text('硬碟剩餘 ${formatBytes(info.diskFree)}'),
          subtitle: Text(
            '共 ${formatBytes(info.diskTotal)}\n'
            '錄影 ${info.recordingsStats.$1} 段 · ${formatBytes(info.recordingsStats.$2)}；'
            '截圖 ${info.snapshotsStats.$1} 張 · ${formatBytes(info.snapshotsStats.$2)}',
          ),
          isThreeLine: true,
        ),
        _Section('最近事件'),
        if (info.events.isEmpty) const ListTile(title: Text('沒有事件')),
        for (final e in info.events)
          ListTile(
            dense: true,
            leading: Icon(_eventIcon(e['type'] as String), size: 20),
            title: Text(_eventText(e)),
            subtitle: Text(
              DateFormat('y/M/d HH:mm:ss').format(DateTime.fromMillisecondsSinceEpoch((e['ts'] as num).toInt())),
            ),
          ),
        const SizedBox(height: 24),
      ],
    );
  }

  static IconData _eventIcon(String type) => switch (type) {
    'camera.online' => Icons.videocam,
    'camera.offline' => Icons.videocam_off,
    'recording.started' => Icons.fiber_manual_record,
    'recording.stopped' => Icons.stop,
    'recording.error' => Icons.error_outline,
    _ => Icons.info_outline,
  };

  static String _eventText(Map<String, dynamic> e) => switch (e['type']) {
    'camera.online' => '鏡頭開啟',
    'camera.offline' => '鏡頭離線${e['reason'] != null ? '：${e['reason']}' : ''}',
    'recording.started' => e['stopAt'] != null ? '開始錄影（定時）' : '開始錄影',
    'recording.stopped' => '停止錄影',
    'recording.error' => '錄影錯誤：${e['message'] ?? ''}',
    _ => '${e['type']}',
  };
}

class _Section extends StatelessWidget {
  const _Section(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(title, style: Theme.of(context).textTheme.titleSmall),
  );
}
