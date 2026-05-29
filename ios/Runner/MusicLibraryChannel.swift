import Flutter
import MediaPlayer

final class MusicLibraryChannel: NSObject {
  private let player = MPMusicPlayerController.systemMusicPlayer
  private let savedQueuesKey = "playlist_mixer.saved_queues"
  private let languageKey = "playlist_mixer.settings.language"
  private let colorPatternKey = "playlist_mixer.settings.color_pattern"

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "playlist_mixer/music_library",
      binaryMessenger: messenger
    )
    let instance = MusicLibraryChannel()
    channel.setMethodCallHandler(instance.handle)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    Task { @MainActor in
      do {
        switch call.method {
        case "loadCollections":
          try await authorizeIfNeeded()
          result(loadCollections())
        case "loadTracks":
          try await authorizeIfNeeded()
          result(loadTracks())
        case "playTracks":
          try await authorizeIfNeeded()
          guard
            let arguments = call.arguments as? [String: Any],
            let trackIds = arguments["trackIds"] as? [String]
          else {
            result(
              FlutterError(
                code: "invalid_arguments",
                message: "trackIds is required.",
                details: nil
              )
            )
            return
          }
          try play(trackIds: trackIds)
          result(nil)
        case "loadNowPlayingTrackId":
          result(loadNowPlayingTrackId())
        case "loadSavedQueues":
          result(loadSavedQueues())
        case "loadSettings":
          result(loadSettings())
        case "saveSettings":
          guard let settings = call.arguments as? [String: Any] else {
            throw MusicLibraryError.invalidArguments
          }
          saveSettings(settings)
          result(nil)
        case "saveQueue":
          guard let queue = call.arguments as? [String: Any] else {
            throw MusicLibraryError.invalidArguments
          }
          saveQueue(queue)
          result(nil)
        case "saveSavedQueues":
          guard let queues = call.arguments as? [[String: Any]] else {
            throw MusicLibraryError.invalidArguments
          }
          saveSavedQueues(queues)
          result(nil)
        case "deleteSavedQueue":
          guard
            let arguments = call.arguments as? [String: Any],
            let queueId = arguments["id"] as? String
          else {
            throw MusicLibraryError.invalidArguments
          }
          deleteSavedQueue(queueId)
          result(nil)
        case "saveToMusicPlaylist":
          try await authorizeIfNeeded()
          guard
            let arguments = call.arguments as? [String: Any],
            let name = arguments["name"] as? String,
            let trackIds = arguments["trackIds"] as? [String]
          else {
            throw MusicLibraryError.invalidArguments
          }
          try await saveToMusicPlaylist(name: name, trackIds: trackIds)
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      } catch let error as MusicLibraryError {
        result(error.flutterError)
      } catch {
        result(
          FlutterError(
            code: "music_library_error",
            message: error.localizedDescription,
            details: nil
          )
        )
      }
    }
  }

  private func authorizeIfNeeded() async throws {
    let status = MPMediaLibrary.authorizationStatus()
    if status == .authorized {
      return
    }

    let requestedStatus = await withCheckedContinuation { continuation in
      MPMediaLibrary.requestAuthorization { status in
        continuation.resume(returning: status)
      }
    }

    guard requestedStatus == .authorized else {
      throw MusicLibraryError.notAuthorized
    }
  }

  private func loadCollections() -> [[String: Any]] {
    var collections: [[String: Any]] = []

    collections.append(
      contentsOf: MPMediaQuery.playlists().collections?.compactMap { collection in
        guard let playlist = collection as? MPMediaPlaylist else {
          return nil
        }
        return collectionMap(
          id: String(playlist.persistentID),
          name: playlist.name ?? "Untitled Playlist",
          type: "playlist",
          items: playlist.items
        )
      } ?? []
    )

    collections.append(
      contentsOf: MPMediaQuery.artists().collections?.compactMap { collection in
        guard let representativeItem = collection.representativeItem else {
          return nil
        }
        return collectionMap(
          id: "artist-\(representativeItem.artistPersistentID)",
          name: representativeItem.artist ?? "Unknown Artist",
          type: "artist",
          items: collection.items
        )
      } ?? []
    )

    collections.append(
      contentsOf: MPMediaQuery.albums().collections?.compactMap { collection in
        guard let representativeItem = collection.representativeItem else {
          return nil
        }
        return collectionMap(
          id: "album-\(representativeItem.albumPersistentID)",
          name: representativeItem.albumTitle ?? "Unknown Album",
          type: "album",
          items: collection.items
        )
      } ?? []
    )

    return collections
  }

  private func loadTracks() -> [[String: Any]] {
    return MPMediaQuery.songs().items?.map(trackMap) ?? []
  }

  private func play(trackIds: [String]) throws {
    let availableItems = MPMediaQuery.songs().items ?? []
    let itemsById = Dictionary(
      uniqueKeysWithValues: availableItems.map { (String($0.persistentID), $0) }
    )
    let items = trackIds.compactMap { itemsById[$0] }

    guard !items.isEmpty else {
      throw MusicLibraryError.noPlayableTracks
    }

    let collection = MPMediaItemCollection(items: items)
    player.setQueue(with: collection)
    player.play()
  }

  private func loadNowPlayingTrackId() -> String? {
    guard player.playbackState == .playing, let item = player.nowPlayingItem else {
      return nil
    }
    return String(item.persistentID)
  }

  private func loadSavedQueues() -> [[String: Any]] {
    return UserDefaults.standard.array(forKey: savedQueuesKey) as? [[String: Any]] ?? []
  }

  private func loadSettings() -> [String: Any] {
    return [
      "language": UserDefaults.standard.string(forKey: languageKey) ?? "japanese",
      "colorPattern": UserDefaults.standard.string(forKey: colorPatternKey) ?? "cyanViolet"
    ]
  }

  private func saveSettings(_ settings: [String: Any]) {
    if let language = settings["language"] as? String {
      UserDefaults.standard.set(language, forKey: languageKey)
    }
    if let colorPattern = settings["colorPattern"] as? String {
      UserDefaults.standard.set(colorPattern, forKey: colorPatternKey)
    }
  }

  private func saveQueue(_ queue: [String: Any]) {
    guard let queueId = queue["id"] as? String else {
      return
    }
    var savedQueues = loadSavedQueues()
    savedQueues.removeAll { existing in
      existing["id"] as? String == queueId
    }
    savedQueues.insert(queue, at: 0)
    UserDefaults.standard.set(savedQueues, forKey: savedQueuesKey)
  }

  private func saveSavedQueues(_ queues: [[String: Any]]) {
    UserDefaults.standard.set(queues, forKey: savedQueuesKey)
  }

  private func deleteSavedQueue(_ queueId: String) {
    var savedQueues = loadSavedQueues()
    savedQueues.removeAll { queue in
      queue["id"] as? String == queueId
    }
    UserDefaults.standard.set(savedQueues, forKey: savedQueuesKey)
  }

  private func saveToMusicPlaylist(name: String, trackIds: [String]) async throws {
    let availableItems = MPMediaQuery.songs().items ?? []
    let itemsById = Dictionary(
      uniqueKeysWithValues: availableItems.map { (String($0.persistentID), $0) }
    )
    let items = trackIds.compactMap { itemsById[$0] }
    guard !items.isEmpty else {
      throw MusicLibraryError.noPlayableTracks
    }

    let metadata = MPMediaPlaylistCreationMetadata(name: name)
    metadata.descriptionText = "Created with Playlist Mixer"
    let playlist = try await MPMediaLibrary.default().getPlaylist(
      with: UUID(),
      creationMetadata: metadata
    )

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      playlist.add(items) { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  private func collectionMap(
    id: String,
    name: String,
    type: String,
    items: [MPMediaItem]
  ) -> [String: Any] {
    [
      "id": id,
      "name": name,
      "type": type,
      "trackIds": items.map { String($0.persistentID) },
    ]
  }

  private func trackMap(_ item: MPMediaItem) -> [String: Any] {
    [
      "id": String(item.persistentID),
      "title": item.title ?? "Untitled Track",
      "artist": item.artist ?? "Unknown Artist",
      "album": item.albumTitle ?? "Unknown Album",
      "durationMilliseconds": Int(item.playbackDuration * 1000),
    ]
  }
}

private enum MusicLibraryError: Error {
  case notAuthorized
  case noPlayableTracks
  case invalidArguments

  var flutterError: FlutterError {
    switch self {
    case .notAuthorized:
      return FlutterError(
        code: "not_authorized",
        message: "Musicライブラリへのアクセスが許可されていません。",
        details: nil
      )
    case .noPlayableTracks:
      return FlutterError(
        code: "no_playable_tracks",
        message: "再生できる曲が見つかりませんでした。",
        details: nil
      )
    case .invalidArguments:
      return FlutterError(
        code: "invalid_arguments",
        message: "Required arguments are missing.",
        details: nil
      )
    }
  }
}
