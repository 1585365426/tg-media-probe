/// Who asked TDLib for bytes, and how many bytes that request really moved.
///
/// `downloadFile` returns as soon as TDLib accepts it; the transfer then runs
/// in the background and the only evidence of how far it got is `updateFile`.
/// That gap is why "the video downloads 152 MB before it plays" kept being
/// attributed to the wrong caller: the request and its growth were never
/// recorded next to each other.
///
/// Every call is recorded with the caller that issued it, and every byte TDLib
/// then writes is attributed to the call that was open for that file. TDLib
/// runs exactly one transfer per file id, so that attribution is exact rather
/// than statistical.
library;

/// Which code path sent a `downloadFile`.
///
/// The list is closed on purpose: a new caller has to be named here, which
/// means a new call site cannot silently show up as [unknown] in a device
/// report.
enum DownloadCaller {
  /// The play itself — the window the player opens on.
  player,

  /// Streaming V2: a window steered by `AVAssetResourceLoader`'s requests.
  resourceLoader,

  /// Streaming V1: a window steered by the loopback HTTP proxy.
  proxy,

  /// A neighbour warmed before the user reaches it.
  preload,

  /// The growing-file reader: an observer, never a downloader. Exists in the
  /// enum so a violation can be *named* if one ever shows up.
  growingFileReader,

  /// The Downloader: the only caller allowed to send `downloadFile` at all,
  /// and the only caller allowed `limit = 0`.
  downloader,

  /// A call site that has not been tagged yet. Should be zero.
  unknown;

  String get label => switch (this) {
        DownloadCaller.player => 'PLAYER',
        DownloadCaller.resourceLoader => 'RESOURCE_LOADER',
        DownloadCaller.proxy => 'PROXY',
        DownloadCaller.preload => 'PRELOAD',
        DownloadCaller.growingFileReader => 'GROWING_FILE_READER',
        // Named plainly: this is the download authority, not a fallback.
        // The one whole-file request a B+ play makes belongs here.
        DownloadCaller.downloader => 'DOWNLOADER',
        DownloadCaller.unknown => 'UNKNOWN',
      };

  /// Callers whose reaching TDLib's download API is an architecture
  /// violation under B+. The loopback proxy is history-compatible code, not
  /// an AUTO path, and is therefore policed by the chain rather than here.
  static const Set<DownloadCaller> forbiddenDownloaders = {
    DownloadCaller.player,
    DownloadCaller.resourceLoader,
    DownloadCaller.growingFileReader,
    DownloadCaller.preload,
  };
}

/// One `downloadFile` and what came of it.
class DownloadCall {
  DownloadCall({
    required this.seq,
    required this.at,
    required this.fileId,
    required this.caller,
    required this.offset,
    required this.limit,
    required this.priority,
    required this.synchronous,
    required this.chatId,
    required this.messageId,
    required this.generation,
    this.fileUniqueId = '',
    this.diskBefore = -1,
    required this.cause,
    required this.startedFrom,
  });

  /// 1-based, per audit instance — the order the requests were sent in.
  final int seq;
  final DateTime at;
  final int fileId;
  final DownloadCaller caller;

  /// `downloadFile.offset`.
  final int offset;

  /// `downloadFile.limit`. **0 means "to the end of the file"** — the shape
  /// that must never be used for a play window.
  final int limit;

  final int priority;
  final bool synchronous;

  final int chatId;
  final int messageId;
  final int generation;

  /// TDLib's stable id for the file, when the play knows one.
  final String fileUniqueId;

  /// Free disk space when the call was sent; -1 when not measured.
  final int diskBefore;

  /// Why this window exists, in the caller's own words: `first window`,
  /// `av=1048576`, `continue`, `sequential`, `whole file`.
  final String cause;

  /// `download_offset + downloaded_size` for the file when the call was sent.
  final int startedFrom;

  /// Bytes TDLib wrote for this file while this call was the open one.
  int grew = 0;

  /// Highest `download_offset + downloaded_size` seen during this call.
  int reached = 0;

