/// Naming rules for files that belong to the user.
///
/// Two hard requirements drive everything here:
///
/// 1. The path must always land strictly inside
///    [StorageZone.userDownloads]. Telegram supplies `file_name` verbatim, and
///    that string reaches us from another account — treating it as a path
///    component is how `../../Library/Preferences/x.plist` gets written.
/// 2. The name must be unique per chat. Two different messages can legitimately
///    carry the same `video.mp4`, and silently overwriting the first download
///    is data loss.
library;

import 'package:path/path.dart' as p;

/// Extensions we map from MIME when Telegram sends no usable file name.
const Map<String, String> _mimeToExtension = <String, String>{
  'video/mp4': '.mp4',
  'video/quicktime': '.mov',
  'video/x-matroska': '.mkv',
  'video/webm': '.webm',
  'image/jpeg': '.jpg',
  'image/png': '.png',
  'image/gif': '.gif',
  'image/webp': '.webp',
  'audio/mpeg': '.mp3',
  'audio/ogg': '.ogg',
  'audio/mp4': '.m4a',
  'application/pdf': '.pdf',
  'application/zip': '.zip',
};

/// Characters that are illegal or dangerous on at least one filesystem we may
/// expose the folder to (Files app, iCloud Drive, a USB copy on Windows).
final RegExp _illegal = RegExp(r'[<>:"/\\|?*\x00-\x1f\x7f]');

/// Collapses runs of whitespace into a single underscore.
final RegExp _whitespaceRun = RegExp(r'\s+');

/// Strips leading dots so a name can never become hidden, `.` or `..`.
final RegExp _leadingDots = RegExp(r'^\.+');

final RegExp _validExtension = RegExp(r'^\.[A-Za-z0-9]{1,6}$');

/// Directory name for one chat.
///
/// Telegram chat ids are 64-bit and can be negative; the `c` prefix keeps the
/// name usable as a shell argument and prevents a leading `-` from being read
/// as a flag by external tools.
String chatFolderName(int chatId) => 'c${chatId.abs()}';

/// Sanitises a Telegram-supplied file name into a single safe path component.
///
/// Returns a name **without** directory separators and without a leading dot.
/// Empty or fully-stripped input falls back to `file`.
String sanitizeFileName(String? raw, {int maxStemLength = 80}) {
  if (raw == null) return 'file';

  // Take the basename first: `p.basename` on a POSIX host does not treat `\`
  // as a separator, so handle both explicitly before anything else.
  final normalised = raw.replaceAll('\\', '/');
  var name = normalised.split('/').last;

  // A name that still carries a query string or a fragment came from a URL
  // rather than from a filename. Cut there instead of mangling `?token=1`
  // into the stem.
  final urlTail = name.indexOf(RegExp(r'[?#]'));
  if (urlTail >= 0) name = name.substring(0, urlTail);

  name = name.replaceAll(_illegal, '_');
  name = name.replaceAll(_leadingDots, '');

  // Trim before collapsing whitespace: `'   '` must become empty (and fall
  // back to `file`), not a single underscore.
  name = name.trim();
  if (name.isEmpty) return 'file';
  name = name.replaceAll(_whitespaceRun, '_');

  // Split off the extension so truncation never eats it.
  final dot = name.lastIndexOf('.');
  var stem = dot > 0 ? name.substring(0, dot) : name;
  var ext = dot > 0 ? name.substring(dot) : '';

  // Reject an extension that is not a short alphanumeric suffix: Telegram has
  // been seen sending names like `clip.MP4?x=1`.
  if (ext.isNotEmpty && !_validExtension.hasMatch(ext)) {
    stem = name;
    ext = '';
  }

  if (stem.length > maxStemLength) stem = stem.substring(0, maxStemLength);
  if (stem.isEmpty) stem = 'file';

  return '$stem$ext';
}

/// Picks an extension from the MIME type when the file name carries none.
String extensionFor({String? fileName, String? mimeType}) {
  final fromName = fileName == null ? '' : p.extension(sanitizeFileName(fileName));
  if (fromName.isNotEmpty) return fromName.toLowerCase();
  if (mimeType == null) return '';
  return _mimeToExtension[mimeType.toLowerCase()] ?? '';
}

/// Final path component: `<sanitised stem>_<fileId><ext>`.
///
/// The file id is appended because it is unique per TDLib file, which makes the
/// name stable across restarts (re-downloading the same file hits the same
/// path, so the operation is idempotent) while still never colliding with a
/// different file that happens to share a name.
String downloadFileName({
  required int fileId,
  String? fileName,
  String? mimeType,
}) {
  final safe = sanitizeFileName(fileName);
  final ext = extensionFor(fileName: fileName, mimeType: mimeType);
  final dot = safe.lastIndexOf('.');
  final stem = dot > 0 ? safe.substring(0, dot) : safe;
  return '${stem}_$fileId$ext';
}

/// Absolute target path inside the user download zone.
///
/// [downloadsRoot] must be [StorageLayout.downloadsDir] or the equivalent test
/// sandbox path; the caller is responsible for having created it.
String userDownloadPath({
  required String downloadsRoot,
  required int chatId,
  required int fileId,
  String? fileName,
  String? mimeType,
}) =>
    p.join(
      downloadsRoot,
      chatFolderName(chatId),
      downloadFileName(fileId: fileId, fileName: fileName, mimeType: mimeType),
    );
