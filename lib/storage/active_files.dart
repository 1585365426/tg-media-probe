import 'package:path/path.dart' as p;

/// Registry of files that are currently being used (playing, downloading,
/// uploading) so the cache cleaner can skip them instead of yanking a file out
/// from under the decoder or an in-flight transfer.
///
/// Reference counted: two owners of the same path both have to release before
/// the file becomes reclaimable.
class ActiveFileRegistry {
  final Map<String, int> _refs = <String, int>{};
  final Map<String, String> _reasons = <String, String>{};

  static String keyOf(String path) => p.normalize(p.absolute(path));

  void markInUse(String path, {String reason = 'in-use'}) {
    final key = keyOf(path);
    _refs[key] = (_refs[key] ?? 0) + 1;
    _reasons[key] = reason;
  }

  void release(String path) {
    final key = keyOf(path);
    final next = (_refs[key] ?? 0) - 1;
    if (next <= 0) {
      _refs.remove(key);
      _reasons.remove(key);
    } else {
      _refs[key] = next;
    }
  }

  bool isInUse(String path) => (_refs[keyOf(path)] ?? 0) > 0;

  String? reasonOf(String path) => _reasons[keyOf(path)];

  Set<String> get activePaths => _refs.keys.toSet();

  void clear() {
    _refs.clear();
    _reasons.clear();
  }
}