  /// Disk space observed when the transfer ended; -1 until stamped.
  int diskAfter = -1;

  /// True when TDLib was asked for the rest of the file.
  bool get unbounded => limit <= 0;

  /// Last byte the request can produce, or -1 when unbounded.
  int get windowEnd => limit <= 0 ? -1 : offset + limit - 1;

  /// The line a device report prints. Every field the task asked for is here.
  String describe() {
    final window = unbounded ? 'limit=WHOLE_FILE' : 'limit=$limit';
    final disk = diskAfter >= 0 ? ' diskAfter=$diskAfter' : '';
    return '#$seq caller=${caller.label} file=$fileId '
        'msg=$messageId chat=$chatId gen=$generation '
        '${fileUniqueId.isEmpty ? '' : 'uid=$fileUniqueId '}'
        'offset=$offset $window priority=$priority '
        'sync=${synchronous ? 'true' : 'false'} '
        'before=$startedFrom grew=$grew '
        '${diskBefore >= 0 ? 'diskBefore=$diskBefore ' : ''}'
        'cause="$cause"$disk';
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'seq': seq,
        'at': at.toIso8601String(),
        'fileId': fileId,
        'chatId': chatId,
        'messageId': messageId,
        'generation': generation,
        'caller': caller.label,
        'offset': offset,
        'limit': limit,
        'unbounded': unbounded,
        'priority': priority,
        'synchronous': synchronous,
        'cause': cause,
        'startedFrom': startedFrom,
        'grew': grew,
        'reached': reached,
      };
}

/// The audit log: every request, every byte attributed.
class DownloadAudit {
  /// Enough for a long play (one call per window step) without growing
  /// without bound over a session.
  static const int maxCalls = 400;

  final List<DownloadCall> _calls = <DownloadCall>[];

  /// The call currently open per file id. TDLib keeps one transfer per file,
  /// so "the last request for this file" is exactly "the call that is
  /// producing these bytes".
  final Map<int, DownloadCall> _open = <int, DownloadCall>{};

  /// Last observed `(downloadOffset, downloadedSize)` per file, so growth is
  /// only counted inside one window. A window move resets `downloaded_size`,
  /// and treating that reset as growth is how a 1.4 GB offset appeared as
  /// "1.4 GB downloaded" in an earlier report.
  final Map<int, (int, int)> _last = <int, (int, int)>{};

  /// Context stamped onto every call, set by the resolver when a play starts.
  int chatId = 0;
  int messageId = 0;
  int generation = 0;
  String fileUniqueId = '';

  /// A B+ rule breach that was caught at runtime: a forbidden caller sent a
  /// download, or a play tried to run with no room on disk. Non-empty means
  /// the report must be read before the code that produced it is trusted.
  final List<String> _violations = <String>[];

  List<String> get violations => List<String>.unmodifiable(_violations);

  void noteArchitectureViolation(String detail) => _violations.add(detail);

  int _seq = 0;

  /// Whether a whole-file `downloadFile` (`limit: 0`) may be sent at all.
  ///
  /// A play starts with this **allowed** and loses it the moment a streaming
  /// transport is entered ([forbidWholeFile]). From that point on, "the stream
  /// failed" must never be allowed to become "download the whole film".
  ///
  /// The device report is why this exists as a hard stop rather than a
  /// convention: a 4.9 MB proxy stall on a 622 MB video became
  /// `caller=FULL_DOWNLOAD limit=WHOLE_FILE grew=622067712`,
  /// `downloadedAtFirstPlayback=593 MB`, `firstPlayback=162.3 s`. Every layer
  /// that decision passed through *chose* it deliberately; nothing refused it.
  bool wholeFileAllowed = true;

  String? _wholeFileRevokedBy;

  /// The whole-file requests refused during this play, one line each. A
  /// non-empty list means some code path tried to download a film to get a
  /// first frame, and was stopped.
  final List<String> _blocked = <String>[];

  List<DownloadCall> get calls => List<DownloadCall>.unmodifiable(_calls);

