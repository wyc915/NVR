import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_view/photo_view.dart';

import '../../core/api.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../state/media_lists.dart';

/// Full-size snapshot with pinch-to-zoom.
class SnapshotViewerPage extends ConsumerWidget {
  const SnapshotViewerPage({super.key, required this.snapshot});

  final Snapshot snapshot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(apiProvider)!;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(formatDateTime(snapshot.takenAt)),
        actions: [
          IconButton(
            tooltip: '刪除',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _delete(context, ref),
          ),
        ],
      ),
      body: PhotoView(
        imageProvider: NetworkImage(api.mediaUrl(snapshot.fileUrl)),
        minScale: PhotoViewComputedScale.contained,
        maxScale: PhotoViewComputedScale.covered * 4,
        loadingBuilder: (_, _) => const Center(child: CircularProgressIndicator(color: Colors.white70)),
        errorBuilder: (_, _, _) => const Center(
          child: Text('無法載入圖片', style: TextStyle(color: Colors.white70)),
        ),
      ),
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('刪除截圖？'),
        content: const Text('刪除後無法復原。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('刪除')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(snapshotsProvider.notifier).delete(snapshot.id);
      if (context.mounted) Navigator.of(context).pop();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('刪除失敗：${describeError(e)}')));
      }
    }
  }
}
