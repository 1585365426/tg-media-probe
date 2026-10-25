#!/usr/bin/env bash
# Proves that TDLib is really compiled in: architecture, linkage and the
# td_* C symbols that dart:ffi resolves at runtime.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${REPO_ROOT}/build/ios/iphoneos/Runner.app"
BIN="${APP_DIR}/Runner"

if [[ ! -f "${BIN}" ]]; then
  echo "ERROR: ${BIN} missing, build did not produce an app" >&2
  exit 1
fi

echo "==> architecture"
file "${BIN}"
lipo -info "${BIN}"

echo "==> deployment target (load commands)"
otool -l "${BIN}" | grep -A4 LC_BUILD_VERSION | head -12

echo "==> dynamic dependencies"
otool -L "${BIN}"

echo "==> TDLib symbols"
if nm -gU "${BIN}" 2>/dev/null | grep -q '_td_create_client_id'; then
  nm -gU "${BIN}" | grep -E '_td_(create_client_id|send|receive|execute)$' || true
  echo "OK: td_create_client_id present in the app binary"
else
  echo "ERROR: td_create_client_id not linked into Runner" >&2
  nm -gU "${BIN}" | grep -i td_ | head -20 >&2 || true
  exit 1
fi

echo "==> app size"
du -sh "${APP_DIR}"
echo "==> embedded frameworks"
ls -la "${APP_DIR}/Frameworks" 2>/dev/null || echo "(no embedded frameworks)"
