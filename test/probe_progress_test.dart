import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/td/media_probe.dart';

void main() {
  group('ProbeProgress.adoptExisting', () {
    test('marks the two configuration steps as done', () {
      final progress = ProbeProgress();
      expect(progress.step(1).state, ProbeStepState.pending);
      expect(progress.step(2).state, ProbeStepState.pending);

      progress.adoptExisting(
        databaseDir: '/var/mobile/x/Library/Application Support/tgmedia/secure/tdlib/db',
        filesDir: '/var/mobile/x/Library/Caches/tgmedia/tdlib_files',
      );

      expect(progress.step(1).state, ProbeStepState.success);
      expect(progress.step(2).state, ProbeStepState.success);
    });

    test('leaves the login and chain steps untouched', () {
      final progress = ProbeProgress();
      progress.adoptExisting(databaseDir: '/db', filesDir: '/files');

      // Reusing a client proves nothing about the chain; those verdicts have to
      // come from real requests.
      for (var i = 3; i <= 9; i++) {
        expect(progress.step(i).state, ProbeStepState.pending,
            reason: 'step $i should still be pending');
      }
    });

    test('records both paths so the storage section can be read off screen', () {
      final progress = ProbeProgress();
      progress.adoptExisting(
        databaseDir: '/secure/tdlib/db',
        filesDir: '/caches/tdlib_files',
      );

      final detail = progress.step(2).detail;
      expect(detail, contains('/secure/tdlib/db'));
      expect(detail, contains('/caches/tdlib_files'));
      expect(detail, contains('setTdlibParameters'));
    });

    test('says the client was reused rather than opened by this page', () {
      final progress = ProbeProgress();
      progress.adoptExisting(databaseDir: '/db', filesDir: '/files');
      expect(progress.step(1).detail, contains('复用已登录实例'));
    });

    test('notifies the UI for each step it writes', () {
      var calls = 0;
      final progress = ProbeProgress()..onChanged = () => calls++;
      progress.adoptExisting(databaseDir: '/db', filesDir: '/files');
      expect(calls, 2);
    });
  });

  group('ProbeProgress.set', () {
    test('rejects no index and reports the step by number', () {
      final progress = ProbeProgress();
      // Nine steps; asking for a tenth is a programming error, not a verdict.
      expect(() => progress.step(10), throwsA(isA<RangeError>()));
      expect(progress.step(9).title, contains('播放校验'));
    });

    test('symbol follows the state', () {
      final progress = ProbeProgress();
      progress.set(1, ProbeStepState.success, 'ok');
      expect(progress.step(1).symbol, '✓');
      progress.set(1, ProbeStepState.failed, 'bad');
      expect(progress.step(1).symbol, '✗');
      progress.set(1, ProbeStepState.running);
      expect(progress.step(1).symbol, '…');
    });
  });
}
