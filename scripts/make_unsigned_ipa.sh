#!/usr/bin/env bash
# Packages the unsigned .app into an IPA that TrollStore can install.
# No code signing happens here: TrollStore applies its own signature on device.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${REPO_ROOT}/build/ios/iphoneos/Runner.app"
OUT_DIR="${REPO_ROOT}/build/ios/ipa"
IPA="${OUT_DIR}/TGMediaProbe-unsigned.ipa"

if [[ ! -d "${APP_DIR}" ]]; then
  echo "ERROR: ${APP_DIR} missing" >&2
  exit 1
fi

rm -rf "${OUT_DIR}" "${REPO_ROOT}/build/ipa-work"
mkdir -p "${OUT_DIR}" "${REPO_ROOT}/build/ipa-work/Payload"
cp -R "${APP_DIR}" "${REPO_ROOT}/build/ipa-work/Payload/"

# zip must keep symlinks inside frameworks intact -> use -y
(cd "${REPO_ROOT}/build/ipa-work" && zip -qry "${IPA}" Payload)
rm -rf "${REPO_ROOT}/build/ipa-work"

echo "==> ${IPA}"
ls -lh "${IPA}"
# Exact bytes, so the report does not have to quote the rounded `ls -lh` value
# or, worse, the size of the artifact zip that wraps it.
echo "ipa_bytes: $(wc -c < "${IPA}" | tr -d ' ')"
shasum -a 256 "${IPA}" | tee "${OUT_DIR}/sha256.txt"
echo "==> bundle info"
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${APP_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Print :MinimumOSVersion" "${APP_DIR}/Info.plist"