  int get count => _calls.length;

  /// Why the whole-file door was closed, for the report.
  String? get wholeFileRevokedBy => _wholeFileRevokedBy;

  List<String> get blockedWholeFile => List<String>.unmodifiable(_blocked);

  int get blockedWholeFileCount => _blocked.length;

  /// Closes the whole-file door for the rest of the play.
  void forbidWholeFile(String why) {
    if (!wholeFileAllowed) return;
    wholeFileAllowed = false;
    _wholeFileRevokedBy = why;
  }

  /// Opens it again — called once per play, by the controller, before the
  /// transport chain starts.
  ///
  /// Deliberately not part of [reset]: `beginPlay` runs again on every
  /// `_streamOnce` retry, and a retry must not reopen a door the failed
  /// attempt closed.
  void allowWholeFile() {
    wholeFileAllowed = true;
    _wholeFileRevokedBy = null;
    _blocked.clear();
  }

  /// Records a refused whole-file attempt. The caller throws with the same
  /// words, so the panel and the exception cannot disagree.
  void noteBlockedWholeFile({
    required int fileId,
    required DownloadCaller caller,
    required String cause,
  }) {
    _blocked.add('file=$fileId caller=${caller.label} '
        'cause="${cause.isEmpty ? '-' : cause}"');
  }

  /// Stamps the identity every following call is attributed to.
  void tag({
    int? chatId,
    int? messageId,
    int? generation,
    String? fileUniqueId,
  }) {
    if (chatId != null) this.chatId = chatId;
    if (messageId != null) this.messageId = messageId;
    if (generation != null) this.generation = generation;
    if (fileUniqueId != null) this.fileUniqueId = fileUniqueId;
  }

  /// Records a request. Called immediately before the TDLib call is sent, so
  /// a request that never reaches TDLib is a separate failure (the exception
  /// propagates from the api) — the log shows the intent and the caller.
  DownloadCall record({
    required int fileId,
    required DownloadCaller caller,
    required int offset,
    required int limit,
    required int priority,
    bool synchronous = false,
    String cause = '',
    int diskBefore = -1,
  }) {
    final before = transferred(fileId);
    // Re-baseline the growth counter on the window this call asks for. TDLib
    // reports `downloaded_size` relative to `download_offset`, so the first
    // update after a request counts from zero — and a move to a far window is
    // a new baseline, not a download.
    _last[fileId] = (offset, 0);
    final call = DownloadCall(
      seq: ++_seq,
      at: DateTime.now(),
      fileId: fileId,
      caller: caller,
      offset: offset,
      limit: limit,
      priority: priority,
      synchronous: synchronous,
      chatId: chatId,
      messageId: messageId,
      generation: generation,
      fileUniqueId: fileUniqueId,
      diskBefore: diskBefore,
      cause: cause,
      startedFrom: before,
    );
    // A forbidden caller reaching the download API is the B+ breach itself:
    // record it as a violation the report cannot miss, then let the call
    // through — the audit documents reality, the gate (not the log) blocks.
    if (DownloadCaller.forbiddenDownloaders.contains(caller)) {
      noteArchitectureViolation(
        'FORBIDDEN_DOWNLOADER caller=${caller.label} file=$fileId '
        'offset=$offset limit=$limit',
      );
    }
    _open[fileId] = call;
    _calls.add(call);
    if (_calls.length > maxCalls) _calls.removeAt(0);
    return call;
  }

  /// `download_offset + downloaded_size` — the furthest byte this file's
  /// current window has reached.
  int transferred(int fileId) {
    final last = _last[fileId];
    if (last == null) return 0;
    return last.$1 + last.$2;
  }

  /// Feeds one `updateFile` into the attribution.
  ///
  /// Growth is only counted when the window offset did not change: a move to
  /// a far window is not growth, and counting it would make a seek look like a
  /// hundred-megabyte download.
  void observe({
    required int fileId,
    required int offset,
    required int downloaded,
  }) {
    final previous = _last[fileId];
    _last[fileId] = (offset, downloaded);
    final call = _open[fileId];
    if (call == null) return;
    if (previous != null && previous.$1 == offset && downloaded > previous.$2) {
      call.grew += downloaded - previous.$2;
    }
    final reached = offset + downloaded;
    if (reached > call.reached) call.reached = reached;
  }

