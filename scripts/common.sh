#!/usr/bin/env bash
# common.sh — shared shell setup for every script in scripts/.
# Sourced, never executed: resolves ROOT_DIR, loads .env, then the optional
# load profile (profile values win over .env), and provides require_command
# / require_value helpers.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Auto-provision .env on first use: every value ships with a working default
# except the two DevOps credential slots. A fresh clone becomes usable by
# filling exactly those two lines — no cp step.
if [[ ! -f "${ROOT_DIR}/.env" && -f "${ROOT_DIR}/.env.example" ]]; then
  cp "${ROOT_DIR}/.env.example" "${ROOT_DIR}/.env"
  chmod 600 "${ROOT_DIR}/.env"
  echo "First run: created .env from .env.example." >&2
fi

if [[ -f "${ROOT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/.env"
  set +a
fi


# Optional load profile: PROFILE=stage-100 loads profiles/stage-100.env on
# top of .env. Values in the profile win, so a profile fully describes its run.
PROFILE="${PROFILE:-}"
if [[ -n "${PROFILE}" ]]; then
  profile_file="${ROOT_DIR}/profiles/${PROFILE}.env"
  [[ -f "${profile_file}" ]] || {
    echo "Profile not found: ${profile_file}" >&2
    exit 1
  }
  set -a
  # shellcheck disable=SC1090
  source "${profile_file}"
  set +a
fi

# Expand ${ROOT_DIR} inside .env/profile values such as
# SUBJECT_SIGNING_KEY_FILE.
for path_var in SUBJECT_SIGNING_KEY_FILE; do
  if [[ -n "${!path_var:-}" && "${!path_var}" == *'${ROOT_DIR}'* ]]; then
    export "${path_var}=${!path_var//\$\{ROOT_DIR\}/${ROOT_DIR}}"
  fi
done

NAMESPACE="${NAMESPACE:-paz-perf}"
# One release carries the whole Ping stack (both products); the chart
# appends each product name, so fullnames read
# <folder>-pingauthorize / <folder>-pingauthorizepap — the namespace convention.
PROJECT_SLUG="$(basename "${ROOT_DIR}")"
RELEASE="${RELEASE:-${PROJECT_SLUG}}"
PAZ_RELEASE="${RELEASE}"
PAP_RELEASE="${RELEASE}"
LOADTEST_RELEASE="${LOADTEST_RELEASE:-${PROJECT_SLUG}-loadtest}"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command not found: $1" >&2
    exit 1
  }
}

require_value() {
  local name="$1"
  [[ -n "${!name:-}" ]] || {
    echo "Required value is empty: ${name} (set it in .env)" >&2
    exit 1
  }
}
