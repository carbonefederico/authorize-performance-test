#!/usr/bin/env bash
# build-package.sh — publish a deployment package: build from PAP's API,
# upload to the S3 package store.
#
# This is the API equivalent of the Policy Editor's publish-to-store action:
# the PAZ nodes run in embedded PDP mode polling an S3 deployment package
# store (created in AWS by scripts/setup-aws.sh, wired in PAZ by the server
# profile's dsconfig layer). PAP holds the committed AgentGatewayPortfolioMCP
# branch (imported by its bootstrap hook at boot). Re-runnable: each run
# creates a fresh package (timestamped name, dodging PAP's duplicate-name
# errors) and uploads it under the bucket prefix; the PAZ nodes pick it up by
# polling within poll-interval — no restart.
#
# Sequence: find the branch head snapshot -> export it -> create a package
# rooted at the Global Decision Point -> download the bytes -> upload to
# s3://<bucket>/<prefix>/. Requires PAP reachable at ${PAP_URL} (the public
# ingress host, .env's PAP_PUBLIC_HOST) and AWS credentials resolvable in
# the session (aws login).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command curl
require_command python3
require_command aws
require_value PAP_ADMIN_PASSWORD
require_value PAZ_S3_BUCKET
require_value PAZ_S3_PREFIX
require_value PAZ_S3_REGION
require_value PAZ_S3_ACCESS_KEY
require_value PAZ_S3_SECRET_KEY

PAP_URL="https://${PAP_PUBLIC_HOST:-paz-perf-pap.ping-devops.com}"
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
items = data if isinstance(data, list) else data.get('branches', data.get('items', []))
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

# --- 2. export the committed head ------------------------------------------
exported="$(curl -sk "${auth_headers[@]}" -X POST -H 'Content-Type: application/json' -d '[]' \
  "${PAP_URL}/api/snapshot/${head_id}/export")" \
  || fail "Snapshot export failed for head ${head_id}" "curl failed"
exported_id="$(echo "${exported}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for key in ('snapshotId', 'id'):
    if isinstance(data, dict) and data.get(key):
        print(data[key]); break
else:
    sys.exit('export response carries no snapshot id; inspect it above')
")"
echo "Exported snapshot: ${exported_id}" >&2

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

# --- 4. download the package bytes ------------------------------------------
mkdir -p "$(dirname "${TARGET}")"
curl -sk "${auth_headers[@]}" -o "${TARGET}" \
  "${PAP_URL}/api/deployment-packages/${pkg_id}/data" \
  || fail "Package download failed for ${pkg_id}" "curl failed"
[[ -s "${TARGET}" ]] || fail "Downloaded package is empty" "${TARGET}"
echo "Downloaded ${TARGET} ($(wc -c < "${TARGET}" | tr -d ' ') bytes)"

# --- 5. publish to the S3 package store --------------------------------------
# A timestamped object name keeps every publish distinct; bucket versioning
# (enabled by setup-aws.sh) preserves the history for rollback.
S3_URI="s3://${PAZ_S3_BUCKET}/${PAZ_S3_PREFIX}/${pkg_name}.deploymentpackage"
AWS_ACCESS_KEY_ID="${PAZ_S3_ACCESS_KEY}" \
AWS_SECRET_ACCESS_KEY="${PAZ_S3_SECRET_KEY}" \
AWS_DEFAULT_REGION="${PAZ_S3_REGION}" \
  aws s3 cp "${TARGET}" "${S3_URI}" \
  || fail "S3 upload failed to ${S3_URI}" "aws s3 cp"
echo "Published ${S3_URI}"
echo "PAZ nodes pick it up by polling (poll-interval 30s) — no restart."
