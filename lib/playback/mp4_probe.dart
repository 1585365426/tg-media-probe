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

/// Scans the first bytes of an MP4 for the order of `ftyp` / `moov` / `mdat`.
class Mp4Probe {
  const Mp4Probe._();

  /// Bytes needed to reach a verdict in the common cases. A `mdat` at the head
  /// is detected from its own header, so 64 KB is plenty; an unusually large
  /// `free`/`skip` box before `moov` falls back to [unknown], which is honest.
  static const int scanBytes = 64 * 1024;

  /// Reads box headers in [bytes] and reports where `moov` must be.
  static MoovPosition locate(List<int> bytes) {
    var offset = 0;
    while (offset + 8 <= bytes.length) {
      final size32 = _u32(bytes, offset);
      final type = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));
      var headerSize = 8;
      var boxSize = size32;
      if (size32 == 1) {
        // 64-bit largesize follows the type.
        if (offset + 16 > bytes.length) return MoovPosition.unknown;
        boxSize = _u64(bytes, offset + 8);
        headerSize = 16;
      } else if (size32 == 0) {
        // Box runs to EOF: whatever follows is inside it.
        boxSize = bytes.length - offset;
      }
      if (boxSize < headerSize) return MoovPosition.unknown;
      if (type == 'moov') return MoovPosition.head;
      if (type == 'mdat') return MoovPosition.afterMdat;
      // A box we cannot skip past means the header table is not available yet.
      if (offset + boxSize > bytes.length) return MoovPosition.unknown;
      offset += boxSize;
    }
    return MoovPosition.unknown;
  }

  static int _u32(List<int> b, int o) =>
      (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

  static int _u64(List<int> b, int o) => (_u32(b, o) << 32) | _u32(b, o + 4);
}
