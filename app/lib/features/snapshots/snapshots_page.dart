import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/format.dart';
import '../../state/media_lists.dart';
import '../../widgets/paged_scroll.dart';
import 'snapshot_viewer_page.dart';

class SnapshotsPage extends ConsumerWidget {
  const SnapshotsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(snapshotsProvider);
    final api = ref.watch(apiProvider)!;
    final notifier = ref.read(snapshotsProvider.notifier);

    return switch (async) {
      AsyncData(:final value) when value.items.isEmpty => RefreshIndicator(
          onRefresh: notifier.refresh,
          child: ListView(children: const [
            SizedBox(height: 120),
            Icon(Icons.photo_library_outlined, size: 56),
            SizedBox(height: 12),
            Center(child: Text('還沒有截圖')),
          ]),
        ),
      AsyncData(:final value) => RefreshIndicator(
          onRefresh: notifier.refresh,
          child: PagedScroll(
            onLoadMore: notifier.loadMore,
            child: GridView.builder(
              padding: const EdgeInsets.all(4),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 200,
                childAspectRatio: 16 / 9,
                mainAxisSpacing: 4,
                crossAxisSpacing: 4,
              ),
              itemCount: value.items.length,
              itemBuilder: (context, i) {
                final s = value.items[i];
                return InkWell(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => SnapshotViewerPage(snapshot: s)),
                  ),
                  child: Stack(fit: StackFit.expand, children: [
                    Image.network(
                      api.mediaUrl(s.thumbUrl ?? s.fileUrl),
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const ColoredBox(color: Colors.black26),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Container(
                        color: Colors.black54,
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                        child: Text(
                          '${formatDay(s.takenAt)} ${formatTime(s.takenAt)}',
                          style: const TextStyle(color: Colors.white, fontSize: 11),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ]),
                );
              },
            ),
          ),
        ),
      AsyncError(:final error) => Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('載入失敗：${describeError(error)}'),
            const SizedBox(height: 8),
            FilledButton.tonal(onPressed: () => ref.invalidate(snapshotsProvider), child: const Text('重試')),
          ]),
        ),
      _ => const Center(child: CircularProgressIndicator()),
    };
  }
}
