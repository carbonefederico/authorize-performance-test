#!/usr/bin/env bash
# deploy.sh — deployment of the PAZ sideband performance stack.
#
#   ./scripts/deploy.sh headroom   per-node allocatable-vs-requested summary
#   ./scripts/deploy.sh            everything: secrets, the WHOLE Ping stack
#                                  (PAP + 2x PAZ, one release), publish the
#                                  policy package through PAP, wait until the
#                                  PAZ poller loads it, smoke-test decisions.
#
# One command to test-ready. The phases inside run in the production order:
# the servers boot first and the policy arrives through the S3 package store
# (published via PAP's package-store API — the API equivalent of the
# Deployment Manager's Publish action, which also writes the pointer file the
# PAZ poller requires). The wait-for-load step confirms the store mechanism
# end to end before smoke asserts actual decisions.
#
# The k6 load generator is NOT part of the deploy: it installs only when a
# campaign run starts (scripts/run-in-cluster.sh), so deploying never
# generates test traffic.
#
# The profile lives in this repository under server-profiles/ and configures
# the SERVERS (dsconfig layer, certificate, S3 store definition, the PAP-side
# package-store registration); the POLICY travels through the S3 package
# store (setup-aws.sh created it, build-package.sh publishes to it, PAZ
# polls it — no restart on policy change).
#
# Licensing: the chart secretRefs the cluster Secret 'devops-secret', which
# the operator provisions by their environment standard. PAP's admin password
# is the lab constant in .env (the DevOps default the images boot with), used
# client-side. Only the profile URLs are injected here.
#
# Re-runnable at any time: secrets and the helm release are idempotent
# (upgrade on re-run), the package publish creates a fresh package, and the
# poller picks it up without a restart.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command kubectl
require_command helm

phase="${1:-deploy}"
if [[ "${phase}" == "headroom" ]]; then
  :
else
  [[ -z "${phase}" || "${phase}" == "deploy" ]] || {
    echo "Usage: $0 [headroom] — plain '$0' deploys everything to test-ready." >&2
    exit 1
  }
  phase="deploy"
fi

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

  deploy)
    # --- 1. secrets (idempotent; generates the sideband secret on first run) ---
    "${ROOT_DIR}/scripts/create-secrets.sh"

    # --- 2. the whole Ping stack, one release ---
    ensure_repo
    install_or_upgrade "${PAZ_RELEASE}" "${ROOT_DIR}/helm/paz/values.yaml" \
      --set-string "pingauthorize.envs.SERVER_PROFILE_URL=${SERVER_PROFILE_URL}" \
      --set-string "pingauthorizepap.envs.SERVER_PROFILE_URL=${SERVER_PROFILE_URL}" \
      --set-string "pingauthorize.envs.PAZ_RELEASE_NAME=${PAZ_RELEASE}"
    kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod \
      -l "app.kubernetes.io/instance=${PAZ_RELEASE},app.kubernetes.io/name=pingauthorizepap" --timeout=15m
    kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod \
      -l "app.kubernetes.io/instance=${PAZ_RELEASE},app.kubernetes.io/name=pingauthorize" --timeout=20m
    "${ROOT_DIR}/scripts/verify.sh"

    # --- 3. publish the policy package through PAP (writes package + pointer) ---
    package_before="$(kubectl -n "${NAMESPACE}" logs "pod/${PAZ_RELEASE}-pingauthorize-0" 2>/dev/null | \
      grep -oE 'DeploymentPackage [0-9a-f-]{36}' | tail -1 || true)"
    "${ROOT_DIR}/scripts/build-package.sh"

    # --- 4. wait until the PAZ poller loads the new package (30s interval) ---
    echo "Waiting for the PAZ nodes to load the published package (poll-interval 30s)..."
    deadline=$((SECONDS + 180))
    loaded=""
    while (( SECONDS < deadline )); do
      loaded="$(kubectl -n "${NAMESPACE}" logs "pod/${PAZ_RELEASE}-pingauthorize-0" --since=3m 2>/dev/null | \
        grep -c 'Successfully deployed package' || true)"
      loaded1="$(kubectl -n "${NAMESPACE}" logs "pod/${PAZ_RELEASE}-pingauthorize-1" --since=3m 2>/dev/null | \
        grep -c 'Successfully deployed package' || true)"
      if [[ "${loaded}" -ge 1 && "${loaded1}" -ge 1 ]]; then
        echo "Both PAZ replicas loaded the package from the store."
        break
      fi
      sleep 10
    done
    if [[ "${loaded}" -lt 1 || "${loaded1}" -lt 1 ]]; then
      echo "ERROR: the PAZ nodes did not load the package within 3 minutes." >&2
      echo "Check: kubectl -n ${NAMESPACE} logs pod/${PAZ_RELEASE}-pingauthorize-0 | grep PDP" >&2
      exit 1
    fi

    # --- 5. smoke: the three go/no-go decisions ---
    kubectl -n "${NAMESPACE}" port-forward "pod/${PAZ_RELEASE}-pingauthorize-0" 18443:1443 > /dev/null 2>&1 &
    pf_pid=$!
    trap 'kill ${pf_pid} 2>/dev/null || true' EXIT
    until nc -z localhost 18443 2>/dev/null; do sleep 0.5; done
    PAZ_PORT_FORWARD=18443 "${ROOT_DIR}/scripts/smoke.sh"
    trap - EXIT
    kill "${pf_pid}" 2>/dev/null || true

    echo ""
    echo "Deploy complete: stack Ready, package published AND loaded, smoke 3/3."
    echo "Trigger the test whenever you want: ./scripts/run-in-cluster.sh PROFILE=stage-100"
    ;;

  *)
    echo "Unknown phase: ${phase} (use 'headroom' or no argument)" >&2
    exit 1
    ;;
esac
