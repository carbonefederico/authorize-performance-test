#!/usr/bin/env bash
# generate-jwks.sh — derive the JWKS document from the campaign's existing
# subject signing key (keys/subject-signing.key). The JWKS carries only the
# PUBLIC half: the issuer publishes, PAZ fetches and caches — exactly the
# issuer-publishes/verifier-fetches model. Same key material as before, so
# every token shape and the smoke test keep working; only the distribution
# channel changes (HTTP JWKS instead of a profile-shipped certificate).
#
# Usage: scripts/generate-jwks.sh   (writes helm/paz/loadtest-jwks/jwks.json)
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command openssl
require_command python3
require_value SUBJECT_SIGNING_KEY_FILE
[[ -f "${SUBJECT_SIGNING_KEY_FILE}" ]] || {
  echo "Signing key not found: ${SUBJECT_SIGNING_KEY_FILE} (git-ignored, lives in keys/)" >&2
  exit 1
}

out_dir="${ROOT_DIR}/helm/paz/loadtest-jwks"
mkdir -p "${out_dir}"

pub_pem="$(mktemp)"
trap 'rm -f "${pub_pem}"' EXIT
openssl pkey -in "${SUBJECT_SIGNING_KEY_FILE}" -pubout -out "${pub_pem}" 2>/dev/null

python3 - "${pub_pem}" "${out_dir}/jwks.json" <<'PYEOF'
import base64, json, subprocess, sys

pub_pem, out_path = sys.argv[1], sys.argv[2]

def b64url_uint(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")

# RSA public numbers via openssl in a subshell: n and e as hex.
n_hex = subprocess.run(
    ["openssl", "rsa", "-pubin", "-in", pub_pem, "-noout", "-modulus"],
    capture_output=True, text=True, check=True,
).stdout.strip().removeprefix("Modulus=")
n = bytes.fromhex(n_hex)
# OpenSSL strips the leading zero byte in the modulus encoding; JWK needs
# the unsigned big-endian form, which bytes.fromhex already gives.
e_long = subprocess.run(
    ["openssl", "rsa", "-pubin", "-in", pub_pem, "-noout", "-text"],
    capture_output=True, text=True, check=True,
).stdout
# exponent shows as "Exponent: 65537 (0x10001)"
e_dec = int(e_long.split("Exponent:")[1].split("(")[0].strip())
e = e_dec.to_bytes((e_dec.bit_length() + 7) // 8, "big")

jwk = {
    "kty": "RSA",
    "use": "sig",
    "alg": "RS256",
    "kid": "perf-subject-key",
    "n": b64url_uint(n),
    "e": b64url_uint(e),
}
json.dump({"keys": [jwk]}, open(out_path, "w"), indent=1)
print(f"wrote {out_path} (kid perf-subject-key, {len(n) * 8}-bit modulus)")
PYEOF
