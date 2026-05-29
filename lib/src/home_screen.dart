import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'models/music_collection.dart';
import 'models/saved_queue.dart';
import 'models/track.dart';
import 'repositories/music_library_repository.dart';
import 'services/mixer_service.dart';

enum _AppLanguage {
  japanese,
  english,
  italian,
  spanish,
  chineseSimplified,
  chineseTraditional,
  german,
  french,
  portuguese,
  korean,
}

enum _ColorPattern {
  cyanViolet,
  azureMagenta,
  tealCoral,
  mintIndigo,
  skyAmber,
  lavenderAqua,
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.repository});

  final MusicLibraryRepository repository;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _mixer = const MixerService();
  static const _settingsChannel = MethodChannel('playlist_mixer/music_library');
  static const _maxHistoryQueues = 10;

  late Future<_LibraryState> _libraryState;
  MusicCollectionType _firstType = MusicCollectionType.playlist;
  MusicCollectionType _secondType = MusicCollectionType.playlist;
  MusicCollection? _first;
  MusicCollection? _second;
  MixMode _mode = MixMode.both;
  String? _playingTrackId;
  Timer? _nowPlayingTimer;
  final Set<String> _removedTrackIds = {};
  List<String> _queueTrackOrder = [];
  List<String>? _loadedSavedTrackIds;
  String? _loadedSavedQueueName;
  bool _isStartingPlayback = false;
  _AppLanguage _language = _AppLanguage.japanese;
  _ColorPattern _colorPattern = _ColorPattern.cyanViolet;
  int _playingGradientPeriodSeconds = 16;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSettings());
    _libraryState = _loadLibrary().then((state) {
      unawaited(_restorePlaybackQueueFromNowPlaying(state));
      return state;
    });
  }

  @override
  void dispose() {
    _nowPlayingTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    try {
      final settings = await _settingsChannel.invokeMapMethod<String, Object?>(
        'loadSettings',
      );
      if (!mounted || settings == null) {
        return;
      }

      final language = _enumByName(
        _AppLanguage.values,
        settings['language'] as String?,
      );
      final colorPattern = _enumByName(
        _ColorPattern.values,
        settings['colorPattern'] as String?,
      );

      setState(() {
        if (language != null) {
          _language = language;
        }
        if (colorPattern != null) {
          _colorPattern = colorPattern;
        }
      });
    } on MissingPluginException {
      return;
    }
  }

  Future<void> _saveSettings() async {
    try {
      await _settingsChannel.invokeMethod<void>('saveSettings', {
        'language': _language.name,
        'colorPattern': _colorPattern.name,
      });
    } on MissingPluginException {
      return;
    }
  }

  Future<_LibraryState> _loadLibrary() async {
    final results = await Future.wait([
      widget.repository.loadCollections(),
      widget.repository.loadTracksById(),
    ]);

    final collections = results[0] as List<MusicCollection>;
    return _LibraryState(
      collections: collections,
      tracksById: results[1] as Map<String, Track>,
    );
  }

  List<Track> _matchingTracks(_LibraryState state) {
    final loadedIds = _loadedSavedTrackIds;
    if (loadedIds != null) {
      return loadedIds
          .map((trackId) => state.tracksById[trackId])
          .whereType<Track>()
          .toList(growable: false);
    }

    final first = _first;
    final second = _second;
    if (first == null || second == null) {
      return const [];
    }

    return _mixer.mix(
      first: first,
      second: second,
      tracksById: state.tracksById,
      mode: _mode,
    );
  }

  List<Track> _visibleQueueTracks(List<Track> tracks) {
    final tracksById = {for (final track in tracks) track.id: track};
    final naturalOrder = tracks.map((track) => track.id).toList();
    final orderedIds = [
      ..._queueTrackOrder.where(tracksById.containsKey),
      ...naturalOrder.where((id) => !_queueTrackOrder.contains(id)),
    ];

    return orderedIds
        .where((id) => !_removedTrackIds.contains(id))
        .map((id) => tracksById[id])
        .whereType<Track>()
        .toList(growable: false);
  }

  void _resetQueueEdits() {
    _removedTrackIds.clear();
    _queueTrackOrder = [];
    _loadedSavedTrackIds = null;
    _loadedSavedQueueName = null;
  }

  void _removeTrack(Track track) {
    setState(() {
      _removedTrackIds.add(track.id);
    });

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(_strings.removedFromQueue(track.title)),
          action: SnackBarAction(
            label: _strings.undo,
            onPressed: () {
              setState(() => _removedTrackIds.remove(track.id));
            },
          ),
        ),
      );
  }

  void _reorderTracks(List<Track> tracks, int oldIndex, int newIndex) {
    final reordered = [...tracks];
    if (newIndex > oldIndex) {
      newIndex -= 1;
    }
    final track = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, track);

    setState(() {
      _queueTrackOrder = reordered.map((track) => track.id).toList();
    });
  }

  Future<void> _playMixedTracks(
    List<Track> tracks, {
    bool shuffle = false,
  }) async {
    if (tracks.isEmpty || _isStartingPlayback) {
      return;
    }

    final playbackQueue = [...tracks];
    if (shuffle) {
      playbackQueue.shuffle();
    }

    setState(() {
      _isStartingPlayback = true;
      _playingTrackId = playbackQueue.first.id;
    });

    try {
      await widget.repository.playTracks(playbackQueue);
      unawaited(_savePlaybackHistory(playbackQueue));
      _startNowPlayingPolling();
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_strings.playbackError(error))));
      setState(() => _playingTrackId = null);
    } finally {
      if (mounted) {
        setState(() => _isStartingPlayback = false);
      }
    }
  }

  void _startNowPlayingPolling() {
    _nowPlayingTimer?.cancel();
    unawaited(_refreshNowPlayingTrack());
    _nowPlayingTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_refreshNowPlayingTrack()),
    );
  }

  Future<void> _refreshNowPlayingTrack() async {
    try {
      final trackId = await widget.repository.loadNowPlayingTrackId();
      if (!mounted || trackId == _playingTrackId) {
        return;
      }
      setState(() => _playingTrackId = trackId);
    } catch (_) {
      return;
    }
  }

  Future<void> _restorePlaybackQueueFromNowPlaying(_LibraryState state) async {
    try {
      final trackId = await widget.repository.loadNowPlayingTrackId();
      if (!mounted ||
          trackId == null ||
          !state.tracksById.containsKey(trackId)) {
        return;
      }

      final queues = await widget.repository.loadSavedQueues();
      if (!mounted) {
        return;
      }

      final historyMatch = queues
          .where((queue) => queue.kind == SavedQueueKind.history)
          .where((queue) => queue.trackIds.contains(trackId))
          .firstOrNull;
      final savedMatch = queues
          .where((queue) => queue.kind == SavedQueueKind.saved)
          .where((queue) => queue.trackIds.contains(trackId))
          .firstOrNull;
      final queue = historyMatch ?? savedMatch;
      final restoredTrackIds = queue?.trackIds ?? [trackId];

      setState(() {
        _removedTrackIds.clear();
        _queueTrackOrder = [];
        _loadedSavedTrackIds = restoredTrackIds
            .where(state.tracksById.containsKey)
            .toList(growable: false);
        _loadedSavedQueueName = queue?.name ?? _strings.nowPlayingQueue;
        _playingTrackId = trackId;
      });
      _startNowPlayingPolling();
    } catch (_) {
      return;
    }
  }

  String _defaultQueueName() {
    final now = DateTime.now();
    final month = now.month.toString().padLeft(2, '0');
    final day = now.day.toString().padLeft(2, '0');
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    return 'Mix ${now.year}-$month-$day $hour:$minute';
  }

  String _historyQueueName() {
    final now = DateTime.now();
    final month = now.month.toString().padLeft(2, '0');
    final day = now.day.toString().padLeft(2, '0');
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    return '${now.year}-$month-$day $hour:$minute';
  }

  Future<void> _savePlaybackHistory(List<Track> tracks) async {
    if (tracks.isEmpty) {
      return;
    }

    try {
      final trackIds = tracks.map((track) => track.id).toList(growable: false);
      final queues = await widget.repository.loadSavedQueues();
      final savedQueues = queues
          .where((queue) => queue.kind == SavedQueueKind.saved)
          .toList(growable: false);
      final historyQueues = queues
          .where((queue) => queue.kind == SavedQueueKind.history)
          .where((queue) => !_sameTrackOrder(queue.trackIds, trackIds))
          .toList();

      historyQueues.insert(
        0,
        SavedQueue(
          id: 'history-${DateTime.now().microsecondsSinceEpoch}',
          name: _historyQueueName(),
          trackIds: trackIds,
          kind: SavedQueueKind.history,
        ),
      );

      await widget.repository.saveSavedQueues([
        ...savedQueues,
        ...historyQueues.take(_maxHistoryQueues),
      ]);
    } catch (_) {
      return;
    }
  }

  Future<void> _showSaveOptions(List<Track> tracks) async {
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
      ),
      builder: (sheetContext) => _SaveQueueSheet(
        initialName: _defaultQueueName(),
        strings: _strings,
        onSaveInApp: (name) => _saveInApp(name, tracks),
        onSaveInMusic: (name) => _saveToMusic(name, tracks),
      ),
    );
  }

  Future<void> _saveInApp(String name, List<Track> tracks) async {
    final queue = SavedQueue(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name,
      trackIds: tracks.map((track) => track.id).toList(growable: false),
    );

    try {
      await widget.repository.saveQueue(queue);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_strings.savedInApp(name))));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_strings.saveFailed(error))));
      }
    }
  }

  Future<void> _saveToMusic(String name, List<Track> tracks) async {
    try {
      await widget.repository.saveToMusicPlaylist(name: name, tracks: tracks);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_strings.savedInMusic(name))));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_strings.saveFailed(error))));
      }
    }
  }

  Future<void> _showSavedQueues() async {
    List<SavedQueue> allQueues;
    try {
      allQueues = await widget.repository.loadSavedQueues();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_strings.saveFailed(error))));
      }
      return;
    }

    if (!mounted) {
      return;
    }

    Future<void> persistQueues(List<SavedQueue> queues) async {
      await widget.repository.saveSavedQueues(queues);
    }

    List<SavedQueue> queuesOf(SavedQueueKind kind) {
      return allQueues.where((queue) => queue.kind == kind).toList();
    }

    Future<void> deleteQueue(SavedQueue queue) async {
      allQueues.removeWhere((item) => item.id == queue.id);
      await widget.repository.deleteSavedQueue(queue.id);
    }

    Future<void> persistManualOrder(List<SavedQueue> savedQueues) async {
      final historyQueues = queuesOf(SavedQueueKind.history);
      allQueues = [...savedQueues, ...historyQueues];
      await persistQueues(allQueues);
    }

    String? editingQueueId;
    final renameController = TextEditingController();

    Future<void> commitRename(
      SavedQueue queue,
      void Function(void Function()) setSheetState,
    ) async {
      final renamed = renameController.text.trim();
      if (renamed.isEmpty || renamed == queue.name) {
        setSheetState(() => editingQueueId = null);
        return;
      }

      final index = allQueues.indexWhere((item) => item.id == queue.id);
      if (index == -1) {
        return;
      }

      setSheetState(() {
        allQueues[index] = queue.copyWith(name: renamed);
        editingQueueId = null;
      });
      if (_loadedSavedQueueName == queue.name) {
        setState(() => _loadedSavedQueueName = renamed);
      }
      await persistQueues(allQueues);
    }

    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            final savedQueues = queuesOf(SavedQueueKind.saved);
            final historyQueues = queuesOf(SavedQueueKind.history);

            Widget buildQueueTile({
              required SavedQueue queue,
              required int index,
              required bool editable,
            }) {
              return Padding(
                key: ValueKey(queue.id),
                padding: const EdgeInsets.only(bottom: 8),
                child: Dismissible(
                  key: ValueKey('saved-dismiss-${queue.id}'),
                  direction: DismissDirection.endToStart,
                  background: _DeleteTrackBackground(label: _strings.delete),
                  onDismissed: (_) async {
                    setSheetState(() {
                      allQueues.removeWhere((item) => item.id == queue.id);
                    });
                    await deleteQueue(queue);
                  },
                  child: _SavedQueueTile(
                    queue: queue,
                    accentColor: _queueAccentColor(index, _palette),
                    strings: _strings,
                    isRenaming: editable && editingQueueId == queue.id,
                    renameController: renameController,
                    dragHandle: editable
                        ? ReorderableDragStartListener(
                            index: index,
                            child: const Icon(Icons.drag_handle),
                          )
                        : const Icon(Icons.history),
                    onRename: editable
                        ? () {
                            setSheetState(() {
                              editingQueueId = queue.id;
                              renameController.text = queue.name;
                              renameController.selection =
                                  TextSelection.collapsed(
                                    offset: queue.name.length,
                                  );
                            });
                          }
                        : null,
                    onCancelRename: () {
                      setSheetState(() => editingQueueId = null);
                    },
                    onSubmitRename: () => commitRename(queue, setSheetState),
                    onTap: () {
                      if (editingQueueId == queue.id) {
                        return;
                      }
                      setState(() {
                        _removedTrackIds.clear();
                        _queueTrackOrder = [];
                        _loadedSavedTrackIds = [...queue.trackIds];
                        _loadedSavedQueueName = queue.name;
                      });
                      Navigator.of(sheetContext).pop();
                    },
                  ),
                ),
              );
            }

            return DefaultTabController(
              length: 2,
              child: SizedBox(
                height: MediaQuery.sizeOf(sheetContext).height * 0.62,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                      child: Text(
                        _strings.savedQueues,
                        style: Theme.of(sheetContext).textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ),
                    TabBar(
                      tabs: [
                        Tab(text: _strings.savedTab),
                        Tab(text: _strings.historyTab),
                      ],
                    ),
                    Expanded(
                      child: TabBarView(
                        children: [
                          savedQueues.isEmpty
                              ? Center(child: Text(_strings.noSavedQueues))
                              : ReorderableListView.builder(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    12,
                                    12,
                                    16,
                                  ),
                                  itemCount: savedQueues.length,
                                  onReorder: (oldIndex, newIndex) async {
                                    setSheetState(() {
                                      if (newIndex > oldIndex) {
                                        newIndex -= 1;
                                      }
                                      final queue = savedQueues.removeAt(
                                        oldIndex,
                                      );
                                      savedQueues.insert(newIndex, queue);
                                    });
                                    await persistManualOrder(savedQueues);
                                  },
                                  itemBuilder: (context, index) =>
                                      buildQueueTile(
                                        queue: savedQueues[index],
                                        index: index,
                                        editable: true,
                                      ),
                                ),
                          historyQueues.isEmpty
                              ? Center(child: Text(_strings.noHistoryQueues))
                              : ListView.builder(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    12,
                                    12,
                                    16,
                                  ),
                                  itemCount: historyQueues.length,
                                  itemBuilder: (context, index) =>
                                      buildQueueTile(
                                        queue: historyQueues[index],
                                        index: index,
                                        editable: false,
                                      ),
                                ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    renameController.dispose();
  }

  _Strings get _strings => _Strings(_language);
  _VennPalette get _palette => _VennPalette.forPattern(_colorPattern);

  Future<void> _showSettings() {
    return showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final strings = _strings;

            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                20,
                0,
                20,
                MediaQuery.viewInsetsOf(context).bottom + 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    strings.settings,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 18),
                  DropdownMenu<_AppLanguage>(
                    width: double.infinity,
                    label: Text(strings.language),
                    leadingIcon: const Icon(Icons.language),
                    initialSelection: _language,
                    dropdownMenuEntries: [
                      for (final language in _AppLanguage.values)
                        DropdownMenuEntry(
                          value: language,
                          label: strings.languageName(language),
                        ),
                    ],
                    onSelected: (language) {
                      if (language == null) {
                        return;
                      }
                      setState(() => _language = language);
                      setSheetState(() {});
                      unawaited(_saveSettings());
                    },
                  ),
                  const SizedBox(height: 16),
                  DropdownMenu<_ColorPattern>(
                    width: double.infinity,
                    label: Text(strings.colorPattern),
                    leadingIcon: const Icon(Icons.palette_outlined),
                    initialSelection: _colorPattern,
                    dropdownMenuEntries: [
                      for (final pattern in _ColorPattern.values)
                        DropdownMenuEntry(
                          value: pattern,
                          label: strings.patternName(pattern),
                          leadingIcon: _PalettePreview(
                            palette: _VennPalette.forPattern(pattern),
                          ),
                        ),
                    ],
                    onSelected: (pattern) {
                      if (pattern == null) {
                        return;
                      }
                      setState(() => _colorPattern = pattern);
                      setSheetState(() {});
                      unawaited(_saveSettings());
                    },
                  ),
                  const SizedBox(height: 20),
                  Text(
                    strings.playingAnimationPeriod,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Slider(
                          min: 4,
                          max: 30,
                          divisions: 26,
                          label: strings.seconds(_playingGradientPeriodSeconds),
                          value: _playingGradientPeriodSeconds.toDouble(),
                          onChanged: (value) {
                            setState(
                              () =>
                                  _playingGradientPeriodSeconds = value.round(),
                            );
                            setSheetState(() {});
                          },
                        ),
                      ),
                      SizedBox(
                        width: 56,
                        child: Text(
                          strings.seconds(_playingGradientPeriodSeconds),
                          textAlign: TextAlign.right,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = _strings;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Playlist Mixer'),
        actions: [
          IconButton(
            tooltip: strings.settings,
            onPressed: _showSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
          const SizedBox(width: 6),
        ],
      ),
      bottomNavigationBar: const _BannerAdSlot(),
      body: DecoratedBox(
        decoration: const BoxDecoration(color: Color(0xFFF6F8FF)),
        child: SafeArea(
          child: FutureBuilder<_LibraryState>(
            future: _libraryState,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }

              if (snapshot.hasError || !snapshot.hasData) {
                return _EmptyState(
                  icon: Icons.error_outline,
                  title: strings.libraryLoadFailed,
                  message: '${snapshot.error ?? 'Unknown error'}',
                );
              }

              final state = snapshot.data!;
              final matchingTracks = _matchingTracks(state);
              final mixedTracks = _visibleQueueTracks(matchingTracks);
              final hasQueueSource =
                  _loadedSavedTrackIds != null ||
                  (_first != null && _second != null);

              return CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    sliver: SliverList.list(
                      children: [
                        _CollectionStage(
                          firstPicker: _CollectionPicker(
                            label: strings.listA,
                            type: _firstType,
                            value: _first,
                            collections: state.collections,
                            strings: strings,
                            accentColor: _palette.a,
                            referenceCollection: _second,
                            showTrackCount: _first != null && _second != null,
                            onChanged: (collection) {
                              setState(() {
                                _first = collection;
                                _firstType = collection.type;
                                _resetQueueEdits();
                              });
                            },
                          ),
                          secondPicker: _CollectionPicker(
                            label: strings.listB,
                            type: _secondType,
                            value: _second,
                            collections: state.collections,
                            strings: strings,
                            accentColor: _palette.b,
                            referenceCollection: _first,
                            showTrackCount: _first != null && _second != null,
                            onChanged: (collection) {
                              setState(() {
                                _second = collection;
                                _secondType = collection.type;
                                _resetQueueEdits();
                              });
                            },
                          ),
                          value: _mode,
                          palette: _palette,
                          strings: strings,
                          onChanged: (mode) {
                            setState(() {
                              _mode = mode;
                              _resetQueueEdits();
                            });
                          },
                        ),
                      ],
                    ),
                  ),
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: _QueueHeaderDelegate(
                      enabled: mixedTracks.isNotEmpty,
                      isLoading: _isStartingPlayback,
                      onPlay: () => _playMixedTracks(mixedTracks),
                      onShuffle: () =>
                          _playMixedTracks(mixedTracks, shuffle: true),
                      onSave: () => _showSaveOptions(mixedTracks),
                      onOpenSaved: _showSavedQueues,
                      loadedQueueName: _loadedSavedQueueName,
                      strings: strings,
                      palette: _palette,
                    ),
                  ),
                  if (!hasQueueSource)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: ColoredBox(
                        color: Colors.white,
                        child: _EmptyState(
                          icon: Icons.library_music_outlined,
                          title: strings.chooseTwoLists,
                          message: strings.chooseTwoListsMessage,
                        ),
                      ),
                    )
                  else if (mixedTracks.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: ColoredBox(
                        color: Colors.white,
                        child: _EmptyState(
                          icon: Icons.filter_alt_off_outlined,
                          title: matchingTracks.isEmpty
                              ? strings.noMatches
                              : strings.emptyQueue,
                          message: matchingTracks.isEmpty
                              ? strings.noMatchesMessage
                              : strings.emptyQueueMessage,
                        ),
                      ),
                    )
                  else
                    SliverReorderableList(
                      itemCount: mixedTracks.length,
                      onReorder: (oldIndex, newIndex) =>
                          _reorderTracks(mixedTracks, oldIndex, newIndex),
                      itemBuilder: (context, index) {
                        final track = mixedTracks[index];
                        return ColoredBox(
                          key: ValueKey(track.id),
                          color: Colors.white,
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              16,
                              0,
                              16,
                              index == mixedTracks.length - 1 ? 24 : 8,
                            ),
                            child: Dismissible(
                              key: ValueKey('dismiss-${track.id}'),
                              direction: DismissDirection.endToStart,
                              onDismissed: (_) => _removeTrack(track),
                              background: _DeleteTrackBackground(
                                label: strings.delete,
                              ),
                              child: _TrackTile(
                                track: track,
                                isPlaying: track.id == _playingTrackId,
                                palette: _palette,
                                gradientPeriodSeconds:
                                    _playingGradientPeriodSeconds,
                                dragHandle: ReorderableDragStartListener(
                                  index: index,
                                  child: const Icon(Icons.drag_handle),
                                ),
                                onTap: () {
                                  setState(() => _playingTrackId = track.id);
                                },
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _LibraryState {
  const _LibraryState({required this.collections, required this.tracksById});

  final List<MusicCollection> collections;
  final Map<String, Track> tracksById;
}

class _SaveQueueSheet extends StatefulWidget {
  const _SaveQueueSheet({
    required this.initialName,
    required this.strings,
    required this.onSaveInApp,
    required this.onSaveInMusic,
  });

  final String initialName;
  final _Strings strings;
  final Future<void> Function(String name) onSaveInApp;
  final Future<void> Function(String name) onSaveInMusic;

  @override
  State<_SaveQueueSheet> createState() => _SaveQueueSheetState();
}

class _SaveQueueSheetState extends State<_SaveQueueSheet> {
  late final TextEditingController _nameController = TextEditingController(
    text: widget.initialName,
  );
  bool _isSaving = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  String get _queueName {
    final name = _nameController.text.trim();
    return name.isEmpty ? widget.initialName : name;
  }

  Future<void> _save(Future<void> Function(String name) action) async {
    if (_isSaving) {
      return;
    }

    setState(() => _isSaving = true);
    await action(_queueName);
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.strings.saveQueue,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _nameController,
            enabled: !_isSaving,
            decoration: InputDecoration(
              labelText: widget.strings.queueName,
              prefixIcon: const Icon(Icons.edit_outlined),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _isSaving ? null : () => _save(widget.onSaveInApp),
            icon: const Icon(Icons.bookmark_add_outlined),
            label: Text(widget.strings.saveInApp),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _isSaving ? null : () => _save(widget.onSaveInMusic),
            icon: const Icon(Icons.library_music_outlined),
            label: Text(widget.strings.saveInMusic),
          ),
        ],
      ),
    );
  }
}

class _Strings {
  const _Strings(this.locale);

  final _AppLanguage locale;

  String _text({
    required String ja,
    required String en,
    required String it,
    required String es,
    required String zhHans,
    required String zhHant,
    required String de,
    required String fr,
    required String pt,
    required String ko,
  }) {
    return switch (locale) {
      _AppLanguage.japanese => ja,
      _AppLanguage.english => en,
      _AppLanguage.italian => it,
      _AppLanguage.spanish => es,
      _AppLanguage.chineseSimplified => zhHans,
      _AppLanguage.chineseTraditional => zhHant,
      _AppLanguage.german => de,
      _AppLanguage.french => fr,
      _AppLanguage.portuguese => pt,
      _AppLanguage.korean => ko,
    };
  }

  String languageName(_AppLanguage language) {
    return switch (language) {
      _AppLanguage.japanese => '日本語',
      _AppLanguage.english => 'English',
      _AppLanguage.italian => 'Italiano',
      _AppLanguage.spanish => 'Español',
      _AppLanguage.chineseSimplified => '简体中文',
      _AppLanguage.chineseTraditional => '繁體中文',
      _AppLanguage.german => 'Deutsch',
      _AppLanguage.french => 'Français',
      _AppLanguage.portuguese => 'Português',
      _AppLanguage.korean => '한국어',
    };
  }

  String get settings => _text(
    ja: '設定',
    en: 'Settings',
    it: 'Impostazioni',
    es: 'Ajustes',
    zhHans: '设置',
    zhHant: '設定',
    de: 'Einstellungen',
    fr: 'Réglages',
    pt: 'Configurações',
    ko: '설정',
  );
  String get language => _text(
    ja: '言語',
    en: 'Language',
    it: 'Lingua',
    es: 'Idioma',
    zhHans: '语言',
    zhHant: '語言',
    de: 'Sprache',
    fr: 'Langue',
    pt: 'Idioma',
    ko: '언어',
  );
  String get colorPattern => _text(
    ja: '配色パターン',
    en: 'Color Pattern',
    it: 'Schema colori',
    es: 'Patrón de color',
    zhHans: '配色方案',
    zhHant: '配色方案',
    de: 'Farbschema',
    fr: 'Palette de couleurs',
    pt: 'Padrão de cores',
    ko: '색상 패턴',
  );
  String get playingAnimationPeriod => _text(
    ja: '再生中アニメーション周期',
    en: 'Now Playing Animation Period',
    it: 'Periodo animazione in riproduzione',
    es: 'Periodo de animación en reproducción',
    zhHans: '正在播放动画周期',
    zhHant: '正在播放動畫週期',
    de: 'Animationsdauer der aktuellen Wiedergabe',
    fr: 'Durée de l’animation en lecture',
    pt: 'Período da animação em reprodução',
    ko: '재생 중 애니메이션 주기',
  );
  String get libraryLoadFailed => _text(
    ja: 'ライブラリを読み込めませんでした',
    en: 'Unable to load your library',
    it: 'Impossibile caricare la libreria',
    es: 'No se pudo cargar tu biblioteca',
    zhHans: '无法加载你的音乐库',
    zhHant: '無法載入你的音樂庫',
    de: 'Mediathek konnte nicht geladen werden',
    fr: 'Impossible de charger votre bibliothèque',
    pt: 'Não foi possível carregar sua biblioteca',
    ko: '라이브러리를 불러올 수 없습니다',
  );
  String get listA => _text(
    ja: 'リスト A',
    en: 'List A',
    it: 'Lista A',
    es: 'Lista A',
    zhHans: '列表 A',
    zhHant: '清單 A',
    de: 'Liste A',
    fr: 'Liste A',
    pt: 'Lista A',
    ko: '목록 A',
  );
  String get listB => _text(
    ja: 'リスト B',
    en: 'List B',
    it: 'Lista B',
    es: 'Lista B',
    zhHans: '列表 B',
    zhHant: '清單 B',
    de: 'Liste B',
    fr: 'Liste B',
    pt: 'Lista B',
    ko: '목록 B',
  );
  String get chooseTwoLists => _text(
    ja: '2つのリストを選択',
    en: 'Choose two lists',
    it: 'Scegli due liste',
    es: 'Elige dos listas',
    zhHans: '选择两个列表',
    zhHant: '選擇兩個清單',
    de: 'Zwei Listen auswählen',
    fr: 'Choisissez deux listes',
    pt: 'Escolha duas listas',
    ko: '두 목록 선택',
  );
  String get chooseTwoListsMessage => _text(
    ja: 'プレイリスト、アーティスト、アルバムを選ぶと、再生キューを作成します。',
    en: 'Choose playlists, artists, or albums to create a queue.',
    it: 'Scegli playlist, artisti o album per creare una coda.',
    es: 'Elige playlists, artistas o álbumes para crear una cola.',
    zhHans: '选择播放列表、艺人或专辑来创建播放队列。',
    zhHant: '選擇播放列表、藝人或專輯來建立播放佇列。',
    de: 'Wähle Playlists, Künstler oder Alben, um eine Warteschlange zu erstellen.',
    fr: 'Choisissez des playlists, artistes ou albums pour créer une file.',
    pt: 'Escolha playlists, artistas ou álbuns para criar uma fila.',
    ko: '플레이리스트, 아티스트 또는 앨범을 선택해 재생 대기열을 만듭니다.',
  );
  String get noMatches => _text(
    ja: '一致する曲がありません',
    en: 'No matching songs',
    it: 'Nessun brano corrispondente',
    es: 'No hay canciones coincidentes',
    zhHans: '没有匹配的歌曲',
    zhHant: '沒有符合的歌曲',
    de: 'Keine passenden Songs',
    fr: 'Aucun morceau correspondant',
    pt: 'Nenhuma música correspondente',
    ko: '일치하는 곡이 없습니다',
  );
  String get noMatchesMessage => _text(
    ja: '条件を切り替えるか、別の組み合わせを選んでください。',
    en: 'Try another condition or choose a different combination.',
    it: 'Prova un altro criterio o scegli una combinazione diversa.',
    es: 'Prueba otra condición o elige otra combinación.',
    zhHans: '请切换条件或选择其他组合。',
    zhHant: '請切換條件或選擇其他組合。',
    de: 'Wähle eine andere Bedingung oder Kombination.',
    fr: 'Essayez une autre condition ou combinaison.',
    pt: 'Tente outra condição ou escolha outra combinação.',
    ko: '조건을 바꾸거나 다른 조합을 선택하세요.',
  );
  String get emptyQueue => _text(
    ja: '再生キューが空になりました',
    en: 'Your queue is empty',
    it: 'La coda è vuota',
    es: 'La cola está vacía',
    zhHans: '播放队列为空',
    zhHant: '播放佇列為空',
    de: 'Die Warteschlange ist leer',
    fr: 'La file est vide',
    pt: 'A fila está vazia',
    ko: '재생 대기열이 비었습니다',
  );
  String get emptyQueueMessage => _text(
    ja: '削除した曲は、リストや条件を変更すると再び候補に戻ります。',
    en: 'Removed songs return when you change lists or conditions.',
    it: 'I brani rimossi tornano quando cambi liste o criteri.',
    es: 'Las canciones eliminadas vuelven al cambiar listas o condiciones.',
    zhHans: '更改列表或条件后，已删除的歌曲会重新作为候选出现。',
    zhHant: '更改清單或條件後，已刪除的歌曲會重新成為候選。',
    de: 'Entfernte Songs kehren zurück, wenn du Listen oder Bedingungen änderst.',
    fr: 'Les morceaux supprimés reviennent si vous changez les listes ou conditions.',
    pt: 'Músicas removidas voltam ao alterar listas ou condições.',
    ko: '삭제한 곡은 목록이나 조건을 바꾸면 다시 후보로 돌아옵니다.',
  );
  String get delete => _text(
    ja: '削除',
    en: 'Delete',
    it: 'Elimina',
    es: 'Eliminar',
    zhHans: '删除',
    zhHant: '刪除',
    de: 'Löschen',
    fr: 'Supprimer',
    pt: 'Excluir',
    ko: '삭제',
  );
  String get undo => _text(
    ja: '元に戻す',
    en: 'Undo',
    it: 'Annulla',
    es: 'Deshacer',
    zhHans: '撤销',
    zhHant: '復原',
    de: 'Rückgängig',
    fr: 'Annuler',
    pt: 'Desfazer',
    ko: '실행 취소',
  );
  String get search => _text(
    ja: '検索',
    en: 'Search',
    it: 'Cerca',
    es: 'Buscar',
    zhHans: '搜索',
    zhHant: '搜尋',
    de: 'Suchen',
    fr: 'Rechercher',
    pt: 'Buscar',
    ko: '검색',
  );
  String get noSearchResults => _text(
    ja: '一致するリストがありません',
    en: 'No matching lists',
    it: 'Nessuna lista corrispondente',
    es: 'No hay listas coincidentes',
    zhHans: '没有匹配的列表',
    zhHant: '沒有符合的清單',
    de: 'Keine passenden Listen',
    fr: 'Aucune liste correspondante',
    pt: 'Nenhuma lista correspondente',
    ko: '일치하는 목록이 없습니다',
  );
  String get chooseList => _text(
    ja: '選択',
    en: 'Select',
    it: 'Seleziona',
    es: 'Seleccionar',
    zhHans: '选择',
    zhHant: '選擇',
    de: 'Auswählen',
    fr: 'Sélectionner',
    pt: 'Selecionar',
    ko: '선택',
  );
  String get common => 'A∩B';
  String get onlyA => 'A-B';
  String get onlyB => 'B-A';
  String get either => 'A∪B';
  String get playbackQueue => _text(
    ja: '再生キュー',
    en: 'Queue',
    it: 'Coda',
    es: 'Cola',
    zhHans: '播放队列',
    zhHant: '播放佇列',
    de: 'Warteschlange',
    fr: 'File',
    pt: 'Fila',
    ko: '재생 대기열',
  );
  String get nowPlayingQueue => _text(
    ja: '再生中',
    en: 'Now Playing',
    it: 'In riproduzione',
    es: 'En reproducción',
    zhHans: '正在播放',
    zhHant: '正在播放',
    de: 'Aktuelle Wiedergabe',
    fr: 'Lecture en cours',
    pt: 'Em reprodução',
    ko: '재생 중',
  );
  String get playInOrder => _text(
    ja: '再生',
    en: 'Play',
    it: 'Riproduci',
    es: 'Reproducir',
    zhHans: '播放',
    zhHant: '播放',
    de: 'Abspielen',
    fr: 'Lire',
    pt: 'Reproduzir',
    ko: '재생',
  );
  String get shufflePlay => _text(
    ja: 'シャッフル',
    en: 'Shuffle',
    it: 'Casuale',
    es: 'Aleatorio',
    zhHans: '随机播放',
    zhHant: '隨機播放',
    de: 'Zufällig',
    fr: 'Aléatoire',
    pt: 'Aleatório',
    ko: '셔플',
  );
  String get preparing => _text(
    ja: '準備中',
    en: 'Loading',
    it: 'Caricamento',
    es: 'Cargando',
    zhHans: '加载中',
    zhHant: '載入中',
    de: 'Lädt',
    fr: 'Chargement',
    pt: 'Carregando',
    ko: '로딩 중',
  );
  String get save => _text(
    ja: '保存',
    en: 'Save',
    it: 'Salva',
    es: 'Guardar',
    zhHans: '保存',
    zhHant: '儲存',
    de: 'Speichern',
    fr: 'Enregistrer',
    pt: 'Salvar',
    ko: '저장',
  );
  String get saveQueue => _text(
    ja: '再生キューを保存',
    en: 'Save Queue',
    it: 'Salva coda',
    es: 'Guardar cola',
    zhHans: '保存播放队列',
    zhHant: '儲存播放佇列',
    de: 'Warteschlange speichern',
    fr: 'Enregistrer la file',
    pt: 'Salvar fila',
    ko: '재생 대기열 저장',
  );
  String get queueName => _text(
    ja: '名前',
    en: 'Name',
    it: 'Nome',
    es: 'Nombre',
    zhHans: '名称',
    zhHant: '名稱',
    de: 'Name',
    fr: 'Nom',
    pt: 'Nome',
    ko: '이름',
  );
  String get rename => _text(
    ja: '名前を変更',
    en: 'Rename',
    it: 'Rinomina',
    es: 'Renombrar',
    zhHans: '重命名',
    zhHant: '重新命名',
    de: 'Umbenennen',
    fr: 'Renommer',
    pt: 'Renomear',
    ko: '이름 변경',
  );
  String get cancel => _text(
    ja: 'キャンセル',
    en: 'Cancel',
    it: 'Annulla',
    es: 'Cancelar',
    zhHans: '取消',
    zhHant: '取消',
    de: 'Abbrechen',
    fr: 'Annuler',
    pt: 'Cancelar',
    ko: '취소',
  );
  String get saveInApp => _text(
    ja: 'アプリ内に保存',
    en: 'Save in App',
    it: 'Salva nell’app',
    es: 'Guardar en la app',
    zhHans: '保存到应用内',
    zhHant: '儲存到 App 內',
    de: 'In der App speichern',
    fr: 'Enregistrer dans l’app',
    pt: 'Salvar no app',
    ko: '앱에 저장',
  );
  String get saveInMusic => _text(
    ja: 'Musicのプレイリストに保存',
    en: 'Save to Music Playlist',
    it: 'Salva nella playlist di Music',
    es: 'Guardar en playlist de Music',
    zhHans: '保存到“音乐”播放列表',
    zhHant: '儲存到「音樂」播放列表',
    de: 'In Music-Playlist speichern',
    fr: 'Enregistrer dans une playlist Music',
    pt: 'Salvar na playlist do Music',
    ko: 'Music 플레이리스트에 저장',
  );
  String get savedQueues => _text(
    ja: '保存済みキュー',
    en: 'Saved Queues',
    it: 'Code salvate',
    es: 'Colas guardadas',
    zhHans: '已保存队列',
    zhHant: '已儲存佇列',
    de: 'Gespeicherte Warteschlangen',
    fr: 'Files enregistrées',
    pt: 'Filas salvas',
    ko: '저장된 대기열',
  );
  String get savedTab => _text(
    ja: '保存済',
    en: 'Saved',
    it: 'Salvate',
    es: 'Guardadas',
    zhHans: '已保存',
    zhHant: '已儲存',
    de: 'Gespeichert',
    fr: 'Enregistrées',
    pt: 'Salvas',
    ko: '저장됨',
  );
  String get historyTab => _text(
    ja: '履歴',
    en: 'History',
    it: 'Cronologia',
    es: 'Historial',
    zhHans: '历史',
    zhHant: '歷史',
    de: 'Verlauf',
    fr: 'Historique',
    pt: 'Histórico',
    ko: '기록',
  );
  String get noSavedQueues => _text(
    ja: '保存済みキューはありません',
    en: 'No saved queues',
    it: 'Nessuna coda salvata',
    es: 'No hay colas guardadas',
    zhHans: '没有已保存队列',
    zhHant: '沒有已儲存佇列',
    de: 'Keine gespeicherten Warteschlangen',
    fr: 'Aucune file enregistrée',
    pt: 'Nenhuma fila salva',
    ko: '저장된 대기열이 없습니다',
  );
  String get noHistoryQueues => _text(
    ja: '再生履歴はありません',
    en: 'No playback history',
    it: 'Nessuna cronologia di riproduzione',
    es: 'No hay historial de reproducción',
    zhHans: '没有播放历史',
    zhHant: '沒有播放歷史',
    de: 'Kein Wiedergabeverlauf',
    fr: 'Aucun historique de lecture',
    pt: 'Nenhum histórico de reprodução',
    ko: '재생 기록이 없습니다',
  );
  String get openSaved => _text(
    ja: '保存済み',
    en: 'Saved',
    it: 'Salvate',
    es: 'Guardadas',
    zhHans: '已保存',
    zhHant: '已儲存',
    de: 'Gespeichert',
    fr: 'Enregistrées',
    pt: 'Salvas',
    ko: '저장됨',
  );

  String playbackError(Object error) => _text(
    ja: '再生を開始できませんでした: $error',
    en: 'Unable to start playback: $error',
    it: 'Impossibile avviare la riproduzione: $error',
    es: 'No se pudo iniciar la reproducción: $error',
    zhHans: '无法开始播放：$error',
    zhHant: '無法開始播放：$error',
    de: 'Wiedergabe konnte nicht gestartet werden: $error',
    fr: 'Impossible de lancer la lecture : $error',
    pt: 'Não foi possível iniciar a reprodução: $error',
    ko: '재생을 시작할 수 없습니다: $error',
  );
  String removedFromQueue(String title) => _text(
    ja: '$title を再生キューから削除しました',
    en: 'Removed $title from the queue',
    it: '$title rimosso dalla coda',
    es: '$title se eliminó de la cola',
    zhHans: '已从播放队列中删除 $title',
    zhHant: '已從播放佇列中刪除 $title',
    de: '$title aus der Warteschlange entfernt',
    fr: '$title a été retiré de la file',
    pt: '$title foi removida da fila',
    ko: '$title 곡을 대기열에서 삭제했습니다',
  );
  String savedInApp(String name) => _text(
    ja: '$name をアプリ内に保存しました',
    en: 'Saved $name in the app',
    it: '$name salvato nell’app',
    es: '$name se guardó en la app',
    zhHans: '已将 $name 保存到应用内',
    zhHant: '已將 $name 儲存到 App 內',
    de: '$name in der App gespeichert',
    fr: '$name enregistré dans l’app',
    pt: '$name foi salvo no app',
    ko: '$name 을(를) 앱에 저장했습니다',
  );
  String savedInMusic(String name) => _text(
    ja: '$name をMusicプレイリストに保存しました',
    en: 'Saved $name to Music playlists',
    it: '$name salvato nelle playlist di Music',
    es: '$name se guardó en playlists de Music',
    zhHans: '已将 $name 保存到“音乐”播放列表',
    zhHant: '已將 $name 儲存到「音樂」播放列表',
    de: '$name in Music-Playlists gespeichert',
    fr: '$name enregistré dans les playlists Music',
    pt: '$name foi salvo nas playlists do Music',
    ko: '$name 을(를) Music 플레이리스트에 저장했습니다',
  );
  String saveFailed(Object error) => _text(
    ja: '保存できませんでした: $error',
    en: 'Unable to save: $error',
    it: 'Impossibile salvare: $error',
    es: 'No se pudo guardar: $error',
    zhHans: '无法保存：$error',
    zhHant: '無法儲存：$error',
    de: 'Speichern fehlgeschlagen: $error',
    fr: 'Impossible d’enregistrer : $error',
    pt: 'Não foi possível salvar: $error',
    ko: '저장할 수 없습니다: $error',
  );

  String trackCount(int count) => _count(count);
  String collectionCount(int count) => _count(count);
  String seconds(int seconds) => _text(
    ja: '$seconds秒',
    en: '${seconds}s',
    it: '${seconds}s',
    es: '${seconds}s',
    zhHans: '$seconds 秒',
    zhHant: '$seconds 秒',
    de: '${seconds}s',
    fr: '${seconds}s',
    pt: '${seconds}s',
    ko: '$seconds초',
  );
  String overlapCount(int matching, int total) => _text(
    ja: '$matching曲一致 / $total曲',
    en: '$matching matching / $total songs',
    it: '$matching corrispondenze / $total brani',
    es: '$matching coincidencias / $total canciones',
    zhHans: '$matching 首匹配 / 共 $total 首',
    zhHant: '$matching 首符合 / 共 $total 首',
    de: '$matching Treffer / $total Songs',
    fr: '$matching correspondances / $total morceaux',
    pt: '$matching correspondências / $total músicas',
    ko: '$matching곡 일치 / 총 $total곡',
  );

  String _count(int count) => _text(
    ja: '$count曲',
    en: '$count songs',
    it: '$count brani',
    es: '$count canciones',
    zhHans: '$count 首',
    zhHant: '$count 首',
    de: '$count Songs',
    fr: '$count morceaux',
    pt: '$count músicas',
    ko: '$count곡',
  );

  String collectionTypeName(MusicCollectionType type) {
    return switch (type) {
      MusicCollectionType.playlist => _text(
        ja: 'プレイリスト',
        en: 'Playlist',
        it: 'Playlist',
        es: 'Playlist',
        zhHans: '播放列表',
        zhHant: '播放列表',
        de: 'Playlist',
        fr: 'Playlist',
        pt: 'Playlist',
        ko: '플레이리스트',
      ),
      MusicCollectionType.artist => _text(
        ja: 'アーティスト',
        en: 'Artist',
        it: 'Artista',
        es: 'Artista',
        zhHans: '艺人',
        zhHant: '藝人',
        de: 'Künstler',
        fr: 'Artiste',
        pt: 'Artista',
        ko: '아티스트',
      ),
      MusicCollectionType.album => _text(
        ja: 'アルバム',
        en: 'Album',
        it: 'Album',
        es: 'Álbum',
        zhHans: '专辑',
        zhHant: '專輯',
        de: 'Album',
        fr: 'Album',
        pt: 'Álbum',
        ko: '앨범',
      ),
    };
  }

  String patternName(_ColorPattern pattern) {
    return switch (pattern) {
      _ColorPattern.cyanViolet => 'Cyan x Violet',
      _ColorPattern.azureMagenta => 'Azure x Magenta',
      _ColorPattern.tealCoral => 'Teal x Coral',
      _ColorPattern.mintIndigo => 'Mint x Indigo',
      _ColorPattern.skyAmber => 'Sky x Amber',
      _ColorPattern.lavenderAqua => 'Lavender x Aqua',
    };
  }
}

class _VennPalette {
  const _VennPalette({
    required this.a,
    required this.b,
    required this.intersection,
    required this.outline,
  });

  final Color a;
  final Color b;
  final Color intersection;
  final Color outline;

  static _VennPalette forPattern(_ColorPattern pattern) {
    return switch (pattern) {
      _ColorPattern.cyanViolet => const _VennPalette(
        a: Color(0x5525B7F3),
        b: Color(0x557C5CFA),
        intersection: Color(0xCC3F7FF2),
        outline: Color(0x802F76D6),
      ),
      _ColorPattern.azureMagenta => const _VennPalette(
        a: Color(0x55238BFF),
        b: Color(0x55E95AA9),
        intersection: Color(0xCC8C63E8),
        outline: Color(0x806756CC),
      ),
      _ColorPattern.tealCoral => const _VennPalette(
        a: Color(0x5517A6A0),
        b: Color(0x55F27868),
        intersection: Color(0xCC85738D),
        outline: Color(0x80637886),
      ),
      _ColorPattern.mintIndigo => const _VennPalette(
        a: Color(0x5527C9A5),
        b: Color(0x55536DFE),
        intersection: Color(0xCC27A9C6),
        outline: Color(0x803A8EAE),
      ),
      _ColorPattern.skyAmber => const _VennPalette(
        a: Color(0x5536A9F7),
        b: Color(0x55F4B942),
        intersection: Color(0xCC66B88C),
        outline: Color(0x80739789),
      ),
      _ColorPattern.lavenderAqua => const _VennPalette(
        a: Color(0x559478F3),
        b: Color(0x5523C5CF),
        intersection: Color(0xCC538DDF),
        outline: Color(0x80627CBE),
      ),
    };
  }
}

class _PalettePreview extends StatelessWidget {
  const _PalettePreview({required this.palette});

  final _VennPalette palette;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 36,
      height: 28,
      child: CustomPaint(painter: _PalettePreviewPainter(palette)),
    );
  }
}

class _PalettePreviewPainter extends CustomPainter {
  const _PalettePreviewPainter(this.palette);

  final _VennPalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = size.height * 0.38;
    final left = Path()
      ..addOval(
        Rect.fromCircle(
          center: Offset(size.width * 0.4, size.height * 0.43),
          radius: radius,
        ),
      );
    final right = Path()
      ..addOval(
        Rect.fromCircle(
          center: Offset(size.width * 0.6, size.height * 0.57),
          radius: radius,
        ),
      );
    final intersection = Path.combine(PathOperation.intersect, left, right);
    final outline = Paint()
      ..color = palette.outline.withValues(alpha: 0.72)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    canvas.drawPath(left, Paint()..color = palette.a.withValues(alpha: 0.82));
    canvas.drawPath(right, Paint()..color = palette.b.withValues(alpha: 0.82));
    canvas.drawPath(intersection, Paint()..color = palette.intersection);
    canvas.drawPath(left, outline);
    canvas.drawPath(right, outline);
  }

  @override
  bool shouldRepaint(covariant _PalettePreviewPainter oldDelegate) {
    return oldDelegate.palette != palette;
  }
}

Color _readableAccent(Color color) {
  return color.withValues(alpha: 1).computeLuminance() > 0.38
      ? const Color(0xFF07517A)
      : color.withValues(alpha: 1);
}

Color _queueAccentColor(int index, _VennPalette palette) {
  final a = palette.a.withValues(alpha: 1);
  final b = palette.b.withValues(alpha: 1);
  final colors = [
    a,
    b,
    palette.intersection.withValues(alpha: 1),
    Color.lerp(a, b, 0.35)!,
  ];
  return colors[index % colors.length];
}

bool _sameTrackOrder(List<String> left, List<String> right) {
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) {
      return false;
    }
  }
  return true;
}

