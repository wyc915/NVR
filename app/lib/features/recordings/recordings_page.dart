import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../state/media_lists.dart';
import '../../widgets/paged_scroll.dart';
import 'player_page.dart';

class RecordingsPage extends ConsumerStatefulWidget {
  const RecordingsPage({super.key});

  @override
  ConsumerState<RecordingsPage> createState() => _RecordingsPageState();
}

class _RecordingsPageState extends ConsumerState<RecordingsPage> {
  /// Selection mode (long-press a recording): IDs to delete together.
  Set<String>? _selected;
  var _deleting = false;

  RecordingsNotifier get _notifier => ref.read(recordingsProvider.notifier);

  void _toast(String msg) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _pickDay() async {
    final now = DateTime.now();
    final day = await showDatePicker(
      context: context,
      firstDate: DateTime(now.year - 3),
      lastDate: now,
      initialDate: _notifier.startBefore?.subtract(const Duration(days: 1)) ?? now,
      helpText: '跳到哪一天的錄影',
    );
    if (day != null) await _notifier.jumpTo(day);
    setState(() {});
  }

  void _toggleSelect(Recording r) => setState(() {
    final s = _selected ??= {};
    if (!s.remove(r.id)) s.add(r.id);
    if (s.isEmpty) _selected = null;
  });

  Future<void> _deleteSelected(List<Recording> items) async {
    final ids = _selected ?? {};
    final chosen = items.where((r) => ids.contains(r.id)).toList();
    if (chosen.isEmpty) return;
    final starred = chosen.where((r) => r.starred).length;
    final bytes = chosen.fold<int>(0, (a, r) => a + r.size);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('刪除 ${chosen.length} 段錄影？'),
        content: Text(
          '共 ${formatBytes(bytes)}，刪除後無法復原。'
          '${starred > 0 ? '\n其中 $starred 段有加星號。' : ''}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('刪除')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _deleting = true);
    var failed = 0;
    for (final r in chosen) {
      try {
        await _notifier.delete(r.id);
      } catch (_) {
        failed++;
      }
    }
    if (!mounted) return;
    setState(() {
      _deleting = false;
      _selected = null;
    });
    _toast(failed == 0 ? '已刪除 ${chosen.length} 段' : '有 $failed 段刪除失敗');
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(recordingsProvider);
    final api = ref.watch(apiProvider)!;
    final items = async.value?.items ?? const <Recording>[];

    return Column(
      children: [
        _selected == null ? _filterBar() : _selectionBar(items),
        const Divider(height: 1),
        Expanded(child: _list(async, api)),
      ],
    );
  }

  Widget _filterBar() {
    final n = _notifier;
    final jumped = n.startBefore;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          FilterChip(
            avatar: Icon(n.starredOnly ? Icons.star : Icons.star_border, size: 18),
            label: const Text('有星號'),
            selected: n.starredOnly,
            showCheckmark: false,
            onSelected: (v) async {
              await n.setStarredOnly(v);
              setState(() {});
            },
          ),
          const SizedBox(width: 8),
          if (jumped != null)
            InputChip(
              avatar: const Icon(Icons.event, size: 18),
              label: Text('${formatDay(jumped.subtract(const Duration(days: 1)))} 以前'),
              onPressed: _pickDay,
              onDeleted: () async {
                await n.jumpTo(null);
                setState(() {});
              },
            )
          else
            ActionChip(avatar: const Icon(Icons.event, size: 18), label: const Text('選日期'), onPressed: _pickDay),
          const Spacer(),
          IconButton(
            tooltip: '選取多段',
            icon: const Icon(Icons.checklist),
            onPressed: () => setState(() => _selected = {}),
          ),
        ],
      ),
    );
  }

  Widget _selectionBar(List<Recording> items) {
    final n = _selected!.length;
    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          children: [
            IconButton(tooltip: '取消選取', icon: const Icon(Icons.close), onPressed: () => setState(() => _selected = null)),
            Text('已選 $n 段'),
            const Spacer(),
            TextButton(
              onPressed: () => setState(() => _selected = items.map((r) => r.id).toSet()),
              child: const Text('全選'),
            ),
            IconButton(
              tooltip: '刪除',
              icon: _deleting
                  ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.delete_outline),
              onPressed: n == 0 || _deleting ? null : () => _deleteSelected(items),
            ),
          ],
        ),
      ),
    );
  }

  Widget _list(AsyncValue<PagedState<Recording>> async, NvrApi api) {
    final notifier = _notifier;
    return switch (async) {
      AsyncData(:final value) when value.items.isEmpty => RefreshIndicator(
        onRefresh: notifier.refresh,
        child: ListView(
          children: [
            const SizedBox(height: 120),
            const Icon(Icons.video_library_outlined, size: 56),
            const SizedBox(height: 12),
            Center(
              child: Text(
                notifier.starredOnly
                    ? '沒有加星號的錄影'
                    : notifier.startBefore != null
                    ? '這天以前沒有錄影'
                    : '還沒有錄影',
              ),
            ),
          ],
        ),
      ),
      AsyncData(:final value) => RefreshIndicator(
        onRefresh: notifier.refresh,
        child: PagedScroll(
          onLoadMore: notifier.loadMore,
          child: ListView.builder(
            itemCount: value.items.length + (value.hasMore ? 1 : 0),
            itemBuilder: (context, i) {
              if (i == value.items.length) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final r = value.items[i];
              final showHeader = i == 0 || !sameDay(value.items[i - 1].startedAt, r.startedAt);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (showHeader)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                      child: Text(formatDay(r.startedAt), style: Theme.of(context).textTheme.titleSmall),
                    ),
                  _RecordingTile(
                    recording: r,
                    api: api,
                    selected: _selected?.contains(r.id),
                    onSelect: () => _toggleSelect(r),
                    onStar: () => notifier.toggleStar(r).catchError((Object e) => _toast('操作失敗：${describeError(e)}')),
                    onDelete: () => _confirmDelete(r),
                  ),
                ],
              );
            },
          ),
        ),
      ),
      AsyncError(:final error) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('載入失敗：${describeError(error)}'),
            const SizedBox(height: 8),
            FilledButton.tonal(onPressed: () => ref.invalidate(recordingsProvider), child: const Text('重試')),
          ],
        ),
      ),
      _ => const Center(child: CircularProgressIndicator()),
    };
  }

  Future<void> _confirmDelete(Recording recording) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('刪除錄影？'),
        content: Text(
          '${formatDateTime(recording.startedAt)}（${formatDuration(recording.duration)}）\n'
          '${recording.starred ? '這段有加星號。' : ''}刪除後無法復原。',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('刪除')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _notifier.delete(recording.id);
    } catch (e) {
      if (mounted) _toast('刪除失敗：${describeError(e)}');
    }
  }
}