  /// The most recent request [caller] sent, or null if it sent none.
  ///
  /// The panel prints it as the live V2 window: "what did the resource loader
  /// ask TDLib for, right now" is a different question from "what grew", and
  /// answering the second one while the first is unreadable is how a window
  /// request ends up looking like a download.
  DownloadCall? lastCallFor(DownloadCaller caller) {
    for (var i = _calls.length - 1; i >= 0; i--) {
      if (_calls[i].caller == caller) return _calls[i];
    }
    return null;
  }

  /// Total bytes TDLib wrote because of [caller].
  int grewBy(DownloadCaller caller) => _calls
      .where((c) => c.caller == caller)
      .fold<int>(0, (sum, c) => sum + c.grew);

  /// The request that moved the most bytes — the answer to "who caused the
  /// big download".
  DownloadCall? get largest {
    DownloadCall? best;
    for (final call in _calls) {
      if (best == null || call.grew > best.grew) best = call;
    }
    return best;
  }

  /// True when any single request was allowed to ask for the whole file.
  bool get anyUnbounded => _calls.any((c) => c.unbounded);

  /// The unbounded calls, oldest first. A play window is not one of these.
  List<DownloadCall> get unboundedCalls =>
      _calls.where((c) => c.unbounded).toList();

  /// `PLAYER:159383552 RESOURCE_LOADER:16777216 …`, largest first.
  String growthSummary() {
    final byCaller = <DownloadCaller, int>{};
    for (final call in _calls) {
      byCaller[call.caller] = (byCaller[call.caller] ?? 0) + call.grew;
    }
    if (byCaller.isEmpty) return '-';
    final entries = byCaller.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.map((e) => '${e.key.label}:${e.value}').join(' ');
  }

  /// The lines the diagnostics panel and the acceptance report print.
  List<String> summary({int max = 8}) {
    final lines = <String>[
      if (_calls.isEmpty)
        'DOWNLOAD AUDIT: no calls'
      else
        'DOWNLOAD AUDIT calls=${_calls.length} '
            'unbounded=${unboundedCalls.length} growthByCaller=${growthSummary()}',
    ];
    // A guard that fired with no request behind it is still the most important
    // thing in this block — printing "no calls" and stopping would hide it.
    if (_calls.isEmpty) {
      for (final blocked in _blocked) {
        lines.add('  AUTO_FULL_DOWNLOAD_BLOCKED $blocked');
      }
      return lines;
    }
    final recent = _calls.length <= max
        ? _calls
        : _calls.sublist(_calls.length - max);
    for (final call in recent) {
      lines.add('  ${call.describe()}');
    }
    final big = largest;
    if (big != null && big.grew > 0) {
      lines.add('  LARGEST caller=${big.caller.label} file=${big.fileId} '
          'offset=${big.offset} '
          'limit=${big.limit <= 0 ? 'WHOLE_FILE' : big.limit} grew=${big.grew}');
    }
    final unbounded = unboundedCalls;
    if (unbounded.isNotEmpty) {
      final who = unbounded.map((c) => c.caller.label).toSet().join(',');
      lines.add('  UNBOUNDED=${unbounded.length} callers=$who');
    }
    for (final blocked in _blocked) {
      lines.add('  AUTO_FULL_DOWNLOAD_BLOCKED $blocked');
    }
    for (final violation in _violations) {
      lines.add('  ARCHITECTURE_VIOLATION $violation');
    }
    return lines;
  }

  void reset() {
    _calls.clear();
    _open.clear();
    _last.clear();
    _seq = 0;
    _violations.clear();
    fileUniqueId = '';
    // `wholeFileAllowed` is *not* reset here on purpose — see [allowWholeFile].
  }
}
