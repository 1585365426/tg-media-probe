/// State machine for the full-screen vertical feed.
///
/// Everything that can go wrong with a video feed is a sequencing problem, so
/// the sequencing is here and the widgets stay dumb:
///
/// * switch away -> cancel the old transfer, release the old player, **then**
///   resolve and start the new one (`SinglePlayerController` enforces the
///   order, this file enforces the intent);
/// * a slow resolution that finishes after the user moved on must not install
///   itself (`LatestOnlySlot`);
/// * backgrounding releases the decoder, foregrounding re-activates the same
///   item from where the list already is;
/// * "preload" means one adjacent *transfer*, never a second player — the
///   product spec caps live players at one.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, Orientation;

import '../data/channel_sync.dart' show MediaPager;
import '../data/index_store.dart';
import '../app/app_preferences.dart';
import '../data/media_record.dart';
import '../data/video_number_lookup.dart';
import '../playback/media_metadata.dart';
import '../playback/playback_trace.dart';
import '../playback/native_streaming.dart';
import '../playback/playback_failure.dart';
import '../playback/playback_session.dart';
import '../playback/player_slot.dart';
import '../playback/source_decision.dart';
import '../playback/video_source.dart';
import '../playback/watch_store.dart';
import '../playback/streaming_diagnostics.dart';
import '../td/td_error_kind.dart';
import '../util/latest_only.dart';

/// Outcome of a "jump to number" request.
enum NumberJumpResult {
  /// The item was located and is now current.
  opened,

  /// The number is valid but this list does not have that many items, even
  /// after parging to the end of the mirror.
  notFound,

  /// Empty, zero, negative, absurdly large or not a number at all.
  invalid,
}

enum FeedPhase {  /// Nothing requested yet.
  idle,

  /// First page in flight.
  loading,

  /// Playing (or paused by the user) with a live player.
  ready,

  /// Resolving the source or starting the player.
  buffering,

  /// The current item failed. [FeedController.error] says why.
  error,

  /// The index holds no video at all.
  empty,
}

/// Where feed items come from. Abstracted so the controller can be tested with
/// a fixed list and the app can page the local index.
abstract class FeedPageSource {
  bool get hasMore;
  Future<List<MediaRecord>> nextPage();
  void reset();
}

/// Pages the local mirror, newest first. No network: the feed never asks
/// Telegram for a list, it plays what the index already knows about.
class IndexFeedSource implements FeedPageSource {
  IndexFeedSource({
    required this.store,
    this.chatId,
    int pageSize = 40,
  }) : _pager = MediaPager(store: store, chatId: chatId, pageSize: pageSize);

  final IndexStore store;
  final int? chatId;
  final MediaPager _pager;

  @override
  bool get hasMore => _pager.hasMore;

  /// Videos indexed for this filter — the number the UI may call "total".
  /// It comes from the index, never from how many rows happen to be loaded.
  int get syncedVideos => chatId == null
      ? store.countByChat().values.fold(0, (sum, value) => sum + value)
      : (store.countByChat()[chatId] ?? 0);

  @override
  Future<List<MediaRecord>> nextPage() async {
    final page = await _pager.next();
    return page.items.where((r) => r.kind == MediaKind.video).toList();
  }

  @override
  void reset() => _pager.reset();
}

class FeedController extends ChangeNotifier {
  FeedController({
    required this.source,
    required this.player,
    required this.sources,
    this.metadata,
    this.chatTitles = const <int, String>{},
    bool defaultMuted = false,
    bool preloadAdjacent = true,
    int? preloadCount,
    this.pollInterval = const Duration(milliseconds: 250),
    this.watch,
    StreamingDiagnostics? diagnostics,
  })  : _muted = defaultMuted,
        _diagnostics = diagnostics ?? StreamingDiagnostics.instance,
        preloadCount = preloadCount ??
            (preloadAdjacent ? AppPreferences.defaultPreloadCount : 0);

  final FeedPageSource source;
  final SinglePlayerController player;
  final VideoSourceResolver sources;

  /// Reads one message again to repair a missing file name or a stale file id.
  /// Null in tests that do not care about it; the feed then simply shows the
  /// channel title as before.
  final MediaMetadataLookup? metadata;

  /// Prefetch window: how many items after the current one may be prepared.
  /// 0 disables it. Read from the saved preference.
  final int preloadCount;

  /// `chatId -> channel title`, filled from the channel directory. Used for the
  /// bottom info line; a missing entry renders as "未知频道" rather than a blank.
  final Map<int, String> chatTitles;

  bool get preloadAdjacent => preloadCount > 0;

  /// Playhead polling. Null in tests, where time does not pass.
  final Duration? pollInterval;

  /// Local watch state (position + finished). Optional so a test without one
  /// exercises exactly the same playback path minus the bookkeeping.
  final WatchStore? watch;

  /// Where the live streaming evidence for the current play is recorded.
  /// Defaults to the process-wide instance the overlay and the settings
  /// diagnostics section read from; tests inject their own.
  final StreamingDiagnostics _diagnostics;

  /// Live streaming evidence for the current play (settings screen, overlay).
  StreamingDiagnostics get diagnostics => _diagnostics;

  /// The state of exactly one play. Created per activation, replaced — never
  /// reused — when the user opens another video. `fullDownloadFallbackUsed`
  /// lives here, not in a global: one tap gets at most one whole-file
  /// fallback, and the next tap starts with a fresh budget.
  PlaybackSession? _session;
  PlaybackSession? get session => _session;

  /// True when the current play gave up on streaming and used the full
  /// download instead. Kept here as well so the diagnostics screen can show it
  /// without reaching into the resolver.
  bool _fallbackOccurred = false;
  bool get fallbackOccurred => _fallbackOccurred;

  /// Set once the finish for the current item has been recorded, so a 250 ms
  /// poll does not write the same row eight times a second.
  String? _finishedKey;

  final List<MediaRecord> _items = <MediaRecord>[];
  final LatestOnlySlot<PlaySource> _gate = LatestOnlySlot<PlaySource>();

  int _index = -1;
  FeedPhase _phase = FeedPhase.idle;
  String? _error;
  RequestFailure _failure = RequestFailure.none;
  bool _controlVisible = false;
  bool _muted;
  bool _loadingMore = false;
  bool _releasedForBackground = false;
  bool _disposed = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _bufferFraction = 0;
  Timer? _poll;

  List<MediaRecord> get items => List<MediaRecord>.unmodifiable(_items);
  int get index => _index;
  int get length => _items.length;
  FeedPhase get phase => _phase;
  String? get error => _error;

  /// What kind of failure put the feed into [FeedPhase.error]. A generic
  /// "读取失败" is useless when the real answer is "登录已失效".
  RequestFailure get failure => _failure;
  bool get controlVisible => _controlVisible;
  bool get muted => _muted;
  bool get isLoadingMore => _loadingMore;
  Duration get position => _position;
  Duration get duration => _duration;
  double get bufferFraction => _bufferFraction;
  bool get isPlaying => player.active?.isPlaying ?? false;

  MediaRecord? get current {
    if (_index < 0 || _index >= _items.length) return null;
    return _items[_index];
  }

  bool get hasPrevious => _index > 0;

  bool get hasNext => _index + 1 < _items.length || source.hasMore;

  /// "3 / 40" for the info line; "0 / 0" is never shown because the empty state
  /// replaces the page.
  /// "3 / 38 · 已同步 725" — loaded window vs. indexed total, never mixed.
  String get positionLabel {
    final total = syncedVideos;
    final loaded = '${_index + 1} / ${_items.length}';
    if (total <= _items.length) return loaded;
    return '$loaded · 已同步 $total';
  }

