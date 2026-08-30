#!/usr/bin/env bash
# AfterInstall — pull the image named by this revision and stage its unit file.
#
# The pull happens before ApplicationStart so a registry outage or bad digest
# fails before systemd attempts to launch the new service. CodeDeploy has already
# drained and stopped this instance; the remaining fleet continues serving.
set -euo pipefail

RELEASE_DIR=/opt/app/release
ENV_FILE=/etc/app/release.env

log() { echo "[after_install] $*"; }

# shellcheck disable=SC1091
source "${RELEASE_DIR}/release.env"

: "${IMAGE_URI:?release.env is missing IMAGE_URI}"
: "${GIT_SHA:?release.env is missing GIT_SHA}"

# The pipeline always writes a digest reference (repo@sha256:...). Refuse a
# mutable tag: with a tag, two instances deploying the same revision minutes apart
# can end up running different code, and the rollback target becomes undefined.
case "${IMAGE_URI}" in
  *@sha256:*) ;;
  *) log "ERROR: IMAGE_URI '${IMAGE_URI}' is not digest-pinned"; exit 1 ;;
esac

REGISTRY="${IMAGE_URI%%/*}"
REGION="${AWS_REGION:-ap-southeast-1}"

log "authenticating to ${REGISTRY}"
# Credentials come from the instance profile. No registry password exists on this
# host to be stolen, and the token expires in 12 hours.
aws ecr get-login-password --region "${REGION}" \
  | docker login --username AWS --password-stdin "${REGISTRY}"

log "pulling ${IMAGE_URI}"
for attempt in 1 2 3; do
  if docker pull "${IMAGE_URI}"; then
    break
  fi
  # Transient registry throttling is common when a whole ASG deploys at once.
  log "pull attempt ${attempt} failed, retrying in $((attempt * 10))s"
  sleep $((attempt * 10))
  [ "${attempt}" -eq 3 ] && { log "ERROR: image pull failed after 3 attempts"; exit 1; }
done

# Publish the release identity for the unit file and for /version to report.
install -d -m 0755 /etc/app
install -m 0644 "${RELEASE_DIR}/release.env" "${ENV_FILE}"

# Application secrets are NOT in this file and never travel through the pipeline.
# The container reads them at startup from SSM Parameter Store / Secrets Manager
# using the instance profile, so a leaked artifact leaks nothing and rotating a
# credential does not require a redeploy.
install -m 0644 "${RELEASE_DIR}/app.service" /etc/systemd/system/app.service 2>/dev/null \
  || log "no unit file in revision, using the one baked into the AMI"

systemctl daemon-reload

log "ok (${GIT_SHA})"
