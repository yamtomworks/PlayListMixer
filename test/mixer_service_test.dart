import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_mixer/src/models/music_collection.dart';
import 'package:playlist_mixer/src/models/track.dart';
import 'package:playlist_mixer/src/services/mixer_service.dart';

void main() {
  const tracksById = {
    'a': Track(
      id: 'a',
      title: 'A',
      artist: 'Artist',
      album: 'Album',
      duration: Duration(minutes: 3),
    ),
    'b': Track(
      id: 'b',
      title: 'B',
      artist: 'Artist',
      album: 'Album',
      duration: Duration(minutes: 3),
    ),
    'c': Track(
      id: 'c',
      title: 'C',
      artist: 'Artist',
      album: 'Album',
      duration: Duration(minutes: 3),
    ),
  };

  const first = MusicCollection(
    id: 'first',
    name: 'First',
    type: MusicCollectionType.playlist,
    trackIds: ['a', 'b'],
  );

  const second = MusicCollection(
    id: 'second',
    name: 'Second',
    type: MusicCollectionType.album,
    trackIds: ['b', 'c'],
  );

  const service = MixerService();

  test('both returns tracks contained in A and B', () {
    final result = service.mix(
      first: first,
      second: second,
      tracksById: tracksById,
      mode: MixMode.both,
    );

    expect(result.map((track) => track.id), ['b']);
  });

  test('onlyFirst returns tracks contained in A but not B', () {
    final result = service.mix(
      first: first,
      second: second,
      tracksById: tracksById,
      mode: MixMode.onlyFirst,
    );

    expect(result.map((track) => track.id), ['a']);
  });

  test('onlySecond returns tracks contained in B but not A', () {
    final result = service.mix(
      first: first,
      second: second,
      tracksById: tracksById,
      mode: MixMode.onlySecond,
    );

    expect(result.map((track) => track.id), ['c']);
  });

  test('either returns unique tracks from A and B', () {
    final result = service.mix(
      first: first,
      second: second,
      tracksById: tracksById,
      mode: MixMode.either,
    );

    expect(result.map((track) => track.id), ['a', 'b', 'c']);
  });
}
