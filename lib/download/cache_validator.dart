/// Decides whether a file on disk may be handed to the player.
///
/// This is the gate that replaces every "is it downloaded?" guess the old chain
/// made. Four independent facts have to agree before a file counts as playable:
///
/// 1. TDLib reported `is_downloading_completed == true`;
/// 2. the path it reported exists;
/// 3. the size on disk equals the size TDLib promised;
/// 4. the first bytes can actually be read.
///
/// `downloaded_size >= size` is deliberately **not** one of them: TDLib
/// documents that figure as possibly counting garbage, and the E1 experiment
/// confirmed the readable window is not the whole file.
library;

import 'dart:io';

enum CacheVerdict {
  /// All four facts agree. Safe to play.
  valid,

  /// No file at the reported path.
  missing,

  /// TDLib has not finished the transfer.
  incomplete,

  /// A file is there but its length is not the expected one.
  sizeMismatch,

  /// The file exists at the right size but cannot be read.
  unreadable,
}

extension CacheVerdictText on CacheVerdict {
  bool get isPlayable => this == CacheVerdict.valid;

  /// True when the bytes are worthless and should be deleted before retrying.
  bool get shouldDelete =>
      this == CacheVerdict.sizeMismatch || this == CacheVerdict.unreadable;

  String get label => switch (this) {
        CacheVerdict.valid => '本地文件就绪',
        CacheVerdict.missing => '本地文件不存在',
        CacheVerdict.incomplete => '尚未下载完成',
        CacheVerdict.sizeMismatch => '本地文件大小异常',
        CacheVerdict.unreadable => '本地文件损坏',
      };
}

/// Reads the first bytes of a file. Injected in tests so "unreadable" can be
/// exercised without permission tricks.
typedef FileReadProbe = Future<bool> Function(String path, int bytes);

class CacheValidator {
  const CacheValidator({this.probeBytes = 4096, this.probe});

  final int probeBytes;

  /// Injected reader; null uses the real filesystem probe below.
  final FileReadProbe? probe;

  Future<CacheVerdict> validate({
    required String? path,
    required int expectedSize,
    required bool downloadCompleted,
  }) async {
    if (path == null || path.isEmpty) {
      return downloadCompleted ? CacheVerdict.missing : CacheVerdict.incomplete;
    }
    if (!downloadCompleted) return CacheVerdict.incomplete;

    final file = File(path);
    if (!await file.exists()) return CacheVerdict.missing;

    final onDisk = await file.length();
    if (expectedSize > 0 && onDisk != expectedSize) {
      return CacheVerdict.sizeMismatch;
    }
    if (onDisk == 0) return CacheVerdict.sizeMismatch;

    final read = probe ?? _defaultProbe;
    final readable = await read(path, probeBytes);
    if (!readable) return CacheVerdict.unreadable;
    return CacheVerdict.valid;
  }

  static Future<bool> _defaultProbe(String path, int bytes) async {
    RandomAccessFile? handle;
    try {
      handle = await File(path).open();
      final data = await handle.read(bytes.clamp(1, 1 << 20));
      return data.isNotEmpty;
    } on Object {
      return false;
    } finally {
      try {
        await handle?.close();
      } on Object {
        // Closing a handle that already failed is not a second failure.
      }
    }
  }
}
