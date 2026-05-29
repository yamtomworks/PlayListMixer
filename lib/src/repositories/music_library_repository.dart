import '../models/music_collection.dart';
import '../models/saved_queue.dart';
import '../models/track.dart';

abstract class MusicLibraryRepository {
  Future<List<MusicCollection>> loadCollections();

  Future<Map<String, Track>> loadTracksById();

  Future<void> playTracks(List<Track> tracks);

  Future<String?> loadNowPlayingTrackId();

  Future<List<SavedQueue>> loadSavedQueues();

  Future<void> saveQueue(SavedQueue queue);

  Future<void> saveSavedQueues(List<SavedQueue> queues);

  Future<void> deleteSavedQueue(String queueId);

  Future<void> saveToMusicPlaylist({
    required String name,
    required List<Track> tracks,
  });
}
