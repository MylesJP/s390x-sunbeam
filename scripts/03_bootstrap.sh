#!/usr/bin/env bash
# Phase 03: sunbeam cluster bootstrap with the s390x 2026.1/edge manifest. Core only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../tools/lib.sh
source "${SCRIPT_DIR}/../tools/lib.sh"

PHASE=03_bootstrap
init_phase "${PHASE}"

phase_skip_if_done "${PHASE}" && exit 0

MANIFEST="${REPO_ROOT}/manifests/sunbeam-2026.1-s390x.yaml"
if [[ ! -r "${MANIFEST}" ]]; then
    log "FATAL: manifest missing at ${MANIFEST}"
    exit 1
fi

# Start a background juju status watcher so a wedge during bootstrap is visible
# in the artifacts even if bootstrap times out or hangs.
status_log="${ARTIFACT_DIR}/juju_status_watch.log"
( while true; do
    {
        printf '\n=== [%s] juju status ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        juju status --color=false 2>&1 || true
    } >> "${status_log}"
    sleep 30
  done ) &
watcher_pid=$!
log_step "background juju status watcher started (pid ${watcher_pid}, log: ${status_log})"
trap '[[ -n "${watcher_pid:-}" ]] && kill "${watcher_pid}" 2>/dev/null || true' EXIT

log_step "running sunbeam cluster bootstrap (core only, no feature plans)"
rc=0
run_logged "sunbeam cluster bootstrap" -- \
    sunbeam cluster bootstrap \
        --manifest "${MANIFEST}" \
        --role control,compute,storage \
        --accept-defaults \
    || rc=$?

if (( rc != 0 )); then
    log "WARN: sunbeam cluster bootstrap returned ${rc}. Phase 05 will still capture state."
    # Do NOT mark the phase done so the user can re-run after fixes.
    echo "${rc}" > "${ARTIFACT_DIR}/.status/${PHASE}.failed"
    exit "${rc}"
fi

phase_done "${PHASE}"
log_step "phase ${PHASE} complete"