class _RecordingTile extends StatelessWidget {
  const _RecordingTile({
    required this.recording,
    required this.api,
    required this.selected,
    required this.onSelect,
    required this.onStar,
    required this.onDelete,
  });

  final Recording recording;
  final NvrApi api;

  /// null = not in selection mode.
  final bool? selected;
  final VoidCallback onSelect;
  final VoidCallback onStar;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final r = recording;
    final thumb = r.thumbUrl;
    final selecting = selected != null;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      selected: selected == true,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (selecting)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Icon(selected! ? Icons.check_circle : Icons.radio_button_unchecked),
            ),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 96,
              height: 54,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (thumb != null)
                    Image.network(
                      api.mediaUrl(thumb),
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const ColoredBox(color: Colors.black26),
                    )
                  else
                    const ColoredBox(color: Colors.black26),
                  Positioned(
                    right: 3,
                    bottom: 3,
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(3)),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                        child: Text(
                          formatDuration(r.duration),
                          style: const TextStyle(color: Colors.white, fontSize: 11),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      title: Text(formatTime(r.startedAt)),
      subtitle: Text([if (r.preset != null) r.preset!, formatBytes(r.size)].join(' · ')),
      trailing: selecting
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: r.starred ? '取消星號' : '加星號',
                  icon: Icon(r.starred ? Icons.star : Icons.star_border, color: r.starred ? Colors.amber : null),
                  onPressed: onStar,
                ),
                IconButton(tooltip: '刪除', icon: const Icon(Icons.delete_outline), onPressed: onDelete),
              ],
            ),
      onLongPress: selecting ? null : onSelect,
      onTap: selecting
          ? onSelect
          : () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PlayerPage(recording: r))),
    );
  }
}
