import 'history_source.dart';
import 'index_store.dart';
import 'media_record.dart';

class SyncCancelled implements Exception {
  const SyncCancelled();

  @override
  String toString() => 'SyncCancelled';
}

/// Cooperative cancellation so leaving a channel (or a newer sync) can stop an
/// in-flight page walk instead of finishing it into a screen nobody watches.
class SyncCancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;

  void throwIfCancelled() {
    if (_cancelled) throw const SyncCancelled();
  }
}

/// Hard limits. A channel with 200k messages must never be pulled in one go:
/// that is the OOM case the task book calls out.
class SyncLimits {
  const SyncLimits._();

  static const int minPageSize = 1;
  static const int maxPageSize = 100;
  static const int defaultPageSize = 50;
  static const int defaultPagesPerCycle = 2;

  static int clampPageSize(int value) =>
      value.clamp(minPageSize, maxPageSize);
}

class PageLoadResult {
  const PageLoadResult({
    required this.chatId,
    required this.records,
    required this.rawMessageCount,
    required this.requestedLimit,
    required this.cursor,
    required this.nextCursor,
    required this.hasMore,
    this.error,
    this.inserted = 0,
    this.cancelled = false,
    this.reachedEnd = false,
  });

  const PageLoadResult.failure({
    required this.chatId,
    required String this.error,
    required this.requestedLimit,
  })  : records = const <MediaRecord>[],
        rawMessageCount = 0,
        cursor = null,
        nextCursor = null,
        hasMore = false,
        inserted = 0,
        cancelled = false,
        reachedEnd = false;

  const PageLoadResult.cancelled({required this.chatId})
      : records = const <MediaRecord>[],
        rawMessageCount = 0,
        requestedLimit = 0,
        cursor = null,
        nextCursor = null,
        hasMore = false,
        error = null,
        inserted = 0,
        cancelled = true,
        reachedEnd = false;

  final int chatId;
  final List<MediaRecord> records;
  final int rawMessageCount;
  final int requestedLimit;

  /// True when TDLib returned a short page: the channel has no older messages.
  /// `hasMore == false` alone cannot tell this apart from "the cursor refused
  /// to advance", and the UI must show a different message for each.
  final bool reachedEnd;
  final int? cursor;

  /// Pass this back as [ChannelSyncEngine.loadPage]'s `cursor` to get the next
  /// older page. Null means the walk reached the start of the channel.
  final int? nextCursor;
  final bool hasMore;
  final String? error;
  final int inserted;
  final bool cancelled;

  bool get isError => error != null;
}

class SyncCycleReport {
  const SyncCycleReport({
    required this.pages,
    required this.rawMessages,
    required this.insertedRecords,
    required this.errors,
    required this.cancelled,
    this.reachedEnd = false,
    this.lastError,
    this.channelsTotal = 0,
    this.channelsAtEnd = 0,
    this.channelsProgressed = 0,
    this.retryAfter,
  });

  final int pages;
  final int rawMessages;
  final int insertedRecords;
  final List<String> errors;
  final bool cancelled;

  /// True only when **every** channel in this cycle reported a short page.
  ///
  /// It used to be "any channel reached its end", which is why a 725-video
  /// channel stopped growing: the directory also holds channels with five
  /// messages, the first of those ended the cycle, and the scheduler treated
  /// the whole backfill as finished.
  final bool reachedEnd;

  /// The last error text, for the screen. Kept alongside [errors] so callers
  /// that only show one line do not have to parse the list.
  final String? lastError;

  /// How many channels the cycle was asked to walk, how many are fully walked,
  /// and how many moved their cursor. The three numbers are what tells "still
  /// working" apart from "nothing left to do".
  final int channelsTotal;
  final int channelsAtEnd;
  final int channelsProgressed;

  /// Set when TDLib answered `FLOOD_WAIT_<n>`: the scheduler must wait this
  /// long before the next slice, or it will be answered the same way forever.
  final Duration? retryAfter;

