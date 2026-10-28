#!/usr/bin/env python3
"""MP4 容器布局探针：判断 moov 在 mdat 之前（faststart）还是之后（tail-moov）。

边下边播能不能起来，几乎完全由这一件事决定：

  * faststart —— moov 在前几个字节里，AVPlayer 拿到头部就能建 track，
    ResourceLoader 只需要按播放进度要中段的 mdat 字节。
  * tail-moov —— 索引在文件末尾。AVPlayer 启动时立刻请求 `bytes=<end>-`，
    而 TDLib 是**从 offset 0 顺序**下载的，末尾的那些字节在下载完成前
    永远不在 safeWatermark 之内。ResourceLoader 的规则是「缺数据 = WAIT」，
    于是播放器就一直等 —— 界面表现为转圈/黑屏，用户说「卡死」。

用法：
    python tools/mp4_layout.py <file.mp4> [...]

输出：顶层 box 表、moov/mdat 相对位置、解码前必须读到的字节数、
mvhd 时长、track handler、stsd 编码、是否 fragmented（moof）。
"""
from __future__ import annotations

import struct
import sys

# 需要递归进去找子 box 的容器类型
CONTAINERS = {
    "moov", "trak", "mdia", "minf", "stbl",
    "edts", "dinf", "udta", "mvex", "moof", "traf",
}


def boxes(buf: bytes, start: int, end: int, depth: int = 0):
    """返回 [(type, offset, size, depth)]，深度优先。"""
    out = []
    i = start
    while i + 8 <= end:
        size = struct.unpack(">I", buf[i:i + 4])[0]
        typ = buf[i + 4:i + 8].decode("latin1", "replace")
        hdr = 8
        if size == 1:  # 64 位 largesize
            if i + 16 > end:
                break
            size = struct.unpack(">Q", buf[i + 8:i + 16])[0]
            hdr = 16
        elif size == 0:  # 直到文件尾
            size = end - i
        if size < hdr or i + size > end:
            out.append((typ, i, size, depth))
            break
        out.append((typ, i, size, depth))
        if typ in CONTAINERS:
            out += boxes(buf, i + hdr, i + size, depth + 1)
        i += size
    return out


def find_all(buf: bytes, flat, want: str):
    return [b for b in flat if b[0] == want]


def child_payload_offset(buf: bytes, box) -> int:
    """报错容忍版：返回 box 内容起点。"""
    _, off, size, _ = box
    hdr = 16 if size > 0 and struct.unpack(">I", buf[off:off + 4])[0] == 1 else 8
    return off + hdr


def scan(path: str) -> int:
    with open(path, "rb") as fh:
        data = fh.read()
    total = len(data)
    print(f"\n{'=' * 68}\n{path}\n  size = {total:,} bytes ({total / 1048576:.2f} MiB)")

    flat = boxes(data, 0, total)
    tops = [b for b in flat if b[3] == 0]
    print("\n  top-level boxes:")
    for typ, off, size, _ in tops:
        print(f"    {typ:6s} offset={off:>12,}  size={size:>12,}  end={off + size:>12,}")

    moov = next((b for b in tops if b[0] == "moov"), None)
    mdat = next((b for b in tops if b[0] == "mdat"), None)
    if moov is None:
        print("\n  !! 没有 moov：文件不完整，或还在下载中")
        return 1

    if mdat is None:
        print("\n  !! 没有 mdat（fragmented 且 mdat 缺席？）")

    tail = mdat is not None and moov[1] > mdat[1]
    print(f"\n  moov @ {moov[1]:,} .. {moov[1] + moov[2]:,}")
    if mdat is not None:
        print(f"  mdat @ {mdat[1]:,} .. {mdat[1] + mdat[2]:,}")
    print(f"  LAYOUT = {'TAIL-MOOV' if tail else 'FASTSTART'}")
    if tail:
        need = total - moov[1]
        print(f"  解码前必须读到的尾部字节 = {need:,} "
              f"({need / total * 100:.1f}% of file) —— 顺序下载要走到文件尾")
    else:
        print(f"  解码前必须读到的头部字节 = {moov[1] + moov[2]:,} "
              f"({(moov[1] + moov[2]) / total * 100:.1f}% of file)")

    # mvhd
    for off, _hdr, size, _d in [(b[1], 0, b[2], b[3]) for b in find_all(data, flat, "mvhd")]:
        b = child_payload_offset(data, (None, off, size, 0))
        ver = data[b]
        if ver == 0:
            ts, dur = struct.unpack(">II", data[b + 12:b + 20])
        else:
            ts, dur = struct.unpack(">IQ", data[b + 20:b + 32])
        print(f"\n  duration = {dur / ts:.2f} s   (timescale={ts})")
        if tail and dur > 0:
            print(f"  首帧可播前的最坏等待 ≈ 整文件下载时间（{dur / ts:.0f} s 素材）")
        break

    handlers = []
    for b in find_all(data, flat, "hdlr"):
        o = child_payload_offset(data, (None, b[1], b[2], 0)) + 8
        handlers.append(data[o:o + 4].decode("latin1", "replace"))
    print(f"  handlers = {handlers}")

    for b in find_all(data, flat, "stsd"):
        o = child_payload_offset(data, (None, b[1], b[2], 0))
        cnt = struct.unpack(">I", data[o + 4:o + 8])[0]
        j = o + 8
        entries = []
        for _ in range(cnt):
            if j + 8 > len(data):
                break
            esz = struct.unpack(">I", data[j:j + 4])[0]
            entries.append(data[j + 4:j + 8].decode("latin1", "replace"))
            if esz <= 0:
                break
            j += esz
        print(f"  sample entries = {entries}")

    print(f"  fragmented (moof present) = {bool(find_all(data, flat, 'moof'))}")
    return 2 if tail else 0


def main(argv) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 64
    worst = 0
    for p in argv[1:]:
        try:
            worst = max(worst, scan(p))
        except FileNotFoundError:
            print(f"\n  !! 文件不存在：{p}")
            worst = max(worst, 1)
    return worst


if __name__ == "__main__":
    sys.exit(main(sys.argv))
