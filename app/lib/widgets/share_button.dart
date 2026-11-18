import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/format.dart';
import '../core/share.dart';

/// App bar button: download a recording/snapshot, then share it (save to Photos on iPhone).
///
/// Two taps on purpose: Safari only opens the share sheet straight from a tap, and the
/// file has to be downloaded before that.
class ShareMediaButton extends StatelessWidget {
  const ShareMediaButton({super.key, required this.url, required this.fileName, required this.mime, this.size});

  final String url;
  final String fileName;
  final String mime;
  final int? size;

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb || !shareSupported()) return const SizedBox.shrink();
    return IconButton(
      tooltip: '存到照片 / 分享',
      icon: const Icon(Icons.ios_share),
      onPressed: () => showDialog<void>(
        context: context,
        builder: (_) => _ShareDialog(url: url, fileName: fileName, mime: mime, size: size),
      ),
    );
  }
}

class _ShareDialog extends StatefulWidget {
  const _ShareDialog({required this.url, required this.fileName, required this.mime, this.size});

  final String url;
  final String fileName;
  final String mime;
  final int? size;

  @override
  State<_ShareDialog> createState() => _ShareDialogState();
}

class _ShareDialogState extends State<_ShareDialog> {
  final _cancel = CancelToken();
  Uint8List? _bytes;
  double? _progress;
  String? _error;

  @override
  void initState() {
    super.initState();
    _download();
  }

  @override
  void dispose() {
    _cancel.cancel();
    super.dispose();
  }

  Future<void> _download() async {
    try {
      final r = await Dio().get<List<int>>(
        widget.url,
        options: Options(responseType: ResponseType.bytes),
        cancelToken: _cancel,
        onReceiveProgress: (got, total) {
          final t = total > 0 ? total : (widget.size ?? 0);
          if (mounted && t > 0) setState(() => _progress = got / t);
        },
      );
      if (mounted) setState(() => _bytes = Uint8List.fromList(r.data!));
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) return;
      if (mounted) setState(() => _error = describeError(e));
    }
  }

  void _share() {
    final bytes = _bytes!;
    // Called synchronously in the tap handler.
    shareFile(bytes, widget.fileName, widget.mime).catchError((Object e) {
      if (!e.toString().contains('AbortError') && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('分享失敗：$e')));
      }
    });
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final ready = _bytes != null;
    return AlertDialog(
      title: const Text('存到照片 / 分享'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null)
            Text('下載失敗：$_error')
          else if (!ready) ...[
            Text(widget.size != null ? '下載中（${formatBytes(widget.size!)}）…' : '下載中…'),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: _progress),
          ] else
            const Text('下載完成。按「分享」後，在分享選單選「儲存影片」或「儲存影像」即可存到照片。'),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton.icon(onPressed: ready ? _share : null, icon: const Icon(Icons.ios_share), label: const Text('分享')),
      ],
    );
  }
}