  bool get isError => errors.isNotEmpty;

  /// True when at least one channel advanced, even if others failed.
  bool get madeProgress => channelsProgressed > 0 || insertedRecords > 0;
}

/// Pulls channel history one bounded page at a time into the local mirror.
///
/// Rules encoded here:
/// * exactly one `getChatHistory` call per [loadPage];
/// * `limit` is clamped to [SyncLimits.maxPageSize] regardless of what the
///   caller asks for;
/// * a cycle touches at most [maxPagesPerCycle] pages of each channel;
/// * every message is upserted by `(chatId, messageId)`, so re-syncing the same
///   range three times leaves the row count unchanged;
/// * errors never turn into "success with zero rows".
class ChannelSyncEngine {
  ChannelSyncEngine({
    required this.source,
    required this.store,
    int pageSize = SyncLimits.defaultPageSize,
    this.maxPagesPerCycle = SyncLimits.defaultPagesPerCycle,
  }) : pageSize = SyncLimits.clampPageSize(pageSize);

  final HistorySource source;
  final IndexStore store;
  final int pageSize;
  final int maxPagesPerCycle;

  /// Fetches one page. [cursor] is the `from_message_id` returned by the
  /// previous page; null starts from the newest message.
  Future<PageLoadResult> loadPage({
    required int chatId,
    int? cursor,
    SyncCancelToken? cancel,
  }) async {
    final limit = SyncLimits.clampPageSize(pageSize);
    if (cancel?.isCancelled ?? false) {
      return PageLoadResult.cancelled(chatId: chatId);
    }

    final page = await source.history(
      chatId: chatId,
      fromMessageId: cursor ?? 0,
      offset: 0,
      limit: limit,
    );
    if (cancel?.isCancelled ?? false) {
      return PageLoadResult.cancelled(chatId: chatId);
    }
    if (page.hasError) {
      return PageLoadResult.failure(
        chatId: chatId,
        error: page.error!,
        requestedLimit: limit,
      );
    }

    final records = <MediaRecord>[];
    // Cursor and watermark come from the **raw** batch, never from the filtered
    // video list. A batch of 100 messages may contain one video as its newest
    // entry; taking that video's id as the cursor re-requests the same batch
    // forever and the channel stops growing — which is exactly the "38 items,
    // bottom never loads more" report.
    int? lowestId;
    int? highestId;
    int? rawLowestId;
    int? rawHighestId;
    for (final message in page.messages) {
      final rawId = message['id'];
      if (rawId is int) {
        if (rawLowestId == null || rawId < rawLowestId) rawLowestId = rawId;
        if (rawHighestId == null || rawId > rawHighestId) rawHighestId = rawId;
      }
      final record = MediaRecord.fromMessage(chatId: chatId, message: message);
      if (record == null) continue;
      records.add(record);
      final id = record.messageId;
      if (lowestId == null || id < lowestId) lowestId = id;
      if (highestId == null || id > highestId) highestId = id;
    }
    // Media ids for the "what did we store" watermark, raw ids for the walk.
    lowestId ??= rawLowestId;
    highestId ??= rawHighestId;

    final inserted = await store.upsertAll(records);
    if (lowestId != null || highestId != null || rawLowestId != null) {
      final existing = store.watermark(chatId);
      await store.setWatermark(
        chatId: chatId,
        newestMessageId: _maxNullable(existing?.newestMessageId, highestId),
        oldestMessageId: _minNullable(existing?.oldestMessageId, lowestId),
        // The resume point is the oldest **raw** id, not the oldest media id.
        // A 50-message batch with one video would otherwise leave a cursor that
        // re-reads 49 messages on the next pass (or, when the media ids happen
        // to line up, no progress at all).
        oldestScannedMessageId: rawLowestId,
        nowUnix: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );
    }

    // TDLib returns fewer than `limit` messages when it hits the start of the
    // history; that is the only end-of-channel signal available.
    final filledPage = page.messages.length >= limit && page.messages.isNotEmpty;
    // The next request is "older than the oldest message in this batch".
    final rawCursor = rawLowestId;
    // A cursor that does not move would make the caller loop on one batch
    // forever, so a non-progressing page counts as the end of the walk.
    final advanced = rawCursor != null && (cursor == null || rawCursor < cursor);
    final hasMore = filledPage && advanced;
    final nextCursor = hasMore ? rawCursor : null;

    return PageLoadResult(
      chatId: chatId,
      records: records,
      rawMessageCount: page.messages.length,
      requestedLimit: limit,
      cursor: cursor,
      nextCursor: nextCursor,
      hasMore: hasMore,
      inserted: inserted,
      // Distinguishes "this batch had no video, keep walking" from "the channel
      // has no more history": the caller needs both to decide what to show.
      reachedEnd: !filledPage,
    );
  }

