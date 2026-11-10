#!/usr/bin/env sh
# Overrides the stock 81-install-policies.sh (same filename = same slot in
# ${STAGING_DIR}/hooks; the profile merge in hook 02 wins). Stock behavior
# imports each staged *.SNAPSHOT under its FILENAME INCLUDING the .SNAPSHOT
# extension and never commits — the PDP serves only COMMITTED snapshots, so a
# stock boot leaves the branch misnamed AND invisible to PAZ. This version:
#
#   1. names the branch after the file WITHOUT the .SNAPSHOT extension
#      (AgentGatewayPortfolioMCP.SNAPSHOT -> branch AgentGatewayPortfolioMCP,
#      the name PAZ's external server `branch:` property points at), and
#   2. ensures the branch is COMMITTED before exiting.
#
# Self-healing on every boot:
#   branch missing            -> import, then commit
#   branch present uncommitted-> commit (a failed first-boot commit can leave
#                                this state behind; do not fail on it)
#   branch present committed  -> nothing to do
#
# The commit is verified by RE-READING the branch head (a committed branch's
# head differs from SYSTEM's; a freshly imported branch inherits SYSTEM's
# head and its tip stays UNCOMMITTED forever), retried a few times — on the
# first boot after a PVC wipe the version-control subsystem can 500 an
# early commit even though /api/system/status already says RUNNING.
#
test "${VERBOSE}" = "true" && set -x

# shellcheck source=../../../../pingcommon/opt/staging/hooks/pingcommon.lib.sh
. "${HOOKS_DIR}/pingcommon.lib.sh"

PAP_ADMIN=${PAP_ADMIN:-admin}
API="https://localhost:${HTTPS_PORT}"
BRANCHES_URL="${API}/api/version-control/branches"

echo "Checking PingAuthorize Policy Editor system status..."
while true; do
    status=$(curl -H "x-user-id: ${PAP_ADMIN}" -k "${API}/api/system/status" 2> /dev/null | jq -r '.status')
    if test "${status}" = "RUNNING"; then
        echo "PingAuthorize Policy Editor is ready"
        break
    else
        echo "PingAuthorize Policy Editor is not ready, waiting to try again..."
        sleep 3
    fi
done

branch_head() { # branch_head <name> -> prints the branch's head snapshot id
    curl -H "x-user-id: ${PAP_ADMIN}" -k "${BRANCHES_URL}" 2>/dev/null | \
        jq -r --arg b "$1" '.data[]? | select(.name == $b) | .head' 2>/dev/null
}

branch_id() { # branch_id <name> -> prints the branch's id
    curl -H "x-user-id: ${PAP_ADMIN}" -k "${BRANCHES_URL}" 2>/dev/null | \
        jq -r --arg b "$1" '.data[]? | select(.name == $b) | .id' 2>/dev/null
}

ensure_committed() { # ensure_committed <branch-name> <branch-id>
    _name="$1"; _bid="$2"
    _try=0
    while test ${_try} -lt 6; do
        _try=$((_try + 1))
        curl -H "x-user-id: ${PAP_ADMIN}" -H 'Content-Type: application/json' -k \
            --data-binary '{"message":"bootstrap: import '"${_name}"'"}' \
            "${BRANCHES_URL}/${_bid}/commit" > /dev/null 2>&1
        sleep 2
        _head=$(branch_head "${_name}")
        _sysHead=$(branch_head "SYSTEM")
        if test -n "${_head}" && test "${_head}" != "${_sysHead}"; then
            echo "Branch ${_name} committed (head ${_head})"
            return 0
        fi
        echo "Commit for ${_name} did not land (attempt ${_try}) - retrying"
    done
    return 1
}

if test -d "${STAGING_DIR}/policies"; then
    for policyFileName in $(find "${STAGING_DIR}/policies/" -iname \*.SNAPSHOT 2> /dev/null | sort | uniq); do
        policyName=$(basename "${policyFileName}")
        branchName="${policyName%.SNAPSHOT}"
        bHead=$(branch_head "${branchName}")
        sHead=$(branch_head "SYSTEM")

        if test -n "${bHead}" && test "${bHead}" != "${sHead}"; then
            echo "Branch ${branchName} already committed - nothing to do"
            continue
        fi

        if test -z "${bHead}"; then
            echo "Importing policy snapshot: ${policyName} -> branch ${branchName}"
            branchId=$(curl -H "x-user-id: ${PAP_ADMIN}" -H 'Content-Type: application/json' -k \
                --data-binary @"${policyFileName}" "${API}/api/snapshot/${branchName}/import" | jq -r '.id')
            if test -z "${branchId}" || test "${branchId}" = "null"; then
                container_failure "81" "Policy '${policyName}' could not be imported as branch '${branchName}'"
            fi
        else
            echo "Branch ${branchName} exists uncommitted - committing it"
            branchId=$(branch_id "${branchName}")
        fi

        if ! ensure_committed "${branchName}" "${branchId}"; then
            container_failure "81" "Branch '${branchName}' could not be committed"
        fi
    done
fi
