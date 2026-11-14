/// Data classes mirroring the server's JSON (see server/README.md).
library;

class RecordingStatus {
  const RecordingStatus({required this.active, this.sessionId, this.startedAt});

  final bool active;
  final String? sessionId;
  final DateTime? startedAt;

  factory RecordingStatus.fromJson(Map<String, dynamic> j) => RecordingStatus(
        active: j['active'] as bool? ?? false,
        sessionId: j['sessionId'] as String?,
        startedAt: _date(j['startedAt']),
      );

  static const idle = RecordingStatus(active: false);
}

class ServerStatus {
  const ServerStatus({
    required this.cameraOnline,
    required this.preset,
    required this.presets,
    required this.encoder,
    required this.recording,
    required this.diskFree,
    required this.diskTotal,
    required this.whepPath,
  });

  final bool cameraOnline;
  final String preset;
  final List<String> presets;
  final String encoder;
  final RecordingStatus recording;
  final int diskFree;
  final int diskTotal;
  final String whepPath;

  factory ServerStatus.fromJson(Map<String, dynamic> j) {
    final cam = j['camera'] as Map<String, dynamic>;
    final disk = j['disk'] as Map<String, dynamic>;
    final live = j['live'] as Map<String, dynamic>;
    return ServerStatus(
      cameraOnline: cam['online'] as bool,
      preset: cam['preset'] as String,
      presets: (cam['presets'] as List).cast<String>(),
      encoder: cam['encoder'] as String,
      recording: RecordingStatus.fromJson(j['recording'] as Map<String, dynamic>),
      diskFree: (disk['free'] as num).toInt(),
      diskTotal: (disk['total'] as num).toInt(),
      whepPath: live['whepPath'] as String,
    );
  }

  ServerStatus copyWith({bool? cameraOnline, String? preset, RecordingStatus? recording}) => ServerStatus(
        cameraOnline: cameraOnline ?? this.cameraOnline,
        preset: preset ?? this.preset,
        presets: presets,
        encoder: encoder,
        recording: recording ?? this.recording,
        diskFree: diskFree,
        diskTotal: diskTotal,
        whepPath: whepPath,
      );
}

class Recording {
  const Recording({
    required this.id,
    required this.startedAt,
    required this.duration,
    required this.size,
    required this.preset,
    required this.fileUrl,
    required this.thumbUrl,
  });

  final String id;
  final DateTime startedAt;
  final Duration duration;
  final int size;
  final String? preset;
  final String fileUrl;
  final String? thumbUrl;

  factory Recording.fromJson(Map<String, dynamic> j) => Recording(
        id: j['id'] as String,
        startedAt: _date(j['startedAt'])!,
        duration: Duration(milliseconds: (((j['duration'] as num?) ?? 0) * 1000).round()),
        size: (j['size'] as num?)?.toInt() ?? 0,
        preset: j['preset'] as String?,
        fileUrl: j['fileUrl'] as String,
        thumbUrl: j['thumbUrl'] as String?,
      );
}

class Snapshot {
  const Snapshot({
    required this.id,
    required this.takenAt,
    required this.size,
    required this.preset,
    required this.fileUrl,
    required this.thumbUrl,
  });

  final String id;
  final DateTime takenAt;
  final int size;
  final String? preset;
  final String fileUrl;
  final String? thumbUrl;

  factory Snapshot.fromJson(Map<String, dynamic> j) => Snapshot(
        id: j['id'] as String,
        takenAt: _date(j['takenAt'])!,
        size: (j['size'] as num?)?.toInt() ?? 0,
        preset: j['preset'] as String?,
        fileUrl: j['fileUrl'] as String,
        thumbUrl: j['thumbUrl'] as String?,
      );
}

DateTime? _date(Object? ms) => ms is num ? DateTime.fromMillisecondsSinceEpoch(ms.toInt()) : null;
