import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../state/media_lists.dart';
import '../../widgets/paged_scroll.dart';
import 'player_page.dart';

class RecordingsPage extends ConsumerWidget {
  const RecordingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(recordingsProvider);
    final api = ref.watch(apiProvider)!;
    final notifier = ref.read(recordingsProvider.notifier);

    return switch (async) {
      AsyncData(:final value) when value.items.isEmpty => RefreshIndicator(
          onRefresh: notifier.refresh,
          child: ListView(children: const [
            SizedBox(height: 120),
            Icon(Icons.video_library_outlined, size: 56),
            SizedBox(height: 12),
            Center(child: Text('還沒有錄影')),
          ]),
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
                    _RecordingTile(recording: r, api: api),
                  ],
                );
              },
            ),
          ),
        ),
      AsyncError(:final error) => Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('載入失敗：${describeError(error)}'),
            const SizedBox(height: 8),
            FilledButton.tonal(onPressed: () => ref.invalidate(recordingsProvider), child: const Text('重試')),
          ]),
        ),
      _ => const Center(child: CircularProgressIndicator()),
    };
  }
}

class _RecordingTile extends ConsumerWidget {
  const _RecordingTile({required this.recording, required this.api});

  final Recording recording;
  final NvrApi api;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = recording;
    final thumb = r.thumbUrl;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: 96,
          height: 54,
          child: Stack(fit: StackFit.expand, children: [
            if (thumb != null)
              Image.network(api.mediaUrl(thumb), fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const ColoredBox(color: Colors.black26))
            else
              const ColoredBox(color: Colors.black26),
            Positioned(
              right: 3,
              bottom: 3,
              child: DecoratedBox(
                decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(3)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                  child: Text(formatDuration(r.duration), style: const TextStyle(color: Colors.white, fontSize: 11)),
                ),
              ),
            ),
          ]),
        ),
      ),
      title: Text(formatTime(r.startedAt)),
      subtitle: Text([if (r.preset != null) r.preset!, formatBytes(r.size)].join(' · ')),
      trailing: IconButton(
        tooltip: '刪除',
        icon: const Icon(Icons.delete_outline),
        onPressed: () => _confirmDelete(context, ref),
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => PlayerPage(recording: r)),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('刪除錄影？'),
        content: Text('${formatDateTime(recording.startedAt)}（${formatDuration(recording.duration)}）\n刪除後無法復原。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('刪除')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(recordingsProvider.notifier).delete(recording.id);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('刪除失敗：${describeError(e)}')));
      }
    }
  }
}
