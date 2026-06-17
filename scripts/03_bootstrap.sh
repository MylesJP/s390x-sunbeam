#!/usr/bin/env bash
# Phase 03: register the running Canonical K8s with Juju, bootstrap a controller,
# and deploy the CORE control-plane bundle into the `openstack` model.
#
# Replaces the old `sunbeam cluster bootstrap`. No Sunbeam CLI: we drive plain
# `juju` against the K8s cluster phase 02b brought up.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../tools/lib.sh
source "${SCRIPT_DIR}/../tools/lib.sh"

PHASE=03_bootstrap
init_phase "${PHASE}"

phase_skip_if_done "${PHASE}" && exit 0

K8S_CLOUD="${K8S_CLOUD:-sunbeam-k8s}"
CONTROLLER="${JUJU_CONTROLLER:-sunbeam-controller}"
K8S_MODEL="${K8S_MODEL:-openstack}"
BUNDLE="${REPO_ROOT}/manifests/control-plane-k8s-s390x.yaml"
DEPLOY_TIMEOUT="${DEPLOY_TIMEOUT:-3600}"

if [[ ! -r "${BUNDLE}" ]]; then
    log "FATAL: control-plane bundle missing at ${BUNDLE}"
    exit 1
fi
command -v juju >/dev/null 2>&1 || { log "FATAL: juju CLI missing (phase 01)"; exit 1; }
command -v k8s  >/dev/null 2>&1 || { log "FATAL: k8s CLI missing (phase 02b)"; exit 1; }

# Background juju status watcher so a wedge during deploy is visible in artifacts
# even if this phase times out.
status_log="${ARTIFACT_DIR}/juju_status_watch.log"
( while true; do
    {
        printf '\n=== [%s] juju status -m %s ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${K8S_MODEL}"
        juju status -m "${CONTROLLER}:${K8S_MODEL}" --color=false 2>&1 || true
    } >> "${status_log}"
    sleep 30
  done ) &
watcher_pid=$!
log_step "background juju status watcher started (pid ${watcher_pid}, log: ${status_log})"
trap '[[ -n "${watcher_pid:-}" ]] && kill "${watcher_pid}" 2>/dev/null || true' EXIT

# 1. Register the Canonical K8s cluster with the juju client.
if juju clouds --client 2>/dev/null | grep -qw "${K8S_CLOUD}"; then
    log "k8s cloud ${K8S_CLOUD} already registered with juju client"
else
    log_step "registering Canonical K8s with juju as cloud '${K8S_CLOUD}'"
    if ! sudo k8s config 2>>"${PHASE_LOG}" | juju add-k8s "${K8S_CLOUD}" --client 2>&1 | tee -a "${PHASE_LOG}"; then
        log "FATAL: juju add-k8s failed. Is the k8s cluster healthy (phase 02b)?"
        exit 1
    fi
fi

# 2. Bootstrap a controller. The controller runs as a pod -> needs an s390x
#    jujud-operator image. Failure here IS an arch signal worth recording.
if juju controllers --format=json 2>/dev/null | jq -e ".controllers | has(\"${CONTROLLER}\")" >/dev/null 2>&1; then
    log "controller ${CONTROLLER} already bootstrapped"
else
    log_step "bootstrapping controller ${CONTROLLER} on ${K8S_CLOUD}"
    if ! run_logged "juju bootstrap" -- juju bootstrap "${K8S_CLOUD}" "${CONTROLLER}" --debug; then
        log "FATAL: juju bootstrap failed (jujud-operator may have no s390x image)."
        arch_report_append oci jujud-operator controller no "juju bootstrap failed -- see phase log"
        exit 1
    fi
    arch_report_append oci jujud-operator controller yes "controller pod started"
fi

# 3. Add the control-plane model.
if juju models --format=json 2>/dev/null | jq -e ".models[] | select(.\"short-name\"==\"${K8S_MODEL}\")" >/dev/null 2>&1; then
    log "model ${K8S_MODEL} already exists"
else
    run_logged "juju add-model ${K8S_MODEL}" -- juju add-model "${K8S_MODEL}" "${K8S_CLOUD}"
fi

# 4. Deploy the control-plane bundle (exports the cross-model offers).
log_step "deploying control-plane bundle into ${K8S_MODEL}"
rc=0
run_logged "juju deploy control-plane bundle" -- \
    juju deploy -m "${CONTROLLER}:${K8S_MODEL}" "${BUNDLE}" --trust || rc=$?
if (( rc != 0 )); then
    log "WARN: juju deploy returned ${rc}. Phase 05 will still capture state."
    echo "${rc}" > "${ARTIFACT_DIR}/.status/${PHASE}.failed"
    exit "${rc}"
fi

# 5. Bounded wait: poll until every unit's agent is settled (idle/error) or
#    timeout. We do NOT require workload=active -- on s390x some apps are
#    expected to block on missing OCI images; that is the signal, captured by
#    phase 05. We just want the deploy to stop churning.
log_step "waiting up to ${DEPLOY_TIMEOUT}s for ${K8S_MODEL} to settle"
juju_wait_settle "${CONTROLLER}:${K8S_MODEL}" "${DEPLOY_TIMEOUT}" || true
juju offers -m "${CONTROLLER}:${K8S_MODEL}" 2>&1 | tee -a "${PHASE_LOG}" || true

phase_done "${PHASE}"
log_step "phase ${PHASE} complete"
log "NEXT: ./run.sh 03b to deploy the machine plane (hypervisor + cinder-volume + microceph)."
