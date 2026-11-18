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

/// Camera power state (the server only runs the camera while it's needed).
enum CameraState {
  idle, // off, nobody watching; starts automatically when needed
  starting,
  live,
  offline; // should be running but isn't (unplugged, driver error, …)

  static CameraState parse(Object? v, {required bool online}) => switch (v) {
    'idle' => idle,
    'starting' => starting,
    'live' => live,
    'offline' => offline,
    _ => online ? live : offline, // older server
  };

  /// Recording / snapshots can be used (they switch the camera on if needed).
  bool get usable => this != offline;
}

class ServerStatus {
  const ServerStatus({
    required this.camera,
    required this.preset,
    required this.presets,
    required this.encoder,
    required this.recording,
    required this.diskFree,
    required this.diskTotal,
    required this.whepPath,
  });

  final CameraState camera;
  bool get cameraOnline => camera == CameraState.live;
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
      camera: CameraState.parse(cam['state'], online: cam['online'] as bool),
      preset: cam['preset'] as String,
      presets: (cam['presets'] as List).cast<String>(),
      encoder: cam['encoder'] as String,
      recording: RecordingStatus.fromJson(j['recording'] as Map<String, dynamic>),
      diskFree: (disk['free'] as num).toInt(),
      diskTotal: (disk['total'] as num).toInt(),
      whepPath: live['whepPath'] as String,
    );
  }

  ServerStatus copyWith({CameraState? camera, String? preset, RecordingStatus? recording}) => ServerStatus(
    camera: camera ?? this.camera,
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

/// A device that signs in with a passkey (Face ID).
class Device {
  const Device({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.lastSeenAt,
    required this.lastIp,
    required this.current,
  });

  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime? lastSeenAt;
  final String? lastIp;
  final bool current;

  factory Device.fromJson(Map<String, dynamic> j) => Device(
    id: j['id'] as String,
    name: j['name'] as String,
    createdAt: _date(j['createdAt'])!,
    lastSeenAt: _date(j['lastSeenAt']),
    lastIp: j['lastIp'] as String?,
    current: j['current'] as bool? ?? false,
  );
}

DateTime? _date(Object? ms) => ms is num ? DateTime.fromMillisecondsSinceEpoch(ms.toInt()) : null;
