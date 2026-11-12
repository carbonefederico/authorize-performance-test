#!/usr/bin/env bash
# deploy.sh — phased deployment of the PAZ sideband performance stack.
#
#   ./scripts/deploy.sh headroom   per-node allocatable-vs-requested summary
#   ./scripts/deploy.sh prep       create secrets + install PAP (ping chart, direct reference)
#   ./scripts/deploy.sh package    wait for PAP, publish the deployment package to S3
#   ./scripts/deploy.sh runtime    install/upgrade PAZ (embedded PDP polling the S3 store), wait Ready
#
# Two direct chart references — the manual-deploy shape, no umbrella chart,
# no vendored dependency:
#   helm install pap pingidentity/ping-devops  -f helm/pingauthorizepap/values.yaml
#   helm install paz pingidentity/ping-devops  -f helm/pingauthorize/values.yaml
#
# The profile lives in this repository under server-profiles/ and configures
# the SERVERS (dsconfig layer, certificate, S3 store definition); the POLICY
# travels through the S3 package store (setup-aws.sh creates it,
# build-package.sh publishes to it, PAZ polls it — no restart on policy
# change). Policy publication and server deployment are therefore separate
# concerns, exactly as in a production store deployment.
#
# Licensing: the chart secretRefs the cluster Secret 'devops-secret', which
# the operator provisions by their environment standard. PAP's admin password
# is the lab constant in .env (the DevOps default the images boot with), used
# by build-package.sh and scrape-monitor.sh client-side. Only the profile
# URLs are injected here.
#
# Phases are idempotent: helm install skips an existing release (upgrades
# re-run). Run in order for a first deploy; re-run any phase after changes.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command kubectl
require_command helm

phase="${1:-}"
[[ -n "${phase}" ]] || {
  echo "Usage: $0 {headroom|prep|package|runtime}" >&2
  exit 1
}

PAP_RELEASE="${PAP_RELEASE:-pap}"
CHART_REPO="pingidentity/ping-devops"
CHART_VERSION="${PING_CHART_VERSION:-0.15.0}"

ensure_repo() {
  helm repo add pingidentity https://helm.pingidentity.com/ --force-update > /dev/null
}

install_or_upgrade() { # install_or_upgrade <release> <values-file> <extra args...>
  local release="$1"; shift
  local values="$1"; shift
  if helm -n "${NAMESPACE}" status "${release}" > /dev/null 2>&1; then
    helm -n "${NAMESPACE}" upgrade "${release}" "${CHART_REPO}" \
      --version "${CHART_VERSION}" -f "${values}" "$@"
  else
    helm -n "${NAMESPACE}" install "${release}" "${CHART_REPO}" \
      --version "${CHART_VERSION}" -f "${values}" "$@"
  fi
}

case "${phase}" in
  headroom)
    echo "Per-node allocatable vs requested (consider co-tenants before load runs):"
    kubectl describe nodes 2>/dev/null | grep -A4 "Allocated resources:" | grep -E "cpu|memory" || echo "(allocation data unavailable)"
    kubectl get nodes -o wide 2>/dev/null | awk 'NR>1 {print "  node:", $1}' || true
    ;;

  prep)
    "${ROOT_DIR}/scripts/create-secrets.sh"
    ensure_repo
    install_or_upgrade "${PAP_RELEASE}" "${ROOT_DIR}/helm/pingauthorizepap/values.yaml" \
      --set-string "pingauthorizepap.envs.SERVER_PROFILE_URL=${SERVER_PROFILE_URL}"
    kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod \
      -l "app.kubernetes.io/instance=${PAP_RELEASE},app.kubernetes.io/name=pingauthorizepap" --timeout=15m
    echo "prep: secrets created and PAP is Ready. PAZ not installed yet."
    ;;

  package)
    "${ROOT_DIR}/scripts/build-package.sh"
    echo "package: published to s3://${PAZ_S3_BUCKET}/${PAZ_S3_PREFIX}/. Re-run any time —"
    echo "the PAZ nodes poll and load it without a restart."
    ;;

  runtime)
    ensure_repo
    install_or_upgrade "${PAZ_RELEASE}" "${ROOT_DIR}/helm/pingauthorize/values.yaml" \
      --set-string "pingauthorize.envs.SERVER_PROFILE_URL=${SERVER_PROFILE_URL}"
    kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod \
      -l "app.kubernetes.io/instance=${PAZ_RELEASE},app.kubernetes.io/name=pingauthorize" --timeout=20m
    "${ROOT_DIR}/scripts/verify.sh"
    echo "runtime: both PAZ pods Ready. Run ./scripts/smoke.sh next."
    ;;

  *)
    echo "Unknown phase: ${phase}" >&2
    exit 1
    ;;
esac
