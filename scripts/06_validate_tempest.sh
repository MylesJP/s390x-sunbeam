#!/usr/bin/env bash
# Phase 06: enable Sunbeam validation feature (tempest-k8s) and run smoke Tempest.
# No feature plans are enabled in phase 03, so only core-service Tempest plugins load.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../tools/lib.sh
source "${SCRIPT_DIR}/../tools/lib.sh"

PHASE=06_validate_tempest
init_phase "${PHASE}"

phase_skip_if_done "${PHASE}" && exit 0

if ! command -v sunbeam >/dev/null 2>&1; then
    log "FATAL: sunbeam CLI missing"
    exit 1
fi

report="${ARTIFACT_DIR}/tempest_report.yaml"
tempest_log="${ARTIFACT_DIR}/tempest_pod.log"

log_step "enabling validation feature (tempest-k8s)"
rc=0
run_logged "sunbeam enable validation" -- sunbeam enable validation || rc=$?
if (( rc != 0 )); then
    log "WARN: sunbeam enable validation returned ${rc}; tempest charm may not be ready"
fi

# Wait for tempest charm to settle. Bounded so a wedge doesn't hang forever.
log_step "waiting up to 20 min for tempest-k8s to reach active/idle"
deadline=$(( $(date +%s) + 1200 ))
while (( $(date +%s) < deadline )); do
    if juju status tempest --format=yaml 2>/dev/null \
        | grep -q 'current: active' \
        && juju status tempest --format=yaml 2>/dev/null \
        | grep -q 'current: idle'; then
        log "tempest charm active/idle"
        break
    fi
    sleep 30
done

log_step "running sunbeam validation run smoke -> ${report}"
# Sub-command spelling has varied across cycles; try the most common forms.
rc=0
if sunbeam validation --help 2>&1 | grep -q '^\s*run\b'; then
    run_logged "sunbeam validation run smoke" -- \
        sunbeam validation run --output "${report}" smoke || rc=$?
else
    log "WARN: 'sunbeam validation run' subcommand not present; falling back to 'sunbeam validation' direct"
    run_logged "sunbeam validation smoke" -- \
        sunbeam validation smoke --output "${report}" || rc=$?
fi

log_step "capturing tempest pod logs"
if command -v k8s >/dev/null 2>&1; then
    sudo k8s kubectl logs -n openstack -l app.kubernetes.io/name=tempest --tail=-1 \
        > "${tempest_log}" 2>> "${PHASE_LOG}" || \
        log "WARN: could not fetch tempest pod logs"
fi

if (( rc != 0 )); then
    log "WARN: tempest run returned ${rc}; report at ${report}"
    echo "${rc}" > "${ARTIFACT_DIR}/.status/${PHASE}.failed"
fi

phase_done "${PHASE}"
log_step "phase ${PHASE} complete"
exit "${rc}"
