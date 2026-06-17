#!/usr/bin/env bash
# Phase 99: bundle artifacts into a single tarball + emit a summary.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../tools/lib.sh
source "${SCRIPT_DIR}/../tools/lib.sh"

PHASE=99_collect_artifacts
init_phase "${PHASE}"

tarball="${ARTIFACT_DIR}/sunbeam-s390x-${RUN_ID}.tar.zst"
tmp_tarball="${ARTIFACT_DIR}.sunbeam-s390x-${RUN_ID}.tar.zst.tmp"
log_step "creating ${tarball}"

# Write outside ARTIFACT_DIR first so tar never archives the file it is creating.
tar --zstd \
    --exclude="$(basename "${tarball}")" \
    -cf "${tmp_tarball}" \
    -C "${ARTIFACT_DIR}" .
mv "${tmp_tarball}" "${tarball}"

log_step "phase status summary:"
{
    printf '\n%-25s %-10s\n' PHASE STATUS
    printf '%-25s %-10s\n' ----- ------
    for p in 00_check_host 01_install_prereqs 02_prepare_node 03_bootstrap \
             04_configure 05_capture_state 06_validate_tempest; do
        if [[ -f "${PHASE_STATUS_DIR}/${p}.done" ]]; then
            st=DONE
        elif [[ -f "${PHASE_STATUS_DIR}/${p}.failed" ]]; then
            st="FAILED(rc=$(cat "${PHASE_STATUS_DIR}/${p}.failed"))"
        else
            st=SKIPPED
        fi
        printf '%-25s %-10s\n' "${p}" "${st}"
    done
    printf '\nartifact bundle: %s\n' "${tarball}"
} | tee -a "${PHASE_LOG}"

phase_done "${PHASE}"
