#!/usr/bin/env bash
# ApplicationStop — stop the currently running revision.
#
# Two properties matter here, and both are easy to get wrong:
#
# 1. This script runs from the PREVIOUSLY deployed revision, not the incoming
#    one. On the very first deployment to a fresh instance there is nothing to
#    stop, so every command must tolerate "not there".
#
# 2. If this script exits non-zero, the deployment fails on this instance — and
#    on a brand-new instance scaled out by the ASG, that means the instance never
#    joins the fleet. A stop hook that is strict about a service that was never
#    started is a self-inflicted capacity outage during a scale-up.
#
# Hence: `set -eu` without `-o pipefail` on the checks, and explicit tolerance of
# absent units.
set -eu

log() { echo "[stop_service] $*"; }

if ! systemctl list-unit-files app.service > /dev/null 2>&1; then
  log "app.service not installed yet — first deployment, nothing to stop"
  exit 0
fi

if ! systemctl is-active --quiet app.service; then
  log "app.service not running, nothing to stop"
  exit 0
fi

log "stopping app.service"
# Graceful: systemd sends SIGTERM and waits TimeoutStopSec before SIGKILL. The
# application is expected to stop accepting new connections and drain in-flight
# ones. Connection draining at the ALB has already happened — CodeDeploy
# deregisters the target before running this hook — so what remains is only
# in-flight work.
systemctl stop app.service || log "stop returned non-zero, continuing"

# Do not leave a half-dead container holding the port; the next revision's
# `docker run` would fail on a name/port conflict, and the error would point at
# the new revision rather than at this script.
docker rm -f app > /dev/null 2>&1 || true

log "ok"