T? _enumByName<T extends Enum>(List<T> values, String? name) {
  if (name == null) {
    return null;
  }
  for (final value in values) {
    if (value.name == name) {
      return value;
    }
  }
  return null;
}

String _typeLabel(MusicCollectionType type, _Strings strings) {
  return strings.collectionTypeName(type);
}

IconData _typeIcon(MusicCollectionType type) {
  return switch (type) {
    MusicCollectionType.playlist => Icons.queue_music,
    MusicCollectionType.artist => Icons.person,
    MusicCollectionType.album => Icons.album,
  };
}

class _CollectionPicker extends StatelessWidget {
  const _CollectionPicker({
    required this.label,
    required this.type,
    required this.value,
    required this.collections,
    required this.strings,
    required this.accentColor,
    required this.showTrackCount,
    required this.onChanged,
    this.referenceCollection,
  });

  final String label;
  final MusicCollectionType type;
  final MusicCollection? value;
  final List<MusicCollection> collections;
  final _Strings strings;
  final Color accentColor;
  final MusicCollection? referenceCollection;
  final bool showTrackCount;
  final ValueChanged<MusicCollection> onChanged;

  @override
  Widget build(BuildContext context) {
    final selectedCollection = value;
    final selectableCollections = collections
        .where((collection) => collection.id != referenceCollection?.id)
        .toList(growable: false);
    final selectedType = selectedCollection?.type ?? type;
    final referenceIds = referenceCollection?.trackIds.toSet();
    final enabled = selectableCollections.isNotEmpty;
    final displayType = selectedCollection == null
        ? null
        : _typeLabel(selectedCollection.type, strings);

    final buttonLabel = selectedCollection == null
        ? strings.chooseList
        : '${selectedCollection.name} ($displayType)';

    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE1E7F8)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF07146F).withValues(alpha: 0.06),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (showTrackCount && value != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: accentColor.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      strings.trackCount(value!.trackIds.length),
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: _readableAccent(accentColor),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  backgroundColor: accentColor.withValues(alpha: 0.18),
                  foregroundColor: _readableAccent(accentColor),
                ),
                onPressed: !enabled
                    ? null
                    : () async {
                        final selected = await _showCollectionSheet(
                          context: context,
                          title: label,
                          collections: selectableCollections,
                          selected: selectedCollection,
                          initialType: selectedType,
                          referenceIds: referenceIds,
                        );
                        if (selected != null) {
                          onChanged(selected);
                        }
                      },
                icon: Icon(
                  selectedCollection == null
                      ? Icons.library_music_outlined
                      : _typeIcon(selectedCollection.type),
                ),
                label: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    buttonLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<MusicCollection> _sortedCollections(
    List<MusicCollection> source,
    Set<String>? referenceIds,
  ) {
    final sorted = [...source];
    if (referenceIds == null) {
      return sorted;
    }

    sorted.sort((left, right) {
      final rightOverlap = _overlapCount(right, referenceIds);
      final leftOverlap = _overlapCount(left, referenceIds);
      final overlapComparison = rightOverlap.compareTo(leftOverlap);
      if (overlapComparison != 0) {
        return overlapComparison;
      }

      final lengthComparison = right.trackIds.length.compareTo(
        left.trackIds.length,
      );
      if (lengthComparison != 0) {
        return lengthComparison;
      }

      return left.name.compareTo(right.name);
    });
    return sorted;
  }

  Future<MusicCollection?> _showCollectionSheet({
    required BuildContext context,
    required String title,
    required List<MusicCollection> collections,
    required MusicCollection? selected,
    required MusicCollectionType initialType,
    required Set<String>? referenceIds,
  }) async {
    return showModalBottomSheet<MusicCollection>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
      ),
      builder: (context) => _CollectionSheetContent(
        title: title,
        collections: collections,
        selected: selected,
        initialType: initialType,
        referenceIds: referenceIds,
        strings: strings,
        sortCollections: _sortedCollections,
      ),
    );
  }
}

