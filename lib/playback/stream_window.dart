/// How much of a file one TDLib `downloadFile` is allowed to ask for.
///
/// The rule this file exists to enforce: **a play never asks TDLib for more
/// bytes than the player is about to read.** `downloadFile(limit: 0)` means
/// "to the end of the file", and that is the shape that produced the report
/// this module was written for — a 1.33 GB video that had 152 MB on disk a
/// couple of seconds after the tap, before AVPlayer had requested anything.
///
/// Nothing here is a guess about what the player needs. The windows are the
/// *ceiling*; what actually gets downloaded is whatever the player's own
/// requests steer towards, and this module only decides the size of one step.
library;

import 'dart:math' as math;

class StreamWindow {
  StreamWindow._();

  /// Bytes of the head downloaded before the player is handed the source.
  ///
  /// 16 MB is ~4 s of 4K video and several moov probes' worth of tail; it is
  /// also small enough that a tap cannot turn into a hundred-megabyte burst.
  static const int firstBytes = 16 * 1024 * 1024;

  /// One continuation step. Same size as [firstBytes] on purpose: playback
  /// that walks the file at a constant step is predictable, and a step that
  /// grows with the file is how a "small window" turns back into a download.
  static const int stepBytes = 16 * 1024 * 1024;

  /// Bytes a preload of a neighbour may pull. A preload that cannot install a
  /// player does not need a whole film; the head is enough to make the tap
  /// instant.
  static const int preloadBytes = 4 * 1024 * 1024;

  /// TDLib chunks on 1 KB boundaries.
  static const int alignMask = ~1023;

  /// Size of the first window for a file of [expectedBytes] bytes.
  ///
  /// Clamped to the file: a 900 KB clip must not be asked for in 16 MB.
  static int firstWindow(int expectedBytes, {int size = firstBytes}) {
    if (expectedBytes <= 0) return size;
    return expectedBytes < size ? expectedBytes : size;
  }

  /// The window that starts at [offset] and covers at most [size] bytes,
  /// clamped to the file. Returns inclusive `(from, to)`.
  static (int, int) windowAt(
    int offset,
    int total, {
    int size = stepBytes,
  }) {
    final from = offset < 0 ? 0 : (offset & alignMask);
    final last = total > 0 ? total - 1 : from + size - 1;
    final to = math.min(last, from + size - 1);
    return (from, to < from ? from : to);
  }

  /// `limit` for a `(from, to)` inclusive pair — what `downloadFile` wants.
  static int limitFor(int from, int to) => to < from ? 0 : to - from + 1;

  /// True when [head] (absolute bytes readable from 0) sits inside the window
  /// `[from, from + limit - 1]` — i.e. the download that window started is
  /// still going to produce the byte the reader is waiting for.
  static bool windowCoversFrom(int from, int limit, int head) {
    if (limit <= 0) return false;
    return head >= from && head <= from + limit - 1;
  }
}
