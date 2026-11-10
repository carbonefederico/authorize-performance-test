#!/usr/bin/env bash
# run-in-cluster.sh — provision the k6 Job, stream it, and collect results
# into results/<run_id>/. Ported from the PF campaign's runner; the changes
# are the SUT inventory (2 PAZ pods, label pingauthorize) and the metric
# stream file names. Exits non-zero if the k6 Job fails (threshold or check
# failure), after saving everything the report needs.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command kubectl
require_command helm
"${ROOT_DIR}/scripts/create-secrets.sh"

agent_count="${AGENTS:-1}"
run_id="$(date -u +%Y%m%d%H%M%S)"

helm_args=(
  --namespace "${NAMESPACE}"
  --set-string runId="${run_id}"
  --set-string agentCount="${agent_count}"
)

# Everything the report generator needs lands in results/<run_id>/: the
# per-agent k6 logs and metric streams (the pods TTL-clean after 1h, so
# capture them here), plus the pod-usage CSV if the monitor is running.
run_dir="${ROOT_DIR}/results/${run_id}"
mkdir -p "${run_dir}"

# Run metadata: every resolved variable that defines the run, plus the
# cluster context and the SUT pod inventory. The report reads thresholds
# from here so the PASS/FAIL gate is the same one the profiles declared.
{
  echo "{"
  echo "  \"run_id\": \"${run_id}\","
  echo "  \"profile\": \"${PROFILE:-<none, .env only>}\","
  echo "  \"timestamp_utc\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
  for v in AGENTS RATE DURATION WARMUP PRE_ALLOCATED_VUS MAX_VUS P95_MS SUCCESS_RATE \
           SUBJECT_ISSUER SUBJECT_USER_COUNT MCP_AUD NAMESPACE PAZ_RELEASE LOADTEST_RELEASE; do
    [[ -n "${!v:-}" ]] && printf '  "%s": "%s",\n' "${v}" "${!v}"
  done
  echo "  \"k6_image\": \"$(helm -n "${NAMESPACE}" get values "${LOADTEST_RELEASE}" -a 2>/dev/null | grep -oE 'repository: .*|tag: .*' | tr -d ' ' | paste -sd':' - | head -1 || echo unknown)\","
  echo "  \"nodes\": ["
  kubectl get nodes -o json 2>/dev/null | python3 -c "
import json, sys
for n in json.load(sys.stdin)['items']:
    print('    ' + json.dumps({'name': n['metadata']['name'], 'instance_type': n['metadata']['labels'].get('beta.kubernetes.io/instance-type', '?'), 'allocatable_cpu': n['status']['allocatable']['cpu']}) + ',')
" 2>/dev/null || true
  echo "  ],"
  echo "  \"paz_pods\": ["
  kubectl -n "${NAMESPACE}" get pods -l "app.kubernetes.io/instance=${PAZ_RELEASE},app.kubernetes.io/name=pingauthorize" -o json 2>/dev/null | python3 -c "
import json, sys
for p in json.load(sys.stdin)['items']:
    print('    ' + json.dumps({'name': p['metadata']['name'], 'node': p['spec']['nodeName'], 'started': p['status']['startTime']}) + ',')
" 2>/dev/null || true
  echo "  ]"
  echo "}"
} > "${run_dir}/env.json"
# Strip trailing commas before '}' or ']' (the looped printf emits trailing commas).
python3 -c 'import re,sys; p=sys.argv[1]; t=open(p).read(); open(p,"w").write(re.sub(r",(\s*[}\]])", lambda m: m.group(1), t))' "${run_dir}/env.json"

helm -n "${NAMESPACE}" uninstall "${LOADTEST_RELEASE}" >/dev/null 2>&1 || true
helm -n "${NAMESPACE}" install "${LOADTEST_RELEASE}" "${ROOT_DIR}/helm/loadtest" "${helm_args[@]}"