typedef _CollectionSorter =
    List<MusicCollection> Function(
      List<MusicCollection> source,
      Set<String>? referenceIds,
    );

class _CollectionSheetContent extends StatefulWidget {
  const _CollectionSheetContent({
    required this.title,
    required this.collections,
    required this.selected,
    required this.initialType,
    required this.referenceIds,
    required this.strings,
    required this.sortCollections,
  });

  final String title;
  final List<MusicCollection> collections;
  final MusicCollection? selected;
  final MusicCollectionType initialType;
  final Set<String>? referenceIds;
  final _Strings strings;
  final _CollectionSorter sortCollections;

  @override
  State<_CollectionSheetContent> createState() =>
      _CollectionSheetContentState();
}

class _CollectionSheetContentState extends State<_CollectionSheetContent> {
  final _searchController = TextEditingController();
  late MusicCollectionType _selectedType = widget.initialType;
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final normalizedQuery = _query.trim().toLowerCase();
    final visibleCollections = widget.sortCollections(
      widget.collections
          .where((collection) => collection.type == _selectedType)
          .where(
            (collection) =>
                normalizedQuery.isEmpty ||
                collection.name.toLowerCase().contains(normalizedQuery),
          )
          .toList(growable: false),
      widget.referenceIds,
    );

    return DefaultTabController(
      length: MusicCollectionType.values.length,
      initialIndex: MusicCollectionType.values.indexOf(widget.initialType),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.72,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                widget.title,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            TabBar(
              labelColor: const Color(0xFF07146F),
              unselectedLabelColor: const Color(0xFF627095),
              indicatorColor: Theme.of(context).colorScheme.primary,
              onTap: (index) {
                setState(
                  () => _selectedType = MusicCollectionType.values[index],
                );
              },
              tabs: [
                for (final type in MusicCollectionType.values)
                  Tab(
                    icon: Icon(_typeIcon(type), size: 20),
                    text: _typeLabel(type, widget.strings),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: TextField(
                controller: _searchController,
                autofocus: false,
                decoration: InputDecoration(
                  hintText: widget.strings.search,
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                          icon: const Icon(Icons.close),
                        ),
                  filled: true,
                  fillColor: const Color(0xFFF3F6FF),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
            Expanded(
              child: visibleCollections.isEmpty
                  ? Center(child: Text(widget.strings.noSearchResults))
                  : ListView.separated(
                      padding: EdgeInsets.fromLTRB(
                        12,
                        4,
                        12,
                        16 + MediaQuery.paddingOf(context).bottom,
                      ),
                      itemCount: visibleCollections.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final collection = visibleCollections[index];
                        final isSelected = collection.id == widget.selected?.id;
                        final referenceIds = widget.referenceIds;

                        return ListTile(
                          leading: Icon(_typeIcon(collection.type)),
                          iconColor: Theme.of(context).colorScheme.primary,
                          title: Text(
                            collection.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(
                            referenceIds == null
                                ? widget.strings.collectionCount(
                                    collection.trackIds.length,
                                  )
                                : widget.strings.overlapCount(
                                    _overlapCount(collection, referenceIds),
                                    collection.trackIds.length,
                                  ),
                          ),
                          trailing: isSelected ? const Icon(Icons.check) : null,
                          onTap: () => Navigator.of(context).pop(collection),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

int _overlapCount(MusicCollection collection, Set<String> referenceIds) {
  return collection.trackIds
      .where((trackId) => referenceIds.contains(trackId))
      .length;
}

class _CollectionStage extends StatefulWidget {
  const _CollectionStage({
    required this.firstPicker,
    required this.secondPicker,
    required this.value,
    required this.palette,
    required this.strings,
    required this.onChanged,
  });

  final Widget firstPicker;
  final Widget secondPicker;
  final MixMode value;
  final _VennPalette palette;
  final _Strings strings;
  final ValueChanged<MixMode> onChanged;

  @override
  State<_CollectionStage> createState() => _CollectionStageState();
}

class _CollectionStageState extends State<_CollectionStage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _drift = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 18),
  )..repeat();

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final pickerWidth = constraints.maxWidth * 0.92;
        final buttonWidth = constraints.maxWidth * 0.3;

        return SizedBox(
          height: 464,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _StageVennPainter(
                    widget.value,
                    widget.palette,
                    _drift,
                  ),
                ),
              ),
              Positioned(
                left: 0,
                top: 8,
                width: pickerWidth,
                child: widget.firstPicker,
              ),
              Positioned(
                right: 0,
                bottom: 8,
                width: pickerWidth,
                child: widget.secondPicker,
              ),
              Positioned(
                top: 208,
                left: 0,
                width: buttonWidth,
                child: _SetChoiceButton(
                  mode: MixMode.onlyFirst,
                  value: widget.value,
                  palette: widget.palette,
                  strings: widget.strings,
                  onChanged: widget.onChanged,
                ),
              ),
              Positioned(
                top: 181,
                left: (constraints.maxWidth - buttonWidth) / 2,
                width: buttonWidth,
                child: _SetChoiceButton(
                  mode: MixMode.both,
                  value: widget.value,
                  palette: widget.palette,
                  strings: widget.strings,
                  onChanged: widget.onChanged,
                ),
              ),
              Positioned(
                top: 235,
                left: (constraints.maxWidth - buttonWidth) / 2,
                width: buttonWidth,
                child: _SetChoiceButton(
                  mode: MixMode.either,
                  value: widget.value,
                  palette: widget.palette,
                  strings: widget.strings,
                  onChanged: widget.onChanged,
                ),
              ),
              Positioned(
                top: 208,
                right: 0,
                width: buttonWidth,
                child: _SetChoiceButton(
                  mode: MixMode.onlySecond,
                  value: widget.value,
                  palette: widget.palette,
                  strings: widget.strings,
                  onChanged: widget.onChanged,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _StageVennPainter extends CustomPainter {
  _StageVennPainter(this.mode, this.palette, this.drift)
    : super(repaint: drift);

  final MixMode mode;
  final _VennPalette palette;
  final Animation<double> drift;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(
      Rect.fromLTRB(-size.width, -size.height, size.width * 2, size.height),
    );

    final phase = drift.value * math.pi * 2;
    final radius = size.width * 0.62;
    final leftCenter =
        Offset(size.width * 0.16, size.height * 0.25) +
        Offset(math.sin(phase) * 5, math.cos(phase) * 7);
    final rightCenter =
        Offset(size.width * 0.84, size.height * 0.74) +
        Offset(
          math.cos(phase + math.pi / 3) * 6,
          math.sin(phase + math.pi / 3) * 8,
        );
    final left = Path()
      ..addOval(Rect.fromCircle(center: leftCenter, radius: radius));
    final right = Path()
      ..addOval(Rect.fromCircle(center: rightCenter, radius: radius));
    final selected = switch (mode) {
      MixMode.both => Path.combine(PathOperation.intersect, left, right),
      MixMode.onlyFirst => Path.combine(PathOperation.difference, left, right),
      MixMode.onlySecond => Path.combine(PathOperation.difference, right, left),
      MixMode.either => Path.combine(PathOperation.union, left, right),
    };

    final leftPaint = Paint()..color = palette.a;
    final rightPaint = Paint()..color = palette.b;
    final intersectionPaint = Paint()..color = palette.intersection;
    final outlinePaint = Paint()
      ..color = palette.outline
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final selectedOutlinePaint = Paint()
      ..color = switch (mode) {
        MixMode.both => palette.intersection.withValues(alpha: 1),
        MixMode.onlyFirst => palette.a.withValues(alpha: 1),
        MixMode.onlySecond => palette.b.withValues(alpha: 1),
        MixMode.either => palette.outline.withValues(alpha: 1),
      }
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.2
      ..strokeJoin = StrokeJoin.round;

    canvas.drawPath(left, Paint()..color = palette.a.withValues(alpha: 0.14));
    canvas.drawPath(right, Paint()..color = palette.b.withValues(alpha: 0.14));
    switch (mode) {
      case MixMode.both:
        canvas.drawPath(selected, intersectionPaint);
      case MixMode.onlyFirst:
        canvas.drawPath(
          selected,
          leftPaint..color = palette.a.withValues(alpha: 0.72),
        );
      case MixMode.onlySecond:
        canvas.drawPath(
          selected,
          rightPaint..color = palette.b.withValues(alpha: 0.72),
        );
      case MixMode.either:
        canvas.drawPath(left, leftPaint);
        canvas.drawPath(right, rightPaint);
        canvas.drawPath(
          Path.combine(PathOperation.intersect, left, right),
          intersectionPaint,
        );
    }
    canvas.drawPath(left, outlinePaint);
    canvas.drawPath(right, outlinePaint);
    canvas.drawPath(selected, selectedOutlinePaint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _StageVennPainter oldDelegate) {
    return oldDelegate.mode != mode || oldDelegate.palette != palette;
  }
}

class _SetChoiceButton extends StatelessWidget {
  const _SetChoiceButton({
    required this.mode,
    required this.value,
    required this.palette,
    required this.strings,
    required this.onChanged,
  });

  final MixMode mode;
  final MixMode value;
  final _VennPalette palette;
  final _Strings strings;
  final ValueChanged<MixMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final selected = mode == value;
    final selectedColor = switch (mode) {
      MixMode.both => palette.intersection,
      MixMode.onlyFirst => palette.a.withValues(alpha: 1),
      MixMode.onlySecond => palette.b.withValues(alpha: 1),
      MixMode.either => const Color(0xFF07146F),
    };
    return Material(
      color: selected ? selectedColor : Colors.white,
      elevation: selected ? 2 : 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(
          color: selected ? selectedColor : const Color(0xFFD1DBF0),
        ),
      ),
      child: InkWell(
        onTap: () => onChanged(mode),
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          height: 44,
          child: Center(
            child: Text(
              _modeLabel(mode, strings),
              maxLines: 1,
              style: TextStyle(
                color: selected ? Colors.white : const Color(0xFF07146F),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _modeLabel(MixMode mode, _Strings strings) {
  return switch (mode) {
    MixMode.both => strings.common,
    MixMode.onlyFirst => strings.onlyA,
    MixMode.onlySecond => strings.onlyB,
    MixMode.either => strings.either,
  };
}

class _QueueHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _QueueHeaderDelegate({
    required this.enabled,
    required this.isLoading,
    required this.onPlay,
    required this.onShuffle,
    required this.onSave,
    required this.onOpenSaved,
    required this.loadedQueueName,
    required this.strings,
    required this.palette,
  });

  final bool enabled;
  final bool isLoading;
  final VoidCallback onPlay;
  final VoidCallback onShuffle;
  final VoidCallback onSave;
  final VoidCallback onOpenSaved;
  final String? loadedQueueName;
  final _Strings strings;
  final _VennPalette palette;

  double get _height => loadedQueueName == null ? 136 : 154;

  @override
  double get minExtent => _height;

  @override
  double get maxExtent => _height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: overlapsContent
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 14,
                  offset: const Offset(0, 6),
                ),
              ]
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
        child: _QueueHeader(
          enabled: enabled,
          isLoading: isLoading,
          onPlay: onPlay,
          onShuffle: onShuffle,
          onSave: onSave,
          onOpenSaved: onOpenSaved,
          loadedQueueName: loadedQueueName,
          strings: strings,
          palette: palette,
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _QueueHeaderDelegate oldDelegate) {
    return oldDelegate.enabled != enabled ||
        oldDelegate.isLoading != isLoading ||
        oldDelegate.loadedQueueName != loadedQueueName ||
        oldDelegate.strings != strings ||
        oldDelegate.palette != palette;
  }
}

class _QueueHeader extends StatelessWidget {
  const _QueueHeader({
    required this.enabled,
    required this.isLoading,
    required this.onPlay,
    required this.onShuffle,
    required this.onSave,
    required this.onOpenSaved,
    required this.loadedQueueName,
    required this.strings,
    required this.palette,
  });

  final bool enabled;
  final bool isLoading;
  final VoidCallback onPlay;
  final VoidCallback onShuffle;
  final VoidCallback onSave;
  final VoidCallback onOpenSaved;
  final String? loadedQueueName;
  final _Strings strings;
  final _VennPalette palette;

  @override
  Widget build(BuildContext context) {
    final a = palette.a.withValues(alpha: 1);
    final b = palette.b.withValues(alpha: 1);
    final mixed = palette.intersection.withValues(alpha: 1);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    strings.playbackQueue,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: _readableAccent(mixed),
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (loadedQueueName != null)
                    Text(
                      loadedQueueName!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ),
            IconButton(
              tooltip: strings.openSaved,
              onPressed: onOpenSaved,
              color: _readableAccent(a),
              icon: const Icon(Icons.folder_open_outlined),
            ),
            IconButton(
              tooltip: strings.save,
              onPressed: enabled ? onSave : null,
              color: _readableAccent(b),
              icon: const Icon(Icons.bookmark_add_outlined),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: _readableAccent(a),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: a.withValues(alpha: 0.16),
                ),
                onPressed: enabled && !isLoading ? onPlay : null,
                icon: isLoading
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow),
                label: Text(
                  isLoading ? strings.preparing : strings.playInOrder,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: _readableAccent(b),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: b.withValues(alpha: 0.16),
                ),
                onPressed: enabled && !isLoading ? onShuffle : null,
                icon: const Icon(Icons.shuffle),
                label: Text(strings.shufflePlay),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _BannerAdSlot extends StatefulWidget {
  const _BannerAdSlot();

  @override
  State<_BannerAdSlot> createState() => _BannerAdSlotState();
}

class _BannerAdSlotState extends State<_BannerAdSlot> {
  static const _iosBannerAdUnitId = 'ca-app-pub-5621442666872148/3373461343';
  static const _iosTestBannerAdUnitId =
      'ca-app-pub-3940256099942544/2934735716';

  BannerAd? _bannerAd;
  bool _isLoaded = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isIOS) {
      _bannerAd = BannerAd(
        adUnitId: kDebugMode ? _iosTestBannerAdUnitId : _iosBannerAdUnitId,
        size: AdSize.banner,
        request: const AdRequest(),
        listener: BannerAdListener(
          onAdLoaded: (_) {
            if (mounted) {
              setState(() => _isLoaded = true);
            }
          },
          onAdFailedToLoad: (ad, _) {
            ad.dispose();
            if (mounted) {
              setState(() => _bannerAd = null);
            }
          },
        ),
      )..load();
    }
  }

  @override
  void dispose() {
    _bannerAd?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      child: SafeArea(
        top: false,
        child: Container(
          height: 56,
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: Color(0xFFE1E7F8))),
          ),
          alignment: Alignment.center,
          child: SizedBox(
            width: AdSize.banner.width.toDouble(),
            height: AdSize.banner.height.toDouble(),
            child: _isLoaded && _bannerAd != null
                ? AdWidget(ad: _bannerAd!)
                : Container(
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF5F7FC),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFFD8DFF2)),
                    ),
                    child: Platform.isIOS
                        ? null
                        : Text(
                            'AD',
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: const Color(0xFF8995B4),
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                  ),
          ),
        ),
      ),
    );
  }
}

class _DeleteTrackBackground extends StatelessWidget {
  const _DeleteTrackBackground({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFE84B55),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 18),
      alignment: Alignment.centerRight,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.delete_outline, color: Colors.white),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _SavedQueueTile extends StatelessWidget {
  const _SavedQueueTile({
    required this.queue,
    required this.accentColor,
    required this.strings,
    required this.isRenaming,
    required this.renameController,
    required this.dragHandle,
    required this.onRename,
    required this.onCancelRename,
    required this.onSubmitRename,
    required this.onTap,
  });

  final SavedQueue queue;
  final Color accentColor;
  final _Strings strings;
  final bool isRenaming;
  final TextEditingController renameController;
  final Widget dragHandle;
  final VoidCallback? onRename;
  final VoidCallback onCancelRename;
  final VoidCallback onSubmitRename;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final readableAccent = _readableAccent(accentColor);

    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: accentColor.withValues(alpha: 0.28)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.queue_music, color: readableAccent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: isRenaming
                    ? TextField(
                        controller: renameController,
                        autofocus: true,
                        textInputAction: TextInputAction.done,
                        decoration: InputDecoration(
                          labelText: strings.queueName,
                          isDense: true,
                          border: const OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => onSubmitRename(),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            queue.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            strings.collectionCount(queue.trackIds.length),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: const Color(0xFF627095),
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ],
                      ),
              ),
              if (isRenaming) ...[
                IconButton(
                  tooltip: strings.cancel,
                  onPressed: onCancelRename,
                  icon: const Icon(Icons.close),
                ),
                IconButton(
                  tooltip: strings.save,
                  onPressed: onSubmitRename,
                  icon: const Icon(Icons.check),
                ),
              ] else ...[
                if (onRename != null)
                  IconButton(
                    tooltip: strings.rename,
                    onPressed: onRename,
                    icon: const Icon(Icons.edit_outlined),
                  ),
                dragHandle,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _TrackTile extends StatefulWidget {
  const _TrackTile({
    required this.track,
    required this.isPlaying,
    required this.palette,
    required this.gradientPeriodSeconds,
    required this.dragHandle,
    required this.onTap,
  });

  final Track track;
  final bool isPlaying;
  final _VennPalette palette;
  final int gradientPeriodSeconds;
  final Widget dragHandle;
  final VoidCallback onTap;

  @override
  State<_TrackTile> createState() => _TrackTileState();
}

class _TrackTileState extends State<_TrackTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _gradientController;

  @override
  void initState() {
    super.initState();
    _gradientController = AnimationController(
      vsync: this,
      duration: Duration(seconds: widget.gradientPeriodSeconds),
    );
    if (widget.isPlaying) {
      _gradientController.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant _TrackTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gradientPeriodSeconds != widget.gradientPeriodSeconds) {
      _gradientController.duration = Duration(
        seconds: widget.gradientPeriodSeconds,
      );
    }
    if (widget.isPlaying && !_gradientController.isAnimating) {
      _gradientController.repeat();
    } else if (!widget.isPlaying && _gradientController.isAnimating) {
      _gradientController.stop();
      _gradientController.value = 0;
    }
  }

  @override
  void dispose() {
    _gradientController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final colorA = widget.palette.a.withValues(alpha: 1);
    final colorB = widget.palette.b.withValues(alpha: 1);
    final mixColor = widget.palette.intersection.withValues(alpha: 1);
    final borderColor = widget.isPlaying ? mixColor : const Color(0xFFE1E7F8);
    final iconColor = widget.isPlaying ? Colors.white : colorScheme.primary;
    final textColor = widget.isPlaying
        ? const Color(0xFF0A1228)
        : colorScheme.onSurface;
    final metaColor = widget.isPlaying
        ? const Color(0xFF334155)
        : colorScheme.onSurfaceVariant;

    return AnimatedBuilder(
      animation: _gradientController,
      builder: (context, child) {
        final shift = _gradientController.value;
        final background = widget.isPlaying
            ? LinearGradient(
                begin: Alignment(-1 + shift * 2, 0),
                end: Alignment(1 + shift * 2, 0),
                colors: [
                  colorA.withValues(alpha: 0.07),
                  colorA.withValues(alpha: 0.07),
                  mixColor.withValues(alpha: 0.14),
                  mixColor.withValues(alpha: 0.14),
                  colorB.withValues(alpha: 0.07),
                  colorB.withValues(alpha: 0.07),
                  mixColor.withValues(alpha: 0.14),
                  mixColor.withValues(alpha: 0.14),
                  colorA.withValues(alpha: 0.07),
                ],
                stops: const [0, 0.16, 0.32, 0.42, 0.5, 0.66, 0.82, 0.92, 1],
                tileMode: TileMode.repeated,
              )
            : null;

        return DecoratedBox(
          decoration: BoxDecoration(
            color: widget.isPlaying ? null : Colors.white,
            gradient: background,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: borderColor,
              width: widget.isPlaying ? 1.6 : 1,
            ),
            boxShadow: widget.isPlaying
                ? [
                    BoxShadow(
                      color: mixColor.withValues(alpha: 0.08),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ]
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: widget.onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: widget.isPlaying
                            ? null
                            : const Color(0xFFF0F4FF),
                        gradient: widget.isPlaying
                            ? LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [colorA, colorB],
                              )
                            : null,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        widget.isPlaying ? Icons.equalizer : Icons.music_note,
                        color: iconColor,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: textColor,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${widget.track.artist} - ${widget.track.album}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: metaColor),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      widget.track.formattedDuration,
                      style: TextStyle(
                        color: metaColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconTheme(
                      data: IconThemeData(
                        color: widget.isPlaying
                            ? _readableAccent(mixColor).withValues(alpha: 0.78)
                            : colorScheme.outline,
                      ),
                      child: widget.dragHandle,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: colorScheme.primary),
            const SizedBox(height: 12),
            Text(
              title,
              style: textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              message,
              style: textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