  /// Videos in the index for this filter. The list only holds what has been
  /// paged in; this is what the channel actually has recorded.
  int get syncedVideos {
    final source = this.source;
    if (source is IndexFeedSource) return source.syncedVideos;
    return _items.length;
  }

  /// True when the loaded window covers everything the index holds.
  bool get loadedAll => _items.length >= syncedVideos;

  /// True when the index itself has no more pages to give.
  bool get historyComplete => atEnd;

  String titleOf(MediaRecord record) {
    final channel = chatTitles[record.chatId];
    final name = record.fileName;
    if (name != null && name.isNotEmpty) return name;
    if (channel != null && channel.isNotEmpty) {
      // A channel video with no file name is the common case, not an edge one.
      // The message id is the only stable handle the user can match against
      // the Telegram client, so it goes in the label instead of a bare "视频".
      return '$channel · #${record.messageId}';
    }
    return '视频 #${record.messageId}';
  }

  /// True when the current item has no file name yet — the UI may show the
  /// channel title meanwhile, and [metadata] is being asked in the background.
  bool get currentHasName {
    final name = current?.fileName;
    return name != null && name.isNotEmpty;
  }

  String get currentChannelTitle {
    final record = current;
    if (record == null) return '';
    return chatTitles[record.chatId] ?? '未知频道';
  }

  /// §4.2: a swipe counts as a page turn above 12% of the viewport height, or
  /// above 300 px/s regardless of distance.
  static bool shouldSwitchPage({
    required double dy,
    required double velocity,
    required double height,
  }) {
    if (height <= 0) return velocity.abs() > 300;
    return dy.abs() > height * 0.12 || velocity.abs() > 300;
  }

  /// Loads the first page and starts the first item.
  Future<void> load() async {
    _gate.cancelAll();
    _items.clear();
    _index = -1;
    // A new list invalidates every play in flight, not just the gate tokens.
    _generation++;
    _error = null;
    _failure = RequestFailure.none;
    _phase = FeedPhase.loading;
    _bufferFraction = 0;
    _notify();

    try {
      source.reset();
      await _appendUntilNonEmpty();
    } on Object catch (e) {
      _fail('读取媒体索引失败：$e', failure: classifyFailure(e));
      return;
    }

    if (_items.isEmpty) {
      _phase = FeedPhase.empty;
      _notify();
      return;
    }
    _index = 0;
    await _activateCurrent();
  }

  /// Retries the item that failed **without rebuilding the list**.
  ///
  /// This used to be `load()`, which cleared `_items`, reset the source cursor
  /// and landed on item 1. A failed play therefore threw away the paging work
  /// and put the user back at "1 / 38" — reported as "播放失败后回到第一条".
  /// A play failure is a transfer problem, not an index problem, so only the
  /// current item is activated again.
  Future<void> retry() async {
    if (_items.isEmpty || _index < 0 || _index >= _items.length) {
      await load();
      return;
    }
    final record = _items[_index];
    _error = null;
    _failure = RequestFailure.none;
    _bufferFraction = 0;

    // A retry is a new play: same item, new generation, and the previous
    // player/proxy pair is released before the new one is resolved.
    final generation = _claim(record);
    _gate.cancelAll();
    await player.release();
    await _disposeActiveSource();
    await _activate(record, generation);
  }

  /// Rebuilds the list from the first page. Only for an explicit
  /// "重新加载列表" — never for a play failure.
  Future<void> reload() => load();

  /// Pulls pages until one contains a video or the source is exhausted.
  ///
  /// The index also holds photos and documents; a page made only of those must
  /// not be mistaken for "this channel has no videos".
  Future<void> _appendUntilNonEmpty({int maxPages = 5}) async {
    var pages = 0;
    while (pages < maxPages) {
      if (!source.hasMore) break;
      final page = await source.nextPage();
      pages++;
      // Filtered here as well as in the source: an item without a file id has
      // nothing to resolve, and a non-video item has nothing to play. Either
      // one reaching the feed would be a spinner that never ends.
      final playable = page
          .where((r) => r.kind == MediaKind.video && r.fileId != 0)
          .toList(growable: false);
      if (playable.isEmpty) continue;
      _items.addAll(playable);
      _notify();
      return;
    }
  }

  /// Jumps to one specific message, paging forward until it appears.
  ///
  /// Returns false when the message is not in the mirror and cannot be reached
  /// within [maxPages] — the caller then stays on the current item instead of
  /// showing a spinner over an item that will never arrive.
  Future<bool> goToMessage(
    int chatId,
    int messageId, {
    int maxPages = 5,
  }) async {
    for (var attempt = 0; attempt <= maxPages; attempt++) {
      final target = _items.indexWhere(
        (r) => r.chatId == chatId && r.messageId == messageId,
      );
      if (target >= 0) {
        await _moveTo(target);
        return true;
      }
      if (!source.hasMore || _loadingMore) break;
      _loadingMore = true;
      _notify();
      try {
        await _appendUntilNonEmpty();
      } finally {
        _loadingMore = false;
        _notify();
      }
    }
    return false;
  }

  Future<void> goNext() async {
    if (_phase == FeedPhase.loading) return;
    if (_index + 1 >= _items.length) {
      await _loadMoreAhead();
      if (_index + 1 >= _items.length) return;
    }
    await _moveTo(_index + 1);
  }

  Future<void> goPrevious() async {
    if (_index <= 0) return;
    await _moveTo(_index - 1);
  }

  /// Jumps to an absolute index. Used by the pager when it settles on a page
  /// the controller did not choose itself.
  Future<void> goToIndex(int target) async {
    if (target == _index) return;
    if (target < 0) return;
    // Reaching the last page must extend the list before the swipe is refused.
    //
    // The page used to call goToIndex() and then goNext() without awaiting the
    // first one; goNext() saw the *old* index, computed target+1, and returned
    // because it was out of range. A 38-item first page therefore never grew:
    // there was no page 39 to swipe to, so onPageChanged never fired again.
    if (target >= _items.length) {
      if (!source.hasMore || _loadingMore) return;
      _loadingMore = true;
      _notify();
      try {
        await _appendUntilNonEmpty();
      } finally {
        _loadingMore = false;
        _notify();
      }
      if (target >= _items.length) return;
    }
    // Landing on the tail of the loaded window: fetch the next page in the
    // background so the following swipe has somewhere to go.
    if (target == _items.length - 1 && source.hasMore && !_loadingMore) {
      unawaited(_loadMoreAhead());
    }
    await _moveTo(target);
  }

  /// Appends one more page without moving the playhead.
  ///
  /// Called when the user reaches the tail of the loaded window: the list has
  /// to be longer than what is on screen, otherwise the vertical PageView has
  /// nowhere to scroll and no further callback ever arrives.
  Future<void> _loadMoreAhead() async {
    if (_loadingMore || !source.hasMore) return;
    _loadingMore = true;
    try {
      await _appendUntilNonEmpty();
    } finally {
      _loadingMore = false;
      _notify();
    }
  }

  /// True once the mirror has no further pages for this filter.
  bool get atEnd => !source.hasMore;

