import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import '../core/models.dart';
import 'status.dart';

/// A newest-first list loaded page by page (`before` = timestamp of the last item).
class PagedState<T> {
  const PagedState({required this.items, required this.hasMore, this.loadingMore = false});

  final List<T> items;
  final bool hasMore;
  final bool loadingMore;

  PagedState<T> copyWith({List<T>? items, bool? hasMore, bool? loadingMore}) => PagedState(
        items: items ?? this.items,
        hasMore: hasMore ?? this.hasMore,
        loadingMore: loadingMore ?? this.loadingMore,
      );
}

abstract class PagedNotifier<T> extends AsyncNotifier<PagedState<T>> {
  int get pageSize;

  /// Server event type that carries a newly saved item, and how to parse it.
  String get savedEventType;
  T parseSavedEvent(Map<String, dynamic> ev);

  Future<List<T>> fetch(NvrApi api, DateTime? before);
  DateTime timeOf(T item);
  String idOf(T item);
  Future<void> deleteRemote(NvrApi api, String id);

  NvrApi get _api => ref.read(apiProvider)!;

  @override
  Future<PagedState<T>> build() async {
    final api = ref.watch(apiProvider);
    if (api == null) return const PagedState(items: [], hasMore: false);

    // Prepend items the server just saved (pushed over the WebSocket).
    final sub = ref.read(serverEventsProvider).stream.listen((ev) {
      if (ev['type'] != savedEventType) return;
      final cur = state.value;
      if (cur == null) return;
      final item = parseSavedEvent(ev);
      if (cur.items.any((e) => idOf(e) == idOf(item))) return;
      final items = [item, ...cur.items]..sort((a, b) => timeOf(b).compareTo(timeOf(a)));
      state = AsyncData(cur.copyWith(items: items));
    });
    ref.onDispose(sub.cancel);

    final items = await fetch(api, null);
    return PagedState(items: items, hasMore: items.length >= pageSize);
  }

  Future<void> refresh() async {
    final items = await fetch(_api, null);
    state = AsyncData(PagedState(items: items, hasMore: items.length >= pageSize));
  }

  Future<void> loadMore() async {
    final cur = state.value;
    if (cur == null || !cur.hasMore || cur.loadingMore || cur.items.isEmpty) return;
    state = AsyncData(cur.copyWith(loadingMore: true));
    try {
      final more = await fetch(_api, timeOf(cur.items.last));
      state = AsyncData(PagedState(items: [...cur.items, ...more], hasMore: more.length >= pageSize));
    } catch (_) {
      state = AsyncData(cur.copyWith(loadingMore: false));
      rethrow;
    }
  }

  Future<void> delete(String id) async {
    await deleteRemote(_api, id);
    final cur = state.value;
    if (cur != null) {
      state = AsyncData(cur.copyWith(items: cur.items.where((e) => idOf(e) != id).toList()));
    }
  }
}

class RecordingsNotifier extends PagedNotifier<Recording> {
  @override
  int get pageSize => 30;
  @override
  String get savedEventType => 'recording.saved';
  @override
  Recording parseSavedEvent(Map<String, dynamic> ev) => Recording.fromJson(ev['recording'] as Map<String, dynamic>);
  @override
  Future<List<Recording>> fetch(NvrApi api, DateTime? before) => api.recordings(before: before, limit: pageSize);
  @override
  DateTime timeOf(Recording item) => item.startedAt;
  @override
  String idOf(Recording item) => item.id;
  @override
  Future<void> deleteRemote(NvrApi api, String id) => api.deleteRecording(id);
}

class SnapshotsNotifier extends PagedNotifier<Snapshot> {
  @override
  int get pageSize => 60;
  @override
  String get savedEventType => 'snapshot.saved';
  @override
  Snapshot parseSavedEvent(Map<String, dynamic> ev) => Snapshot.fromJson(ev['snapshot'] as Map<String, dynamic>);
  @override
  Future<List<Snapshot>> fetch(NvrApi api, DateTime? before) => api.snapshots(before: before, limit: pageSize);
  @override
  DateTime timeOf(Snapshot item) => item.takenAt;
  @override
  String idOf(Snapshot item) => item.id;
  @override
  Future<void> deleteRemote(NvrApi api, String id) => api.deleteSnapshot(id);
}

final recordingsProvider =
    AsyncNotifierProvider<RecordingsNotifier, PagedState<Recording>>(RecordingsNotifier.new);

final snapshotsProvider = AsyncNotifierProvider<SnapshotsNotifier, PagedState<Snapshot>>(SnapshotsNotifier.new);
