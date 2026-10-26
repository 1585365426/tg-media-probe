/// Byte-range plumbing for progressive playback.
///
/// Pure functions and value types only: no sockets, no TDLib. Everything here
/// is asserted by unit tests, because an off-by-one in `Content-Range` makes
/// AVPlayer fail with `-11800` and nothing in the UI explains why.
library;

/// A contiguous run of bytes that TDLib can serve from its pool file.
///
/// TDLib's `localFile` carries three numbers: `download_offset` (where the
/// stored bytes start inside the logical file), `downloaded_prefix_size` (how
/// many bytes are contiguous from there) and `downloaded_size` (total, which
/// may include holes and is therefore useless for streaming). A read at logical
/// position `p` is only possible when
/// `download_offset <= p < download_offset + downloaded_prefix_size`, and it
/// maps to physical offset `p - download_offset` inside [path].
class FileWindow {
  const FileWindow({
    required this.path,
    required this.offset,
    required this.prefixSize,
  });

  static const FileWindow empty =
      FileWindow(path: '', offset: 0, prefixSize: 0);

  final String path;

  /// `localFile.download_offset`
  final int offset;

  /// `localFile.downloaded_prefix_size`
  final int prefixSize;

  int get endExclusive => offset + prefixSize;

  bool get isEmpty => path.isEmpty || prefixSize <= 0;

  /// True when [length] bytes starting at logical [position] are all present.
  bool covers(int position, int length) {
    if (isEmpty || length <= 0) return false;
    if (position < offset) return false;
    return position + length <= endExclusive;
  }

  /// How many bytes are readable from [position] before the window ends.
  int availableFrom(int position) {
    if (isEmpty || position < offset) return 0;
    final remaining = endExclusive - position;
    return remaining < 0 ? 0 : remaining;
  }

  /// Offset to seek to inside [path] for logical [position].
  int physicalOffset(int position) => position - offset;

  @override
  String toString() =>
      'FileWindow($path, offset=$offset, prefix=$prefixSize)';
}

/// A single `bytes=` range, inclusive on both ends per RFC 7233.
class ByteRange {
  const ByteRange(this.start, this.endInclusive);

  final int start;
  final int endInclusive;

  int get length => endInclusive - start + 1;

  @override
  String toString() => 'ByteRange($start-$endInclusive)';

  @override
  bool operator ==(Object other) =>
      other is ByteRange &&
      other.start == start &&
      other.endInclusive == endInclusive;

  @override
  int get hashCode => Object.hash(start, endInclusive);
}

/// Outcome of parsing a `Range` header.
sealed class RangeParse {
  const RangeParse();
}

/// No usable range: serve the whole entity with 200.
class RangeNone extends RangeParse {
  const RangeNone();
}

/// Serve 206 with `range`.
class RangeOk extends RangeParse {
  const RangeOk(this.range);

  final ByteRange range;
}

/// Serve 416 with `Content-Range: bytes */total`.
class RangeUnsatisfiable extends RangeParse {
  const RangeUnsatisfiable(this.totalBytes);

  final int totalBytes;
}

/// Parses the `Range` header of a media request.
///
/// Deliberately narrow:
/// * only `bytes=` is understood; anything else (or no header) means "send the
///   whole body", which is legal and what an unadorned GET expects;
/// * multi-range requests are collapsed to their first range — AVPlayer never
///   sends them, and a multipart response would be far more code to get wrong;
/// * a syntactically broken header is treated as absent rather than as an
///   error, because refusing to serve a file over a malformed header helps
///   nobody.
RangeParse parseRangeHeader(String? header, int totalBytes) {
  if (header == null) return const RangeNone();
  final value = header.trim();
  if (value.isEmpty) return const RangeNone();
  final lower = value.toLowerCase();
  if (!lower.startsWith('bytes=')) return const RangeNone();
  if (totalBytes <= 0) return const RangeNone();

  final spec = value.substring(6).split(',').first.trim();
  final dash = spec.indexOf('-');
  if (dash < 0) return const RangeNone();

  final startText = spec.substring(0, dash).trim();
  final endText = spec.substring(dash + 1).trim();

  // `bytes=-500`: the last 500 bytes.
  if (startText.isEmpty) {
    final suffix = int.tryParse(endText);
    if (suffix == null || suffix <= 0) return const RangeNone();
    final start = suffix >= totalBytes ? 0 : totalBytes - suffix;
    return RangeOk(ByteRange(start, totalBytes - 1));
  }

  final start = int.tryParse(startText);
  if (start == null || start < 0) return const RangeNone();
  if (start >= totalBytes) return RangeUnsatisfiable(totalBytes);

  int end;
  if (endText.isEmpty) {
    end = totalBytes - 1;
  } else {
    final parsed = int.tryParse(endText);
    if (parsed == null || parsed < start) return const RangeNone();
    end = parsed >= totalBytes ? totalBytes - 1 : parsed;
  }
  return RangeOk(ByteRange(start, end));
}
