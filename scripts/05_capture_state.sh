#!/usr/bin/env bash
# Phase 05: state capture. Always exits 0 so collection finishes even on partial deploy.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../tools/lib.sh
source "${SCRIPT_DIR}/../tools/lib.sh"

PHASE=05_capture_state
init_phase "${PHASE}"

# Intentionally do NOT phase_skip_if_done: re-running this should always refresh.

bundle="${ARTIFACT_DIR}/juju_bundle.yaml"
status_file="${ARTIFACT_DIR}/juju_status.txt"
status_rel="${ARTIFACT_DIR}/juju_status_relations.txt"
k8s_yaml="${ARTIFACT_DIR}/k8s_resources.yaml"
k8s_events="${ARTIFACT_DIR}/k8s_events.txt"
k8s_nodes="${ARTIFACT_DIR}/k8s_nodes_describe.txt"
snaps_file="${ARTIFACT_DIR}/snaps.txt"

log_step "juju export bundle -> ${bundle}"
juju export bundle > "${bundle}" 2>> "${PHASE_LOG}" || \
    log "WARN: juju export bundle failed (no model? bootstrap incomplete?)"

log_step "juju status -> ${status_file}"
juju status --format=yaml > "${status_file}" 2>> "${PHASE_LOG}" || \
    log "WARN: juju status failed"
juju status --relations --color=false > "${status_rel}" 2>> "${PHASE_LOG}" || true

log_step "k8s resources -> ${k8s_yaml}"
if command -v k8s >/dev/null 2>&1; then
    sudo k8s kubectl get all -A -o yaml > "${k8s_yaml}" 2>> "${PHASE_LOG}" || \
        log "WARN: k8s kubectl get all failed"
    sudo k8s kubectl get events -A --sort-by=.lastTimestamp > "${k8s_events}" 2>> "${PHASE_LOG}" || true
    sudo k8s kubectl describe nodes > "${k8s_nodes}" 2>> "${PHASE_LOG}" || true
else
    log "WARN: k8s CLI missing; skipping k8s captures"
fi

log_step "snap inventory -> ${snaps_file}"
{
    echo "=== snap list ==="
    snap list 2>&1 || true
    echo
    for s in openstack k8s openstack-hypervisor juju microceph; do
        echo "=== snap info ${s} ==="
        snap info --verbose "${s}" 2>&1 || true
        echo
    done
} > "${snaps_file}"

log_step "OCI arch introspection across the resolved bundle"
if [[ -s "${bundle}" ]]; then
    mapfile -t images < <("${SCRIPT_DIR}/../tools/extract_oci_images.sh" "${bundle}")
    log_step "found ${#images[@]} OCI image refs in bundle"
    for img in "${images[@]}"; do
        "${SCRIPT_DIR}/../tools/check_oci_arch.sh" "${img}" || true
    done
else
    log "WARN: bundle empty, skipping OCI introspection"
fi

# Always succeed: collection-of-failure is itself the artifact.
phase_done "${PHASE}"
log_step "phase ${PHASE} complete"
exit 0
