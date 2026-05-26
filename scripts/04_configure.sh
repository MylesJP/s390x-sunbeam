#!/usr/bin/env bash
# Phase 04: sunbeam configure (demo project + external network) for single-node.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../tools/lib.sh
source "${SCRIPT_DIR}/../tools/lib.sh"

PHASE=04_configure
init_phase "${PHASE}"

phase_skip_if_done "${PHASE}" && exit 0

openrc="${ARTIFACT_DIR}/cloud-admin-openrc"

log_step "running sunbeam configure (accepting defaults)"
rc=0
run_logged "sunbeam configure" -- \
    sunbeam configure --accept-defaults --openrc "${openrc}" \
    || rc=$?

if (( rc != 0 )); then
    log "WARN: sunbeam configure returned ${rc}. Phase 05 will still capture state."
    echo "${rc}" > "${ARTIFACT_DIR}/.status/${PHASE}.failed"
    exit "${rc}"
fi

if [[ -r "${openrc}" ]]; then
    log_step "openrc written: ${openrc}"
fi

phase_done "${PHASE}"
log_step "phase ${PHASE} complete"
