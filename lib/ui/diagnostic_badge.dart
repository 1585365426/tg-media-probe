/// The optional top-right badge.
///
/// Off by default. When on it shows only what is true right now: the number, and
/// either the real transfer speed with real byte counts, or `LOCAL_FILE` with the
/// real file size. There is no code path that prints a speed while nothing is
/// downloading, because after a LOCAL_FILE handover there is no transfer to
/// measure — showing the last number would be a lie the user could act on.
library;

import 'package:flutter/material.dart';

import '../download/download_state.dart';
import '../util/byte_format.dart';

class DiagnosticBadge extends StatelessWidget {
  const DiagnosticBadge({
    super.key,
    required this.label,
    required this.download,
    this.compact = false,
  });

  final String label;
  final DownloadState download;

  /// Landscape: one line instead of three.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    // IgnorePointer matters: the badge sits over the video surface, and a
    // diagnostic must never eat a tap meant for the player.
    return IgnorePointer(
      child: Opacity(
        opacity: 0.32,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(10),
          ),
          child: DefaultTextStyle(
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              height: 1.25,
              fontWeight: FontWeight.w500,
            ),
            child: compact
                ? Text('$label · ${_shortLine()}')
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(label,
                          style: const TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(_lineOne()),
                      Text(_lineTwo()),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  String _shortLine() {
    if (download.phase == DownloadPhase.downloading) {
      return '${formatRate(download.bytesPerSecond)} · '
          '${(download.progress * 100).toStringAsFixed(0)}%';
    }
    if (download.phase == DownloadPhase.ready) {
      return 'LOCAL_FILE · ${formatBytes(download.totalBytes)}';
    }
    if (download.phase == DownloadPhase.failed) return 'DOWNLOAD ERROR';
    return download.phase.name.toUpperCase();
  }

  String _lineOne() {
    switch (download.phase) {
      case DownloadPhase.downloading:
        // A zero rate means "no measurement yet", never "0 B/s".
        final rate = download.bytesPerSecond;
        return rate > 0 ? formatRate(rate) : '连接中';
      case DownloadPhase.checking:
        return '检查缓存';
      case DownloadPhase.verifying:
        return '校验文件';
      case DownloadPhase.ready:
        return 'LOCAL_FILE';
      case DownloadPhase.failed:
        return 'DOWNLOAD ERROR';
      case DownloadPhase.cancelled:
        return '已取消';
      case DownloadPhase.idle:
        return '—';
    }
  }

  String _lineTwo() {
    switch (download.phase) {
      case DownloadPhase.downloading:
        return download.progressLabel;
      case DownloadPhase.ready:
      case DownloadPhase.verifying:
        return formatBytes(download.totalBytes);
      case DownloadPhase.failed:
        return download.failure.message;
      default:
        return '';
    }
  }
}
