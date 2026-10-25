#!/usr/bin/env bash
# Publishes CI diagnostics to the `ci-report` branch so build results can be
# read without a local macOS machine or Actions UI access.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

OUT="ci-report"
mkdir -p "${OUT}"

{
  echo "run_id: ${GITHUB_RUN_ID:-local}"
  echo "run_attempt: ${GITHUB_RUN_ATTEMPT:-0}"
  echo "sha: ${GITHUB_SHA:-local}"
  echo "ref: ${GITHUB_REF:-local}"
  echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "runner: ${RUNNER_OS:-unknown} ${RUNNER_ARCH:-unknown}"
  echo "--- host"
  sw_vers || true
  echo "--- xcode"
  xcodebuild -version || true
  echo "--- flutter"
  flutter --version || true
  echo "--- ipa artifacts"
  ls -lh build/ios/ipa 2>/dev/null || echo "(no ipa)"
  cat build/ios/ipa/sha256.txt 2>/dev/null || true
} > "${OUT}/summary.txt"

git config user.name "tg-media-ci"
git config user.email "tg-media-ci@users.noreply.github.com"
git checkout -B ci-report
git add -f "${OUT}"
if git diff --cached --quiet; then
  echo "no report changes"
else
  git commit -m "ci report ${GITHUB_RUN_ID:-local} (${GITHUB_SHA:-local})"
fi
git push -f origin ci-report
echo "report pushed to branch ci-report"
