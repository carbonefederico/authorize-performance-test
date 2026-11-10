#!/usr/bin/env bash
# smoke.sh — run the go/no-go smoke test against a port-forwarded PAZ.
# Terminal A: kubectl -n <ns> port-forward svc/paz-pingauthorize 18443:8443
# Terminal B: ./scripts/smoke.sh
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command node
for name in SIDEBAND_SHARED_SECRET MCP_AUD SUBJECT_ISSUER SUBJECT_SIGNING_KEY_FILE; do
  require_value "${name}"
done
[[ -f "${SUBJECT_SIGNING_KEY_FILE}" ]] || {
  echo "Signing key not found: ${SUBJECT_SIGNING_KEY_FILE} (run ./scripts/generate-signing-key.sh)" >&2
  exit 1
}

port="${PAP_PORT_FORWARD:-18443}"
if ! nc -z localhost "${port}" 2>/dev/null; then
  echo "Nothing listening on localhost:${port}." >&2
  echo "Start the port-forward first: kubectl -n ${NAMESPACE} port-forward svc/${PAZ_RELEASE}-pingauthorize ${port}:8443" >&2
  exit 1
fi

# Lab TLS only: PAZ serves the chart's self-signed private certificate.
NODE_TLS_REJECT_UNAUTHORIZED=0 \
PAZ_SIDEBAND_URL="https://localhost:${port}/sideband/request" \
SIDEBAND_SHARED_SECRET="${SIDEBAND_SHARED_SECRET}" \
MCP_AUD="${MCP_AUD}" \
SUBJECT_ISSUER="${SUBJECT_ISSUER}" \
SUBJECT_SIGNING_KEY_PEM="$(cat "${SUBJECT_SIGNING_KEY_FILE}")" \
node "${ROOT_DIR}/scripts/smoke.mjs"