  /// Opens position [number] in the **current** list, numbering from 1.
  ///
  /// The number is a view over a stable identity, not over an array slot: the
  /// item is resolved to (chatId, messageId) first, then the jump verifies that
  /// the item actually reached is the one that was asked for. If the list grew
  /// between the two moments the call reports [NumberJumpResult.notFound]
  /// instead of silently playing a neighbour.
  Future<NumberJumpResult> openNumber(int number) async {
    if (number < 1 || number > VideoNumberLookup.maxNumber) {
      return NumberJumpResult.invalid;
    }
    final target = number - 1;

    var guard = 0;
    while (target >= _items.length && source.hasMore && guard++ < 200) {
      final before = _items.length;
      await _loadMoreAhead();
      if (_items.length == before) break;
    }
    if (target >= _items.length) return NumberJumpResult.notFound;

    final expected = _items[target];
    await _moveTo(target);
    final landed = current;
    if (landed == null ||
        landed.messageId != expected.messageId ||
        landed.chatId != expected.chatId) {
      return NumberJumpResult.notFound;
    }
    return NumberJumpResult.opened;
  }

  /// The visible position of the current item, 1-based, or null when nothing is
  /// playing. Same numbering as [openNumber].
  int? get currentNumber => _index < 0 ? null : _index + 1;

  /// Upper bound for the number box. Not a list limit — it only keeps a typo
  /// like 999999999 from becoming a million page requests.
  static const int maxNumber = VideoNumberLookup.maxNumber;

  Future<void> _moveTo(int target) async {
    if (target < 0 || target >= _items.length) return;
    final leaving = current;
    final record = _items[target];

    // Claim the player *before* the first await: the index and the generation
    // change together, so an activation of the item being left can never
    // resume later and still believe it is the current one. This is the exact
    // hole that let video B install itself while the user was opening A.
    _index = target;
    final generation = _claim(record);
    _gate.cancelAll();
    _position = Duration.zero;
    _duration = Duration.zero;
    _bufferFraction = 0;
    // Deliberately NOT resetting _controlVisible here: a swipe must inherit
    // the current immersive state. Re-hiding on every page turn is what made
    // the feed "flash" its overlays while swiping through videos.
    _error = null;
    _phase = FeedPhase.buffering;
    _notify();
    _noteClick(record);

    // One player, one proxy: the previous pair is torn down before anything
    // new is resolved. A new activation never disposes a source it did not
    // create — that cross-disposal closed the live proxy's port mid-play and
    // surfaced on device as "无法连接服务器".
    await player.release();
    await _disposeActiveSource();
    if (leaving != null &&
        leaving.fileId != 0 &&
        leaving.fileId != record.fileId) {
      // Only the current item's transfer is allowed to run (§4.5).
      unawaited(sources.cancel(leaving.fileId));
    }

    await _activate(record, generation);
  }

  // ---- play generation -------------------------------------------------
  //
  // Every activation runs under a generation token. Anything async — a
  // resolve, a fallback download, a player initialisation, a diagnostics
  // callback — re-checks the token before it touches the player, the proxy,
  // the index or the panel. A mismatch means the user already moved on, and
  // the result is dropped instead of installed.

  int _generation = 0;

  /// Who owns the player right now, by identity rather than by index.
  int _activeChatId = 0;
  int _activeMessageId = 0;
  int _activeFileId = 0;

  /// The current play generation (diagnostics and tests read this).
  int get playGeneration => _generation;

  /// The file id the player was claimed for.
  int get activeFileId => _activeFileId;

  /// Claims the player for [record]; everything older is now stale.
  int _claim(MediaRecord record) {
    _generation++;
    _activeChatId = record.chatId;
    _activeMessageId = record.messageId;
    _activeFileId = record.fileId;
    return _generation;
  }

  /// True while [generation] is still the play the user is watching.
  bool _owns(int generation) => !_disposed && generation == _generation;

  /// True when [generation] is current *and* the feed still points at the
  /// same video. Both halves matter: the index can move before the generation
  /// (a swipe) and the generation before the index (a deep link).
  bool _ownsRecord(int generation, MediaRecord record) =>
      _owns(generation) &&
      record.chatId == _activeChatId &&
      record.messageId == _activeMessageId &&
      record.fileId == _activeFileId;

  void _noteClick(MediaRecord record) {
    _diagnostics.noteStage(
      'CLICKED',
      chatId: record.chatId,
      messageId: record.messageId,
      fileId: record.fileId,
    );
  }

  /// Releases whatever the live player is reading. The field is nulled first,
  /// so two activations can never both own — or both dispose — one source.
  Future<void> _disposeActiveSource() async {
    final source = _activeSource;
    _activeSource = null;
    if (source != null) _releaseActiveFile(source);
    await source?.dispose();
  }

  Future<void> _activateCurrent() async {
    final record = current;
    if (record == null) return;
    await _activate(record, _claim(record));
  }

  /// Opens the whole-file door for this play, and only this play.
  ///
  /// Outside a play the door is irrelevant: `TdFileTransferApi` is only used by
  /// the player path. Inside one, the door closes as soon as a streaming
  /// transport is entered (see `VideoSourceResolver._streamOnce`), so a failed
  /// stream cannot reach `downloadFile(limit: 0)`. The only play that keeps it
  /// open end-to-end is the one where the user turned streaming off — that is
  /// an instruction, not a fallback.
  Future<void> _activate(MediaRecord record, int generation) async {
    if (!_ownsRecord(generation, record)) return;

    _diagnostics.allowWholeFile();
    _fallbackOccurred = false;
    // One tap, one session. The previous play's budget (its spent fallback,
    // its resolved id, its flags) dies here; nothing from it survives into
    // this one.
    _session = PlaybackSession(
      chatId: record.chatId,
      messageId: record.messageId,
    );
    _phase = FeedPhase.buffering;
    _notify();
    _diagnostics.noteStage(
      'ACTIVE',
      chatId: record.chatId,
      messageId: record.messageId,
      fileId: record.fileId,
    );

    final trace = PlaybackTrace(
      fileId: record.fileId,
      chatId: record.chatId,
      messageId: record.messageId,
    );
    trace.mark(PlaybackStage.selected);
    _lastTrace = trace;

    // The index stores whatever `messageVideo.video.file_name` held when the
    // message was mirrored, and for channel videos that is frequently empty.
    // Ask the message itself; the answer arrives a moment later and the label
    // updates without blocking the play.
    unawaited(_fetchNameIfMissing(record));

    // What the user actually tapped: file id and the size the tile shows.
    // Recorded before the play so the panel can prove whether the opened file
    // is the tapped one — a 3.45 GB tile playing a 1.38 GB file is a defect,
    // not a rounding difference.
    _diagnostics.noteRecordSnapshot(
      fileId: record.fileId,
      messageId: record.messageId,
      sizeBytes: record.sizeBytes,
    );

    PlaySource? source;
    try {
      source = await _gate.run(
        () => _resolvePlaySource(record, generation, trace),
      );
    } on VideoSourceTimeout catch (e) {
      // A stream failed. Re-measure the file, try the other transport, and if
      // that fails too, stop — this is the one place the device report says
      // must never answer "download the whole file". A 4.9 MB proxy stall on a
      // 622 MB video used to become 593 MB downloaded and 162 seconds before
      // the first frame.
      source = await _recoverFromStreamFailure(record, trace, e, generation);
      if (source == null) {
        if (!_ownsRecord(generation, record)) return;
        _fail(
          e.message,
          failure: e.isStall ? RequestFailure.offline : RequestFailure.generic,
          kind: classifyPlaybackFailure(e),
        );
        return;
      }
    } on VideoSourceException catch (e) {
      source = await _recoverFromStreamFailure(record, trace, e, generation);
      if (source == null) {
        if (!_ownsRecord(generation, record)) return;
        _fail(
          e.message,
          failure: classifyFailure(e),
          kind: classifyPlaybackFailure(e),
        );
        return;
      }
    } on Object catch (e) {
      source = await _recoverFromStreamFailure(record, trace, e, generation);
      if (source == null) {
        if (!_ownsRecord(generation, record)) return;
        _fail(
          '$e',
          failure: classifyFailure(e),
          kind: classifyPlaybackFailure(e),
        );
        return;
      }
    }

    // Null means a newer navigation already started — or this one was
    // superseded while the fallback was downloading. Either way the source
    // belongs to a video the user is no longer watching: drop it, do not
    // install it, and above all do not dispose the *current* one.
    if (source == null) return;
    if (!_ownsRecord(generation, record)) {
      await source.dispose();
      return;
    }

    // Install from the top of the transport chain downwards:
    // V2 (resource loader) → V1 (loopback proxy) → local file → error. A
    // transport that never produced a ready player is disposed before the next
    // one is tried, so the slot never holds two sources and the user never
    // sees a "无法连接服务器" from a transport that was already replaced.
    var current = source;
    while (true) {
      _activeSource = current;
      _registerActiveFile(current, record);
      final installed = await _installPlayer(current, record, generation, trace);
      if (installed) break;
      final failed = current;
      if (_activeSource == failed) _activeSource = null;
      await failed.dispose();
      _releaseActiveFile(failed);
      if (!_ownsRecord(generation, record)) return;
      // Not routed through `_gate`: that slot is typed to `PlaySource`, and
      // this step legitimately ends with "no source left". Staleness is
      // already covered by the generation check right below.
      final next = await _nextTransportAfter(
        failed,
        record,
        generation,
        trace,
      );
      if (!_ownsRecord(generation, record)) {
        await next?.dispose();
        return;
      }
      if (next == null) return;
      current = next;
    }
    source = current;
    if (!_ownsRecord(generation, record)) return;

    PlaybackTraceLog.instance.add(trace);
    await _applyVolume();
    if (!_ownsRecord(generation, record)) return;
    _phase = FeedPhase.ready;
    _bufferFraction = 0;
    _startPolling();
    await _restoreProgress(record);
    if (!_ownsRecord(generation, record)) return;
    _notify();
    // Preload runs *after* the play owns the player, is never awaited, and can
    // never produce a PlaySource — see [_prefetchNext].
    unawaited(_prefetchNext(generation));
  }

