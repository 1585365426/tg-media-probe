#!/usr/bin/env bash
# Downloads the prebuilt TDLib xcframework, verifies its checksum and unpacks it
# into ios/tdlib/. The 350 MB binary is never committed to the repository.
set -euo pipefail

VERSION="1.8.69-025086e3"
URL="https://github.com/Swiftgram/TDLibFramework/releases/download/${VERSION}/TDLibFramework.zip"
# checksum published in Swiftgram/TDLibFramework Package.swift (binaryTarget)
SHA256="65758175da552aabee45463698c6fb4553d614612df0cbd49c07d550eed46a41"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_DIR="${TDLIB_CACHE_DIR:-${HOME}/tdlib-cache}"
ZIP_PATH="${CACHE_DIR}/TDLibFramework-${VERSION}.zip"
DEST="${REPO_ROOT}/ios/tdlib"

mkdir -p "${CACHE_DIR}"

if [[ ! -f "${ZIP_PATH}" ]]; then
  echo "==> downloading ${URL}"
  curl -L --fail --retry 5 --retry-delay 5 --retry-all-errors -o "${ZIP_PATH}" "${URL}"
fi

echo "==> verifying sha256"
echo "${SHA256}  ${ZIP_PATH}" | shasum -a 256 -c -

rm -rf "${DEST}/TDLibFramework.xcframework"
echo "==> unzipping into ${DEST}"
unzip -q -o "${ZIP_PATH}" -d "${DEST}"

echo "==> xcframework layout"
find "${DEST}" -maxdepth 3 -name "*.xcframework" -o -maxdepth 4 -type f -name "TDLibFramework" | head -20
for bin in $(find "${DEST}" -type f -name "TDLibFramework" -path "*ios-arm64*"); do
  echo "--- ${bin}"
  file "${bin}"
  lipo -info "${bin}" || true
  otool -hv "${bin}" | head -3 || true
done

if [[ ! -d "${DEST}/TDLibFramework.xcframework" ]]; then
  echo "ERROR: TDLibFramework.xcframework not found after unzip" >&2
  ls -la "${DEST}" >&2
  exit 1
fi

echo "==> TDLib ready"