  /// Bounded multi-page cycle used on app launch / pull-to-refresh.
  /// Reads a bounded number of pages per channel.
  ///
  /// [resume] decides where the walk starts:
  /// * `true` (default) continues from the scanned cursor — the oldest **raw**
  ///   message id already consumed — so repeated calls keep digging into a
  ///   4000-message channel instead of re-reading the same newest pages;
  /// * `false` starts at the newest message, which is what a pull-to-refresh
  ///   wants.
  ///
  /// [pageGap] spaces `getChatHistory` calls. Zero-gap bursts are what get a
  /// long backfill answered with `FLOOD_WAIT`, and a flood wait is
  /// indistinguishable from a stall to the user.
  Future<SyncCycleReport> syncCycle({
    required List<int> chatIds,
    int? pagesPerChannel,
    SyncCancelToken? cancel,
    bool resume = true,
    Duration pageGap = const Duration(milliseconds: 120),
  }) async {
    final pagesBudget = (pagesPerChannel ?? maxPagesPerCycle).clamp(1, 10);
    var pages = 0;
    var raw = 0;
    var inserted = 0;
    final errors = <String>[];
    var cancelled = false;
    var progressed = 0;
    var atEnd = 0;
    String? lastError;
    Duration? retryAfter;

    for (final chatId in chatIds) {
      // Resume from the scan cursor; fall back to the media watermark for rows
      // written by an older build that predates the field.
      final watermark = store.watermark(chatId);
      int? cursor = resume ? (watermark?.scanCursor ?? watermark?.oldestMessageId) : null;
      var channelAtEnd = false;
      var channelMoved = false;
      for (var i = 0; i < pagesBudget; i++) {
        if (cancel?.isCancelled ?? false) {
          cancelled = true;
          break;
        }
        if (pages > 0 && pageGap > Duration.zero) {
          await Future<void>.delayed(pageGap);
        }
        final result = await loadPage(chatId: chatId, cursor: cursor, cancel: cancel);
        if (result.cancelled) {
          cancelled = true;
          break;
        }
        if (result.isError) {
          errors.add('chat $chatId: ${result.error}');
          lastError = result.error;
          retryAfter ??= parseRetryAfter(result.error);
          // One bad channel must not stop the others: a channel the account
          // left, or a flood wait on one id, used to end the whole cycle.
          break;
        }
        pages++;
        raw += result.rawMessageCount;
        inserted += result.inserted;
        if (result.nextCursor != null &&
            (cursor == null || result.nextCursor! < cursor)) {
          channelMoved = true;
        }
        if (result.reachedEnd) {
          channelAtEnd = true;
          break;
        }
        if (!result.hasMore || result.nextCursor == null) break;
        cursor = result.nextCursor;
      }
      if (channelMoved) progressed++;
      if (channelAtEnd) atEnd++;
      if (cancelled) break;
    }

    return SyncCycleReport(
      pages: pages,
      rawMessages: raw,
      insertedRecords: inserted,
      errors: errors,
      cancelled: cancelled,
      // Only "every channel is exhausted" ends the backfill. Anything else
      // means there is still history to walk.
      reachedEnd: chatIds.isNotEmpty && atEnd == chatIds.length && !cancelled,
      lastError: lastError,
      channelsTotal: chatIds.length,
      channelsAtEnd: atEnd,
      channelsProgressed: progressed,
      retryAfter: retryAfter,
    );
  }

  /// Walks the whole channel page by page. Only used by tests and diagnostics —
  /// the UI path is [MediaPager], which loads on demand.
  Future<SyncCycleReport> drainChannel({
    required int chatId,
    int maxPages = 1000,
    SyncCancelToken? cancel,
  }) async {
    int? cursor;
    var pages = 0;
    var raw = 0;
    var inserted = 0;
    final errors = <String>[];
    var cancelled = false;
    var reachedEnd = false;
    String? lastError;

    while (pages < maxPages) {
      if (cancel?.isCancelled ?? false) {
        cancelled = true;
        break;
      }
      final result = await loadPage(chatId: chatId, cursor: cursor, cancel: cancel);
      if (result.cancelled) {
        cancelled = true;
        break;
      }
      if (result.isError) {
        errors.add(result.error!);
        lastError = result.error;
        break;
      }
      pages++;
      raw += result.rawMessageCount;
      inserted += result.inserted;
      if (result.reachedEnd) {
        reachedEnd = true;
        break;
      }
      if (!result.hasMore || result.nextCursor == null) break;
      cursor = result.nextCursor;
    }

    return SyncCycleReport(
      pages: pages,
      rawMessages: raw,
      insertedRecords: inserted,
      errors: errors,
      cancelled: cancelled,
      reachedEnd: reachedEnd,
      lastError: lastError,
    );
  }

  static int? _maxNullable(int? a, int? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a > b ? a : b;
  }

  static int? _minNullable(int? a, int? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a < b ? a : b;
  }
}

/// Pulls the wait out of `TDLib error 420: FLOOD_WAIT_37`.
///
/// Returning null means "not a flood wait", which is a different instruction
/// to the scheduler: a flood wait must be honoured to the second, anything else
/// may be retried with ordinary backoff.
Duration? parseRetryAfter(String? text) {
  if (text == null || text.isEmpty) return null;
  final match = RegExp(r'FLOOD_WAIT_(\d+)').firstMatch(text.toUpperCase());
  if (match == null) return null;
  final seconds = int.tryParse(match.group(1)!);
  if (seconds == null || seconds <= 0) return null;
  // Capped: a bogus 86400 in an error string must not park the app for a day.
  return Duration(seconds: seconds.clamp(1, 900));
}

/// Scroll-to-bottom pagination over the local mirror (not over Telegram).
///
/// The UI gets a fixed page size and a cursor; there is no API here that can
/// ask for "everything", so a 200k-row index cannot be materialised at once.
class MediaPager {
  MediaPager({
    required this.store,
    this.chatId,
    this.favoritesOnly = false,
    int pageSize = 40,
  }) : pageSize = pageSize.clamp(1, 200);

  final IndexStore store;
  final int? chatId;
  final bool favoritesOnly;
  final int pageSize;

  String? _cursor;
  bool _hasMore = true;
  bool _loading = false;

  bool get hasMore => _hasMore;
  bool get isLoading => _loading;
  int get loadedCount => _loaded;
  int _loaded = 0;

  Future<IndexPage> next() async {
    if (!_hasMore || _loading) return IndexPage.empty;
    _loading = true;
    try {
      final page = await store.page(
        limit: pageSize,
        cursor: _cursor,
        favoritesOnly: favoritesOnly,
        chatId: chatId,
      );
      _cursor = page.nextCursor;
      _hasMore = page.hasMore;
      _loaded += page.items.length;
      return page;
    } finally {
      _loading = false;
    }
  }

  void reset() {
    _cursor = null;
    _hasMore = true;
    _loaded = 0;
  }
}
