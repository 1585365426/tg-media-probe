/// E1 — does this TDLib build really serve consecutive bounded ranges?
///
/// This file exists to answer one question with measurements instead of
/// theory: can `downloadFile(offset, limit)` be the data source of a chunked
/// player, or does TDLib only ever hold one range and discard the previous one?
///
/// Everything here talks to a real TDLib client over a real Telegram account.
/// There is no fake backend and no simulated progress: a chunk counts as
/// delivered only when the bytes are readable at the expected absolute offset
/// and two independent readers (POSIX `pread` on `local.path`, and TDLib's own
/// `readFilePart`) return the same SHA-256.
///
/// The measurements it records, per chunk:
///
/// * `downloadFile` round-trip (ack latency) and any error it returned;
/// * the exact `updateFile` sequence, with `downloaded_size`,
///   `downloaded_prefix_size`, `download_offset`, `is_downloading_active`;
/// * `getFileDownloadedPrefixSize(offset)` — the only call that answers
///   "how many contiguous bytes exist at *this* offset";
/// * bytes+sha of a POSIX read and of `readFilePart` of the same window;
/// * whether an earlier window is still readable after later offsets ran.
///
/// Pure planning/verdict logic lives at the top so it can be unit tested
/// without a TDLib; the engine below it is deliberately dumb and linear.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../util/redact.dart';
import '../util/sha256.dart';
import 'td_client.dart';
import 'td_models.dart';
import 'td_requests.dart';

// ---------------------------------------------------------------------------
// Planning — pure
// ---------------------------------------------------------------------------

/// One bounded range request: `downloadFile(offset, limit)`.
class ChunkRange {
  const ChunkRange({
    required this.index,
    required this.offset,
    required this.limit,
  });

  final int index;
  final int offset;
  final int limit;

  int get end => offset + limit;

  @override
  String toString() => 'chunk#$index [$offset, $end)';
}

/// Splits a file into the ranges E1 asks for, in order.
///
/// The last range is clamped to the file end so a 23 MB test never asks for
/// bytes past EOF (TDLib answers that with an error, which would be blamed on
/// chunking rather than on the request).
List<ChunkRange> planChunks({
  required int fileSize,
  required int chunkBytes,
  int maxChunks = 5,
}) {
  if (chunkBytes <= 0) throw ArgumentError.value(chunkBytes, 'chunkBytes');
  if (maxChunks <= 0) throw ArgumentError.value(maxChunks, 'maxChunks');
  if (fileSize <= 0) return const <ChunkRange>[];

  final ranges = <ChunkRange>[];
  for (var i = 0; i < maxChunks; i++) {
    final offset = i * chunkBytes;
    if (offset >= fileSize) break;
    final limit =
        (offset + chunkBytes > fileSize) ? fileSize - offset : chunkBytes;
    ranges.add(ChunkRange(index: i, offset: offset, limit: limit));
  }
  return ranges;
}

// ---------------------------------------------------------------------------
// Observations
// ---------------------------------------------------------------------------

/// One `localFile`, as it looked at one moment.
class FileSnapshot {
  const FileSnapshot({
    required this.tMs,
    required this.state,
    required this.diskSize,
  });

  /// Milliseconds since the run started. Monotonic: it comes from a Stopwatch,
  /// so a clock change mid-run cannot make the ordering lie.
  final int tMs;
  final FileState state;

  /// `stat` of `state.path`, or -1 when the path is empty/missing. Kept apart
  /// from what TDLib *claims*, because the whole point of E1 is to catch the
  /// case where those two disagree.
  final int diskSize;

  String get line => 't=${tMs}ms ${state.transferLine} disk=$diskSize';
}

/// One `updateFile` event, kept in arrival order.
class FileEvent {
  const FileEvent({
    required this.seq,
    required this.tMs,
    required this.state,
    required this.diskSize,
  });

  final int seq;
  final int tMs;
  final FileState state;
  final int diskSize;

  String get line => 't=$tMs ${state.transferLine} disk=$diskSize';
}

/// What the event stream did during one chunk.
class ChunkSignals {
  const ChunkSignals({
    required this.events,
    required this.activeRuns,
    required this.endedInactive,
    required this.offsetDrift,
    required this.maxGapMs,
    required this.firstEventMs,
  });

  final int events;

  /// Number of `active: false -> true` transitions. More than one inside a
  /// single bounded range means TDLib tore the task down and built it again.
  final int activeRuns;

  /// True when the last event of the window shows no transfer running, which
  /// is the expected end state of a `limit > 0` request.
  final bool endedInactive;

  /// True when TDLib reported a `download_offset` other than the one asked for.
  final bool offsetDrift;

  /// Longest silence between two events, in ms. A large value next to a
  /// satisfied chunk means the chunk arrived in one burst after a pause.
  final int maxGapMs;

  /// When the first event of this window arrived, relative to the request.
  final int firstEventMs;

  static const ChunkSignals none = ChunkSignals(
    events: 0,
    activeRuns: 0,
    endedInactive: false,
    offsetDrift: false,
    maxGapMs: 0,
    firstEventMs: -1,
  );

  /// Derives the signals from the events that arrived inside one chunk window.
  static ChunkSignals of(List<FileEvent> window, {required int requestedOffset}) {
    if (window.isEmpty) return none;
    var runs = 0;
    var wasActive = false;
    var drift = false;
    var maxGap = 0;
    for (var i = 0; i < window.length; i++) {
      final event = window[i];
      if (event.state.isDownloadingActive && !wasActive) runs++;
      wasActive = event.state.isDownloadingActive;
      if (event.state.downloadOffset != requestedOffset &&
          event.state.downloadOffset != 0) {
        drift = true;
      }
      if (i > 0) {
        final gap = event.tMs - window[i - 1].tMs;
        if (gap > maxGap) maxGap = gap;
      }
    }
    return ChunkSignals(
      events: window.length,
      activeRuns: runs,
      endedInactive: !wasActive,
      offsetDrift: drift,
      maxGapMs: maxGap,
      firstEventMs: window.first.tMs,
    );
  }
}

