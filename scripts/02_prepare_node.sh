#!/usr/bin/env bash
# Phase 02: run Sunbeam's prepare-node-script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../tools/lib.sh
source "${SCRIPT_DIR}/../tools/lib.sh"

PHASE=02_prepare_node
init_phase "${PHASE}"

phase_skip_if_done "${PHASE}" && exit 0

if ! command -v sunbeam >/dev/null 2>&1; then
    log "FATAL: sunbeam CLI not on PATH. Did phase 01 install the openstack snap successfully?"
    exit 1
fi

prep_script="${ARTIFACT_DIR}/prepare-node.sh"
log_step "fetching prepare-node-script to ${prep_script}"
if ! sunbeam prepare-node-script > "${prep_script}" 2> >(tee -a "${PHASE_LOG}" >&2); then
    log "FATAL: sunbeam prepare-node-script failed"
    exit 1
fi
chmod +x "${prep_script}"

log_step "executing prepare-node-script"
if ! run_logged "prepare-node-script" -- bash -x "${prep_script}"; then
    log "WARN: prepare-node-script returned non-zero. Continuing to re-introspect snap arch."
fi

log_step "post-install snap arch introspection"
for snap_name in openstack k8s openstack-hypervisor juju; do
    if snap list "${snap_name}" >/dev/null 2>&1; then
        installed_channel=$(snap list "${snap_name}" 2>/dev/null | awk 'NR==2 {print $4}')
        "${SCRIPT_DIR}/../tools/check_snap_arch.sh" "${snap_name}" "${installed_channel}" || true
    fi
done

# Group check: prepare-node-script adds the user to `snap_daemon` and friends.
# A new login shell is needed for groups to take effect.
current_groups=$(id -nG)
need_relogin=0
for g in snap_daemon; do
    if ! grep -qw "${g}" <<<"${current_groups}"; then
        log "NOTE: not yet in group ${g} for this shell"
        need_relogin=1
    fi
done
if (( need_relogin == 1 )); then
    log "ACTION REQUIRED: log out and back in (or 'newgrp snap_daemon') before phase 03 so group membership takes effect."
fi

phase_done "${PHASE}"
log_step "phase ${PHASE} complete"
log "NEXT: run phase 02b (./run.sh 02b) to bootstrap k8s with Calico before phase 03. The default cilium CNI does not run on s390x."
