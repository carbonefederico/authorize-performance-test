#!/usr/bin/env bash
# sync-profile-repo.sh — mirror server-profiles/ into the standalone profile
# repository the Ping products clone at boot, commit, and push.
#
# One-time manual setup (the owner creates the repo):
#   gh repo create carbonefederico/paz-sideband-perf-profiles --public
#   git clone https://github.com/carbonefederico/paz-sideband-perf-profiles.git ~/.paz-perf-profile-repo
# Every later push from this script is pre-approved (the new-repo decision).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command rsync
require_command git
require_value SERVER_PROFILE_URL

PROFILE_REPO_DIR="${PROFILE_REPO_DIR:-${HOME}/.paz-perf-profile-repo}"
if [[ ! -d "${PROFILE_REPO_DIR}/.git" ]]; then
  echo "Profile repository not found at ${PROFILE_REPO_DIR}." >&2
  echo "Create it once: gh repo create <name> --public && git clone ${SERVER_PROFILE_URL} ${PROFILE_REPO_DIR}" >&2
  exit 1
fi

rsync -a --delete --exclude '.DS_Store' "${ROOT_DIR}/server-profiles/" "${PROFILE_REPO_DIR}/"
cd "${PROFILE_REPO_DIR}"
if [[ -z "$(git status --porcelain)" ]]; then
  echo "Profile repository already up to date."
  exit 0
fi
git add -A
git commit -m "server-profiles sync from authorize-performance-test ($(cd "${ROOT_DIR}" && git rev-parse --short HEAD))"
git push origin "${SERVER_PROFILE_BRANCH:-main}"
echo "Profile repository updated and pushed."
