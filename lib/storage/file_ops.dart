import 'dart:io';

import 'package:path/path.dart' as p;

/// Minimal file system surface used by the storage layer.
///
/// Everything goes through this interface so the safety-critical cache-clear
/// path can be exercised against failures that are awkward to reproduce on a
/// real device: a delete that silently fails, a symlink that points outside
/// the sandbox, a path that escapes through `..`.
abstract class FileOps {
  Future<bool> exists(String path);
  Future<bool> isDirectory(String path);
  Future<int> sizeOf(String path);

  /// Recursive file listing. Missing directory yields an empty list.
  Future<List<String>> listFilesRecursive(String path);

  /// Immediate sub-directory names (not recursive).
  Future<List<String>> listDirectories(String path);

  Future<void> deleteFile(String path);
  Future<void> deleteEmptyDirectory(String path);
  Future<String> realPath(String path);
  Future<String> readAsString(String path);
  Future<void> writeAsString(String path, String data);

  /// Appends without truncating; used by the append-only index journal.
  Future<void> appendAsString(String path, String data);
  Future<void> createDirectory(String path);
  Future<void> rename(String from, String to);
}

class IoFileOps implements FileOps {
  const IoFileOps();

  @override
  Future<bool> exists(String path) async =>
      await FileSystemEntity.type(path, followLinks: false) !=
      FileSystemEntityType.notFound;

  @override
  Future<bool> isDirectory(String path) async =>
      await FileSystemEntity.type(path, followLinks: true) ==
      FileSystemEntityType.directory;

  @override
  Future<int> sizeOf(String path) async {
    final stat = await File(path).stat();
    return stat.type == FileSystemEntityType.notFound ? 0 : stat.size;
  }

  @override
  Future<List<String>> listFilesRecursive(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) return const <String>[];
    final files = <String>[];
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) files.add(entity.path);
    }
    return files;
  }

  @override
  Future<List<String>> listDirectories(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) return const <String>[];
    final dirs = <String>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is Directory) dirs.add(entity.path);
    }
    return dirs;
  }

  @override
  Future<void> deleteFile(String path) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<void> deleteEmptyDirectory(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) return;
    if ((await dir.list().toList()).isNotEmpty) return;
    await dir.delete();
  }

  /// Resolves symlinks for the deepest existing ancestor and re-appends the
  /// missing tail. Used to detect a symlink that escapes the zone root before
  /// anything is deleted.
  @override
  Future<String> realPath(String path) async {
    var probe = p.normalize(p.absolute(path));
    final tail = <String>[];
    while (true) {
      final type = await FileSystemEntity.type(probe, followLinks: true);
      if (type != FileSystemEntityType.notFound) {
        final resolved = type == FileSystemEntityType.directory
            ? await Directory(probe).resolveSymbolicLinks()
            : await File(probe).resolveSymbolicLinks();
        return p.normalize(p.joinAll(<String>[resolved, ...tail]));
      }
      final parent = p.dirname(probe);
      if (parent == probe) return p.normalize(p.absolute(path));
      tail.insert(0, p.basename(probe));
      probe = parent;
    }
  }

  @override
  Future<String> readAsString(String path) => File(path).readAsString();

  @override
  Future<void> writeAsString(String path, String data) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(data, flush: true);
  }

  @override
  Future<void> appendAsString(String path, String data) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(data, mode: FileMode.append, flush: true);
  }

  @override
  Future<void> createDirectory(String path) =>
      Directory(path).create(recursive: true);

  @override
  Future<void> rename(String from, String to) async {
    // Dart's rename replaces an existing destination, which is what the index
    // snapshot swap relies on.
    await File(from).rename(to);
  }
}
