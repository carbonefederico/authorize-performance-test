#!/usr/bin/env bash
# validate.sh — the project's front door: every offline check in one run.
# Prints a one-line PASS/FAIL per check and exits non-zero on any failure.
# Cluster-side verification (deploy/verify/smoke) is separate — see README.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

fail=0
check() { # check <label> <command...>
  local label="$1"; shift
  if "$@" > /dev/null 2>&1; then
    echo "PASS: ${label}"
  else
    echo "FAIL: ${label}"
    fail=1
  fi
}

check "node unit tests (envelope, claims, decision)" npm test
render_values() { # render_values <release> <set-arg>
  # helm lint on chart 0.15.0 mis-parses its own multi-doc secret-cert.yaml
  # (lint-only quirk; template and install --dry-run are clean), so the
  # chart-level check is a full client render instead.
  local chart_tgz="${TMPDIR:-/tmp}/ping-devops-${PING_CHART_VERSION:-0.15.0}.tgz"
  [[ -f "${chart_tgz}" ]] || helm pull pingidentity/ping-devops --version "${PING_CHART_VERSION:-0.15.0}" --destination "${chart_tgz%/*}" > /dev/null 2>&1
  helm template "$1" "${chart_tgz}" -f "${ROOT_DIR}/helm/paz/values.yaml" --set-string "$2" > /dev/null 2>&1
}
check "render helm/paz (values)" render_values test "pingauthorize.envs.SERVER_PROFILE_URL=https://example.invalid/x.git"
check "helm lint helm/loadtest" bash -c "helm lint helm/loadtest > /dev/null"
# k6 dry-run: exit 0 (all green) or 99 (thresholds crossed — expected with
# nothing listening) both prove the script compiles and executes; a script
# exception exits 107 and fails.
k6_dry_run() {
  env \
    PAZ_SIDEBAND_URL=https://localhost:1/sideband/request \
    SIDEBAND_SHARED_SECRET=x \
    MCP_AUD=https://x/mcp/portfolio \
    SUBJECT_ISSUER=https://x \
    SUBJECT_SIGNING_KEY="$(cat "${ROOT_DIR}/keys/subject-signing.key")" \
    RATE=250 AGENTS=10 DURATION=1s WARMUP=1s \
    k6 run --no-usage-report -q \
    "${ROOT_DIR}/helm/loadtest/files/sideband-decision.js" > /dev/null 2>&1
  local code=$?
  [[ ${code} -eq 0 || ${code} -eq 99 ]]
}
check "k6 script compiles (1s dry-run)" k6_dry_run
for script in scripts/*.sh; do
  check "bash -n ${script}" bash -n "${script}"
done
check "node syntax smoke.mjs" node --check scripts/smoke.mjs
check "node syntax smoke-helpers.mjs" node --check scripts/smoke-helpers.mjs
check "python3 report generator compiles" python3 -m py_compile scripts/generate-report.py
check "subject signing certificate parses" openssl x509 -in server-profiles/pingauthorize/instance/server/default/data/perf-subject-cert.pem -noout

if [[ ${fail} -eq 0 ]]; then
  echo "All checks passed."
else
  echo "FAILURES above — fix before deploying."
fi
exit "${fail}"
