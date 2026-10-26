import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/playback/playback_timeline.dart';

void main() {
  setUp(PlaybackTimelineLog.clear);

  test('marks are elapsed milliseconds, in order, first write wins', () async {
    final timeline = PlaybackTimeline.start('1:2');
    expect(timeline.marks, isEmpty);

    timeline.mark('activate');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    timeline.mark('stream-url');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    timeline.mark('stream-url'); // a second writer must not overwrite
    timeline.mark('player-load');

    final marks = timeline.marks;
    expect(marks.keys, <String>['activate', 'stream-url', 'player-load']);
    // The first mark is taken right after start(), so it is near zero but not
    // guaranteed to be exactly 0.
    expect(marks['activate'], lessThan(15));
    expect(marks['stream-url'], greaterThanOrEqualTo(15));
    expect(marks['player-load'], greaterThanOrEqualTo(marks['stream-url']!));
  });

  test('summary is greppable and ends with the total', () {
    final timeline = PlaybackTimeline.start('9:9');
    timeline.mark('activate');
    timeline.mark('player-load');
    final summary = timeline.summary();
    expect(summary, contains('activate='));
    expect(summary, contains('player-load='));
    expect(summary, matches(RegExp(r'total=\d+ms$')));
  });

  test('finish records the outcome and the done mark', () {
    final timeline = PlaybackTimeline.start('3:4');
    timeline.mark('activate');
    timeline.finish('stream');
    expect(timeline.outcome, 'stream');
    expect(timeline.marks.containsKey('done'), isTrue);
  });

  test('the log keeps the newest entries and is capped', () {
    for (var i = 0; i < PlaybackTimelineLog.capacity + 4; i++) {
      final timeline = PlaybackTimeline.start('chat:$i');
      timeline.mark('activate');
      timeline.finish('file');
      PlaybackTimelineLog.record(timeline);
    }
    final recent = PlaybackTimelineLog.recent;
    expect(recent.length, PlaybackTimelineLog.capacity);
    // Newest first.
    expect(recent.first.recordKey, 'chat:${PlaybackTimelineLog.capacity + 3}');
    expect(recent.last.recordKey, 'chat:4');
  });

  test('recent is a view, not the backing list', () {
    final timeline = PlaybackTimeline.start('a:b');
    PlaybackTimelineLog.record(timeline);
    expect(
      () => PlaybackTimelineLog.recent.add(timeline),
      throwsUnsupportedError,
    );
  });

  test('marks is a view, so a caller cannot inject stages', () {
    final timeline = PlaybackTimeline.start('c:d');
    timeline.mark('activate');
    expect(
      () => timeline.marks['fake'] = 1,
      throwsUnsupportedError,
    );
  });
}
