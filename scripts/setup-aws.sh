#!/usr/bin/env bash
# setup-aws.sh — one-time AWS entity creation for the package store.
# Run while logged into AWS (aws login / aws sso / credentials in session):
# the script uses the caller's identity for every call and stores nothing.
#
# Creates:
#   1. A private, versioned S3 bucket (the deployment package store)
#   2. An IAM user with a least-privilege policy (Get/List for the PAZ
#      runtime, Put for the package publisher) scoped to the bucket/prefix
#   3. An access key pair for that user, written to .env (git-ignored)
#
# Idempotent: re-running skips what already exists; the access key is created
# only when absent from .env. Names derive from the project by default so a
# replicated demo lands in its own bucket.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command aws

REGION="${PAZ_S3_REGION:-us-east-1}"
BUCKET="${PAZ_S3_BUCKET:-fc-paz-perf-packages}"
PREFIX="${PAZ_S3_PREFIX:-policy}"
IAM_USER="${PAZ_S3_IAM_USER:-paz-perf-package-store}"

echo "Using: region=${REGION} bucket=${BUCKET} prefix=${PREFIX} iam-user=${IAM_USER}"
echo "Caller identity: $(aws sts get-caller-identity --query 'Arn' --output text)"

# --- 1. the bucket ----------------------------------------------------------
if aws s3api head-bucket --bucket "${BUCKET}" --region "${REGION}" 2>/dev/null; then
  echo "Bucket ${BUCKET} already exists."
else
  # us-east-1 needs no LocationConstraint; other regions require it.
  if [[ "${REGION}" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}" > /dev/null
  else
    aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}" \
      --create-bucket-configuration LocationConstraint="${REGION}" > /dev/null
  fi
  # Private by default; make it explicit, and block any public access.
  aws s3api put-public-access-block --bucket "${BUCKET}" \
    --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  echo "Created bucket ${BUCKET} (${REGION})."
fi
aws s3api put-bucket-versioning --bucket "${BUCKET}" \
  --versioning-configuration Status=Enabled
echo "Versioning enabled (rollback story for packages)."

# --- 2. the IAM user + least-privilege policy --------------------------------
if aws iam get-user --user-name "${IAM_USER}" > /dev/null 2>&1; then
  echo "IAM user ${IAM_USER} already exists."
else
  aws iam create-user --user-name "${IAM_USER}" > /dev/null
  echo "Created IAM user ${IAM_USER}."
fi

POLICY_DOC=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadPackagesForRuntime",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:ListBucket"],
      "Resource": ["arn:aws:s3:::${BUCKET}", "arn:aws:s3:::${BUCKET}/${PREFIX}/*"]
    },
    {
      "Sid": "PublishPackages",
      "Effect": "Allow",
      "Action": ["s3:PutObject"],
      "Resource": ["arn:aws:s3:::${BUCKET}/${PREFIX}/*"]
    }
  ]
}
EOF
)
POLICY_NAME="${IAM_USER}-policy"
aws iam put-user-policy --user-name "${IAM_USER}" --policy-name "${POLICY_NAME}" \
  --policy-document "${POLICY_DOC}"
echo "Applied least-privilege policy ${POLICY_NAME} (Get/List + Put, bucket/prefix-scoped)."

# --- 3. the access key, written to .env --------------------------------------
if [[ -f "${ROOT_DIR}/.env" ]] && grep -q "^PAZ_S3_ACCESS_KEY=" "${ROOT_DIR}/.env" && \
   [[ -n "$(grep '^PAZ_S3_ACCESS_KEY=' "${ROOT_DIR}/.env" | cut -d= -f2)" ]]; then
  echo "PAZ_S3_ACCESS_KEY already present in .env; leaving the key as is."
else
  KEY_JSON="$(aws iam create-access-key --user-name "${IAM_USER}" --output json)"
  ACCESS_KEY_ID="$(echo "${KEY_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["AccessKeyId"])')"
  SECRET_KEY="$(echo "${KEY_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["SecretAccessKey"])')"
  {
    echo ""
    echo "# S3 deployment-package store credentials (created by setup-aws.sh)"
    echo "PAZ_S3_ACCESS_KEY=${ACCESS_KEY_ID}"
    echo "PAZ_S3_SECRET_KEY=${SECRET_KEY}"
  } >> "${ROOT_DIR}/.env"
  echo "Wrote PAZ_S3_ACCESS_KEY / PAZ_S3_SECRET_KEY to .env (git-ignored)."
fi

# --- 4. persist the resolved names back to .env for the other scripts --------
# The script-level defaults (REGION/BUCKET/PREFIX above) are the source of
# truth: write those values even when the caller's environment never set
# the PAZ_S3_* names (the fresh-clone case).
declare -A resolved=( [PAZ_S3_REGION]="${REGION}" [PAZ_S3_BUCKET]="${BUCKET}" [PAZ_S3_PREFIX]="${PREFIX}" )
for var in PAZ_S3_REGION PAZ_S3_BUCKET PAZ_S3_PREFIX; do
  value="${resolved[${var}]}"
  if grep -q "^${var}=" "${ROOT_DIR}/.env" 2>/dev/null; then
    sed -i '' "s|^${var}=.*|${var}=${value}|" "${ROOT_DIR}/.env"
  else
    echo "${var}=${value}" >> "${ROOT_DIR}/.env"
  fi
done

cat <<NOTE

Done. The PAZ pods will read packages from s3://${BUCKET}/${PREFIX}/.
Next: ./scripts/deploy.sh prep   (the dsconfig layer wires the S3 store)
NOTE
