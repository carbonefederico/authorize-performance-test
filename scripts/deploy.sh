#!/usr/bin/env bash
# deploy.sh — deployment of the PAZ sideband performance stack.
#
#   ./scripts/deploy.sh headroom   per-node allocatable-vs-requested summary
#   ./scripts/deploy.sh stack      create secrets, install the WHOLE Ping stack (PAP + PAZ), wait Ready
#   ./scripts/deploy.sh package    publish the deployment package to S3 (needs PAP running)
#
# One chart (helm/paz), one values file, one release carrying both products —
# the manual-deploy shape: helm install <folder> pingidentity/ping-devops
# -f helm/paz/values.yaml. PAZ boots embedded-PDP polling the S3 store; an
# empty bucket at boot is a normal production state — the poller picks the
# package up when 'stack' is followed by 'package'. No restart, no phasing.
#
# The k6 load generator is NOT part of the stack: it installs only when a
# campaign run starts (scripts/run-in-cluster.sh), so deploying never
# generates test traffic.
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
    # Per-node CPU picture the operator can actually read: allocatable,
    # what the co-tenants already request, what is left, and whether this
    # stack (PAP 1 CPU + 2x PAZ 2 CPU) fits on that node.
    python3 - <<'PY'
import subprocess, json

def kubectl_json(*args):
    out = subprocess.run(['kubectl'] + list(args), capture_output=True, text=True)
    return json.loads(out.stdout) if out.stdout.strip() else {}

def parse_cpu(v):
    v = str(v)
    return float(v[:-1]) / 1000 if v.endswith('m') else float(v or 0)

nodes = kubectl_json('get', 'nodes', '-o', 'json')['items']
alloc = {n['metadata']['name']: parse_cpu(n['status']['allocatable'].get('cpu', '0')) for n in nodes}
req = {name: 0.0 for name in alloc}
for pod in kubectl_json('get', 'pods', '-A', '-o', 'json')['items']:
    if pod.get('status', {}).get('phase') in ('Succeeded', 'Failed'):
        continue
    name = pod['spec'].get('nodeName')
    if name in req:
        for c in pod['spec'].get('containers', []):
            req[name] += parse_cpu(c.get('resources', {}).get('requests', {}).get('cpu', '0'))

print(f"{'NODE':<44} {'ALLOC':>5} {'REQ':>5} {'FREE':>5}   FITS-STACK (needs 2)")
total_free = 0.0
for name in sorted(alloc):
    free = alloc[name] - req[name]
    total_free += free
    fits = 'yes' if free >= 2 else 'NO'
    print(f'{name:<44} {alloc[name]:>4.1f} {req[name]:>5.1f} {free:>5.1f}   {fits}')
print(f'{"TOTAL free CPU":<55} {total_free:.1f}')
print("Stack needs: PAP 1 + PAZ 2x2 = 5 CPU of requests; k6 agents later ~0.1 each (burstable).")
PY
    ;;

  stack)
    "${ROOT_DIR}/scripts/create-secrets.sh"
    ensure_repo
    install_or_upgrade "${PAZ_RELEASE}" "${ROOT_DIR}/helm/paz/values.yaml" \
      --set-string "pingauthorize.envs.SERVER_PROFILE_URL=${SERVER_PROFILE_URL}" \
      --set-string "pingauthorizepap.envs.SERVER_PROFILE_URL=${SERVER_PROFILE_URL}"
    kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod \
      -l "app.kubernetes.io/instance=${PAZ_RELEASE},app.kubernetes.io/name=pingauthorizepap" --timeout=15m
    kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod \
      -l "app.kubernetes.io/instance=${PAZ_RELEASE},app.kubernetes.io/name=pingauthorize" --timeout=20m
    "${ROOT_DIR}/scripts/verify.sh"
    echo "stack: PAP and both PAZ replicas are Ready. Next: ./scripts/deploy.sh package."
    ;;

  package)
    "${ROOT_DIR}/scripts/build-package.sh"
    echo "package: published to s3://${PAZ_S3_BUCKET}/${PAZ_S3_PREFIX}/. Re-run any time —"
    echo "the PAZ nodes poll and load it without a restart."
    ;;

  pap|paz|prep|runtime)
    echo "The deploy is now 'stack' (whole Ping stack, one release) + 'package' (publish policy to S3)." >&2
    exit 1
    ;;

  *)
    echo "Unknown phase: ${phase}" >&2
    exit 1
    ;;
esac
