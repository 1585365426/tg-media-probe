#!/usr/bin/env bash
# Publishes CI diagnostics — and the built IPA — to the `ci-report` branch, so a
# build can be picked up from a machine that has neither macOS nor an
# authenticated `gh`. The Actions artifact is the canonical copy; this branch is
# the one that can be fetched with a plain HTTPS GET.
#
# One commit per run (`--orphan`): the IPA is ~19 MB and keeping every run's
# copy in history would grow the branch by that much each time.
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

# Ship the IPA itself when the build produced one. A failed build publishes the
# logs only, which is exactly what is needed to read the compiler error.
if [ -f build/ios/ipa/TGMediaProbe-unsigned.ipa ]; then
  cp build/ios/ipa/TGMediaProbe-unsigned.ipa "${OUT}/TGMediaProbe-unsigned.ipa"
  ( cd "${OUT}" && shasum -a 256 TGMediaProbe-unsigned.ipa \
      > TGMediaProbe-unsigned.ipa.sha256 )
  echo "ipa packaged into the report branch" >&2
else
  echo "no ipa to publish (build failed before packaging)" >&2
fi

git config user.name "tg-media-ci"
git config user.email "tg-media-ci@users.noreply.github.com"
# A fresh single-commit branch: same content each run, no growing history.
git checkout --orphan ci-report-tmp
git rm -rf --cached . >/dev/null 2>&1 || true
git add -f "${OUT}"
git commit -q -m "ci report ${GITHUB_RUN_ID:-local} (${GITHUB_SHA:-local})"
git branch -D ci-report >/dev/null 2>&1 || true
git branch -m ci-report
git push -f origin ci-report
echo "report pushed to branch ci-report"
