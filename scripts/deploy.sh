#!/usr/bin/env bash
# deploy.sh — phased deployment of the PAZ sideband performance stack.
#
#   ./scripts/deploy.sh headroom   per-node allocatable-vs-requested summary
#   ./scripts/deploy.sh prep       create secrets, sync profile repo, install chart (PAP only, PAZ disabled)
#   ./scripts/deploy.sh package    wait for PAP, build the deployment package from its API
#   ./scripts/deploy.sh runtime    push profile (now with package+cert) + enable PAZ, wait Ready
#
# Phases are idempotent: helm install skips an existing release; upgrades
# re-run. Run in order for a first deploy; re-run any phase after changes.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command kubectl
require_command helm

phase="${1:-}"
[[ -n "${phase}" ]] || {
  echo "Usage: $0 {headroom|prep|package|runtime}" >&2
  exit 1
}

chart_args=(
  --set-string sidebandSharedSecret="${SIDEBAND_SHARED_SECRET:-}"
  --set-string papAdminPassword="${PAP_ADMIN_PASSWORD:-}"
  --set-string devopsUser="${PING_IDENTITY_DEVOPS_USER:-}"
  --set-string devopsKey="${PING_IDENTITY_DEVOPS_KEY:-}"
  --set-string "ping-devops.pingauthorize.envs.SERVER_PROFILE_URL=${SERVER_PROFILE_URL}"
  --set-string "ping-devops.pingauthorizepap.envs.SERVER_PROFILE_URL=${SERVER_PROFILE_URL}"
)

case "${phase}" in
  headroom)
    echo "Per-node allocatable vs requested (consider co-tenants before load runs):"
    kubectl describe nodes 2>/dev/null | grep -A4 "Allocated resources:" | grep -E "cpu|memory" || echo "(allocation data unavailable)"
    kubectl get nodes -o wide 2>/dev/null | awk 'NR>1 {print "  node:", $1}' || true
    ;;

  prep)
    "${ROOT_DIR}/scripts/create-secrets.sh"
    "${ROOT_DIR}/scripts/sync-profile-repo.sh"
    if helm -n "${NAMESPACE}" status "${PAZ_RELEASE}" > /dev/null 2>&1; then
      echo "Release ${PAZ_RELEASE} already exists; upgrading with PAZ disabled."
      helm -n "${NAMESPACE}" upgrade "${PAZ_RELEASE}" "${ROOT_DIR}/helm/paz" "${chart_args[@]}" \
        --set ping-devops.pingauthorize.enabled=false
    else
      helm -n "${NAMESPACE}" install "${PAZ_RELEASE}" "${ROOT_DIR}/helm/paz" "${chart_args[@]}" \
        --set ping-devops.pingauthorize.enabled=false
    fi
    kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod \
      -l "app.kubernetes.io/instance=${PAZ_RELEASE},app.kubernetes.io/name=pingauthorizepap" --timeout=15m
    echo "prep: secrets created and PAP is Ready (PAZ still disabled)."
    ;;

  package)
    "${ROOT_DIR}/scripts/build-package.sh"
    echo "package: built. Next: ./scripts/sync-profile-repo.sh runs inside the runtime phase."
    ;;

  runtime)
    "${ROOT_DIR}/scripts/sync-profile-repo.sh"
    helm -n "${NAMESPACE}" upgrade "${PAZ_RELEASE}" "${ROOT_DIR}/helm/paz" "${chart_args[@]}" \
      --set ping-devops.pingauthorize.enabled=true
    kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod \
      -l "app.kubernetes.io/instance=${PAZ_RELEASE},app.kubernetes.io/name=pingauthorize" --timeout=20m
    "${ROOT_DIR}/scripts/verify.sh"
    echo "runtime: both PAZ pods Ready. Run ./scripts/verify.sh and the smoke test."
    ;;

  *)
    echo "Unknown phase: ${phase}" >&2
    exit 1
    ;;
esac