  /// Resolves the play through the transport chain.
  ///
  /// V2 first: `AVAssetResourceLoader` answers AVFoundation directly, with no
  /// socket, no HTTP status line and no connection lifetime to get wrong.
  /// V1 is not removed — a platform without the bridge, or a session the
  /// native side refused, drops to the loopback proxy for the *same* record,
  /// which is a transport change and not a play failure.
  Future<PlaySource> _resolvePlaySource(
    MediaRecord record,
    int generation,
    PlaybackTrace trace,
  ) async {
    _diagnostics.noteStage(
      'RESOLVE',
      chatId: record.chatId,
      messageId: record.messageId,
      fileId: record.fileId,
    );

    void onProgress(VideoSourceUpdate update) {
      if (update.stage != SourceStage.fetching) return;
      if (!_owns(generation)) return;
      _bufferFraction = update.fraction;
      _notify();
    }

    if (StreamingV2.supported) {
      // Recorded on entry, not on failure: a V2 attempt that throws before the
      // player exists used to leave `v2Attempted=false` in the report while
      // the device log showed a `tgmedia://` session being opened.
      _diagnostics.noteTransportStart('RESOURCE_LOADER');
      final session = _session;
      session?.streamingAttempted = true;
      session?.resolvedFileId = record.fileId;
      try {
        return await sources.resolveStreamV2(
          record.fileId,
          chatId: record.chatId,
          messageId: record.messageId,
          mimeType: record.mimeType,
          trace: trace,
          onRecordRefreshed: _absorbRefreshed,
          onProgress: onProgress,
        );
      } on VideoSourceTimeout {
        _failedStreamTransport = StreamTransport.resourceLoader;
        _diagnostics.noteTransportAttempt('RESOURCE_LOADER', failed: true);
        _diagnostics.noteV2OnlyStop('timeout');
        rethrow;
      } on VideoSourceException catch (e) {
        _failedStreamTransport = StreamTransport.resourceLoader;
        _diagnostics.noteTransportAttempt('RESOURCE_LOADER', failed: true);
        _diagnostics.noteV2OnlyStop(e.message);
        rethrow;
      } on Object catch (e) {
        _failedStreamTransport = StreamTransport.resourceLoader;
        _diagnostics.noteTransportAttempt('RESOURCE_LOADER', failed: true);
        _diagnostics.noteResourceLoader(
          'v2 failed: $e',
          generation: generation,
        );
        _diagnostics.noteV2OnlyStop('$e');
        // V2-only: a native error is this play's error. There is no second
        // transport to hide behind, and no download to make it look better.
        // Re-thrown as-is so the user sees the transport's own reason.
        if (StreamingV2.v2Only) rethrow;
        _diagnostics.noteDecision(
          candidate: true,
          decision: 'STREAM',
          reason: 'v2_unavailable_using_v1',
          generation: generation,
        );
      }
    }

    // Only reachable when this build has no V2 bridge at all (or V2-only is
    // switched off in code): the loopback proxy is then the only streaming
    // transport that exists, not a fallback from a V2 failure.
    _failedStreamTransport = StreamTransport.httpProxy;
    return sources.resolveStream(
      record.fileId,
      chatId: record.chatId,
      messageId: record.messageId,
      // The served Content-Type comes from the message's own mime type;
      // guessing mp4 for a webm is another way to make AVPlayer refuse.
      mimeType: record.mimeType,
      trace: trace,
      // TDLib rejected the stored file id (or the message carried a file name
      // the mirror never had): keep the repaired record.
      onRecordRefreshed: _absorbRefreshed,
      onProgress: onProgress,
    );
  }

  /// Hands [source]'s URL to the player and waits for it to become ready.
  ///
  /// Returns false when the player never initialised — the caller then moves
  /// one step down the transport chain instead of showing an error.
  Future<bool> _installPlayer(
    PlaySource source,
    MediaRecord record,
    int generation,
    PlaybackTrace trace,
  ) async {
    try {
      trace.mark(PlaybackStage.playerCreated);
      // Record what the player is *about to open*, from the source itself. A
      // V2 play names its own transport; STREAM_HTTP / LOCAL_FILE would make
      // the report claim a socket that was never opened.
      _diagnostics.notePlayerSource(
        isStreaming: source.isStreaming,
        url: source.url,
        generation: generation,
        sourceLabel: source.isResourceLoader ? StreamingV2.sourceLabel : null,
      );
      _diagnostics.noteStage(
        'PLAYER',
        chatId: record.chatId,
        messageId: record.messageId,
        fileId: record.fileId,
      );
      _diagnostics.notePlayerCreated(generation: generation);
      await player.activate(source.url);
      if (!_ownsRecord(generation, record)) return false;
      _diagnostics.noteFinalSource(source.origin);
      _diagnostics.notePlayerReady(generation: generation);
      final session = _session;
      session
        ?..finalSource = source.origin
        ..playerReady = true;
      trace.mark(PlaybackStage.playerInitialized);
      return true;
    } on Object catch (e) {
      // A stale activation failing is not the current video's failure.
      if (!_ownsRecord(generation, record)) return false;
      // The player's own message is the only thing that says *why* the item
      // never became ready — keep it verbatim instead of a generic line.
      _diagnostics.notePlayerFailed('$e', generation: generation);
      _diagnostics.noteDecision(
        proxyAvailable: source.isStreaming,
        decision: 'FALLBACK',
        reason: 'player_initialization_failed',
        generation: generation,
      );
      trace.note = source.isResourceLoader
          ? 'V2 播放器初始化失败'
          : (source.isStreaming ? 'V1 播放器初始化失败' : '本地文件播放失败');
      return false;
    }
  }

  /// The streaming transport that last failed in this play, so a recovery can
  /// tell "V2 failed, V1 is still worth a try" from "V1 failed, there is
  /// nothing left".
  StreamTransport? _failedStreamTransport;

  /// Tries V1 on the current record. Null means the proxy refused too.
  ///
  /// Shared by the two places that may still reach it — a V2 player that never
  /// installed, and a V2 resolve that timed out — so both name the attempt the
  /// same way in the report.
  Future<PlaySource?> _tryV1(
    MediaRecord record,
    int generation,
    PlaybackTrace trace,
  ) async {
    _diagnostics.noteTransportStart('HTTP_PROXY');
    try {
      final v1 = await sources.resolveStream(
        record.fileId,
        chatId: record.chatId,
        messageId: record.messageId,
        // The served Content-Type comes from the message's own mime type;
        // guessing mp4 for a webm is another way to make AVPlayer refuse.
        mimeType: record.mimeType,
        trace: trace,
        onRecordRefreshed: _absorbRefreshed,
        onProgress: (update) {
          if (update.stage != SourceStage.fetching) return;
          if (!_owns(generation)) return;
          _bufferFraction = update.fraction;
          _notify();
        },
      );
      if (!_ownsRecord(generation, record)) {
        await v1.dispose();
        return null;
      }
      _diagnostics.noteTransportAttempt('HTTP_PROXY', failed: false);
      _diagnostics.noteDecision(
        proxyAvailable: true,
        decision: 'STREAM',
        reason: 'v1_after_v2_failure',
        generation: generation,
      );
      return v1;
    } on Object catch (e) {
      _failedStreamTransport = StreamTransport.httpProxy;
      _diagnostics.noteTransportAttempt('HTTP_PROXY', failed: true);
      _diagnostics.noteFallback('V1 也失败：$e');
      return null;
    }
  }

  /// What a failed stream may do next. In order, and nothing else:
  ///
  /// 1. the file finished while the transport was failing → play it from disk;
  /// 2. V2 was the one that failed → one attempt on V1;
  /// 3. otherwise → null, and the caller shows an error.
  ///
  /// There used to be a step before 1 — "no stream was possible, so wait for
  /// the whole file" — and the device report is what removed it: a 24 MB video
  /// whose tiled `file_id` had gone stale reported `no_file_record`, downloaded
  /// the whole file through a *different* id, and filed it as `LOCAL_FILE` with
  /// `localFileExists=false`. A play that cannot stream says
  /// `STREAMING_NOT_STARTED` and stops; it does not download the film.
  Future<PlaySource?> _recoverFromStreamFailure(
    MediaRecord record,
    PlaybackTrace trace,
    Object failure,
    int generation,
  ) async {
    if (!_ownsRecord(generation, record)) return null;

    _diagnostics.noteFallback('$failure');
    final facts = await sources.inspect(record.fileId);
    if (!_ownsRecord(generation, record)) return null;

    // 1. The bytes arrived while the transport was dying.
    if (facts.isPlayableFromDisk) {
      _diagnostics.noteDecision(
        proxyAvailable: false,
        decision: 'LOCAL_FILE',
        reason: 'completed_while_stream_was_failing',
        generation: generation,
      );
      trace.note = '流式失败后文件已完整，改用本地文件';
      return PlaySource.file(facts.path);
    }

    // 2. V2-only builds stop here. The proxy is not tried: a V2 failure is
    //    the play's failure, not a reason to start a second transport inside
    //    the same tap.
    if (!StreamingV2.v2Only && _failedStreamTransport != StreamTransport.httpProxy) {
      final v1 = await _tryV1(record, generation, trace);
      if (v1 != null) return v1;
      if (!_ownsRecord(generation, record)) return null;
    }

    // 3. One whole-file fallback per session — and only for a file TDLib
    //    actually has a record for. A missing record is an id problem: the
    //    fresh stat above could not resolve the message's file, and a
    //    whole-file request for that same unproven id is how the device log
    //    burned a `downloadFile` on 4999 and downloaded 2221 instead. The
    //    play stops; the budget survives for a tap whose id resolved.
    if (facts.hasRecord) {
      final session = _session;
      if (session != null && session.spendFullDownloadFallback()) {
        return _fullDownloadFallback(record, trace, generation);
      }
    }

    // 4. Nothing left that does not involve downloading the film — and the
    //    one download this session was allowed has been spent.
    return null;
  }

  /// The explicit last rung: download the whole file, on purpose, with the
  /// user watching a progress bar instead of a spinner.
  ///
  /// Reachable exactly once per [PlaybackSession] — the caller spent the
  /// budget to get here. The door in the audit (`wholeFileAllowed`) is
  /// reopened for this one call: the stream that closed it has already
  /// failed, and this is the play's documented way out, not a background
  /// decision. What comes back is measured: a "completed" transfer with no
  /// bytes behind the path is an error, never a [PlaySource.file].
  Future<PlaySource?> _fullDownloadFallback(
    MediaRecord record,
    PlaybackTrace trace,
    int generation,
  ) async {
    _fallbackOccurred = true;
    _diagnostics.allowWholeFile();
    _diagnostics.noteDecision(
      proxyAvailable: false,
      decision: 'FULL_DOWNLOAD',
      reason: 'stream_failed_fallback_once',
      generation: generation,
    );
    final session = _session;
    try {
      final playable = await sources.downloadWhole(
        record.chatId,
        record.messageId,
        record.fileId,
        trace: trace,
        generation: generation,
      );
      if (!_ownsRecord(generation, record)) return null;
      if (!playable.isComplete) {
        if (phase != FeedPhase.error) {
          _fail(
            '下载完成但文件不完整'
            '（${playable.localSize}/${playable.expectedSize} 字节）',
            kind: PlaybackFailure.downloadStalled,
          );
        }
        return null;
      }
      session?.finalSource = 'LOCAL_FILE';
      session?.resolvedFileId = playable.fileId;
      session?.playerReady = true;
      _diagnostics.noteDecision(
        proxyAvailable: false,
        decision: 'LOCAL_FILE',
        reason: 'full_download_completed_and_verified',
        generation: generation,
      );
      // The file exists because a full download put it there — the origin is
      // part of the report, not cosmetic: `finalSource=LOCAL_FILE` without
      // it is how a 593 MB wait once read as a cache hit.
      return PlaySource.file(playable.localPath, origin: 'FULL_DOWNLOAD');
    } on Object catch (e) {
      if (!_ownsRecord(generation, record)) return null;
      _diagnostics.noteTransportAttempt('FULL_DOWNLOAD_FALLBACK', failed: true);
      if (phase != FeedPhase.error) {
        _fail('整文件下载失败：$e', kind: PlaybackFailure.downloadStalled);
      }
      return null;
    }
  }

