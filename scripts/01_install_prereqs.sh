#!/usr/bin/env bash
# Phase 01: install Sunbeam CLI snap + helper tools. Diagnose s390x snap availability.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../tools/lib.sh
source "${SCRIPT_DIR}/../tools/lib.sh"

PHASE=01_install_prereqs
init_phase "${PHASE}"

phase_skip_if_done "${PHASE}" && exit 0

CHANNEL="${SUNBEAM_CHANNEL:-2026.1/edge}"
K8S_CHANNEL="${K8S_CHANNEL:-1.32-classic/stable}"
HYPERVISOR_CHANNEL="${HYPERVISOR_CHANNEL:-2026.1/edge}"
JUJU_CHANNEL="${JUJU_CHANNEL:-3/stable}"

log_step "diagnosing s390x availability for required snaps (channel records appended to ${ARCH_REPORT})"
"${SCRIPT_DIR}/../tools/check_snap_arch.sh" openstack             "${CHANNEL}"           || true
"${SCRIPT_DIR}/../tools/check_snap_arch.sh" k8s                   "${K8S_CHANNEL}"       || true
"${SCRIPT_DIR}/../tools/check_snap_arch.sh" openstack-hypervisor  "${HYPERVISOR_CHANNEL}" || true
"${SCRIPT_DIR}/../tools/check_snap_arch.sh" juju                  "${JUJU_CHANNEL}"      || true

log_step "ensuring skopeo is installed for OCI introspection"
if ! command -v skopeo >/dev/null 2>&1; then
    run_logged "apt install skopeo" -- sudo apt-get install -y skopeo || \
        log "WARN: skopeo install failed; OCI arch checks will be marked unknown"
fi

log_step "installing openstack snap (Sunbeam CLI) from ${CHANNEL}"
if snap list openstack >/dev/null 2>&1; then
    log "openstack snap already installed; refreshing to ${CHANNEL}"
    run_logged "snap refresh openstack" -- sudo snap refresh openstack --channel="${CHANNEL}" || \
        log "WARN: snap refresh failed (may be no s390x revision in ${CHANNEL})"
else
    run_logged "snap install openstack" -- sudo snap install openstack --channel="${CHANNEL}" || \
        log "WARN: snap install failed (may be no s390x revision in ${CHANNEL})"
fi

phase_done "${PHASE}"
log_step "phase ${PHASE} complete"
