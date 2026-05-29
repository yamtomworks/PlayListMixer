import '../models/music_collection.dart';
import '../models/track.dart';

enum MixMode { both, onlyFirst, onlySecond, either }

class MixerService {
  const MixerService();

  List<Track> mix({
    required MusicCollection first,
    required MusicCollection second,
    required Map<String, Track> tracksById,
    required MixMode mode,
  }) {
    final secondIds = second.trackIds.toSet();
    final firstIds = first.trackIds.toSet();

    final mixedIds = switch (mode) {
      MixMode.both => first.trackIds.where(secondIds.contains),
      MixMode.onlyFirst => first.trackIds.where(
        (trackId) => !secondIds.contains(trackId),
      ),
      MixMode.onlySecond => second.trackIds.where(
        (trackId) => !firstIds.contains(trackId),
      ),
      MixMode.either => {...first.trackIds, ...second.trackIds},
    };

    return mixedIds
        .map((trackId) => tracksById[trackId])
        .whereType<Track>()
        .toList(growable: false);
  }
}
