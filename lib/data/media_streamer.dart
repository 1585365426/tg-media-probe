import '../playback/range_server.dart';
import '../td/td_client.dart';
import 'media_record.dart';
import 'td_stream_source.dart';

/// Hands out loopback URLs that stream a record while TDLib is still fetching it.
///
/// One URL per record, kept for the life of the process: re-activating a video
/// the user has already watched reuses the token instead of publishing a second
/// route, which keeps the route table from growing once per swipe.
///
/// Returns null — never an exception — when streaming cannot work, so the caller
/// can fall back to the whole-file download path without special-casing. That
/// happens for: no file id, protected content, and an unknown size (a range
/// server cannot answer without a total length).
class MediaStreamer {
  MediaStreamer({required this.client, RangeServer? server})
      : server = server ?? RangeServer();

  final TdClient client;
  final RangeServer server;

  /// Route table cap. Each route holds one broadcast-stream subscription, so
  /// an unbounded table would leak a listener per video ever opened. 24 is far
  /// more than a swipe-back in practice; the 25th drops the oldest route, which
  /// is re-published on demand if the user returns to it.
  static const int maxRoutes = 24;

  final Map<String, Uri> _urls = <String, Uri>{};
  final Map<String, TdStreamSource> _sources = <String, TdStreamSource>{};
  final List<String> _order = <String>[];

  /// URLs currently published, for diagnostics.
  int get routeCount => _urls.length;

  Future<Uri?> urlFor(MediaRecord record) async {
    if (!canStream(record)) return null;

    final cached = _urls[record.key];
    if (cached != null) return cached;

    final source = TdStreamSource(
      client: client,
      fileId: record.fileId,
      expectedBytes: record.sizeBytes,
      contentType: _contentTypeOf(record),
    );
    source.start();
    try {
      final url = await server.register(source);
      _urls[record.key] = url;
      _sources[record.key] = source;
      _order.add(record.key);
      await _evictOldest();
      return url;
    } catch (_) {
      await source.release();
      return null;
    }
  }

  /// Drops the route for one record (cache cleared, message gone).
  Future<void> forget(String recordKey) async {
    final url = _urls.remove(recordKey);
    _sources.remove(recordKey);
    _order.remove(recordKey);
    if (url != null) await server.unregister(url);
  }

  Future<void> _evictOldest() async {
    while (_order.length > maxRoutes) {
      final oldest = _order.removeAt(0);
      final url = _urls.remove(oldest);
      _sources.remove(oldest);
      if (url != null) await server.unregister(url);
    }
  }

  Future<void> dispose() async {
    _urls.clear();
    _sources.clear();
    _order.clear();
    await server.close();
  }

  static String _contentTypeOf(MediaRecord record) {
    final mime = record.mimeType;
    if (mime != null && mime.startsWith('video/')) return mime;
    return 'video/mp4';
  }
}

/// Whether a record can be served through the range server at all.
///
/// Three hard requirements:
/// * a file id — nothing to ask TDLib for otherwise;
/// * no protected content — Telegram forbids saving it, and a local byte cache
///   is exactly that;
/// * a known size — `Content-Range` needs a total, and a response without one
///   makes AVPlayer buffer the whole entity.
bool canStream(MediaRecord record) {
  if (record.fileId == 0) return false;
  if (record.hasProtectedContent) return false;
  return record.sizeBytes > 0;
}
