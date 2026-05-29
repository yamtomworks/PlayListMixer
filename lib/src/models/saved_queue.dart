enum SavedQueueKind { saved, history }

class SavedQueue {
  const SavedQueue({
    required this.id,
    required this.name,
    required this.trackIds,
    this.kind = SavedQueueKind.saved,
  });

  final String id;
  final String name;
  final List<String> trackIds;
  final SavedQueueKind kind;

  SavedQueue copyWith({
    String? name,
    List<String>? trackIds,
    SavedQueueKind? kind,
  }) {
    return SavedQueue(
      id: id,
      name: name ?? this.name,
      trackIds: trackIds ?? this.trackIds,
      kind: kind ?? this.kind,
    );
  }
}
