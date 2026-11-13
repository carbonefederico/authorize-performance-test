#!/usr/bin/env bash
# smoke-jwks.sh — assert the JWKS distribution model is live: the in-cluster
# JWKS server serves the perf-subject-key set, and PAZ (which fetched it into
# its validator cache) reaches it. Run alongside smoke.sh (same port-forward
# session); best paired: ./scripts/smoke.sh && ./scripts/smoke-jwks.sh
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_command kubectl

pods="$(kubectl -n "${NAMESPACE}" get pods \
  -l "app.kubernetes.io/instance=${PAZ_RELEASE},app.kubernetes.io/name=pingauthorize" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -v '^$')"
[[ -n "${pods}" ]] || { echo "no PAZ pods found" >&2; exit 1; }

fail=0
for pod in ${pods}; do
  body="$(kubectl -n "${NAMESPACE}" exec "${pod}" -c pingauthorize -- \
    curl -s "http://${PAZ_RELEASE}-jwks/.well-known/jwks.json" 2>/dev/null || true)"
  if echo "${body}" | grep -q '"kid":"perf-subject-key"'; then
    echo "PASS JWKS reachable from ${pod} (kid perf-subject-key served)"
  else
    echo "FAIL JWKS fetch from ${pod}: ${body:0:120}"
    fail=1
  fi
done
exit ${fail}