  /// One step down the transport chain: V2 → V1 → local file → error.
  ///
  /// The next rung is chosen from a fresh reading of the file, not from the
  /// rung that failed. The device report is the reason: V2 failed to install,
  /// the controller went straight to V1, and by then the 756 MB file was
  /// complete — V1 is the one transport that cannot serve a complete file
  /// without a growing-file race, and it produced a 206 that declared
  /// 754,966,576 bytes and carried 20,496,682.
  ///
  /// A complete file here is not a step down at all. It is the answer.
  ///
  /// **`FULL_DOWNLOAD` is not a rung.** It used to be the last one, and the
  /// device measurement is what removed it: V1 stalled at 4.9 MB on a 622 MB
  /// video, the ladder answered with `start()` → `downloadFile(limit: 0)`,
  /// and the user waited 162 seconds to watch a file download to 593 MB
  /// first. The end of this ladder is an error.
  Future<PlaySource?> _nextTransportAfter(
    PlaySource failed,
    MediaRecord record,
    int generation,
    PlaybackTrace trace,
  ) async {
    // A local file that will not decode is the end of the chain: the bytes are
    // all there and the player still refused them.
    if (!failed.isStreaming) {
      if (_ownsRecord(generation, record) && phase != FeedPhase.error) {
        _fail('此视频无法解码');
      }
      return null;
    }
    _fallbackOccurred = true;
    _diagnostics.noteTransportAttempt(
      failed.isResourceLoader ? 'RESOURCE_LOADER' : 'HTTP_PROXY',
      failed: true,
    );
    final facts = await sources.inspect(record.fileId);
    if (!_ownsRecord(generation, record)) return null;
    final decision = decideAfterTransportFailure(
      facts,
      failed: failed.isResourceLoader
          ? PlaybackSourceKind.resourceLoader
          : PlaybackSourceKind.httpProxy,
      v2Supported: StreamingV2.supported,
      // V2-only: the ladder has one rung. `httpProxy` would name a transport
      // this build never reaches, and the report would then claim a V1 attempt
      // that never happened.
      allowProxy: !StreamingV2.v2Only,
    );
    _diagnostics.noteSourceDecision(decision, generation: generation);

    if (decision.source == PlaybackSourceKind.localFile) {
      _diagnostics.noteDecision(
        proxyAvailable: false,
        decision: 'LOCAL_FILE',
        reason: decision.reason,
        generation: generation,
      );
      trace.note = '流式传输失败后文件已完整，改用本地文件';
      return PlaySource.file(facts.path);
    }

    if (decision.source == PlaybackSourceKind.httpProxy) {
      _diagnostics.noteResourceLoader(
        'v2 player failed, retrying with V1',
        generation: generation,
      );
      final v1 = await _tryV1(record, generation, trace);
      if (v1 != null) return v1;
      if (!_ownsRecord(generation, record)) return null;
    }

    // Nothing streamable is left, and the file is still short. The honest next
    // state is an error. It used to be `_fallbackFullDownload` here, and that
    // is where the device report's 593 MB / 162 s came from: one transport
    // stalled on a 622 MB video, and the "fallback" answered by downloading
    // all of it before showing a frame.
    if (_ownsRecord(generation, record) && phase != FeedPhase.error) {
      _diagnostics.noteDecision(
        decision: 'STOP',
        reason: decision.reason,
        generation: generation,
      );
      _fail(
        failed.isResourceLoader
            // The message names the transport that failed, because in a
            // V2-only build there is no second one to blame.
            ? 'V2 流式播放失败，已停止（未回退 V1，未整文件下载）'
            : '流式播放失败，已停止下载',
        failure: RequestFailure.generic,
        kind: failed.isResourceLoader
            ? PlaybackFailure.resourceLoading
            : PlaybackFailure.downloadStalled,
      );
    }
    return null;
  }

  /// Marks the growing file behind a stream as in-use and names the transport
  /// in the diagnostics timeline.
  void _registerActiveFile(PlaySource source, MediaRecord record) {
    if (!source.isStreaming) return;
    _diagnostics.noteStage(
      source.isResourceLoader ? 'RESOURCE_LOADER' : 'PROXY',
      chatId: record.chatId,
      messageId: record.messageId,
      fileId: record.fileId,
    );
    final registry = player.activeFiles;
    if (registry == null) return;
    // What must survive a cache clean is the TDLib pool file behind the URL.
    registry.markInUse(source.path, reason: 'streaming');
    source.proxy?.onClose(() => registry.release(source.path));
  }

  /// Releases the in-use mark a stream added.
  ///
  /// V1 releases through the proxy's close callback; V2 has no port to close,
  /// so the release has to happen where the source is torn down — otherwise
  /// every streamed video would stay "in use" for the rest of the session and
  /// the cache cleaner would never reclaim it.
  void _releaseActiveFile(PlaySource source) {
    if (!source.isStreaming) return;
    if (source.isResourceLoader) player.activeFiles?.release(source.path);
  }

  /// Warms the next [preloadCount] items — a transfer each, nothing else.
  ///
  /// This used to *resolve* each neighbour through the full-download path,
  /// await the whole download, and cache the resulting path. Three things
  /// followed from that, all reported from the device: the activation future
  /// stayed pending for minutes (so a stale activation could resume later),
  /// clicking the prefetched item joined that same future and played a
  /// LOCAL_FILE, and the prefetch's own watchdog could cancel the transfer the
  /// user was watching. A warm start cannot do any of that: it returns as soon
  /// as TDLib accepts the request and produces no [PlaySource].
  Future<void> _prefetchNext(int generation) async {
    // FORCE_STREAMING_TEST: a background download steals bandwidth from the
    // play under test. During acceptance the feed prefetches nothing.
    if (_diagnostics.forceStreamingTest) return;
    final count = preloadCount.clamp(0, AppPreferences.maxPreloadCount);
    if (count <= 0) return;
    final window = ++_prefetchGeneration;
    // What the warm window is, stated as ids: the isolation check compares it
    // against `activeFileId`, and a bare counter cannot answer that.
    final windowIds = <int>[
      for (var offset = 1; offset <= count; offset++)
        if (_index + offset < _items.length) _items[_index + offset].fileId,
    ].where((id) => id != 0).toList();
    _diagnostics.notePreloadWindow(windowIds);
    // A window that was accepted but is no longer wanted keeps downloading.
    // That is the "152 MB loaded first" report: the neighbour's request was
    // still running when the user opened a different video.
    await sources.abandonWarm(windowIds);
    if (!_owns(generation) || window != _prefetchGeneration) return;
    for (var offset = 1; offset <= count; offset++) {
      final next = _index + offset;
      if (next >= _items.length) return;
      if (_disposed || !_owns(generation) || window != _prefetchGeneration) {
        return; // superseded
      }
      final record = _items[next];
      if (record.fileId == 0) continue;
      if (record.fileId == _activeFileId) continue; // never steer the play
      _diagnostics.noteStage(
        'PRELOAD',
        chatId: record.chatId,
        messageId: record.messageId,
        fileId: record.fileId,
      );
      final ok = await sources.prefetch(record.fileId);
      if (ok) {
        _prefetchCompleted++;
      } else {
        _prefetchFailed++;
      }
      // A failed warm start is invisible by design: the item is resolved again
      // (with a visible error) when the user actually reaches it.
    }
  }

  /// The trace of the most recent play, for the diagnostics export.
  PlaybackTrace? _lastTrace;
  PlaybackTrace? get lastTrace => _lastTrace;

  /// The source the live player is reading — a file path or a loopback stream.
  /// Owning it here is what guarantees the proxy dies with the play: page
  /// turns, tab switches, backgrounding and shutdown all run [dispose] on it.
  PlaySource? _activeSource;

