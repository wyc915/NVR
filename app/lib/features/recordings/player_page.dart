import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../core/api.dart';
import '../../core/format.dart';
import '../../core/models.dart';

/// Plays a recorded MP4 streamed from the PC (HTTP range requests, so seeking works).
class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({super.key, required this.recording});

  final Recording recording;

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage> {
  late final VideoPlayerController _c;
  Object? _error;
  var _showControls = true;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    final api = ref.read(apiProvider)!;
    _c = VideoPlayerController.networkUrl(Uri.parse(api.mediaUrl(widget.recording.fileUrl)));
    _c.initialize().then((_) {
      if (!mounted) return;
      setState(() {});
      _c.play();
      _scheduleHide();
    }, onError: (Object e) {
      if (mounted) setState(() => _error = e);
    });
    _c.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _c.dispose();
    super.dispose();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _c.value.isPlaying) setState(() => _showControls = false);
    });
  }

  void _togglePlay() {
    _c.value.isPlaying ? _c.pause() : _c.play();
    setState(() => _showControls = true);
    _scheduleHide();
  }

  void _seekBy(Duration d) {
    final target = _c.value.position + d;
    _c.seekTo(target < Duration.zero ? Duration.zero : target);
    setState(() => _showControls = true);
    _scheduleHide();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.recording;
    final v = _c.value;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(formatDateTime(r.startedAt)),
      ),
      body: SafeArea(
        child: Center(
          child: _error != null
              ? const Text('無法播放這段錄影', style: TextStyle(color: Colors.white70))
              : !v.isInitialized
                  ? const CircularProgressIndicator(color: Colors.white70)
                  : GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        setState(() => _showControls = !_showControls);
                        if (_showControls) _scheduleHide();
                      },
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          // IgnorePointer: on web the <video> element would swallow taps.
                          AspectRatio(aspectRatio: v.aspectRatio, child: IgnorePointer(child: VideoPlayer(_c))),
                          AnimatedOpacity(
                            opacity: _showControls ? 1 : 0,
                            duration: const Duration(milliseconds: 200),
                            child: IgnorePointer(
                              ignoring: !_showControls,
                              child: _Controls(
                                value: v,
                                controller: _c,
                                onTogglePlay: _togglePlay,
                                onSeekBy: _seekBy,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
        ),
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.value,
    required this.controller,
    required this.onTogglePlay,
    required this.onSeekBy,
  });

  final VideoPlayerValue value;
  final VideoPlayerController controller;
  final VoidCallback onTogglePlay;
  final ValueChanged<Duration> onSeekBy;

  @override
  Widget build(BuildContext context) {
    final ended = value.position >= value.duration && value.duration > Duration.zero && !value.isPlaying;
    return Stack(
      children: [
        Positioned.fill(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                iconSize: 40,
                color: Colors.white,
                icon: const Icon(Icons.replay_10),
                onPressed: () => onSeekBy(const Duration(seconds: -10)),
              ),
              const SizedBox(width: 24),
              IconButton.filled(
                iconSize: 48,
                style: IconButton.styleFrom(backgroundColor: Colors.black54),
                color: Colors.white,
                icon: Icon(ended
                    ? Icons.replay
                    : value.isPlaying
                        ? Icons.pause
                        : Icons.play_arrow),
                onPressed: () {
                  if (ended) controller.seekTo(Duration.zero);
                  onTogglePlay();
                },
              ),
              const SizedBox(width: 24),
              IconButton(
                iconSize: 40,
                color: Colors.white,
                icon: const Icon(Icons.forward_10),
                onPressed: () => onSeekBy(const Duration(seconds: 10)),
              ),
            ],
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            color: Colors.black45,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Row(children: [
              Text(formatDuration(value.position), style: const TextStyle(color: Colors.white, fontSize: 12)),
              const SizedBox(width: 8),
              Expanded(
                child: VideoProgressIndicator(
                  controller,
                  allowScrubbing: true,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  colors: const VideoProgressColors(
                    playedColor: Colors.redAccent,
                    bufferedColor: Colors.white38,
                    backgroundColor: Colors.white12,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(formatDuration(value.duration), style: const TextStyle(color: Colors.white, fontSize: 12)),
            ]),
          ),
        ),
      ],
    );
  }
}
