#!/usr/bin/env bash
# verify.sh — assert the deployed topology matches the campaign design:
# 2 PAZ pods Running+Ready, 1 PAP pod Ready, the PAZ Service on 8443.
# Prints each PAZ pod's node so co-location (anti-affinity miss) is visible.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command kubectl

fail=0

paz_ready="$(kubectl -n "${NAMESPACE}" get pods \
  -l "app.kubernetes.io/instance=${PAZ_RELEASE},app.kubernetes.io/name=pingauthorize" \
  -o json 2>/dev/null | python3 -c "
import json, sys
pods = [p for p in json.load(sys.stdin)['items']
        if all(c['ready'] for c in p['status'].get('containerStatuses', []))
        and p['status'].get('phase') == 'Running']
print(len(pods))
for p in json.load(sys.stdin)['items'] if False else []: pass
")"
if [[ "${paz_ready}" == "2" ]]; then
  echo "PASS: 2 PAZ pods Running and Ready"
else
  echo "FAIL: expected 2 Ready PAZ pods, found ${paz_ready:-0}"
  fail=1
fi
kubectl -n "${NAMESPACE}" get pods \
  -l "app.kubernetes.io/instance=${PAZ_RELEASE},app.kubernetes.io/name=pingauthorize" \
  -o jsonpath='{range .items[*]}{.metadata.name}{" on "}{.spec.nodeName}{"\n"}{end}'

pap_ready="$(kubectl -n "${NAMESPACE}" get pods \
  -l "app.kubernetes.io/instance=${PAP_RELEASE},app.kubernetes.io/name=pingauthorizepap" \
  -o json 2>/dev/null | python3 -c "
import json, sys
pods = [p for p in json.load(sys.stdin)['items']
        if all(c['ready'] for c in p['status'].get('containerStatuses', []))
        and p['status'].get('phase') == 'Running']
print(len(pods))
")"
if [[ "${pap_ready}" == "1" ]]; then
  echo "PASS: 1 PAP pod Running and Ready"
else
  echo "FAIL: expected 1 Ready PAP pod, found ${pap_ready:-0}"
  fail=1
fi

if kubectl -n "${NAMESPACE}" get svc "${PAZ_RELEASE}-pingauthorize" \
    -o jsonpath='{.spec.ports[?(@.port==8443)].port}' 2>/dev/null | grep -q 8443; then
  echo "PASS: Service ${PAZ_RELEASE}-pingauthorize exposes 8443"
else
  echo "FAIL: Service ${PAZ_RELEASE}-pingauthorize does not expose 8443"
  fail=1
fi

exit "${fail}"
