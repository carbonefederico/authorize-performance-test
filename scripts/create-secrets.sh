#!/usr/bin/env bash
# create-secrets.sh — idempotent cluster Secrets for the campaign.
#   paz-devops-secret   Ping DevOps eval credentials, taken from the calling
#                       terminal session's environment (never from files in
#                       this repository)
#   paz-secrets         sideband shared secret (generated + written back to
#                       .env when empty, so k6 and PAZ share one value across
#                       redeploys) + PAP admin password (session environment)
#   paz-loadtest        every env key the k6 script reads (overridden per
#                       profile by run-in-cluster.sh --set-string)
#
# Required in the session environment:
#   PING_IDENTITY_DEVOPS_USER / PING_IDENTITY_DEVOPS_KEY  (eval licensing)
#   PAP_ADMIN_PASSWORD                                    (lab default ok)
# SIDEBAND_SHARED_SECRET may be preset in .env or is generated here.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command kubectl
require_command openssl
for name in PING_IDENTITY_DEVOPS_USER PING_IDENTITY_DEVOPS_KEY PAP_ADMIN_PASSWORD \
            SUBJECT_SIGNING_KEY_FILE MCP_AUD PAZ_SIDEBAND_URL SUBJECT_ISSUER; do
  require_value "${name}"
done
[[ -f "${SUBJECT_SIGNING_KEY_FILE}" ]] || {
  echo "Signing key not found: ${SUBJECT_SIGNING_KEY_FILE} (run ./scripts/generate-signing-key.sh)" >&2
  exit 1
}

kubectl -n "${NAMESPACE}" create secret generic paz-devops-secret \
  --from-literal=username="${PING_IDENTITY_DEVOPS_USER}" \
  --from-literal=password="${PING_IDENTITY_DEVOPS_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -
