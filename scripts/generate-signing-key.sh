#!/usr/bin/env bash
# generate-signing-key.sh — create the subject-token signing key and the
# matching self-signed certificate once per campaign. The private key signs
# every k6-minted token; PAZ validates tokens against the certificate, which
# ships in the PAZ server profile (local trusted-certificate model — this
# stack has no JWKS server).
#
# Idempotent: skips when both files already exist. --force regenerates.
# The certificate CommonName and the JWT header kid are both perf-subject-key.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

KEY_FILE="${ROOT_DIR}/keys/subject-signing.key"
CERT_FILE="${ROOT_DIR}/server-profiles/pingauthorize/instance/server/default/data/perf-subject-cert.pem"

force=0
[[ "${1:-}" == "--force" ]] && force=1

if [[ ${force} -eq 0 && -f "${KEY_FILE}" && -f "${CERT_FILE}" ]]; then
  echo "Signing key and certificate already exist; nothing to do (use --force to regenerate)."
  exit 0
fi

mkdir -p "$(dirname "${KEY_FILE}")" "$(dirname "${CERT_FILE}")"

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${KEY_FILE}"
chmod 600 "${KEY_FILE}"
openssl req -x509 -key "${KEY_FILE}" -out "${CERT_FILE}" -days 3650 \
  -subj "/CN=perf-subject-key"

echo "Wrote ${KEY_FILE}"
echo "Wrote ${CERT_FILE}"
echo "Regenerating mid-campaign invalidates every token signed with the old key;"
echo "after --force, redeploy so the profile repo carries the new certificate."