/// How a chunk's wait ended.
class SettleOutcome {
  const SettleOutcome({
    required this.satisfied,
    required this.gate,
    required this.ms,
    this.note = '',
  });

  final bool satisfied;

  /// Which evidence ended the wait: `prefixFromOffset`, `downloadedSize`,
  /// `diskAfterInactive`, `synchronousReturn`, or `timeout`.
  final String gate;
  final int ms;
  final String note;
}

/// One read of a byte window, by whichever reader produced it.
class WindowRead {
  const WindowRead({
    required this.bytes,
    required this.ms,
    required this.sha,
    this.error,
  });

  final int bytes;
  final int ms;
  final String sha;
  final String? error;

  bool get ok => error == null;

  static WindowRead failed(String error, int ms) =>
      WindowRead(bytes: 0, ms: ms, sha: '', error: error);
}

/// Everything measured for one bounded range.
class ChunkRow {
  ChunkRow({
    required this.range,
    required this.ackMs,
    required this.ackError,
    required this.settle,
    required this.before,
    required this.after,
    required this.signals,
    required this.prefixFromOffset,
    required this.prefixFromZero,
    required this.prefixFromOffsetError,
    required this.prefixFromZeroError,
    required this.posix,
    required this.part,
  });

  final ChunkRange range;
  final int ackMs;
  final String? ackError;
  final SettleOutcome settle;
  final FileSnapshot before;
  final FileSnapshot after;
  final ChunkSignals signals;

  /// `getFileDownloadedPrefixSize(fileId, range.offset)` — contiguous bytes
  /// available at this chunk's own start.
  final int? prefixFromOffset;

  /// Same call with `offset = 0`, i.e. TDLib's idea of the file's prefix.
  final int? prefixFromZero;
  final String? prefixFromOffsetError;
  final String? prefixFromZeroError;

  final WindowRead posix;
  final WindowRead part;

  /// POSIX and TDLib returned identical bytes for the same window.
  bool get readersAgree => posix.ok && part.ok && posix.sha == part.sha;

  /// The window really holds as many bytes as was asked for.
  bool get windowComplete => posix.ok && posix.bytes == range.limit;

  bool get delivered => windowComplete && readersAgree && settle.satisfied;
}

/// An earlier window, re-read after later offsets ran.
class PersistenceCheck {
  const PersistenceCheck({
    required this.targetIndex,
    required this.checkedAfterChunk,
    required this.offset,
    required this.limit,
    required this.originalSha,
    required this.recheck,
  });

  final int targetIndex;
  final int checkedAfterChunk;
  final int offset;
  final int limit;
  final String originalSha;
  final WindowRead recheck;

  bool get survived =>
      recheck.ok && recheck.bytes == limit && recheck.sha == originalSha;

  String get label =>
      'chunk#$targetIndex after chunk#$checkedAfterChunk '
      '${survived ? 'intact' : 'CHANGED'}';
}

// ---------------------------------------------------------------------------
// Verdict — pure
// ---------------------------------------------------------------------------

/// The four answers a probe is allowed to give. Nothing else is a status.
class ProbeVerdict {
  const ProbeVerdict({
    required this.status,
    required this.reasons,
    required this.notes,
  });

  /// `PASS` / `CONDITIONAL` / `FAIL` / `NOT TESTED` / `UNKNOWN`.
  final String status;
  final List<String> reasons;

  /// Observations that do not decide the verdict but must reach the report,
  /// e.g. "the prefix field does not grow monotonically after a mid-file
  /// download" — that changes the player's design without failing E1.
  final List<String> notes;

  static const ProbeVerdict notTested = ProbeVerdict(
    status: 'NOT TESTED',
    reasons: <String>['没有执行任何分块请求'],
    notes: <String>[],
  );
}

/// First 12 hex characters of a digest, or the placeholder when it is empty.
String _shortSha(String sha) =>
    sha.isEmpty ? '<none>' : sha.substring(0, sha.length < 12 ? sha.length : 12);

