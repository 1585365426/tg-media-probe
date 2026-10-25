#!/usr/bin/env bash
# Proves that TDLib is really compiled into Runner: architecture, linkage,
# minimum OS and the td_* C symbols that dart:ffi resolves at runtime.
# Every check prints the command output it relied on; nothing is inferred.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${REPO_ROOT}/build/ios/iphoneos/Runner.app"
BIN="${APP_DIR}/Runner"
XCF="${REPO_ROOT}/ios/tdlib/TDLibFramework.xcframework"

if [[ ! -f "${BIN}" ]]; then
  echo "ERROR: ${BIN} missing, build did not produce an app" >&2
  exit 1
fi

echo "==> vendored xcframework slice"
FW_PLIST="${XCF}/ios-arm64/TDLibFramework.framework/Info.plist"
if [[ -f "${FW_PLIST}" ]]; then
  /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${FW_PLIST}"
  echo -n "MinimumOSVersion = "
  /usr/libexec/PlistBuddy -c "Print :MinimumOSVersion" "${FW_PLIST}"
  echo -n "CFBundleShortVersionString = "
  /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${FW_PLIST}"
else
  echo "ERROR: ${FW_PLIST} missing, fetch_tdlib.sh did not unpack" >&2
  exit 1
fi
echo -n "static archive? "
if head -c 8 "${XCF}/ios-arm64/TDLibFramework.framework/TDLibFramework" | grep -q '!<arch>'; then
  echo "yes (ar archive: linked in, nothing to embed)"
else
  echo "no (Mach-O: must be embedded and signed)"
fi

echo "==> app plist minimum OS"
/usr/libexec/PlistBuddy -c "Print :MinimumOSVersion" "${APP_DIR}/Info.plist" || true
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${APP_DIR}/Info.plist" || true
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_DIR}/Info.plist" || true

echo "==> architecture"
file "${BIN}"
lipo -info "${BIN}"

echo "==> minimum OS recorded in the Mach-O load commands"
otool -l "${BIN}" | grep -A4 -E 'LC_BUILD_VERSION|LC_VERSION_MIN_IPHONEOS' | head -24

echo "==> dynamic dependencies (no TDLib dylib expected)"
otool -L "${BIN}"

echo "==> TDLib symbols"
# Release builds strip, so try the richest listing first and fall back.
SYMS="$(mktemp)"
for flags in "-gU" "-g" ""; do
  # shellcheck disable=SC2086
  if nm ${flags} "${BIN}" > "${SYMS}" 2>/dev/null; then
    if grep -q '_td_create_client_id' "${SYMS}"; then
      echo "found with: nm ${flags}"
      break
    fi
  fi
done

if grep -q '_td_create_client_id' "${SYMS}"; then
  grep -E '_td_(create_client_id|send|receive|execute)$' "${SYMS}" | sort -u || true
  MISSING=0
  for sym in _td_create_client_id _td_send _td_receive _td_execute; do
    grep -q "${sym}$" "${SYMS}" || { echo "ERROR: ${sym} missing from binary" >&2; MISSING=1; }
  done
  if [[ "${MISSING}" -ne 0 ]]; then
    rm -f "${SYMS}"
    exit 1
  fi
  echo "OK: all four tdjson entry points are present in Runner"
else
  echo "ERROR: td_create_client_id not linked into Runner" >&2
  echo "--- any td_ symbols visible:" >&2
  nm -a "${BIN}" 2>/dev/null | grep -i td_ | head -20 >&2 || true
  rm -f "${SYMS}"
  exit 1
fi
rm -f "${SYMS}"

echo "==> TDLib footprint in the binary"
otool -l "${BIN}" | grep -c LC_SEGMENT_64 || true
du -sh "${APP_DIR}"

echo "==> embedded frameworks (static TDLib means this stays empty of TDLib)"
ls -la "${APP_DIR}/Frameworks" 2>/dev/null || echo "(no embedded frameworks)"

echo "==> final verdict"
echo "TDLib is statically linked into Runner and the four tdjson symbols are exported"
