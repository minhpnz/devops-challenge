#!/usr/bin/env bash
# BeforeInstall — prepare the host for the new revision.
#
# Everything here is idempotent: CodeDeploy hooks re-run on retry and on rollback,
# so a script that only works the first time turns a routine redeploy into an
# incident.
set -euo pipefail

APP_DIR=/opt/app
RELEASE_DIR="${APP_DIR}/release"

log() { echo "[before_install] $*"; }

mkdir -p "${APP_DIR}" /var/log/app

# CodeDeploy fails the deployment if the destination directory already has
# content from a previous revision. Clearing it is the documented pattern.
if [ -d "${RELEASE_DIR}" ]; then
  log "clearing previous revision at ${RELEASE_DIR}"
  rm -rf "${RELEASE_DIR:?}"/*
fi

# Reclaim space before pulling a new image. An EC2 host that has been deploying
# for six months without this accumulates every image it has ever run and
# eventually fails a deploy with "no space left on device" — at which point the
# instance is also failing health checks, because the application cannot write
# logs either.
#
# 72h keeps enough history for an instant rollback to the last few revisions.
log "pruning docker images older than 72h"
docker image prune --all --force --filter "until=72h" || log "prune failed, continuing"

# Fail early and legibly if the host cannot possibly succeed, rather than midway
# through the image pull.
AVAIL_MB=$(df --output=avail -m /var/lib/docker | tail -1 | tr -d ' ')
if [ "${AVAIL_MB}" -lt 2048 ]; then
  log "ERROR: only ${AVAIL_MB}MB free on /var/lib/docker, need >= 2048MB"
  exit 1
fi

log "ok (${AVAIL_MB}MB free)"
