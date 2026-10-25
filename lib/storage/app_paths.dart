import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'file_ops.dart';
import 'storage_layout.dart';

/// Resolves the real iOS sandbox roots through `path_provider`.
///
/// Not used by unit tests (it needs the platform channel); tests build the same
/// [StorageLayout] with [StorageLayout.forSandbox] so the production code path
/// below and the tested code path are the same object type.
class AppPaths {
  const AppPaths._();

  static Future<StorageLayout> resolveLayout({FileOps? ops}) async {
    final support = await getApplicationSupportDirectory();
    final cache = await getApplicationCacheDirectory();
    final documents = await getApplicationDocumentsDirectory();

    return StorageLayout.explicit(
      // Library/Caches — purgeable by iOS, rebuildable by us.
      tempRoot: p.join(cache.path, 'tgmedia'),
      // Documents — user-owned downloads, visible in the Files app.
      downloadsRoot: p.join(documents.path, 'TGMediaDownloads'),
      // Application Support — the local mirror that must survive cache clears.
      indexRoot: p.join(support.path, 'tgmedia', 'index'),
      authRoot: p.join(support.path, 'tgmedia', 'secure'),
      ops: ops,
    );
  }
}
