/// Free space as the OS reports it.
///
/// `-1` means "could not be measured" and is treated as "assume there is room":
/// refusing every download because a platform call failed would be worse than
/// trying and reporting a real write error. The settings row prints the same
/// number, so an unmeasured value shows as an em dash rather than 0 B.
library;

import 'package:flutter/services.dart';

abstract class DiskSpace {
  Future<int> availableBytes();
}

class MethodChannelDiskSpace implements DiskSpace {
  const MethodChannelDiskSpace();

  static const MethodChannel _channel = MethodChannel('com.tgmedia/storage');

  @override
  Future<int> availableBytes() async {
    try {
      final value = await _channel.invokeMethod<Object?>('availableBytes');
      if (value is int) return value;
      if (value is num) return value.toInt();
      return -1;
    } on Object {
      return -1;
    }
  }
}

/// Test / desktop double.
class FixedDiskSpace implements DiskSpace {
  const FixedDiskSpace(this.bytes);

  final int bytes;

  @override
  Future<int> availableBytes() async => bytes;
}