job_name="${LOADTEST_RELEASE}-${run_id}"
echo "Following ${job_name}; the command exits non-zero if k6 thresholds fail."
kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod \
  -l "job-name=${job_name}" --timeout=5m

# Results collection happens AFTER the load completes: the k6 container holds
# its pod alive for COLLECT_GRACE_SECONDS after k6 exits (see job.yaml), so
# the complete, flushed k6.json can be copied once per pod — no mid-run
# snapshot race, no datapoint loss.
echo "Waiting for load to finish (${agent_count} agents)..."
declare -A collected
deadline=$((SECONDS + 1200))
while [[ ${SECONDS} -lt ${deadline} ]]; do
  all_done=1
  for i in $(seq 0 $((agent_count - 1))); do
    [[ "${collected[$i]:-}" == "yes" ]] && continue
    pod="$(kubectl -n "${NAMESPACE}" get pods -l "job-name=${job_name}" \
      -o jsonpath="{range .items[?(@.metadata.annotations['batch\.kubernetes\.io/job-completion-index']=='${i}')]}{.metadata.name}{end}" 2>/dev/null)"
    if [[ -z "${pod}" ]]; then
      all_done=0
      continue
    fi
    # The k6 summary block is only printed once the run finished.
    if kubectl -n "${NAMESPACE}" logs "${pod}" -c k6 --request-timeout=10s 2>/dev/null \
        | grep -q "checks_succeeded\|checks_failed"; then
      kubectl -n "${NAMESPACE}" cp "${pod}:/out/k6.json" \
        "${run_dir}/agent-${i}-metrics.json" -c k6 >/dev/null 2>&1 \
        && collected[$i]=yes || all_done=0
    else
      all_done=0
    fi
  done
  [[ "${all_done}" -eq 1 ]] && break
  sleep 5
done
[[ "${collected[$((agent_count - 1))]:-}" == "yes" ]] || {
  echo "WARNING: some agent result files were not collected (pod logs below)." >&2
}

kubectl -n "${NAMESPACE}" logs -f "job/${job_name}" || true

# Wait for the Job to reach a terminal condition.
kubectl -n "${NAMESPACE}" wait --for=condition=complete "job/${job_name}" --timeout=2m 2>/dev/null \
  || kubectl -n "${NAMESPACE}" wait --for=condition=failed "job/${job_name}" --timeout=5s 2>/dev/null || true

succeeded="$(kubectl -n "${NAMESPACE}" get "job/${job_name}" -o jsonpath='{.status.succeeded}' 2>/dev/null || echo 0)"
if [[ "${succeeded}" != "${agent_count}" ]]; then
  echo "k6 Job failed (usually because a request check or threshold failed)." >&2
  kubectl -n "${NAMESPACE}" get "job/${job_name}" -o wide >&2
  exit 1
fi

# Capture every agent's end-of-run summary, then the best-effort cn=Monitor
# scrape (never fails the run — see scrape-monitor.sh).
echo "Capturing per-agent results to ${run_dir}..."
for i in $(seq 0 $((agent_count - 1))); do
  pod="$(kubectl -n "${NAMESPACE}" get pods -o jsonpath="{range .items[?(@.metadata.annotations['batch\.kubernetes\.io/job-completion-index']=='${i}')]}{.metadata.name}{end}" 2>/dev/null)"
  if [[ -n "${pod}" ]]; then
    kubectl -n "${NAMESPACE}" logs "${pod}" -c k6 > "${run_dir}/agent-${i}.log" 2>/dev/null || true
  fi
done
kubectl -n "${NAMESPACE}" get "job/${job_name}" -o wide > "${run_dir}/job.txt" 2>&1 || true
"${ROOT_DIR}/scripts/scrape-monitor.sh" "${run_dir}" || true
echo "Results saved: ${run_dir}/"
echo "Generate the dashboard with: python3 scripts/generate-report.py ${run_dir}"
