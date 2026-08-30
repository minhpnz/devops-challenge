#!/usr/bin/env bash
# ApplicationStart — start the new container and wait until it is locally healthy.
#
# "Started" is not "working". systemd reports success as soon as the process
# execs, which for a container means "docker run returned", not "the application
# can serve a request". Returning success here without the local health check
# would hand a dead instance to AfterAllowTraffic and waste its validation window.
set -euo pipefail

log() { echo "[start_service] $*"; }

systemctl start app.service

# Local check only — 127.0.0.1, not the load balancer. At this point CodeDeploy
# has not re-registered the instance with the target group, so there is no
# public path to it yet. Confusing the two produces a hook that can never pass.
HEALTH_URL="http://127.0.0.1:8080/health"
DEADLINE=$(( $(date +%s) + 120 ))

log "waiting for ${HEALTH_URL}"
until curl -fsS --max-time 2 "${HEALTH_URL}" > /dev/null 2>&1; do
  if [ "$(date +%s)" -ge "${DEADLINE}" ]; then
    log "ERROR: not healthy within 120s"
    # Emit diagnostics into the CodeDeploy log while the evidence still exists.
    # The container is about to be replaced by the rollback, taking its logs with
    # it, and "the deploy failed" with no further detail is a wasted outage.
    systemctl status app.service --no-pager --full || true
    journalctl -u app.service --no-pager --lines 100 || true
    docker logs --tail 100 app 2>&1 || true
    exit 1
  fi
  sleep 2
done

log "ok"
