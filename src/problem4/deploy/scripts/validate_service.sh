#!/usr/bin/env bash
# AfterAllowTraffic — the canary gate.
#
# This is the most important script in the repository, so it is worth being
# explicit about what it buys:
#
# With CodeDeployDefault.OneAtATime, CodeDeploy will not begin instance 2 until
# instance 1's AfterAllowTraffic hook returns 0. At this point the instance is
# registered with the ALB and serving 1/N of production traffic while every other
# instance still runs the previous revision.
#
# Three questions, in order, each strictly stronger than the last:
#   1. Does the application answer locally?          (process-level)
#   2. Has the ALB accepted it into the target group? (routing-level)
#   3. Is it healthy under real traffic for a bake window? (behaviour-level)
#
# Skipping question 3 is what makes most "successful" deploys page you nine
# minutes later.
set -euo pipefail

log() { echo "[validate_service] $*"; }

REGION="${AWS_REGION:-ap-southeast-1}"
BAKE_SECONDS="${BAKE_SECONDS:-180}"
ERROR_RATE_THRESHOLD="${ERROR_RATE_THRESHOLD:-2.0}" # percent of requests 5xx

# IMDSv2. The token-based flow is not optional hardening: IMDSv1's unauthenticated
# GET is reachable through any SSRF in the application, which turns a web bug into
# credential theft.
IMDS_TOKEN=$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
imds() { curl -fsS -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" "http://169.254.169.254/latest/$1"; }

INSTANCE_ID=$(imds "meta-data/instance-id")

# Two env files with different lifetimes, deliberately not merged:
#
#   /etc/app/release.env   rewritten by after_install.sh on every deployment.
#                          Carries IMAGE_URI and GIT_SHA.
#   /etc/app/instance.env  written once by the ASG launch-template user data.
#                          Carries the instance's place in the world —
#                          TARGET_GROUP_ARN and LOAD_BALANCER_DIMENSION.
#
# Putting the target group ARN in release.env would mean the pipeline has to know
# which environment each revision is for, which is exactly the coupling that
# "build once, promote many" exists to avoid.
# shellcheck disable=SC1091
source /etc/app/release.env
# shellcheck disable=SC1091
source /etc/app/instance.env

: "${GIT_SHA:?release.env is missing GIT_SHA}"
: "${TARGET_GROUP_ARN:?instance.env is missing TARGET_GROUP_ARN — check the launch template user data}"

# --- 1. local -----------------------------------------------------------------
log "checking local readiness"
DEADLINE=$(( $(date +%s) + 60 ))
until curl -fsS --max-time 2 "http://127.0.0.1:8080/ready" > /dev/null 2>&1; do
  [ "$(date +%s)" -ge "${DEADLINE}" ] && { log "ERROR: /ready never succeeded"; exit 1; }
  sleep 2
done

# Confirm the running process is the revision we think we deployed. Without this,
# a container that silently failed to restart still validates green — the classic
# "deploy succeeded but nothing changed".
RUNNING_SHA=$(curl -fsS --max-time 2 "http://127.0.0.1:8080/version" | jq -r .git_sha)
if [ "${RUNNING_SHA}" != "${GIT_SHA}" ]; then
  log "ERROR: instance is running ${RUNNING_SHA}, expected ${GIT_SHA}"
  exit 1
fi

# --- 2. load balancer ---------------------------------------------------------
# The ALB applies its own health check policy (interval x threshold). Passing our
# local check while failing the ALB's means the two definitions of "healthy"
# disagree — a real and common misconfiguration that this catches at instance 1.
log "waiting for ALB target registration"
DEADLINE=$(( $(date +%s) + 180 ))
while true; do
  STATE=$(aws elbv2 describe-target-health \
    --region "${REGION}" \
    --target-group-arn "${TARGET_GROUP_ARN}" \
    --targets "Id=${INSTANCE_ID}" \
    --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text 2>/dev/null || echo "unknown")

  [ "${STATE}" = "healthy" ] && break

  if [ "$(date +%s)" -ge "${DEADLINE}" ]; then
    log "ERROR: target state is '${STATE}' after 180s, expected 'healthy'"
    aws elbv2 describe-target-health --region "${REGION}" \
      --target-group-arn "${TARGET_GROUP_ARN}" --targets "Id=${INSTANCE_ID}" \
      --query 'TargetHealthDescriptions[0].TargetHealth' || true
    exit 1
  fi
  log "target state ${STATE}, waiting"
  sleep 10
done

# --- 3. bake ------------------------------------------------------------------
# Now it is taking real traffic. Watch the target group's own 5xx count — the
# application's opinion of itself is not evidence, the load balancer's is.
log "baking for ${BAKE_SECONDS}s (threshold ${ERROR_RATE_THRESHOLD}% 5xx)"
# CloudWatch wants the trailing portion of the ARN, not the ARN.
TG_DIMENSION="${TARGET_GROUP_ARN##*:}"
LB_DIMENSION="${LOAD_BALANCER_DIMENSION:-}"

BAKE_END=$(( $(date +%s) + BAKE_SECONDS ))
while [ "$(date +%s)" -lt "${BAKE_END}" ]; do
  sleep 30

  START=$(date -u -d '2 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
  END=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  dims="Name=TargetGroup,Value=${TG_DIMENSION}"
  [ -n "${LB_DIMENSION}" ] && dims="${dims} Name=LoadBalancer,Value=${LB_DIMENSION}"

  metric() {
    aws cloudwatch get-metric-statistics --region "${REGION}" \
      --namespace AWS/ApplicationELB --metric-name "$1" \
      --dimensions ${dims} \
      --start-time "${START}" --end-time "${END}" \
      --period 60 --statistics Sum \
      --query 'sum(Datapoints[].Sum)' --output text 2>/dev/null || echo "0"
  }

  ERRORS=$(metric HTTPCode_Target_5XX_Count)
  REQUESTS=$(metric RequestCount)
  [ "${ERRORS}" = "None" ] && ERRORS=0
  [ "${REQUESTS}" = "None" ] && REQUESTS=0

  # Below this volume the error *rate* is statistical noise — one failed health
  # probe out of eight requests is 12.5% and means nothing. Wait for signal
  # rather than rolling back a good deploy on a sample of eight.
  if awk "BEGIN{exit !(${REQUESTS} < 20)}"; then
    log "only ${REQUESTS} requests in window, not enough signal yet"
    continue
  fi

  RATE=$(awk "BEGIN{printf \"%.2f\", (${ERRORS} / ${REQUESTS}) * 100}")
  log "5xx rate ${RATE}% (${ERRORS}/${REQUESTS})"

  if awk "BEGIN{exit !(${RATE} > ${ERROR_RATE_THRESHOLD})}"; then
    log "ERROR: 5xx rate ${RATE}% exceeds ${ERROR_RATE_THRESHOLD}%"
    # Non-zero here fails the whole deployment. CodeDeploy stops — the remaining
    # instances are never touched — and its auto-rollback configuration restores
    # the previous revision on this one.
    exit 1
  fi
done

log "ok — canary clean after ${BAKE_SECONDS}s"
