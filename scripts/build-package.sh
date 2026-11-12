#!/usr/bin/env bash
# build-package.sh — build a deployment package from PAP's API and publish it
# through PAP to the S3 package store.
#
# The PAZ nodes run in embedded PDP mode polling an S3 deployment package
# store (created in AWS by scripts/setup-aws.sh, wired into PAZ by the server
# profile's dsconfig layer, and registered as a PAP publishing target by the
# profile's 50-before-post-start.sh hook). PAP holds the committed
# AgentGatewayPortfolioMCP branch (imported by its bootstrap hook at boot).
# Re-runnable: each run creates a fresh package (timestamped name, dodging
# PAP's duplicate-name errors) and publishes it; the PAZ nodes pick it up by
# polling within poll-interval — no restart.
#
# Sequence: find the branch head snapshot -> export it -> create a package
# rooted at the Global Decision Point -> publish via
# POST /api/deployment-package-store/paz-perf-packages/package (PAP writes
# the package bytes AND the pointer file the PAZ poller requires — the same
# two objects the Deployment Manager UI's Publish action writes) -> download
# a copy into results/ for inspection. Requires PAP reachable at ${PAP_URL}
# (the public ingress host, .env's PAP_PUBLIC_HOST).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command curl
require_command python3
require_value PAP_ADMIN_PASSWORD

PAP_URL="https://${PAP_PUBLIC_HOST:-${PAP_RELEASE}-pingauthorizepap.ping-devops.com}"
AUTH="administrator:${PAP_ADMIN_PASSWORD}"
BRANCH_NAME="AgentGatewayPortfolioMCP"
# The Global Decision Point PolicySet id inside the snapshot — the package
# root. Verified present in the snapshot (server-profiles/README.md); if the
# snapshot is ever regenerated with a re-created GDP, update this value.
DECISION_NODE_ID="a7c4e2d0-8f11-4b5a-9c3d-6e8f2a1b4c7d"
TARGET="${ROOT_DIR}/results/agentgateway-portfolio-mcp.deploymentpackage"

auth_headers=(-u "${AUTH}" -H "x-user-id: administrator" -H "X-XSRF-HEADER: ping" -k)

fail() {
  echo "ERROR: $1" >&2
  echo "$2" >&2
  exit 1
}

# --- 1. find the branch and its head snapshot id ---------------------------
branches="$(curl -sk "${auth_headers[@]}" "${PAP_URL}/api/version-control/branches")" \
  || fail "PAP unreachable at ${PAP_URL} — is the port-forward running?" "curl failed"
branch_json="$(echo "${branches}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
items = data if isinstance(data, list) else data.get('data', data.get('branches', data.get('items', [])))
for b in items:
    if b.get('name') == '${BRANCH_NAME}':
        print(json.dumps(b))
        break
")" || true
if [[ -z "${branch_json}" ]]; then
  fail "Branch ${BRANCH_NAME} not found in PAP (has the bootstrap hook imported and committed it?)" \
       "GET /api/version-control/branches returned: $(echo "${branches}" | head -c 400)"
fi
echo "Branch found: ${branch_json}" >&2
head_id="$(echo "${branch_json}" | python3 -c "
import json, sys
b = json.load(sys.stdin)
# field name discovered from the response; try the common shapes
for key in ('headSnapshotId', 'headId', 'head_id', 'head'):
    if b.get(key):
        print(b[key]); break
else:
    sys.exit('no head snapshot field found in branch object; inspect the JSON above')
")"

# --- 2. export the committed head (confirmation; the stream itself is the snapshot) ---
exported="$(curl -sk "${auth_headers[@]}" -X POST -H 'Content-Type: application/json' -d '[]' \
  "${PAP_URL}/api/snapshot/${head_id}/export")" \
  || fail "Snapshot export failed for head ${head_id}" "curl failed"
# The export stream is the snapshot: DataStreamHeader + PackageHeader (echoing
# the snapshot id) + elements. Confirm the header matches the branch head.
echo "${exported}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
hdr = next((e for e in data if isinstance(e, dict) and 'PackageHeader' in str(e.get('type', ''))), None)
sid = (hdr or {}).get('snapshotId')
if sid != '${head_id}':
    sys.exit(f'export header snapshotId {sid} does not match branch head ${head_id}')
print('Exported snapshot confirmed: ' + sid, file=sys.stderr)
"
exported_id="${head_id}"

# --- 3. create the deployment package --------------------------------------
pkg_name="agentgateway-portfolio-mcp-$(date -u +%Y%m%dT%H%M%SZ)"
created="$(curl -sk "${auth_headers[@]}" -X POST -H 'Content-Type: application/json' \
  -d "{\"name\":\"${pkg_name}\",\"snapshotId\":\"${exported_id}\",\"decisionNodeId\":\"${DECISION_NODE_ID}\"}" \
  "${PAP_URL}/api/deployment-packages")" \
  || fail "Package creation failed" "curl failed"
pkg_id="$(echo "${created}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for key in ('id', 'deploymentPackageId'):
    if isinstance(data, dict) and data.get(key):
        print(data[key]); break
else:
    sys.exit('package creation response carries no id — if this is a 404, the pinned PAP image lacks the deployment-packages API: fall back to snapshot-export tooling or a newer builder PAP (spec pivot note); inspect the response above')
")"
echo "Created package ${pkg_name} (${pkg_id})" >&2

# --- 4. publish through PAP to the store --------------------------------------
# PAP writes the package object (named by package id) and the pointer file
# deploymentpackage.store that says which id is current — exactly what the
# Deployment Manager's Publish action writes. PAP holds the S3 credentials in
# its own configuration; nothing here touches AWS.
publish_code="$(curl -sk "${auth_headers[@]}" -X POST -H 'Content-Type: application/json' \
  -d "{\"id\":\"${pkg_id}\"}" -o /tmp/pap-publish-response -w "%{http_code}" \
  "${PAP_URL}/api/deployment-package-store/paz-perf-packages/package")" \
  || fail "Store publish call failed for package ${pkg_id}" "curl failed"
[[ "${publish_code}" == "200" ]] \
  || fail "Store publish returned HTTP ${publish_code} (store paz-perf-packages registered in PAP? see profile hook 50-before-post-start.sh)" \
           "$(head -c 400 /tmp/pap-publish-response)"
echo "Published package ${pkg_id} through PAP to s3://${PAZ_S3_BUCKET}/${PAZ_S3_PREFIX}/"

# --- 5. keep a local copy for inspection --------------------------------------
mkdir -p "$(dirname "${TARGET}")"
curl -sk "${auth_headers[@]}" -o "${TARGET}" \
  "${PAP_URL}/api/deployment-packages/${pkg_id}/data" \
  || fail "Package download failed for ${pkg_id}" "curl failed"
[[ -s "${TARGET}" ]] || fail "Downloaded package is empty" "${TARGET}"
echo "Saved ${TARGET} ($(wc -c < "${TARGET}" | tr -d ' ') bytes)"
echo "PAZ nodes pick it up by polling (poll-interval 30s) — no restart."
