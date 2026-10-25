import 'package:path/path.dart' as p;

import 'file_ops.dart';

/// The four physical storage classes of TG Media.
///
/// They are deliberately **disjoint directories** with different lifetimes:
///
/// | zone            | location on iOS                                  | who may delete it                     |
/// |-----------------|--------------------------------------------------|---------------------------------------|
/// | [tempCache]     | `Library/Caches/tgmedia`                          | "clear cache" only                    |
/// | [userDownloads] | `Documents/TGMediaDownloads`                      | the user, from the download screen     |
/// | [indexDb]       | `Library/Application Support/tgmedia/index`       | never (it is the local mirror)         |
/// | [authMeta]      | `Library/Application Support/tgmedia/secure`      | never (session/account metadata)       |
///
/// `Library/Caches` is purgeable by iOS, which is exactly the contract we want
/// for thumbnails and playback temporaries: losing them is harmless, so the OS
/// may reclaim them under disk pressure.
enum StorageZone { tempCache, userDownloads, indexDb, authMeta }

extension StorageZoneSafety on StorageZone {
  /// Single source of truth for "may the cache cleaner touch this?".
  /// Everything except [StorageZone.tempCache] answers false, and the cache
  /// manager refuses to run against any other zone even if asked directly.
  bool get isClearedByCacheClear => this == StorageZone.tempCache;

  /// Zones whose contents are irreplaceable from the app's point of view.
  bool get isProtected => !isClearedByCacheClear;

  String get label => switch (this) {
        StorageZone.tempCache => '临时运行缓存',
        StorageZone.userDownloads => '用户下载文件',
        StorageZone.indexDb => '媒体索引数据库',
        StorageZone.authMeta => '账号与会话数据',
      };
}

class ZoneViolation implements Exception {
  ZoneViolation(this.message, {this.zone, this.path});

  final String message;
  final StorageZone? zone;
  final String? path;

  @override
  String toString() =>
      'ZoneViolation(${zone?.name ?? 'unknown'}): $message${path == null ? '' : ' [$path]'}';
}

/// Path layout + containment checks for the storage zones.
///
/// The layout takes explicit roots instead of calling `path_provider` itself so
/// tests can run against a temporary directory and the same code path is
/// exercised on device and in unit tests.
class StorageLayout {
  StorageLayout.explicit({
    required String tempRoot,
    required String downloadsRoot,
    required String indexRoot,
    required String authRoot,
    FileOps? ops,
  })  : tempRoot = p.normalize(p.absolute(tempRoot)),
        downloadsRoot = p.normalize(p.absolute(downloadsRoot)),
        indexRoot = p.normalize(p.absolute(indexRoot)),
        authRoot = p.normalize(p.absolute(authRoot)),
        ops = ops ?? const IoFileOps() {
    _assertDisjoint();
  }

  /// Sandbox-shaped layout, used by tests and by [AppPaths] once the real
  /// sandbox roots are known.
  factory StorageLayout.forSandbox(String sandboxRoot, {FileOps? ops}) {
    final base = p.normalize(p.absolute(sandboxRoot));
    return StorageLayout.explicit(
      tempRoot: p.join(base, 'Library', 'Caches', 'tgmedia'),
      downloadsRoot: p.join(base, 'Documents', 'TGMediaDownloads'),
      indexRoot: p.join(base, 'Library', 'Application Support', 'tgmedia', 'index'),
      authRoot: p.join(base, 'Library', 'Application Support', 'tgmedia', 'secure'),
      ops: ops,
    );
  }

  final String tempRoot;
  final String downloadsRoot;
  final String indexRoot;
  final String authRoot;
  final FileOps ops;

  String rootOf(StorageZone zone) => switch (zone) {
        StorageZone.tempCache => tempRoot,
        StorageZone.userDownloads => downloadsRoot,
        StorageZone.indexDb => indexRoot,
        StorageZone.authMeta => authRoot,
      };

  /// Sub-directories of the temp zone. All three are rebuildable.
  String get thumbnailDir => p.join(tempRoot, 'thumb');
  String get playbackTempDir => p.join(tempRoot, 'player');
  String get partialDownloadDir => p.join(tempRoot, 'partial');

  /// Roots of the protected zones, exposed with explicit names so call sites
  /// read as "user downloads" rather than "zone 2".
  String get downloadsDir => downloadsRoot;
  String get indexDir => indexRoot;
  String get authMetaDir => authRoot;

  Map<StorageZone, String> get allRoots => <StorageZone, String>{
        StorageZone.tempCache: tempRoot,
        StorageZone.userDownloads: downloadsRoot,
        StorageZone.indexDb: indexRoot,
        StorageZone.authMeta: authRoot,
      };

  void _assertDisjoint() {
    final entries = allRoots.entries.toList();
    for (var i = 0; i < entries.length; i++) {
      for (var j = 0; j < entries.length; j++) {
        if (i == j) continue;
        final a = entries[i].value;
        final b = entries[j].value;
        if (p.equals(a, b) || p.isWithin(a, b)) {
          throw ArgumentError(
            'storage zones must be disjoint: ${entries[i].key.name}=$a '
            'overlaps ${entries[j].key.name}=$b',
          );
        }
      }
    }
  }

  Future<void> ensureCreated() async {
    for (final root in allRoots.values) {
      await ops.createDirectory(root);
    }
    await ops.createDirectory(thumbnailDir);
    await ops.createDirectory(playbackTempDir);
    await ops.createDirectory(partialDownloadDir);
  }

  /// Canonical absolute form with symlinks resolved as far as the path exists.
  Future<String> canonical(String path) async =>
      p.normalize(p.absolute(await ops.realPath(path)));

  /// True when [path] is the zone root itself or lives underneath it.
  Future<bool> contains(StorageZone zone, String path) async {
    final root = await canonical(rootOf(zone));
    final target = await canonical(path);
    return p.equals(root, target) || p.isWithin(root, target);
  }

  Future<bool> isZoneRoot(String path) async {
    final target = await canonical(path);
    for (final root in allRoots.values) {
      if (p.equals(await canonical(root), target)) return true;
    }
    return false;
  }

  /// Which zone owns [path], or null when it belongs to none of them.
  Future<StorageZone?> zoneOf(String path) async {
    for (final zone in StorageZone.values) {
      if (await contains(zone, path)) return zone;
    }
    return null;
  }

  /// Throws [ZoneViolation] unless [path] is strictly inside [zone].
  Future<void> assertInside(StorageZone zone, String path) async {
    final root = await canonical(rootOf(zone));
    final target = await canonical(path);
    if (p.equals(root, target)) {
      throw ZoneViolation('refusing to operate on a zone root itself',
          zone: zone, path: path);
    }
    if (!p.isWithin(root, target)) {
      throw ZoneViolation('path escapes the zone root', zone: zone, path: path);
    }
  }

  /// Guard used by every deletion in the cache path.
  ///
  /// Two independent checks: the path must belong to [StorageZone.tempCache]
  /// (not merely "look like a cache path"), and it must resolve inside that
  /// zone after symlinks are followed.
  Future<void> assertDeletableByCacheClear(String path) async {
    final zone = await zoneOf(path);
    if (zone == null) {
      throw ZoneViolation('path is outside every managed zone', path: path);
    }
    if (!zone.isClearedByCacheClear) {
      throw ZoneViolation('zone is protected from cache clearing',
          zone: zone, path: path);
    }
    await assertInside(StorageZone.tempCache, path);
  }
}
