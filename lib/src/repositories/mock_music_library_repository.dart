import '../models/music_collection.dart';
import '../models/saved_queue.dart';
import '../models/track.dart';
import 'music_library_repository.dart';

class MockMusicLibraryRepository implements MusicLibraryRepository {
  final List<SavedQueue> _savedQueues = [];
  String? _nowPlayingTrackId;
  static const _tracks = <Track>[
    Track(
      id: 't1',
      title: 'City Lights',
      artist: 'Mina Kato',
      album: 'Night Sketches',
      duration: Duration(minutes: 3, seconds: 42),
    ),
    Track(
      id: 't2',
      title: 'Blue Hour',
      artist: 'Mina Kato',
      album: 'Night Sketches',
      duration: Duration(minutes: 4, seconds: 8),
    ),
    Track(
      id: 't3',
      title: 'Drive North',
      artist: 'Paper Planes',
      album: 'Road Film',
      duration: Duration(minutes: 2, seconds: 58),
    ),
    Track(
      id: 't4',
      title: 'Late Coffee',
      artist: 'Lumen',
      album: 'Desk Radio',
      duration: Duration(minutes: 3, seconds: 21),
    ),
    Track(
      id: 't5',
      title: 'Low Tide',
      artist: 'Harbor Trio',
      album: 'Coastline',
      duration: Duration(minutes: 5, seconds: 4),
    ),
    Track(
      id: 't6',
      title: 'Soft Reset',
      artist: 'Lumen',
      album: 'Desk Radio',
      duration: Duration(minutes: 3, seconds: 35),
    ),
  ];

  static const _collections = <MusicCollection>[
    MusicCollection(
      id: 'p1',
      name: '朝のプレイリスト',
      type: MusicCollectionType.playlist,
      trackIds: ['t1', 't2', 't3', 't4'],
    ),
    MusicCollection(
      id: 'p2',
      name: '集中用',
      type: MusicCollectionType.playlist,
      trackIds: ['t2', 't4', 't5', 't6'],
    ),
    MusicCollection(
      id: 'a1',
      name: 'Night Sketches',
      type: MusicCollectionType.album,
      trackIds: ['t1', 't2'],
    ),
    MusicCollection(
      id: 'a2',
      name: 'Desk Radio',
      type: MusicCollectionType.album,
      trackIds: ['t4', 't6'],
    ),
  ];

  @override
  Future<List<MusicCollection>> loadCollections() async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    return _collections;
  }

  @override
  Future<Map<String, Track>> loadTracksById() async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    return {for (final track in _tracks) track.id: track};
  }

  @override
  Future<void> playTracks(List<Track> tracks) async {
    _nowPlayingTrackId = tracks.isEmpty ? null : tracks.first.id;
  }

  @override
  Future<String?> loadNowPlayingTrackId() async => _nowPlayingTrackId;

  @override
  Future<List<SavedQueue>> loadSavedQueues() async => [..._savedQueues];

  @override
  Future<void> saveQueue(SavedQueue queue) async {
    _savedQueues.removeWhere((existing) => existing.id == queue.id);
    _savedQueues.insert(0, queue);
  }

  @override
  Future<void> saveSavedQueues(List<SavedQueue> queues) async {
    _savedQueues
      ..clear()
      ..addAll(queues);
  }

  @override
  Future<void> deleteSavedQueue(String queueId) async {
    _savedQueues.removeWhere((queue) => queue.id == queueId);
  }

  @override
  Future<void> saveToMusicPlaylist({
    required String name,
    required List<Track> tracks,
  }) async {}
}
