#!/usr/bin/env bash
# uninstall.sh — remove the campaign's Helm releases. The namespace and
# Secrets are retained so credentials and the signing key survive between
# campaigns; pass --purge-secrets to also delete the three Secrets.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command helm

helm -n "${NAMESPACE}" uninstall "${LOADTEST_RELEASE}" 2>/dev/null || echo "(loadtest release not present)"
helm -n "${NAMESPACE}" uninstall "${PAZ_RELEASE}" 2>/dev/null || echo "(paz release not present)"

if [[ "${1:-}" == "--purge-secrets" ]]; then
  kubectl -n "${NAMESPACE}" delete secret paz-secrets paz-devops-secret paz-loadtest 2>/dev/null \
    || echo "(secrets already gone)"
  echo "Secrets deleted."
fi

echo "Uninstalled from namespace ${NAMESPACE}. The namespace itself is retained."