/// Turns measurements into a verdict. No I/O, so the rules can be tested.
///
/// The asymmetry matters: a missing byte is `FAIL` (the data source cannot be
/// trusted), while data that was delivered correctly but later evicted is
/// `CONDITIONAL` (the player must re-request instead of assuming a cache).
ProbeVerdict evaluateE1({
  required List<ChunkRow> rows,
  required List<PersistenceCheck> persistence,
  required bool fileWasCompleteBeforeRun,
  required int chunkBytes,
}) {
  if (rows.isEmpty) return ProbeVerdict.notTested;

  final reasons = <String>[];
  final notes = <String>[];
  var hardFailure = false;

  for (final row in rows) {
    final label = 'chunk#${row.range.index}';
    if (row.ackError != null) {
      reasons.add('$label downloadFile 报错: ${row.ackError}');
      hardFailure = true;
      continue;
    }
    if (!row.settle.satisfied) {
      reasons.add('$label 在 ${row.settle.ms}ms 内没有拿到完整窗口'
          '（gate=${row.settle.gate}）');
      hardFailure = true;
      continue;
    }
    if (!row.windowComplete) {
      reasons.add('$label POSIX 只读到 ${row.posix.bytes}/${row.range.limit} B'
          '${row.posix.error == null ? '' : '（${row.posix.error}）'}');
      hardFailure = true;
    }
    if (!row.posix.ok || !row.part.ok) {
      reasons.add('$label 读取失败 '
          'posix=${row.posix.error ?? 'ok'} part=${row.part.error ?? 'ok'}');
      hardFailure = true;
    } else if (!row.readersAgree) {
      reasons.add('$label 两个读取器内容不一致 '
          'posix=${_shortSha(row.posix.sha)} '
          'part=${_shortSha(row.part.sha)}');
      hardFailure = true;
    }
  }

  // A chunk that needed more than one task build is not a failure by itself,
  // but it is the difference between "chunking is cheap" and "every offset
  // switch reconnects", so it has to be said out loud.
  final rebuilt = rows.where((r) => r.signals.activeRuns > 1).toList();
  if (rebuilt.isNotEmpty) {
    notes.add('${rebuilt.length} 个分块出现多次 download task 重建'
        '（${rebuilt.map((r) => '#${r.range.index}(${r.signals.activeRuns})').join(', ')}）');
  }

  final drifted = rows.where((r) => r.signals.offsetDrift).toList();
  if (drifted.isNotEmpty) {
    notes.add('${drifted.length} 个分块期间 download_offset 与请求值不同'
        '（${drifted.map((r) => '#${r.range.index}').join(', ')}）');
  }

  // Q2: which anchor does `downloaded_prefix_size` use?
  //
  // The schema says it is counted from `download_offset`
  // (`//@download_offset ... downloaded_prefix_size is calculated from this
  // offset`), which would make it useless as an absolute watermark. That is a
  // documentation claim, so the run checks it: with a download of chunk k
  // starting at k*chunkBytes, a relative prefix reaches `offset + limit`
  // while an absolute one would have to reach the same number from zero.
  final anchoredToOffset = rows.every((r) =>
      r.after.state.downloadOffset + r.after.state.downloadedPrefixSize >=
      r.range.end);
  final anchoredToZero =
      rows.every((r) => r.after.state.downloadedPrefixSize >= r.range.end);

  if (rows.length <= 1) {
    notes.add('只有 1 个分块，无法判定 downloaded_prefix_size 的锚点');
  } else if (anchoredToOffset && !anchoredToZero) {
    notes.add('downloaded_prefix_size 相对 download_offset 计：'
        '必须算 download_offset + downloaded_prefix_size，'
        '直接当绝对水位会读到错位置');
  } else if (anchoredToOffset && anchoredToZero) {
    notes.add('两种解释都成立（prefix 一路涨到 chunkEnd），本次无法区分锚点');
  } else {
    notes.add('download_offset + downloaded_prefix_size 也没覆盖到 chunkEnd：'
        '它既不是绝对水位也不是本区间的完整前缀，只能当进度值');
  }

  final fromOffsetOk =
      rows.where((r) => (r.prefixFromOffset ?? 0) >= r.range.limit).length;
  final fromZeroOk =
      rows.where((r) => (r.prefixFromZero ?? 0) >= r.range.end).length;
  notes.add('getFileDownloadedPrefixSize(offset) 在 $fromOffsetOk/${rows.length} '
      '个分块上直接给出整窗可用；(0) 在 $fromZeroOk/${rows.length} 个分块上'
      '达到 chunkEnd');

  if (persistence.isNotEmpty) {
    final lost = persistence.where((c) => !c.survived).toList();
    if (lost.isEmpty) {
      notes.add('${persistence.length} 次复查中，早先的分块在后续 offset 切换后'
          '仍然完整可读（旧数据不会被立刻丢弃）');
    } else {
      notes.add('${lost.length}/${persistence.length} 次复查发现早先的分块变了：'
          '${lost.map((c) => c.label).join(', ')}');
    }
  }

  if (fileWasCompleteBeforeRun) {
    notes.add('实验开始前文件已完整，本次没有观测到真实的下载过程');
  }

  if (hardFailure) {
    return ProbeVerdict(status: 'FAIL', reasons: reasons, notes: notes);
  }
  if (fileWasCompleteBeforeRun) {
    return ProbeVerdict(
      status: 'CONDITIONAL',
      reasons: reasons
        ..add('文件在实验前已完整，分块下载行为未被观测；需要先清空或换一个未缓存的视频'),
      notes: notes,
    );
  }
  final anyLost = persistence.any((c) => !c.survived);
  if (anyLost) {
    return ProbeVerdict(
      status: 'CONDITIONAL',
      reasons: reasons
        ..add('分块本身可取，但旧分块在后续 offset 切换后不可读；'
            '播放器不能假设已取过的区间还在（chunkBytes=$chunkBytes）'),
      notes: notes,
    );
  }
  return ProbeVerdict(
    status: 'PASS',
    reasons: reasons
      ..add('${rows.length} 个连续分块全部完整、双读取器一致、旧分块存活'),
    notes: notes,
  );
}

// ---------------------------------------------------------------------------
// Engine
// ---------------------------------------------------------------------------

/// The TDLib build this app links, as pinned in `scripts/fetch_tdlib.sh`.
///
/// Written into every probe report: a verdict without the library version is
/// not reproducible, and TDLib's file-download semantics have changed between
/// releases before.
const String kTdlibBuildVersion = '1.8.69-025086e3';

/// A video found in an authorised channel, with the identity E1 needs.
class ProbeVideo {
  const ProbeVideo({
    required this.chatId,
    required this.chatTitle,
    required this.messageId,
    required this.fileId,
    required this.size,
    this.width,
    this.height,
    this.durationSeconds,
    this.mimeType,
    this.fileName,
  });

  final int chatId;
  final String chatTitle;
  final int messageId;
  final int fileId;
  final int size;
  final int? width;
  final int? height;
  final int? durationSeconds;
  final String? mimeType;
  final String? fileName;

  String get sizeLabel {
    if (size >= 1 << 30) {
      return '${(size / (1 << 30)).toStringAsFixed(2)} GB';
    }
    if (size >= 1 << 20) {
      return '${(size / (1 << 20)).toStringAsFixed(1)} MB';
    }
    return '${(size / 1024).toStringAsFixed(0)} KB';
  }

  String get label =>
      '$sizeLabel · ${width ?? 0}x${height ?? 0} · '
      '${durationSeconds ?? 0}s · ${mimeType ?? '?'} · fileId=$fileId';
}

/// The three size classes E1 asks for. A run is still valid on a different
/// size — the report records what was actually tested — but a sample far from
/// these numbers says nothing about the 593 MB case.
const List<int> kSampleTargets = <int>[
  23 * 1024 * 1024,
  152 * 1024 * 1024,
  593 * 1024 * 1024,
];

/// The candidate closest in size to [targetBytes], or null when there is none.
///
/// Neutral on format: E1 measures the byte transport, not the codec, so a
/// HEVC file is as good a subject as H.264. Container and codec are recorded in
/// the report so the two can be told apart afterwards.
ProbeVideo? pickClosest(List<ProbeVideo> videos, int targetBytes) {
  ProbeVideo? best;
  var bestDelta = -1;
  for (final video in videos) {
    final delta = (video.size - targetBytes).abs();
    if (bestDelta < 0 || delta < bestDelta) {
      bestDelta = delta;
      best = video;
    }
  }
  return best;
}

class ChunkProbeResult {
  const ChunkProbeResult({
    required this.verdict,
    required this.rows,
    required this.persistence,
    required this.markdown,
    required this.jsonlPath,
    required this.markdownPath,
    required this.header,
  });

  final ProbeVerdict verdict;
  final List<ChunkRow> rows;
  final List<PersistenceCheck> persistence;
  final String markdown;
  final String jsonlPath;
  final String markdownPath;

  /// The `key=value` block that has to accompany any verdict: device, TDLib
  /// version, file identity. Without it the numbers are unverifiable.
  final String header;
}

/// Runs E1 against a real file. One instance per run.
class ChunkProbeRunner {
  ChunkProbeRunner({
    required this.client,
    this.onLog,
    this.onProgress,
  });

  final TdClient client;

  /// Human-readable progress lines for the on-screen panel.
  void Function(String line)? onLog;

  /// Called after each chunk so the panel can show partial evidence.
  void Function(String line)? onProgress;

  final Stopwatch _clock = Stopwatch();
  final List<FileEvent> _events = <FileEvent>[];
  StreamSubscription<Map<String, Object?>>? _sub;
  IOSink? _jsonl;
  String _jsonlPath = '';
  int _seq = 0;
  int _fileId = 0;

  void _log(String line) => onLog?.call(line);

  Future<void> _openLog(Directory dir, String stamp) async {
    _jsonlPath = '${dir.path}/E1-$stamp.jsonl';
    final file = File(_jsonlPath);
    await file.writeAsString('', flush: true);
    _jsonl = file.openWrite(mode: FileMode.writeOnlyAppend);
  }

  void _emit(Map<String, Object?> record) {
    final sink = _jsonl;
    if (sink == null) return;
    sink.writeln(jsonEncode(record));
  }

  // ---- TDLib helpers -----------------------------------------------------

  /// The version string the running library reports, or `unknown`.
  Future<String> _runtimeVersion() async {
    try {
      final response = await client.request(
        getOption('version'),
        timeout: const Duration(seconds: 10),
      );
      if (errorText(response) != null) return 'error:${errorText(response)}';
      final value = response['value'];
      if (value is String) return value;
      return 'unexpected:${response['@type']}';
    } catch (e) {
      return 'unknown:$e';
    }
  }

  /// Whether this build implements `getFileDownloadedPrefixSize`.
  ///
  /// The schema fixture in `test/fixtures/` is upstream master while the app
  /// links a pinned build; the two can disagree. Asking once, at the start of
  /// the run, turns "probably supported" into a recorded fact.
  Future<String> _prefixApiCheck(int fileId) async {
    try {
      final response = await client.request(
        getFileDownloadedPrefixSize(fileId: fileId, offset: 0),
        timeout: const Duration(seconds: 10),
      );
      final err = errorText(response);
      if (err != null) return 'absent ($err)';
      return 'present (size=${response['size']})';
    } catch (e) {
      return 'unknown ($e)';
    }
  }

  Future<FileState?> _getFile(int fileId) async {
    try {
      final response = await client.request(
        getFile(fileId),
        timeout: const Duration(seconds: 20),
      );
      if (errorText(response) != null) return null;
      return fileFromResponse(response);
    } catch (_) {
      return null;
    }
  }

  Future<int?> _prefixSize(int fileId, int offset) async {
    try {
      final response = await client.request(
        getFileDownloadedPrefixSize(fileId: fileId, offset: offset),
        timeout: const Duration(seconds: 15),
      );
      if (errorText(response) != null) return null;
      final size = response['size'];
      return size is num ? size.toInt() : null;
    } catch (_) {
      return null;
    }
  }

  Future<(int?, String?)> _prefixSizeOrError(int fileId, int offset) async {
    try {
      final response = await client.request(
        getFileDownloadedPrefixSize(fileId: fileId, offset: offset),
        timeout: const Duration(seconds: 15),
      );
      final err = errorText(response);
      if (err != null) return (null, err);
      final size = response['size'];
      return (size is num ? size.toInt() : null, null);
    } catch (e) {
      return (null, e.toString());
    }
  }

  int _diskSize(String path) {
    if (path.isEmpty) return -1;
    try {
      final file = File(path);
      if (!file.existsSync()) return -1;
      return file.lengthSync();
    } catch (_) {
      return -1;
    }
  }

  Future<FileSnapshot> _snapshot(FileState? state) async {
    final tMs = _clock.elapsedMilliseconds;
    if (state == null) {
      return FileSnapshot(
        tMs: tMs,
        state: const FileState(
          id: 0,
          size: 0,
          expectedSize: 0,
          downloadedSize: 0,
          isCompleted: false,
          path: '',
          canBeDownloaded: false,
        ),
        diskSize: -1,
      );
    }
    return FileSnapshot(tMs: tMs, state: state, diskSize: _diskSize(state.path));
  }

  // ---- byte readers -----------------------------------------------------

  /// Reads the window straight out of `local.path`, which is what a player
  /// with file-system access would do.
  Future<WindowRead> _readPosix(String path, int offset, int count) async {
    final started = _clock.elapsedMilliseconds;
    if (path.isEmpty) {
      return WindowRead.failed('path is empty', 0);
    }
    RandomAccessFile? raf;
    try {
      raf = await File(path).open();
      await raf.setPosition(offset);
      final bytes = await raf.read(count);
      final sha = await _hashHex(bytes);
      return WindowRead(
        bytes: bytes.length,
        ms: _clock.elapsedMilliseconds - started,
        sha: sha,
      );
    } catch (e) {
      return WindowRead.failed(e.toString(), _clock.elapsedMilliseconds - started);
    } finally {
      try {
        await raf?.close();
      } catch (_) {
        // A close failure cannot change the bytes that were already read.
      }
    }
  }

  /// Reads the same window through TDLib. The doc says it is slower than a
  /// direct read and that it errors on a range that is not fully local — both
  /// of which E4 is supposed to measure, so the error text is kept as data.
  Future<WindowRead> _readPart(int fileId, int offset, int count) async {
    final started = _clock.elapsedMilliseconds;
    try {
      final response = await client.request(
        readFilePart(fileId: fileId, offset: offset, count: count),
        timeout: const Duration(seconds: 30),
      );
      final err = errorText(response);
      if (err != null) {
        return WindowRead.failed(err, _clock.elapsedMilliseconds - started);
      }
      // `readFilePart` returns `Data`, i.e. `data data:bytes`, and `bytes` is
      // base64 on the JSON bus.
      final raw = response['data'];
      if (raw is! String) {
        return WindowRead.failed(
          'unexpected response @type=${response['@type']}',
          _clock.elapsedMilliseconds - started,
        );
      }
      final bytes = base64Decode(raw);
      final sha = await _hashHex(bytes);
      return WindowRead(
        bytes: bytes.length,
        ms: _clock.elapsedMilliseconds - started,
        sha: sha,
      );
    } catch (e) {
      return WindowRead.failed(e.toString(), _clock.elapsedMilliseconds - started);
    }
  }

  Future<String> _hashHex(List<int> bytes) {
    // A megabyte through pure-Dart SHA-256 takes hundreds of milliseconds; on
    // the UI isolate that would stall the panel for the whole run.
    final copy = Uint8List.fromList(bytes);
    return Isolate.run(() => bytesToHex(sha256(copy)));
  }

  // ---- discovery --------------------------------------------------------

  /// Lists videos large enough to matter, from the channels the account is in.
  ///
  /// Read-only: `getChats` / `getChat` / `getChatHistory`, nothing else.
  Future<List<ProbeVideo>> scanVideos({
    int maxChannels = 12,
    int historyLimit = 200,
    int maxChatProbes = 40,
  }) async {
    final chatsResponse = await client.request(
      getChats(limit: 200),
      timeout: const Duration(seconds: 30),
    );
    final chatIds = chatIdsFromResponse(chatsResponse);
    if (chatIds.isEmpty) {
      throw StateError('getChats 返回 0 个会话');
    }
    _log('会话 ${chatIds.length} 个，开始筛频道');

    final channels = <ChatSummary>[];
    for (final id in chatIds.take(maxChatProbes)) {
      if (channels.length >= maxChannels) break;
      try {
        final chatResponse = await client.request(
          getChat(id),
          timeout: const Duration(seconds: 20),
        );
        final chat = chatFromResponse(chatResponse);
        if (chat != null && chat.isChannel) channels.add(chat);
      } catch (_) {
        // One unreadable chat must not abort discovery.
      }
    }
    _log('频道 ${channels.length} 个，读取最近 $historyLimit 条消息');

    final videos = <ProbeVideo>[];
    for (final channel in channels) {
      try {
        final history = await client.request(
          getChatHistory(chatId: channel.id, limit: historyLimit),
          timeout: const Duration(seconds: 40),
        );
        for (final message in messagesFromResponse(history)) {
          final meta = VideoMeta.fromMessage(message);
          if (meta == null || meta.fileId == 0 || meta.expectedSize <= 0) {
            continue;
          }
          videos.add(ProbeVideo(
            chatId: channel.id,
            chatTitle: channel.title,
            messageId: (message['id'] as num?)?.toInt() ?? 0,
            fileId: meta.fileId,
            size: meta.expectedSize,
            width: meta.width,
            height: meta.height,
            durationSeconds: meta.durationSeconds,
            mimeType: meta.mimeType,
            fileName: meta.fileName,
          ));
        }
      } catch (e) {
        _log('频道 ${channel.title} 读取失败: ${redactText(e.toString())}');
      }
    }
    videos.sort((a, b) => a.size.compareTo(b.size));
    _log('找到 ${videos.length} 个视频');
    return videos;
  }

  // ---- E1 ---------------------------------------------------------------

  /// Runs the sequential bounded-range experiment on one file.
  Future<ChunkProbeResult> runE1({
    required ProbeVideo video,
    required String tdlibVersion,
    required String deviceLabel,
    int chunkBytes = 1 << 20,
    int maxChunks = 5,
    bool purgeFirst = true,
    bool synchronousProbe = true,
    Duration settleTimeout = const Duration(seconds: 40),
    Directory? outputDir,
  }) async {
    _clock
      ..reset()
      ..start();
    _seq = 0;
    _fileId = video.fileId;
    _events.clear();

    final dir = outputDir ?? await _defaultOutputDir();
    final stamp = _stamp(DateTime.now());
    await _openLog(dir, stamp);

    final ranges = planChunks(
      fileSize: video.size,
      chunkBytes: chunkBytes,
      maxChunks: maxChunks,
    );
    if (ranges.isEmpty) {
      throw StateError('文件 ${video.size} B 小于一个分块 $chunkBytes B');
    }

    final runtimeVersion = await _runtimeVersion();
    final prefixApi = await _prefixApiCheck(video.fileId);

    final header = <String, Object?>{
      '@type': 'e1_header',
      'startedAt': DateTime.now().toIso8601String(),
      'device': deviceLabel,
      'tdlibPinned': tdlibVersion,
      'tdlibRuntime': runtimeVersion,
      'getFileDownloadedPrefixSizeApi': prefixApi,
      'probe': 'E1 sequential bounded ranges',
      'fileId': video.fileId,
      'chatId': video.chatId,
      'messageId': video.messageId,
      'fileSize': video.size,
      'mimeType': video.mimeType,
      'chunkBytes': chunkBytes,
      'chunkCount': ranges.length,
      'purgeFirst': purgeFirst,
    };
    _emit(header);
    _log('E1 开始 fileId=${video.fileId} size=${video.size} '
        'chunk=${chunkBytes}B × ${ranges.length}');

    // TDLib is the only source of updates; subscribe before the first request
    // so no transition is missed between "ack" and "already finished".
    _sub = client.updates.listen((event) {
      if (event['@type'] != 'updateFile') return;
      final raw = event['file'];
      if (raw is! Map) return;
      final file = raw.cast<String, Object?>();
      if ((file['id'] as num?)?.toInt() != _fileId) return;
      final state = FileState.fromJson(file);
      final record = FileEvent(
        seq: ++_seq,
        tMs: _clock.elapsedMilliseconds,
        state: state,
        diskSize: _diskSize(state.path),
      );
      _events.add(record);
      _emit(<String, Object?>{
        '@type': 'updateFile',
        'seq': record.seq,
        't': record.tMs,
        'downloaded': state.downloadedSize,
        'prefix': state.downloadedPrefixSize,
        'offset': state.downloadOffset,
        'active': state.isDownloadingActive,
        'completed': state.isCompleted,
        'disk': record.diskSize,
        'path': state.path,
      });
    });

    final beforeStart = await _snapshot(await _getFile(_fileId));
    _emit(<String, Object?>{
      '@type': 'baseline',
      't': _clock.elapsedMilliseconds,
      'downloaded': beforeStart.state.downloadedSize,
      'prefix': beforeStart.state.downloadedPrefixSize,
      'offset': beforeStart.state.downloadOffset,
      'completed': beforeStart.state.isCompleted,
      'disk': beforeStart.diskSize,
      'path': beforeStart.state.path,
    });
    _log('基线 ${beforeStart.line}');

    // Was the file already whole before we asked for anything? If so E1 cannot
    // observe chunking at all, and the verdict has to say so instead of
    // printing a green PASS over an empty experiment.
    final wasComplete = beforeStart.state.isCompleted ||
        (beforeStart.diskSize >= video.size && video.size > 0);

    if (purgeFirst) {
      _log('deleteFile 清空本地缓存（仅本地，云端消息不动）');
      try {
        final response = await client.request(
          deleteFile(_fileId),
          timeout: const Duration(seconds: 30),
        );
        final err = errorText(response);
        if (err != null) _log('deleteFile: $err');
      } catch (e) {
        _log('deleteFile 异常: $e');
      }
      await Future<void>.delayed(const Duration(milliseconds: 600));
      // The pool keeps the same path but truncates it; re-stat so the first
      // chunk is not judged against stale bytes.
      final afterPurge = await _snapshot(await _getFile(_fileId));
      _emit(<String, Object?>{
        '@type': 'after_purge',
        't': _clock.elapsedMilliseconds,
        'downloaded': afterPurge.state.downloadedSize,
        'prefix': afterPurge.state.downloadedPrefixSize,
        'disk': afterPurge.diskSize,
      });
      _log('清空后 ${afterPurge.line}');
    }

    final rows = <ChunkRow>[];
    final persistence = <PersistenceCheck>[];

    for (final range in ranges) {
      final eventMark = _events.length;
      final before = await _snapshot(await _getFile(_fileId));

      _log('→ $range 请求中');
      final callStarted = _clock.elapsedMilliseconds;
      String? ackError;
      try {
        final response = await client.request(
          downloadFile(
            fileId: _fileId,
            offset: range.offset,
            limit: range.limit,
            priority: 32,
          ),
          timeout: const Duration(seconds: 30),
        );
        ackError = errorText(response);
      } catch (e) {
        ackError = e.toString();
      }
      final ackMs = _clock.elapsedMilliseconds - callStarted;
      _emit(<String, Object?>{
        '@type': 'downloadFile',
        't': callStarted,
        'chunk': range.index,
        'offset': range.offset,
        'limit': range.limit,
        'ackMs': ackMs,
        'error': ackError,
      });

      SettleOutcome settle;
      if (ackError != null) {
        settle = SettleOutcome(
          satisfied: false,
          gate: 'ackError',
          ms: ackMs,
          note: ackError,
        );
      } else {
        settle = await _waitRange(
          fileId: _fileId,
          range: range,
          timeout: settleTimeout,
          baselineDownloaded: before.state.downloadedSize,
        );
      }
      _log('  ack=${ackMs}ms settle=${settle.ms}ms gate=${settle.gate} '
          'satisfied=${settle.satisfied}');

      final after = await _snapshot(await _getFile(_fileId));
      final (prefixFromOffset, prefixFromOffsetError) =
          await _prefixSizeOrError(_fileId, range.offset);
      final (prefixFromZero, prefixFromZeroError) =
          await _prefixSizeOrError(_fileId, 0);

      final posix = await _readPosix(after.state.path, range.offset, range.limit);
      final part = await _readPart(_fileId, range.offset, range.limit);

      final signals = ChunkSignals.of(
        _events.sublist(eventMark),
        requestedOffset: range.offset,
      );

      final row = ChunkRow(
        range: range,
        ackMs: ackMs,
        ackError: ackError,
        settle: settle,
        before: before,
        after: after,
        signals: signals,
        prefixFromOffset: prefixFromOffset,
        prefixFromZero: prefixFromZero,
        prefixFromOffsetError: prefixFromOffsetError,
        prefixFromZeroError: prefixFromZeroError,
        posix: posix,
        part: part,
      );
      rows.add(row);
      _emit(<String, Object?>{
        '@type': 'chunk',
        'chunk': range.index,
        'offset': range.offset,
        'limit': range.limit,
        'ackMs': ackMs,
        'ackError': ackError,
        'settleMs': settle.ms,
        'gate': settle.gate,
        'satisfied': settle.satisfied,
        'afterDownloaded': after.state.downloadedSize,
        'afterPrefix': after.state.downloadedPrefixSize,
        'afterOffset': after.state.downloadOffset,
        'afterActive': after.state.isDownloadingActive,
        'afterCompleted': after.state.isCompleted,
        'disk': after.diskSize,
        'prefixFromOffset': prefixFromOffset,
        'prefixFromOffsetError': prefixFromOffsetError,
        'prefixFromZero': prefixFromZero,
        'prefixFromZeroError': prefixFromZeroError,
        'posixBytes': posix.bytes,
        'posixMs': posix.ms,
        'posixSha': posix.sha,
        'posixError': posix.error,
        'partBytes': part.bytes,
        'partMs': part.ms,
        'partSha': part.sha,
        'partError': part.error,
        'agree': row.readersAgree,
        'events': signals.events,
        'activeRuns': signals.activeRuns,
        'offsetDrift': signals.offsetDrift,
        'maxGapMs': signals.maxGapMs,
      });

      _log('  posix=${posix.bytes}B/${posix.ms}ms part=${part.bytes}B/'
          '${part.ms}ms agree=${row.readersAgree} '
          'prefix0=${prefixFromZero ?? -1} prefixAt=${prefixFromOffset ?? -1}');
      onProgress?.call(_rowSummary(row));

      // Q3: after a later offset ran, is the first window still readable?
      if (range.index > 0 && rows.isNotEmpty) {
        final first = rows.first;
        if (first.windowComplete) {
          final recheck =
              await _readPosix(after.state.path, first.range.offset, first.range.limit);
          final check = PersistenceCheck(
            targetIndex: first.range.index,
            checkedAfterChunk: range.index,
            offset: first.range.offset,
            limit: first.range.limit,
            originalSha: first.posix.sha,
            recheck: recheck,
          );
          persistence.add(check);
          _emit(<String, Object?>{
            '@type': 'persistence',
            'target': check.targetIndex,
            'afterChunk': check.checkedAfterChunk,
            'bytes': recheck.bytes,
            'sha': recheck.sha,
            'intact': check.survived,
            'error': recheck.error,
          });
          _log('  复查 chunk0: ${recheck.bytes}B ${check.survived ? '完好' : '变了'}');
        }
      }
    }

    // A synchronous request is the only way to time a bounded range end to end:
    // the response arrives when the transfer succeeded, failed or was cancelled.
    // It runs on a range that has not been fetched yet, so the measurement is
    // not hidden by bytes that are already there.
    if (synchronousProbe) {
      final syncOffset = ranges.length * chunkBytes;
      if (syncOffset < video.size) {
        final limit = (syncOffset + chunkBytes > video.size)
            ? video.size - syncOffset
            : chunkBytes;
        final started = _clock.elapsedMilliseconds;
        String? syncError;
        try {
          final response = await client.request(
            downloadFile(
              fileId: _fileId,
              offset: syncOffset,
              limit: limit,
              priority: 32,
              synchronous: true,
            ),
            timeout: const Duration(seconds: 90),
          );
          syncError = errorText(response);
        } catch (e) {
          syncError = e.toString();
        }
        final elapsed = _clock.elapsedMilliseconds - started;
        final after = await _snapshot(await _getFile(_fileId));
        final posix = await _readPosix(after.state.path, syncOffset, limit);
        _emit(<String, Object?>{
          '@type': 'sync_probe',
          'offset': syncOffset,
          'limit': limit,
          'ms': elapsed,
          'error': syncError,
          'posixBytes': posix.bytes,
          'posixSha': posix.sha,
          'disk': after.diskSize,
        });
        _log('同步请求 [$syncOffset, ${syncOffset + limit}) '
            '${elapsed}ms error=${syncError ?? '-'} posix=${posix.bytes}B');
      }
    }

    await _sub?.cancel();
    _sub = null;

    final (finalPrefix, _) = await _prefixSizeOrError(_fileId, 0);
    final finalState = await _getFile(_fileId);
    _emit(<String, Object?>{
      '@type': 'final',
      't': _clock.elapsedMilliseconds,
      'prefixFromZero': finalPrefix,
      'downloaded': finalState?.downloadedSize,
      'offset': finalState?.downloadOffset,
      'completed': finalState?.isCompleted,
      'disk': finalState == null ? -1 : _diskSize(finalState.path),
      'prefixCallsForDiagnostics': rows.length,
    });

    final verdict = evaluateE1(
      rows: rows,
      persistence: persistence,
      fileWasCompleteBeforeRun: wasComplete && !purgeFirst,
      chunkBytes: chunkBytes,
    );

    final headerText = 'device=$deviceLabel\n'
        'tdlibPinned=$tdlibVersion\n'
        'tdlibRuntime=$runtimeVersion\n'
        'getFileDownloadedPrefixSize=$prefixApi\n'
        'probe=E1 sequential bounded ranges\n'
        'fileId=${video.fileId} chatId=${video.chatId} '
        'messageId=${video.messageId}\n'
        'fileSize=${video.size} mime=${video.mimeType ?? '?'}\n'
        'chunkBytes=$chunkBytes chunks=${ranges.length} '
        'purgeFirst=$purgeFirst';

    final markdown = _markdown(
      header: headerText,
      video: video,
      rows: rows,
      persistence: persistence,
      verdict: verdict,
      startedAt: header['startedAt']! as String,
    );

    final mdPath = '${dir.path}/E1-$stamp.md';
    await File(mdPath).writeAsString(markdown, flush: true);
    _emit(<String, Object?>{
      '@type': 'verdict',
      'status': verdict.status,
      'reasons': verdict.reasons,
      'notes': verdict.notes,
    });
    await _jsonl?.flush();
    await _jsonl?.close();
    _jsonl = null;
    _log('E1 结论: ${verdict.status}');

    return ChunkProbeResult(
      verdict: verdict,
      rows: rows,
      persistence: persistence,
      markdown: markdown,
      jsonlPath: _jsonlPath,
      markdownPath: mdPath,
      header: headerText,
    );
  }

  /// Waits until the requested window is really there.
  ///
  /// Three independent signals are accepted, because TDLib's bookkeeping for a
  /// bounded download is not documented to the byte and a single one of them
  /// could be wrong:
  /// * `getFileDownloadedPrefixSize(offset) >= limit` — the offset-relative
  ///   answer, the one a chunk store would use;
  /// * `download_offset == requested` and `downloaded_size >= limit` — the
  ///   historical field pair;
  /// * the file already reaches `offset + limit` on disk with no transfer
  ///   running — the request already auto-cancelled at its limit.
  Future<SettleOutcome> _waitRange({
    required int fileId,
    required ChunkRange range,
    required Duration timeout,
    required int baselineDownloaded,
  }) async {
    final started = _clock.elapsedMilliseconds;
    var gate = 'timeout';
    while (_clock.elapsedMilliseconds - started < timeout.inMilliseconds) {
      final prefix = await _prefixSize(fileId, range.offset);
      if (prefix != null && prefix >= range.limit) {
        gate = 'prefixFromOffset';
        break;
      }
      final state = await _getFile(fileId);
      if (state != null) {
        if (state.downloadOffset == range.offset &&
            state.downloadedSize >= range.limit) {
          gate = 'downloadedSize';
          break;
        }
        if (!state.isDownloadingActive &&
            state.downloadedSize > baselineDownloaded &&
            _diskSize(state.path) >= range.end) {
          gate = 'diskAfterInactive';
          break;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    final elapsed = _clock.elapsedMilliseconds - started;
    return SettleOutcome(
      satisfied: gate != 'timeout',
      gate: gate,
      ms: elapsed,
    );
  }

  String _rowSummary(ChunkRow row) =>
      'chunk#${row.range.index} ${row.range.offset}..${row.range.end} '
      'ack=${row.ackMs}ms settle=${row.settle.ms}ms '
      '${row.posix.bytes}B agree=${row.readersAgree}';

  Future<Directory> _defaultOutputDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/probes');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static String _stamp(DateTime now) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }

  String _markdown({
    required String header,
    required ProbeVideo video,
    required List<ChunkRow> rows,
    required List<PersistenceCheck> persistence,
    required ProbeVerdict verdict,
    required String startedAt,
  }) {
    final b = StringBuffer()
      ..writeln('# E1 — 连续分块下载（真实 TDLib）')
      ..writeln()
      ..writeln('```')
      ..writeln(header)
      ..writeln('startedAt=$startedAt')
      ..writeln('```')
      ..writeln()
      ..writeln('## 结论')
      ..writeln()
      ..writeln('`E1 = ${verdict.status}`')
      ..writeln();
    for (final reason in verdict.reasons) {
      b.writeln('- $reason');
    }
    b
      ..writeln()
      ..writeln('## 观察（不影响判定，但影响播放器设计）')
      ..writeln();
    for (final note in verdict.notes) {
      b.writeln('- $note');
    }
    b
      ..writeln()
      ..writeln('## 样本')
      ..writeln()
      ..writeln('| 项 | 值 |')
      ..writeln('|---|---|')
      ..writeln('| 频道 | ${video.chatTitle} (${video.chatId}) |')
      ..writeln('| messageId | ${video.messageId} |')
      ..writeln('| fileId | ${video.fileId} |')
      ..writeln('| 大小 | ${video.size} B (${video.sizeLabel}) |')
      ..writeln('| 分辨率 / 时长 | ${video.width}x${video.height} / '
          '${video.durationSeconds}s |')
      ..writeln('| mime | ${video.mimeType ?? '?'} |')
      ..writeln()
      ..writeln('## 每个分块')
      ..writeln()
      ..writeln('| # | offset | limit | ack ms | 满足 ms | gate | '
          'download_offset | prefix(from 0) | prefix(at offset) | '
          'POSIX B | readFilePart B | 一致 | activeRuns | maxGap ms |')
      ..writeln('|---|---|---|---|---|---|---|---|---|---|---|---|---|---|');

    for (final row in rows) {
      b.writeln('| ${row.range.index} | ${row.range.offset} | ${row.range.limit} '
          '| ${row.ackMs} | ${row.settle.ms} | ${row.settle.gate} '
          '| ${row.after.state.downloadOffset} '
          '| ${row.prefixFromZero ?? -1} | ${row.prefixFromOffset ?? -1} '
          '| ${row.posix.bytes} | ${row.part.bytes} '
          '| ${row.readersAgree ? '是' : '否'} '
          '| ${row.signals.activeRuns} | ${row.signals.maxGapMs} |');
    }

    b
      ..writeln()
      ..writeln('## 分块明细')
      ..writeln();
    for (final row in rows) {
      b
        ..writeln('### chunk#${row.range.index} — [${row.range.offset}, '
            '${row.range.end})')
        ..writeln()
        ..writeln('```')
        ..writeln('downloadFile(fileId=${video.fileId}, '
            'offset=${row.range.offset}, limit=${row.range.limit})')
        ..writeln('调用时 t=${row.before.tMs}ms  ack=${row.ackMs}ms  '
            'error=${row.ackError ?? '-'}')
        ..writeln('调用前 ${row.before.line}')
        ..writeln('满足    gate=${row.settle.gate} ${row.settle.ms}ms')
        ..writeln('调用后 ${row.after.line}')
        ..writeln('updateFile 数=${row.signals.events} '
            'activeRuns=${row.signals.activeRuns} '
            'offsetDrift=${row.signals.offsetDrift} '
            'maxGap=${row.signals.maxGapMs}ms '
            '首个事件=${row.signals.firstEventMs}ms')
        ..writeln('getFileDownloadedPrefixSize(offset)='
            '${row.prefixFromOffset ?? 'ERR ${row.prefixFromOffsetError}'}')
        ..writeln('getFileDownloadedPrefixSize(0)='
            '${row.prefixFromZero ?? 'ERR ${row.prefixFromZeroError}'}')
        ..writeln('POSIX      ${row.posix.bytes}B ${row.posix.ms}ms '
            'sha=${row.posix.sha} ${row.posix.error ?? ''}')
        ..writeln('readFilePart ${row.part.bytes}B ${row.part.ms}ms '
            'sha=${row.part.sha} ${row.part.error ?? ''}')
        ..writeln('path=${row.after.state.path}')
        ..writeln('```')
        ..writeln();
    }

    b
      ..writeln('## 旧分块存活')
      ..writeln();
    if (persistence.isEmpty) {
      b.writeln('没有可复查的分块（分块数为 1 或首块未完成）');
    } else {
      b.writeln('| 目标 | 在哪个分块之后复查 | 字节 | 完好 | sha |');
      b.writeln('|---|---|---|---|---|');
      for (final check in persistence) {
        b.writeln('| #${check.targetIndex} | #${check.checkedAfterChunk} '
            '| ${check.recheck.bytes} | ${check.survived ? '是' : '否'} '
            '| ${check.recheck.sha} |');
      }
    }
    b.writeln();
    return b.toString();
  }

  /// Releases the update subscription and log sink if the run was abandoned.
  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await _jsonl?.close();
    } catch (_) {
      // Closing twice is not an error worth raising.
    }
    _jsonl = null;
  }
}
