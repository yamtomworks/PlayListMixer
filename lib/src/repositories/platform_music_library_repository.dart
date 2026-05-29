import 'package:flutter/services.dart';

import '../models/music_collection.dart';
import '../models/saved_queue.dart';
import '../models/track.dart';
import 'music_library_repository.dart';

class PlatformMusicLibraryRepository implements MusicLibraryRepository {
  const PlatformMusicLibraryRepository();

  static const _channel = MethodChannel('playlist_mixer/music_library');

  @override
  Future<List<MusicCollection>> loadCollections() async {
    final rawCollections = await _channel.invokeListMethod<Object?>(
      'loadCollections',
    );

    return (rawCollections ?? const [])
        .whereType<Map<Object?, Object?>>()
        .map(_collectionFromMap)
        .toList(growable: false);
  }

  @override
  Future<Map<String, Track>> loadTracksById() async {
    final rawTracks = await _channel.invokeListMethod<Object?>('loadTracks');

    final tracks = (rawTracks ?? const [])
        .whereType<Map<Object?, Object?>>()
        .map(_trackFromMap)
        .toList(growable: false);

    return {for (final track in tracks) track.id: track};
  }

  @override
  Future<void> playTracks(List<Track> tracks) async {
    await _channel.invokeMethod<void>('playTracks', {
      'trackIds': tracks.map((track) => track.id).toList(growable: false),
    });
  }

  @override
  Future<String?> loadNowPlayingTrackId() async {
    return _channel.invokeMethod<String>('loadNowPlayingTrackId');
  }

  @override
  Future<List<SavedQueue>> loadSavedQueues() async {
    final rawQueues = await _channel.invokeListMethod<Object?>(
      'loadSavedQueues',
    );

    return (rawQueues ?? const [])
        .whereType<Map<Object?, Object?>>()
        .map(_savedQueueFromMap)
        .toList(growable: false);
  }

  @override
  Future<void> saveQueue(SavedQueue queue) async {
    await _channel.invokeMethod<void>('saveQueue', _savedQueueToMap(queue));
  }

  @override
  Future<void> saveSavedQueues(List<SavedQueue> queues) async {
    await _channel.invokeMethod<void>(
      'saveSavedQueues',
      queues.map(_savedQueueToMap).toList(growable: false),
    );
  }

  @override
  Future<void> deleteSavedQueue(String queueId) async {
    await _channel.invokeMethod<void>('deleteSavedQueue', {'id': queueId});
  }

  @override
  Future<void> saveToMusicPlaylist({
    required String name,
    required List<Track> tracks,
  }) async {
    await _channel.invokeMethod<void>('saveToMusicPlaylist', {
      'name': name,
      'trackIds': tracks.map((track) => track.id).toList(growable: false),
    });
  }

  static MusicCollection _collectionFromMap(Map<Object?, Object?> map) {
    return MusicCollection(
      id: map['id']! as String,
      name: map['name']! as String,
      type: _typeFromString(map['type']! as String),
      trackIds: (map['trackIds']! as List<Object?>).cast<String>(),
    );
  }

  static Track _trackFromMap(Map<Object?, Object?> map) {
    final durationMilliseconds = map['durationMilliseconds'] as int? ?? 0;

    return Track(
      id: map['id']! as String,
      title: map['title']! as String,
      artist: map['artist']! as String,
      album: map['album']! as String,
      duration: Duration(milliseconds: durationMilliseconds),
    );
  }

  static SavedQueue _savedQueueFromMap(Map<Object?, Object?> map) {
    return SavedQueue(
      id: map['id']! as String,
      name: map['name']! as String,
      trackIds: (map['trackIds']! as List<Object?>).cast<String>(),
      kind: _queueKindFromString(map['kind'] as String?),
    );
  }

  static Map<String, Object?> _savedQueueToMap(SavedQueue queue) {
    return {
      'id': queue.id,
      'name': queue.name,
      'trackIds': queue.trackIds,
      'kind': queue.kind.name,
    };
  }

  static MusicCollectionType _typeFromString(String value) {
    return switch (value) {
      'playlist' => MusicCollectionType.playlist,
      'artist' => MusicCollectionType.artist,
      'album' => MusicCollectionType.album,
      _ => MusicCollectionType.playlist,
    };
  }

  static SavedQueueKind _queueKindFromString(String? value) {
    return switch (value) {
      'history' => SavedQueueKind.history,
      _ => SavedQueueKind.saved,
    };
  }
}
