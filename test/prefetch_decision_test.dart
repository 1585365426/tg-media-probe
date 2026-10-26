import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/data/media_resolver.dart';

/// The prefetch skip rules, tested without a TDLib client.
///
/// Each case below is a real failure mode: fetching a protected clip leaks
/// bytes the user was told cannot be saved, and re-fetching a complete file
/// burns their data allowance on every swipe.
void main() {
  PrefetchDecision decide({
    int fileId = 100,
    bool protected = false,
    int expectedBytes = 1000,
    bool queued = false,
    bool exists = false,
    int actualBytes = 0,
  }) =>
      decidePrefetch(
        fileId: fileId,
        hasProtectedContent: protected,
        expectedBytes: expectedBytes,
        alreadyQueued: queued,
        targetExists: exists,
        targetBytes: actualBytes,
      );

  group('decidePrefetch', () {
    test('enqueues a normal clip that is not on disk yet', () {
      expect(decide(), PrefetchDecision.enqueue);
    });

    test('a row without a file id is never fetched', () {
      expect(decide(fileId: 0), PrefetchDecision.noFileId);
    });

    test('protected content is never pulled to the local zone', () {
      expect(decide(protected: true), PrefetchDecision.protectedContent);
    });

    test('a clip already queued this session is not queued twice', () {
      expect(decide(queued: true), PrefetchDecision.alreadyQueued);
    });

    test('a complete promoted copy is left alone', () {
      expect(
        decide(exists: true, actualBytes: 1000),
        PrefetchDecision.alreadyLocal,
      );
    });

    test('a truncated copy is fetched again', () {
      expect(
        decide(exists: true, actualBytes: 400),
        PrefetchDecision.enqueue,
      );
    });

    test('an unknown expected size trusts whatever is on disk', () {
      // TDLib sometimes reports no size for a photo-backed animation. The file
      // exists, so re-downloading it would be pure waste.
      expect(
        decide(expectedBytes: 0, exists: true, actualBytes: 400),
        PrefetchDecision.alreadyLocal,
      );
    });

    test('file id and protection outrank the on-disk short circuit', () {
      expect(
        decide(fileId: 0, exists: true, actualBytes: 1000),
        PrefetchDecision.noFileId,
      );
      expect(
        decide(protected: true, exists: true, actualBytes: 1000),
        PrefetchDecision.protectedContent,
      );
    });
  });
}
