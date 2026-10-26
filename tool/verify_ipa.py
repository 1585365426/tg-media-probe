#!/usr/bin/env python
"""Verify an unsigned iOS .ipa: bundle metadata, code signature presence, Mach-O header."""
import glob
import os
import plistlib
import struct
import sys


def ver(v):
    return "%d.%d.%d" % (v >> 16, (v >> 8) & 0xFF, v & 0xFF)


def main(root):
    apps = glob.glob(os.path.join(root, "Payload", "*.app"))
    if not apps:
        print("FAIL: no Payload/*.app")
        return 2
    app = apps[0]
    print("APP:", app)

    with open(os.path.join(app, "Info.plist"), "rb") as fh:
        info = plistlib.load(fh)
    for key in (
        "CFBundleIdentifier",
        "CFBundleShortVersionString",
        "CFBundleVersion",
        "MinimumOSVersion",
        "CFBundleExecutable",
    ):
        print("  %s = %s" % (key, info.get(key)))
    ats = info.get("NSAppTransportSecurity", {})
    print("  NSAllowsLocalNetworking =", ats.get("NSAllowsLocalNetworking"))
    print("  UIOrientations =", info.get("UISupportedInterfaceOrientations"))

    sig = os.path.join(app, "_CodeSignature")
    print("  _CodeSignature exists:", os.path.isdir(sig))
    print(
        "  embedded.mobileprovision exists:",
        os.path.isfile(os.path.join(app, "embedded.mobileprovision")),
    )

    exe = os.path.join(app, info["CFBundleExecutable"])
    print("  binary size:", os.path.getsize(exe))
    with open(exe, "rb") as fh:
        data = fh.read()

    magic = struct.unpack("<I", data[:4])[0]
    print("  mach magic:", hex(magic))
    slices = []
    if magic == 0xCAFEBABE:
        n = struct.unpack(">I", data[4:8])[0]
        for i in range(n):
            cpu, _sub, off, size, _al = struct.unpack(
                ">IIIII", data[8 + i * 20: 28 + i * 20]
            )
            slices.append((cpu, off, size))
            print("  arch cputype 0x%x offset %d size %d" % (cpu, off, size))
    elif magic in (0xFEEDFACF, 0xCFFAEDFE):
        # Thin file: the cputype lives in the header we just read.
        cpu = struct.unpack("<I", data[4:8])[0]
        slices.append((cpu, 0, len(data)))

    for cpu, off, _size in slices:
        _mt, _ct, _ft, _ns, ncmds = struct.unpack("<iiIII", data[off: off + 20])
        p = off + 32
        codesig = 0
        build_versions = []
        for _ in range(ncmds):
            cmd, sz = struct.unpack("<II", data[p: p + 8])
            if sz < 8:
                print("  cputype 0x%x malformed load command 0x%x" % (cpu, cmd))
                break
            if cmd == 0x32:
                plat, minos, sdk, _nt = struct.unpack("<IIII", data[p + 8: p + 24])
                build_versions.append(
                    "  cputype 0x%x LC_BUILD_VERSION platform %d minos %s sdk %s"
                    % (cpu, plat, ver(minos), ver(sdk))
                )
            elif cmd == 0x1D:
                codesig += 1
            p += sz
        for line in build_versions:
            print(line)
        if not build_versions:
            print("  cputype 0x%x no LC_BUILD_VERSION (old-style min version)" % cpu)
        print("  cputype 0x%x LC_CODE_SIGNATURE count %d" % (cpu, codesig))

    # Strings the app is supposed to contain. Dart keeps Chinese literals as
    # TwoByteString (UTF-16LE) in the AOT snapshot, which lives in
    # Frameworks/App.framework/App -- not in the Runner binary that carries the
    # statically linked TDLib. Searching the wrong file yields a false negative.
    dart_aot = os.path.join(app, "Frameworks", "App.framework", "App")
    if not os.path.isfile(dart_aot):
        print("  WARN: no Dart AOT snapshot at", dart_aot)
        return 0
    with open(dart_aot, "rb") as fh:
        dart = fh.read()
    print("  dart aot snapshot:", os.path.getsize(dart_aot), "bytes")

    for probe in sys.argv[2:]:
        hit_utf8 = dart.find(probe.encode("utf-8")) >= 0
        hit_utf16 = dart.find(probe.encode("utf-16-le")) >= 0
        verdict = "ok" if (hit_utf8 or hit_utf16) else "MISSING"
        print(
            "  string %-22s utf8=%-5s utf16le=%-5s %s"
            % (probe, hit_utf8, hit_utf16, verdict)
        )

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
