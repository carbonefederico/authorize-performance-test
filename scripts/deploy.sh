#!/usr/bin/env bash
# deploy.sh — phased deployment of the PAZ sideband performance stack.
#
#   ./scripts/deploy.sh headroom   per-node allocatable-vs-requested summary
#   ./scripts/deploy.sh prep       create secrets + install chart (PAP only, PAZ disabled)
#   ./scripts/deploy.sh package    wait for PAP, build the deployment package from its API
#   ./scripts/deploy.sh runtime    commit+push the profile (now with package+cert),
#                                  then enable PAZ and wait Ready
#
# The profile lives in this repository under server-profiles/; the Ping
# products clone it from this repo (the GitHub remote) at boot. The package
# and runtime phases therefore push before PAZ boots — a commit-and-push to
# this repository's remote, which the user has approved.
#
# Licensing credentials never touch this repository: the chart reads the
# cluster Secret 'devops-secret', created once via pingctl from the session
# environment. PAP's admin password is the lab constant in .env (the DevOps
# default the images boot with), used by build-package.sh and scrape-monitor.sh
# client-side. Only the profile URLs are injected here.
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
  --set-string "ping-devops.pingauthorize.envs.SERVER_PROFILE_URL=${SERVER_PROFILE_URL}"
  --set-string "ping-devops.pingauthorizepap.envs.SERVER_PROFILE_URL=${SERVER_PROFILE_URL}"
)

push_profile() {
  require_command git
  [[ -n "$(git -C "${ROOT_DIR}" status --porcelain -- server-profiles/)" ]] || {
    echo "server-profiles/ already committed; nothing to push."
    return 0
  }
  git -C "${ROOT_DIR}" add server-profiles/
  git -C "${ROOT_DIR}" commit -m "server-profiles: package + certificate for PAZ bootstrap"
  git -C "${ROOT_DIR}" push origin HEAD
}

case "${phase}" in
  headroom)
    echo "Per-node allocatable vs requested (consider co-tenants before load runs):"
    kubectl describe nodes 2>/dev/null | grep -A4 "Allocated resources:" | grep -E "cpu|memory" || echo "(allocation data unavailable)"
    kubectl get nodes -o wide 2>/dev/null | awk 'NR>1 {print "  node:", $1}' || true
    ;;

  prep)
    "${ROOT_DIR}/scripts/create-secrets.sh"
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
    echo "package: built and staged in server-profiles/. The runtime phase commits and pushes it."
    ;;

  runtime)
    push_profile
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
