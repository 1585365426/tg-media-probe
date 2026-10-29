/// The four facts that decide whether a file may be played.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/download/cache_validator.dart';

void main() {
  late Directory dir;
  const validator = CacheValidator();

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tgmedia_validator_');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<String> fileOf(int bytes) async {
    final file = File('${dir.path}/v.mp4');
    await file.writeAsBytes(List<int>.filled(bytes, 7));
    return file.path;
  }

  test('complete + right size + readable is the only valid combination',
      () async {
    final path = await fileOf(2048);
    expect(
      await validator.validate(
          path: path, expectedSize: 2048, downloadCompleted: true),
      CacheVerdict.valid,
    );
  });

  test('TDLib not done is incomplete even when the file exists', () async {
    final path = await fileOf(2048);
    expect(
      await validator.validate(
          path: path, expectedSize: 2048, downloadCompleted: false),
      CacheVerdict.incomplete,
    );
  });

  test('missing path is reported as missing', () async {
    expect(
      await validator.validate(
          path: '${dir.path}/gone.mp4',
          expectedSize: 10,
          downloadCompleted: true),
      CacheVerdict.missing,
    );
    expect(
      await validator.validate(
          path: null, expectedSize: 10, downloadCompleted: true),
      CacheVerdict.missing,
    );
    expect(
      await validator.validate(
          path: '', expectedSize: 10, downloadCompleted: false),
      CacheVerdict.incomplete,
    );
  });

  test('a short file is a size mismatch, not "almost done"', () async {
    final path = await fileOf(1024);
    expect(
      await validator.validate(
          path: path, expectedSize: 2048, downloadCompleted: true),
      CacheVerdict.sizeMismatch,
    );
  });

  test('an unreadable file is reported as unreadable', () async {
    final path = await fileOf(1024);
    final failing = CacheValidator(probe: (_, _) async => false);
    expect(
      await failing.validate(
          path: path, expectedSize: 1024, downloadCompleted: true),
      CacheVerdict.unreadable,
    );
  });

  test('an empty file never counts as valid', () async {
    final path = await fileOf(0);
    expect(
      await validator.validate(
          path: path, expectedSize: 0, downloadCompleted: true),
      CacheVerdict.sizeMismatch,
    );
  });

  test('a zero expected size skips only the size check', () async {
    final path = await fileOf(5);
    expect(
      await validator.validate(
          path: path, expectedSize: 0, downloadCompleted: true),
      CacheVerdict.valid,
    );
  });

  test('shouldDelete flags exactly the worthless cases', () {
    expect(CacheVerdict.sizeMismatch.shouldDelete, isTrue);
    expect(CacheVerdict.unreadable.shouldDelete, isTrue);
    expect(CacheVerdict.missing.shouldDelete, isFalse);
    expect(CacheVerdict.incomplete.shouldDelete, isFalse);
    expect(CacheVerdict.valid.shouldDelete, isFalse);
  });
}
