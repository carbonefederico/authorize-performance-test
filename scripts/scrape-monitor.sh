#!/usr/bin/env bash
# scrape-monitor.sh — best-effort end-of-run scrape of PAZ's cn=Monitor tree
# (Gateway Timing providers). NEVER fails the caller: on any error it writes
# a status marker and exits 0, because a scrape failure must not invalidate
# a completed load run. Monitor counters are since-server-start; the report
# derives deltas between consecutive runs.
#
# Usage: scrape-monitor.sh [run_dir]   (default: results/<latest>)
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command kubectl

run_dir="${1:-}"
if [[ -z "${run_dir}" ]]; then
  run_dir="$(ls -d "${ROOT_DIR}"/results/*/ 2>/dev/null | sort | tail -1 | sed 's:/$::')"
fi
[[ -n "${run_dir}" ]] || { echo "no results directory; nothing to scrape" >&2; exit 0; }
mkdir -p "${run_dir}"

pods="$(kubectl -n "${NAMESPACE}" get pods \
  -l "app.kubernetes.io/instance=${PAZ_RELEASE},app.kubernetes.io/name=pingauthorize" \
  -o jsonpath='{range .items[*]}{.metadata.name}{end}' 2>/dev/null | tr ' ' '\n' | grep -v '^$' || true)"

if [[ -z "${pods}" ]]; then
  echo "scrape-monitor: no PAZ pods found; writing status marker" >&2
  echo '{ "status": "no-paz-pods" }' > "${run_dir}/monitor-scrape-status.json"
  exit 0
fi

# The admin bind password: the lab constant the images boot with (.env's
# PAP_ADMIN_PASSWORD, the DevOps default).
admin_pw="${PAP_ADMIN_PASSWORD:-}"

status="ok"
for pod in ${pods}; do
  out="${run_dir}/monitor-paz-${pod}.json"
  if kubectl -n "${NAMESPACE}" exec "${pod}" -c pingauthorize -- \
      bin/ldapsearch --hostname localhost --port 1636 --useSSL \
      --bindDN "cn=Directory Manager" --bindPassword "${admin_pw}" \
      --baseDN cn=monitor --searchScope sub "(cn=*Gateway*)" "*" "+" \
      > "${run_dir}/monitor-paz-${pod}.ldif" 2> "${run_dir}/monitor-paz-${pod}.err" \
      && [[ -s "${run_dir}/monitor-paz-${pod}.ldif" ]]; then
    python3 - "${run_dir}/monitor-paz-${pod}.ldif" "${out}" <<'PYEOF'
import json, sys
entries, current = [], None
for line in open(sys.argv[1]):
    line = line.rstrip("\n")
    if line.startswith("dn:"):
        current = {"dn": line[3:].strip(), "attrs": {}}
        entries.append(current)
    elif current is not None and ": " in line:
        k, v = line.split(": ", 1)
        current["attrs"].setdefault(k, []).append(v)
json.dump(entries, open(sys.argv[2], "w"), indent=1)
PYEOF
    rm -f "${run_dir}/monitor-paz-${pod}.ldif" "${run_dir}/monitor-paz-${pod}.err"
  else
    echo "scrape-monitor: ldapsearch failed on ${pod} (kept stderr in ${run_dir})" >&2
    status="scrape-failed-on-${pod}"
    [[ -s "${run_dir}/monitor-paz-${pod}.err" ]] || echo "exec or search failed" > "${run_dir}/monitor-paz-${pod}.err"
  fi
done

echo '{ "status": "'"${status}"'" }' > "${run_dir}/monitor-scrape-status.json"
echo "scrape-monitor: ${status}"
exit 0
