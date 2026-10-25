/// One row of the local media mirror.
///
/// Everything here is copied out of a TDLib object; nothing is inferred. The
/// record is what the app sorts, pages and filters on, so it has to survive a
/// process restart without the network being reachable.
library;

int? _asInt(Object? v) {
  if (v is int) return v;
  if (v is double) return v.round();
  if (v is String) return int.tryParse(v);
  return null;
}

String? _asString(Object? v) => v is String ? v : null;

bool _asBool(Object? v) => v is bool ? v : false;

Map<String, Object?> _asMap(Object? v) =>
    v is Map ? v.cast<String, Object?>() : const <String, Object?>{};

List<Map<String, Object?>> _asList(Object? v) => v is List
    ? v.whereType<Map>().map((e) => e.cast<String, Object?>()).toList()
    : const <Map<String, Object?>>[];

enum MediaKind { video, photo, document, animation, unknown }

extension MediaKindCodec on MediaKind {
  String get code => name;

  static MediaKind fromCode(String? code) => switch (code) {
        'video' => MediaKind.video,
        'photo' => MediaKind.photo,
        'document' => MediaKind.document,
        'animation' => MediaKind.animation,
        _ => MediaKind.unknown,
      };
}

class MediaRecord {
  const MediaRecord({
    required this.chatId,
    required this.messageId,
    required this.fileId,
    required this.kind,
    this.width,
    this.height,
    this.durationSeconds,
    this.sizeBytes = 0,
    this.fileName,
    this.mimeType,
    this.caption,
    this.messageDateUnix = 0,
    this.favorite = false,
    this.hasProtectedContent = false,
  });

  final int chatId;
  final int messageId;
  final int fileId;
  final MediaKind kind;
  final int? width;
  final int? height;
  final int? durationSeconds;
  final int sizeBytes;
  final String? fileName;
  final String? mimeType;

  /// Message caption / text, lower-cased once at index time so search does not
  /// re-fold the same string on every keystroke.
  final String? caption;

  /// Seconds since epoch, as reported by TDLib `message.date`.
  final int messageDateUnix;
  final bool favorite;

  /// Telegram-side content protection flag. Kept so the UI can explain why a
  /// media item is not downloadable instead of failing silently.
  final bool hasProtectedContent;

  /// `chatId:messageId` — the dedupe key for incremental sync.
  String get key => '$chatId:$messageId';

  bool get isVideo => kind == MediaKind.video;

  MediaRecord copyWith({bool? favorite}) => MediaRecord(
        chatId: chatId,
        messageId: messageId,
        fileId: fileId,
        kind: kind,
        width: width,
        height: height,
        durationSeconds: durationSeconds,
        sizeBytes: sizeBytes,
        fileName: fileName,
        mimeType: mimeType,
        caption: caption,
        messageDateUnix: messageDateUnix,
        favorite: favorite ?? this.favorite,
        hasProtectedContent: hasProtectedContent,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'c': chatId,
        'm': messageId,
        'f': fileId,
        'k': kind.code,
        if (width != null) 'w': width,
        if (height != null) 'h': height,
        if (durationSeconds != null) 'd': durationSeconds,
        if (sizeBytes != 0) 's': sizeBytes,
        if (fileName != null) 'n': fileName,
        if (mimeType != null) 't': mimeType,
        if (caption != null && caption!.isNotEmpty) 'cap': caption,
        if (messageDateUnix != 0) 'date': messageDateUnix,
        if (hasProtectedContent) 'p': true,
      };

  static MediaRecord? fromJson(Map<String, Object?>? json) {
    if (json == null) return null;
    final chatId = _asInt(json['c']);
    final messageId = _asInt(json['m']);
    if (chatId == null || messageId == null) return null;
    return MediaRecord(
      chatId: chatId,
      messageId: messageId,
      fileId: _asInt(json['f']) ?? 0,
      kind: MediaKindCodec.fromCode(_asString(json['k'])),
      width: _asInt(json['w']),
      height: _asInt(json['h']),
      durationSeconds: _asInt(json['d']),
      sizeBytes: _asInt(json['s']) ?? 0,
      fileName: _asString(json['n']),
      mimeType: _asString(json['t']),
      caption: _asString(json['cap']),
      messageDateUnix: _asInt(json['date']) ?? 0,
      hasProtectedContent: _asBool(json['p']),
    );
  }