  /// The mirror this feed pages, when it pages one. Null for a synthetic source
  /// (tests, previews), in which case nothing is persisted.
  IndexStore? get _store {
    final source = this.source;
    return source is IndexFeedSource ? source.store : null;
  }

  /// Replaces the row for [fresh] and writes it back to the mirror.
  ///
  /// Called when TDLib answered with a different file id or a file name the
  /// index never had. The favourite flag is kept: a metadata refresh must not
  /// silently unstar an item.
  void _absorbRefreshed(MediaRecord fresh) {
    var replaced = false;
    for (var i = 0; i < _items.length; i++) {
      final item = _items[i];
      if (item.chatId != fresh.chatId || item.messageId != fresh.messageId) {
        continue;
      }
      if (item.fileId == fresh.fileId &&
          (item.fileName ?? '') == (fresh.fileName ?? '')) {
        return; // Nothing changed; do not churn the store.
      }
      _items[i] = fresh.copyWith(favorite: item.favorite);
      replaced = true;
      break;
    }
    if (!replaced) return;
    _lastTrace?.mark(PlaybackStage.metadataFetched);
    final store = _store;
    if (store != null) {
      unawaited(store.upsertAll(<MediaRecord>[fresh]).catchError((Object _) => 0));
    }
    _notify();
  }

  /// Fills in a missing file name by re-reading one message.
  ///
  /// Deliberately one shot and silent: a name is a label, and a failed lookup
  /// must not turn into an error screen on top of a playing video.
  Future<void> _fetchNameIfMissing(MediaRecord record) async {
    final lookup = metadata;
    if (lookup == null) return;
    final name = record.fileName;
    if (name != null && name.isNotEmpty) return;
    final fresh = await lookup.fetch(record.chatId, record.messageId);
    if (_disposed || fresh == null) return;
    final freshName = fresh.fileName;
    if (freshName == null || freshName.isEmpty) return;
    _absorbRefreshed(fresh);
  }

  /// Counters for the report: how many prefetches finished, failed, or were
  /// dropped because the user moved on. No gameplay depends on them.
  int _prefetchCompleted = 0;
  int _prefetchFailed = 0;
  int _prefetchGeneration = 0;
  int get prefetchCompleted => _prefetchCompleted;
  int get prefetchFailed => _prefetchFailed;

  Future<void> togglePlayPause() async {
    final active = player.active;
    if (active == null) return;
    if (active.isPlaying) {
      await player.pauseActive();
    } else {
      await active.play();
    }
    refreshProgress();
    _notify();
  }

  Future<void> pause() async {
    await player.pauseActive();
    refreshProgress();
    _notify();
  }

  Future<void> seekTo(Duration target) async {
    final active = player.active;
    if (active is PlayerSeek) {
      await (active as PlayerSeek).seekTo(target);
    }
    _position = target;
    _notify();
  }

  Future<void> setMuted(bool muted) async {
    if (_muted == muted) return;
    _muted = muted;
    await _applyVolume();
    _notify();
  }

  Future<void> _applyVolume() async {
    final active = player.active;
    if (active is PlayerVolume) {
      await (active as PlayerVolume).setVolume(_muted ? 0 : 1);
    }
  }

  void toggleControls() {
    _controlVisible = !_controlVisible;
    _notify();
  }

  void setControlsVisible(bool visible) {
    if (_controlVisible == visible) return;
    _controlVisible = visible;
    _notify();
  }

  /// Reads the playhead from the live handle. Called by a UI timer, and
  /// directly by tests.
  void refreshProgress() {
    final active = player.active;
    if (active is PlayerProgress) {
      _position = (active as PlayerProgress).position;
      _duration = (active as PlayerProgress).duration;
    }
    _captureStreamingEvidence();
    _checkDecoderError(active);
    _maybeRecordProgress();
    _notify();
  }

  /// Takes the streaming evidence at the first confirmed playhead movement.
  ///
  /// This is the moment the whole verdict rests on: the byte counter is
  /// whatever TDLib last reported (`updateFile`), the playhead is whatever
  /// the player reported. Comparing the two here — and only here — is what
  /// separates "played while bytes were still missing" from "played after the
  /// file finished". Nothing is inferred from which code path ran.
  void _captureStreamingEvidence() {
    final active = player.active;
    if (active == null || !active.isPlaying) return;
    if (_position <= Duration.zero) return;
    // Idempotent: the player's own listener may have taken the snapshot
    // first (it fires per value change, this runs on the 250 ms poll).
    _diagnostics.recordFirstPlayback();
    final trace = _lastTrace;
    if (trace == null) return;
    if (!trace.has(PlaybackStage.firstPlayback)) {
      trace.mark(
        PlaybackStage.firstPlayback,
        bytes: _diagnostics.firstPlaybackDownloadedBytes,
      );
    }
    if (!trace.has(PlaybackStage.firstFrame)) {
      trace.mark(PlaybackStage.firstFrame);
    }
  }

  /// A real decoder failure (AVPlayerItem.status == failed) is one recoverable
  /// event: if the file finished downloading while the stream was playing, the
  /// same bytes can be opened from disk. It is **not** a reason to download the
  /// rest of the film — this used to call [_fallbackFullDownload], which on a
  /// 622 MB video meant a decoder hiccup turned into a multi-hundred-megabyte
  /// download. `waitingToPlayAtSpecifiedRate` and a slow proxy wait never reach
  /// here; they are not errors, and the buffering UI already covers them.
  Future<void> _checkDecoderError(PlayerHandle? active) async {
    final reporter = active is PlayerErrorReporter ? active as PlayerErrorReporter : null;
    if (reporter == null) return;
    final error = reporter.lastError;
    if (error == null) return;
    final errorText = error;
    // The raw AVPlayer text can carry container paths; the trace only needs
    // to know that the decoder failed, not where the file lived.
    _lastTrace?.note = 'decoder error (${errorText.length} chars)';
    final record = current;
    if (record == null) return;
    // The recovery below awaits a file measurement. The video the user is
    // watching when it finishes may be a different one, so the generation is
    // taken now and re-checked before anything is installed.
    final generation = _generation;
    final source = _activeSource;
    if (source != null && source.isStreaming) {
      final trace = _lastTrace;
      if (trace != null && !trace.has(PlaybackStage.streamingFallback)) {
        final facts = await sources.inspect(record.fileId);
        if (_ownsRecord(generation, record) && facts.isPlayableFromDisk) {
          _diagnostics.noteDecision(
            proxyAvailable: true,
            decision: 'LOCAL_FILE',
            reason: 'decoder_error_file_now_complete',
            generation: generation,
          );
          trace.mark(PlaybackStage.streamingFallback);
          _diagnostics.notePlayerSource(isStreaming: false, url: facts.path);
          await player.activate(facts.path);
          if (!_ownsRecord(generation, record)) return;
          // The transport served its purpose: release its port / session
          // instead of leaving it behind for the rest of the session.
          await _disposeActiveSource();
          _activeSource = PlaySource.file(facts.path);
          _notify();
          return;
        }
      }
    }
    if (!_ownsRecord(generation, record)) return;
    if (!_disposed && phase != FeedPhase.error) {
      _fail('此视频无法解码', failure: RequestFailure.generic);
    }
  }

