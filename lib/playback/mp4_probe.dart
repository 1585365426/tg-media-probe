/// Where the `moov` atom sits in the file the player is being fed.
///
/// This decides whether a progressive HTTP response can work at all: with
/// `moov` at the head AVPlayer can build its tracks from the first kilobytes;
/// with `moov` at the tail it must read the end of the file before it can even
/// know the duration — which is precisely why a proxy has to serve ranges that
/// sit far beyond the download cursor.
///
/// The scan reads box headers only (8 or 16 bytes each), so it works on the
/// bytes already on disk and never touches the network.
library;

/// Result of the box scan.
enum MoovPosition {
  /// `moov` found before any `mdat`: the file can start from the head.
  head,

  /// `mdat` came first, so `moov` lives after it — at or near the tail.
  afterMdat,

  /// Not enough bytes available yet, or the file is not a plain MP4.
  unknown,
}

/// Where `moov` is, in absolute byte offsets when the layout allows it.
///
/// [locate] answers "head or tail"; this answers "the tail starts at byte N and
/// is M bytes long", which is what a bounded `downloadFile(offset: N, limit:
/// M)` needs. A tail-moov film cannot show a frame until those bytes exist, and
/// waiting for a 638 MB sequential download to reach them is the "0.1 % and
/// frozen" shape: the player is not broken, it is waiting for a box that sits at
/// the far end of a file nobody asked for a window on.
class MoovScan {
  const MoovScan(this.position, {this.start = -1, this.end = -1});

  /// No box order available yet (fewer than 8 bytes, or a `free` box so large
  /// the header table needs more bytes than we read).
  static const MoovScan unknown = MoovScan(MoovPosition.unknown);

  final MoovPosition position;

  /// First byte of the `moov` box, or -1 when unknown.
  final int start;

  /// Last byte of the `moov` box (inclusive), or -1 when unknown.
  final int end;

  /// `moov` sits after `mdat` and its first byte is known.
  bool get isTail =>
      position == MoovPosition.afterMdat && start > 0;

  int get length => (start >= 0 && end >= start) ? end - start + 1 : 0;

  @override
  String toString() => 'moov=$position start=$start end=$end';
}

/// Scans the first bytes of an MP4 for the order of `ftyp` / `moov` / `mdat`.
class Mp4Probe {
  const Mp4Probe._();

  /// Bytes needed to reach a verdict in the common cases. A `mdat` at the head
  /// is detected from its own header, so 64 KB is plenty; an unusually large
  /// `free`/`skip` box before `moov` falls back to [unknown], which is honest.
  static const int scanBytes = 64 * 1024;

  /// Reads box headers in [bytes] and reports where `moov` must be.
  static MoovPosition locate(List<int> bytes) => scan(bytes).position;

  /// Same walk as [locate], but with the absolute offsets of the `moov` box.
  ///
  /// [total] is the file length TDLib reported. A `moov` after a sized `mdat`
  /// runs from the end of that `mdat` to EOF — the common tail-moov layout
  /// (`ftyp` + `mdat` + `moov`), where EOF is the end of the file.
  static MoovScan scan(List<int> bytes, {int total = 0}) {
    var offset = 0;
    while (offset + 8 <= bytes.length) {
      final size32 = _u32(bytes, offset);
      final type = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));
      var headerSize = 8;
      var boxSize = size32;
      if (size32 == 1) {
        // 64-bit largesize follows the type.
        if (offset + 16 > bytes.length) return MoovScan.unknown;
        boxSize = _u64(bytes, offset + 8);
        headerSize = 16;
      } else if (size32 == 0) {
        // "Runs to EOF": this box owns everything left, so a `moov` after it
        // cannot be located from here. Saying so is better than a wrong offset.
        if (type == 'mdat') return MoovScan.unknown;
        boxSize = bytes.length - offset;
      }
      if (boxSize < headerSize) return MoovScan.unknown;
      if (type == 'moov') {
        return MoovScan(
          MoovPosition.head,
          start: offset,
          end: offset + boxSize - 1,
        );
      }
      if (type == 'mdat') {
        // A sized `mdat` pins the next box exactly: `moov` starts right after.
        final start = offset + boxSize;
        final end = total > start ? total - 1 : -1;
        return MoovScan(MoovPosition.afterMdat, start: start, end: end);
      }
      // A box we cannot skip past means the header table is not available yet.
      if (offset + boxSize > bytes.length) return MoovScan.unknown;
      offset += boxSize;
    }
    return MoovScan.unknown;
  }

  static int _u32(List<int> b, int o) =>
      (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

  static int _u64(List<int> b, int o) => (_u32(b, o) << 32) | _u32(b, o + 4);
}
