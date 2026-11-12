#!/usr/bin/env sh
# Registers this stack's S3 deployment-package store with the Policy Editor.
#
# The app reads publishing targets from the deploymentPackageStores key of
# config/configuration.yml (the Dropwizard configuration the PAP `setup` tool
# generates at boot). setup regenerates that file from the image template every
# start, overwriting anything a server profile ships at the same path, so the
# store is added here instead: by overriding the stock 50-before-post-start.sh
# (same filename = same slot), which runs after setup and before the server
# starts, by appending the entry. The Publish action in the Deployment Manager
# UI — called by scripts/build-package.sh via
# POST /api/deployment-package-store/<name>/package — then writes the package
# AND the pointer file that the PAZ-side S3 store poller expects.
#
# The PAZ-side store (server-profiles/pingauthorize/pd.profile/dsconfig/
# 30-embedded-pdp.dsconfig.subst) must point at the same bucket+prefix and
# use the same security level (unsigned) for the package to be accepted.
#
# Env (wired from the paz-s3 Secret by helm/paz/values.yaml):
#   PAZ_S3_BUCKET / PAZ_S3_PREFIX / PAZ_S3_REGION /
#   PAZ_S3_ACCESS_KEY / PAZ_S3_SECRET_KEY

test "${VERBOSE}" = "true" && set -x

# shellcheck source=../../../../pingcommon/opt/staging/hooks/pingcommon.lib.sh
. "${HOOKS_DIR}/pingcommon.lib.sh"

CONFIG_FILE="${SERVER_ROOT_DIR}/config/configuration.yml"

for var in PAZ_S3_BUCKET PAZ_S3_PREFIX PAZ_S3_REGION PAZ_S3_ACCESS_KEY PAZ_S3_SECRET_KEY; do
    if test -z "$(eval "echo \${${var}:-}")"; then
        echo "50-before-post-start: ${var} not set - skipping package store registration"
        return 0
    fi
done

if grep -q "name: paz-perf-packages" "${CONFIG_FILE}" 2>/dev/null; then
    echo "50-before-post-start: package store already registered"
    return 0
fi

cat >> "${CONFIG_FILE}" <<EOF

# Added by profile hook 50-before-post-start.sh — the S3 store the Deployment
# Manager publishes to and the PAZ embedded PDP polls.
deploymentPackageStores:
  - name: paz-perf-packages
    description: PAZ sideband performance stack package store
    type: s3bucket
    securityLevel: unsigned
    config:
      bucket: ${PAZ_S3_BUCKET}
      prefix: ${PAZ_S3_PREFIX}
      region: ${PAZ_S3_REGION}
      accessKey: ${PAZ_S3_ACCESS_KEY}
      secretKey: ${PAZ_S3_SECRET_KEY}
EOF

echo "50-before-post-start: registered S3 store paz-perf-packages (bucket ${PAZ_S3_BUCKET}, prefix ${PAZ_S3_PREFIX})"