  /// Jumps to the saved position for [record], if there is one worth using.
  Future<void> _restoreProgress(MediaRecord record) async {
    final store = watch;
    if (store == null) return;
    try {
      await store.load();
      final entry = store.read(record.chatId, record.messageId);
      if (entry == null) return;
      final target = entry.resumePositionMs;
      if (target <= 0) return;
      final active = player.active;
      if (active is PlayerSeek) await (active as PlayerSeek).seekTo(Duration(milliseconds: target));
      _position = Duration(milliseconds: target);
    } on Object {
      // History is a convenience; a failure here must not stop playback.
    }
  }

  /// Writes the playhead, and marks the item finished when it reaches the end.
  void _maybeRecordProgress() {
    final store = watch;
    final record = current;
    if (store == null || record == null) return;
    if (_duration <= Duration.zero) return;
    final reachedEnd = _position >= _duration - const Duration(milliseconds: 600);
    if (!reachedEnd) {
      // Nothing to persist every tick: only meaningful movement, and only on a
      // whole second, keeps the file small and the writes rare.
      if (_position.inSeconds == _lastPersistedSecond) return;
      _lastPersistedSecond = _position.inSeconds;
      unawaited(_writePosition(store, record, completed: false));
      return;
    }
    final key = WatchEntry.keyOf(record.chatId, record.messageId);
    if (_finishedKey == key) return;
    _finishedKey = key;
    unawaited(_writePosition(store, record, completed: true));
  }

  int _lastPersistedSecond = -1;

  Future<void> _writePosition(
    WatchStore store,
    MediaRecord record, {
    required bool completed,
  }) async {
    try {
      await store.upsert(
        record.chatId,
        record.messageId,
        (current, now) => current.copyWith(
          positionMs: completed ? _duration.inMilliseconds : _position.inMilliseconds,
          durationMs: _duration.inMilliseconds,
          completed: completed || current.completed,
          updatedAtUnix: now,
        ),
      );
    } on Object {
      // Swallowed on purpose: a full disk must not break playback.
    }
  }

  /// Forgets the saved position for one item ("从头再看").
  Future<void> resetProgress(int chatId, int messageId) async {
    try {
      await watch?.clear(chatId, messageId);
    } on Object {
      // Same rule as the write path.
    }
    _finishedKey = null;
    _lastPersistedSecond = -1;
  }

  /// §4.5: releasing on background keeps audio from continuing and frees the
  /// decoder. Coming back re-activates the same item, not the first one.
  Future<void> handleLifecycle(AppLifecycleState state) async {
    if (state == AppLifecycleState.resumed) {
      if (!_releasedForBackground) return;
      _releasedForBackground = false;
      await _activateCurrent();
      return;
    }
    _releasedForBackground = true;
    _stopPolling();
    // Persist the playhead before the decoder goes away: the poll timer was
    // the only writer, and stopping it above would drop the final position.
    refreshProgress();
    // Backgrounding invalidates any activation still in flight: it must not
    // install a player behind a screen the user cannot see.
    _generation++;
    _gate.cancelAll();
    await player.release();
    // The source dies with the visible play; resuming re-resolves and picks up
    // wherever the download got to (cache hit if it finished).
    await _disposeActiveSource();
  }

  void _startPolling() {
    final interval = pollInterval;
    if (interval == null || _poll != null) return;
    _poll = Timer.periodic(interval, (_) => refreshProgress());
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  void _fail(
    String message, {
    RequestFailure failure = RequestFailure.generic,
    PlaybackFailure? kind,
  }) {
    _phase = FeedPhase.error;
    _error = message;
    _failure = failure;
    // One classification, recorded once: the panel, the exported report and
    // the error page then name the same reason. Classified from the message
    // only when the caller did not know better — most call sites throw a typed
    // exception and pass its kind explicitly.
    _diagnostics.noteFailure(
      kind ?? classifyPlaybackMessage(message),
      message: message,
    );
    _bufferFraction = 0;
    _stopPolling();
    _notify();
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  /// Releases the player, stops the transfer and the poll timer. Must be called
  /// before [dispose] from a widget that can await.
  Future<void> shutdown() async {
    _generation++;
    _gate.cancelAll();
    _stopPolling();
    // Leaving the feed is the one guaranteed write: without it the last second
    // of a video the user just watched would never reach the watch store.
    refreshProgress();
    final record = current;
    if (record != null && record.fileId != 0) {
      unawaited(sources.cancel(record.fileId));
    }
    await player.release();
    await _disposeActiveSource();
  }

  @override
  void dispose() {
    _disposed = true;
    // Nothing may finish into a disposed controller: bumping the generation
    // makes every in-flight callback stale by construction.
    _generation++;
    _stopPolling();
    _gate.cancelAll();
    super.dispose();
  }
}

/// Which overlay layers the feed shows for a given screen orientation.
///
/// Confirmed design decision #4: in landscape the bottom info block is hidden so
/// the video gets the whole screen. The controls stay: a landscape video with no
/// way to pause or rotate back is a trap.
@immutable
class FeedOverlayPlan {
  const FeedOverlayPlan({
    required this.showInfo,
    required this.showTopBar,
    required this.showControls,
  });

  factory FeedOverlayPlan.forOrientation(Orientation orientation) {
    final portrait = orientation == Orientation.portrait;
    return FeedOverlayPlan(
      showInfo: portrait,
      showTopBar: true,
      // Controls are only rendered when the user asked for them AND there is
      // room; hiding them in landscape would remove the rotate-back button.
      showControls: true,
    );
  }

  final bool showInfo;
  final bool showTopBar;
  final bool showControls;

  @override
  bool operator ==(Object other) =>
      other is FeedOverlayPlan &&
      other.showInfo == showInfo &&
      other.showTopBar == showTopBar &&
      other.showControls == showControls;

  @override
  int get hashCode => Object.hash(showInfo, showTopBar, showControls);

  @override
  String toString() =>
      'FeedOverlayPlan(info=$showInfo, top=$showTopBar, controls=$showControls)';
}

/// Immersive-playback decisions, extracted so they can be tested without a
/// widget tree.
///
/// The rule the product settled on: the video owns the whole screen while it
/// is playing. Channel name, number entry, title, date, size, position and the
/// synced count are all "chrome" and stay hidden until the user taps once.
/// Errors and buffering are NOT chrome — they are the actual state of the
/// playback and stay visible regardless.
@immutable
class FeedImmersivePlan {
  const FeedImmersivePlan._();

  /// True when the pager is showing items at all — the phase where overlays
  /// make sense. Loading/empty screens replace the pager entirely, so there is
  /// nothing for a tap to reveal.
  static bool playbackActive({required FeedPhase phase, required int itemCount}) {
    if (itemCount <= 0) return false;
    return phase == FeedPhase.buffering ||
        phase == FeedPhase.ready ||
        // An error on top of a loaded list still shows the items behind it;
        // the failure card is independent and always visible.
        phase == FeedPhase.error;
  }

  /// Whether the top bar, the info block and the controls render. One tap
  /// toggles [FeedController.controlVisible]; this only decides whether that
  /// flag has anything to reveal.
  static bool overlaysVisible({
    required FeedPhase phase,
    required int itemCount,
    required bool controlVisible,
  }) =>
      controlVisible && playbackActive(phase: phase, itemCount: itemCount);

  /// Whether the shell must hide its bottom tab bar: the feed tab is active
  /// and a video is on screen. Revealing overlays with a tap does NOT bring
  /// the tab bar back — the product explicitly wants the three main tabs to
  /// stay hidden until the user leaves the feed.
  static bool tabBarHidden({
    required bool feedTabActive,
    required bool playbackActive,
  }) =>
      feedTabActive && playbackActive;
}
