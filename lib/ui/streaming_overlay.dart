/// On-device streaming badge (diagnostics mode only).
///
/// Why an overlay instead of another settings row: the question "is this
/// actually streaming?" can only be answered *while the video is playing*, and
/// a panel the user has to navigate to shows a different moment's numbers. This
/// badge sits on top of the running video and reads the live counters.
///
/// It renders nothing at all unless diagnostics mode is on, so for a normal
/// user the feed is byte-for-byte the same UI as before.
library;

import 'package:flutter/material.dart';

import '../playback/playback_trace.dart';
import '../playback/streaming_diagnostics.dart';
import '../util/byte_format.dart';

/// Top-right badge showing what the current play is really doing.
class StreamingOverlay extends StatelessWidget {
  const StreamingOverlay({super.key, this.diagnostics});

  /// Shared live state. Defaults to [StreamingDiagnostics.instance].
  final StreamingDiagnostics? diagnostics;

  @override
  Widget build(BuildContext context) {
    final source = diagnostics ?? StreamingDiagnostics.instance;
    return ListenableBuilder(
      listenable: source,
      builder: (context, _) {
        if (!source.enabled) return const SizedBox.shrink();
        return Positioned(
          // Under the top bar rather than on top of it: the badge is a
          // diagnostic, the top bar still owns the screen edge.
          top: 52,
          right: 8,
          child: IgnorePointer(
            child: _Badge(source: source),
          ),
        );
      },
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.source});

  final StreamingDiagnostics source;

  @override
  Widget build(BuildContext context) {
    final verdict = source.verdict;
    // `FULL` is a measurement, not a claim. It needs TDLib to have said the
    // transfer finished *and* the length behind the path to reach the total:
    // either half alone printed `1.19 GB / 1.19 GB · 100%` on a file that had
    // barely started, and `downloadedBytes >= totalBytes` could never rescue
    // it because that counter is the one being raised by the claim.
    final complete = source.isDownloadingCompleted && source.diskCoversTotal;
    final mode = complete
        ? 'FULL'
        : (verdict == StreamingVerdict.streamingActive ? 'STREAM' : 'STREAM?');
    final accent = complete
        ? const Color(0xFF7FD1B9)
        : (verdict == StreamingVerdict.streamingActive
            ? const Color(0xFF6FD3FF)
            : const Color(0xFFFFC46B));

    return Container(
      constraints: const BoxConstraints(minWidth: 132),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xBF000000),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent.withValues(alpha: 0.5)),
      ),
      child: DefaultTextStyle(
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          height: 1.25,
          fontFamily: 'Menlo',
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              mode,
              style: TextStyle(
                color: accent,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              ),
            ),
            Text('${formatBytes(source.downloadedBytes)} / '
                '${formatBytes(source.totalBytes)}'),
            Text('${(source.downloadedPercent * 100).toStringAsFixed(1)}%'),
            Text(source.lastStatus == null
                ? 'HTTP -'
                : 'HTTP ${source.lastStatus}'),
            // What the player actually opened: STREAM_HTTP proves the bytes
            // flow through the range proxy, LOCAL_FILE means a local path.
            Text('SRC ${source.playerSourceType ?? '-'}'),
            Text('PLAY ${_clock(source.playerTime)}'),
          ],
        ),
      ),
    );
  }

  static String _clock(Duration value) {
    final seconds = value.inSeconds;
    final minutes = seconds ~/ 60;
    final rest = seconds % 60;
    final mm = '$minutes'.padLeft(2, '0');
    final ss = '$rest'.padLeft(2, '0');
    return '$mm:$ss';
  }
}

/// The full diagnostics block the settings screen shows: verdict, live
/// counters, the acceptance result and the timeline of the last play.
///
/// Values come straight from [StreamingDiagnostics] — TDLib counters, proxy
/// responses and the player's own state — and are never derived from which
/// code path ran.
class StreamingDiagnosticsSection extends StatelessWidget {
  const StreamingDiagnosticsSection({super.key, this.diagnostics});

  final StreamingDiagnostics? diagnostics;

  @override
  Widget build(BuildContext context) {
    final source = diagnostics ?? StreamingDiagnostics.instance;
    return ListenableBuilder(
      listenable: source,
      builder: (context, _) {
        final theme = Theme.of(context);
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(10),
          ),
          child: DefaultTextStyle(
            style: TextStyle(
              color: theme.colorScheme.onSurface,
              fontSize: 12,
              height: 1.4,
              fontFamily: 'Menlo',
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  source.verdict.label,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                for (final line in source.panelLines()) Text(line),
                if (source.acceptanceRunning) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    source.acceptanceConcluded ? '验收结论' : '验收进行中…',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  if (source.acceptanceConcluded)
                    for (final line in source.acceptanceLines()) Text(line),
                ],
                const SizedBox(height: 8),
                const Text(
                  '播放时间线',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                for (final line in _timelineLines()) Text(line),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Timeline lines of the most recent play, or one honest placeholder.
List<String> _timelineLines() {
  final last = PlaybackTraceLog.instance.last;
  if (last == null) return const <String>['(尚未播放)'];
  return last.timelineLines();
}
