enum MusicCollectionType { playlist, artist, album }

class MusicCollection {
  const MusicCollection({
    required this.id,
    required this.name,
    required this.type,
    required this.trackIds,
  });

  final String id;
  final String name;
  final MusicCollectionType type;
  final List<String> trackIds;

  String get typeLabel {
    return switch (type) {
      MusicCollectionType.playlist => 'Playlist',
      MusicCollectionType.artist => 'Artist',
      MusicCollectionType.album => 'Album',
    };
  }
}