  /// Builds a record from a TDLib `message` object. Returns null for messages
  /// that carry no media this app indexes (text, service messages, ...).
  static MediaRecord? fromMessage({
    required int chatId,
    required Map<String, Object?> message,
  }) {
    final content = _asMap(message['content']);
    final contentType = _asString(content['@type']) ?? '';
    final messageId = _asInt(message['id']);
    if (messageId == null) return null;

    final base = <String, Object?>{
      'chatId': chatId,
      'messageId': messageId,
      'date': _asInt(message['date']) ?? 0,
      'protected': _asBool(message['has_protected_content']),
      'caption': _captionOf(content),
    };

    switch (contentType) {
      case 'messageVideo':
        return _fromFileBacked(
          base: base,
          media: _asMap(content['video']),
          fileKey: 'video',
          kind: MediaKind.video,
          widthKey: 'width',
          heightKey: 'height',
          durationKey: 'duration',
        );
      case 'messageAnimation':
        return _fromFileBacked(
          base: base,
          media: _asMap(content['animation']),
          fileKey: 'animation',
          kind: MediaKind.animation,
          widthKey: 'width',
          heightKey: 'height',
          durationKey: 'duration',
        );
      case 'messageVideoNote':
        return _fromFileBacked(
          base: base,
          media: _asMap(content['video_note']),
          fileKey: 'video',
          kind: MediaKind.video,
          durationKey: 'duration',
        );
      case 'messageDocument':
        return _fromFileBacked(
          base: base,
          media: _asMap(content['document']),
          fileKey: 'document',
          kind: MediaKind.document,
        );
      case 'messagePhoto':
        return _fromPhoto(base: base, photo: _asMap(content['photo']));
      default:
        return null;
    }
  }

  static MediaRecord _fromFileBacked({
    required Map<String, Object?> base,
    required Map<String, Object?> media,
    required String fileKey,
    required MediaKind kind,
    String? widthKey,
    String? heightKey,
    String? durationKey,
  }) {
    final file = _asMap(media[fileKey]);
    return MediaRecord(
      chatId: base['chatId']! as int,
      messageId: base['messageId']! as int,
      fileId: _asInt(file['id']) ?? 0,
      kind: kind,
      width: widthKey == null ? null : _asInt(media[widthKey]),
      height: heightKey == null ? null : _asInt(media[heightKey]),
      durationSeconds: durationKey == null ? null : _asInt(media[durationKey]),
      sizeBytes: _asInt(file['expected_size']) ?? 0,
      fileName: _asString(media['file_name']) ?? _asString(file['name']),
      mimeType: _asString(media['mime_type']),
      caption: base['caption'] as String?,
      messageDateUnix: base['date']! as int,
      hasProtectedContent: base['protected']! as bool,
    );
  }

  /// Photos come as a list of sizes; the largest one is the one worth indexing
  /// (its file id is what a download has to target).
  static MediaRecord? _fromPhoto({
    required Map<String, Object?> base,
    required Map<String, Object?> photo,
  }) {
    final sizes = _asList(photo['sizes']);
    if (sizes.isEmpty) return null;
    Map<String, Object?> best = sizes.first;
    var bestArea = 0;
    for (final size in sizes) {
      final w = _asInt(size['width']) ?? 0;
      final h = _asInt(size['height']) ?? 0;
      if (w * h >= bestArea) {
        bestArea = w * h;
        best = size;
      }
    }
    final file = _asMap(best['photo']);
    return MediaRecord(
      chatId: base['chatId']! as int,
      messageId: base['messageId']! as int,
      fileId: _asInt(file['id']) ?? 0,
      kind: MediaKind.photo,
      width: _asInt(best['width']),
      height: _asInt(best['height']),
      sizeBytes: _asInt(file['expected_size']) ?? 0,
      caption: base['caption'] as String?,
      messageDateUnix: base['date']! as int,
      hasProtectedContent: base['protected']! as bool,
    );
  }

  /// Telegram caption, folded to lower case once at index time.
  ///
  /// TDLib hands captions over as `formattedText`; only `text` matters here —
  /// formatting entities are irrelevant to a keyword filter. The 512-char cap
  /// keeps the append-only journal from being inflated by a wall of text that
  /// no one will ever read in a one-line overlay.
  static String? _captionOf(Map<String, Object?> content) {
    final caption = _asMap(content['caption']);
    final text = _asString(caption['text'])?.trim();
    if (text == null || text.isEmpty) return null;
    final capped = text.length > 512 ? text.substring(0, 512) : text;
    return capped.toLowerCase();
  }

  @override
  String toString() =>
      'MediaRecord($chatId/$messageId ${kind.name} '
      '${width ?? '?'}x${height ?? '?'} ${durationSeconds ?? '?'}s)';
}
