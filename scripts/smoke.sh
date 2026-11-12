#!/usr/bin/env bash
# smoke.sh — run the go/no-go smoke test against the in-cluster PAZ Service
# from a machine with cluster access (kubectl proxy/VPN), or against a
# locally port-forwarded PAZ. No PAP dependency.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command node
for name in SIDEBAND_SHARED_SECRET MCP_AUD SUBJECT_ISSUER SUBJECT_SIGNING_KEY_FILE; do
  require_value "${name}"
done
[[ -f "${SUBJECT_SIGNING_KEY_FILE}" ]] || {
  echo "Signing key not found: ${SUBJECT_SIGNING_KEY_FILE} (it is git-ignored and lives in keys/)" >&2
  exit 1
}

port="${PAZ_PORT_FORWARD:-18443}"
if [[ "${PAZ_SIDEBAND_URL}" != *localhost* ]]; then
  # In-cluster/VPN URL from .env: connectivity is the cluster's problem, no preflight.
  :
elif ! nc -z localhost "${port}" 2>/dev/null; then
  echo "Nothing listening on localhost:${port}." >&2
  echo "Start the port-forward first: kubectl -n ${NAMESPACE} port-forward svc/${PAZ_RELEASE}-pingauthorize ${port}:8443" >&2
  exit 1
fi

# Lab TLS only: PAZ serves the chart's self-signed private certificate.
NODE_TLS_REJECT_UNAUTHORIZED=0 \
PAZ_SIDEBAND_URL="${PAZ_SIDEBAND_OVERRIDE:-https://localhost:${port}/sideband/request}" \
SIDEBAND_SHARED_SECRET="${SIDEBAND_SHARED_SECRET}" \
MCP_AUD="${MCP_AUD}" \
SUBJECT_ISSUER="${SUBJECT_ISSUER}" \
SUBJECT_SIGNING_KEY_PEM="$(cat "${SUBJECT_SIGNING_KEY_FILE}")" \
node "${ROOT_DIR}/scripts/smoke.mjs"
