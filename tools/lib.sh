# Shared helpers for the s390x Sunbeam deploy scripts.
# Source me; do not execute.

set -o pipefail

: "${REPO_ROOT:?REPO_ROOT must be exported by run.sh}"
: "${RUN_ID:?RUN_ID must be exported by run.sh}"
: "${ARTIFACT_DIR:?ARTIFACT_DIR must be exported by run.sh}"

ARCH_REPORT="${ARTIFACT_DIR}/arch_report.md"
PHASE_STATUS_DIR="${ARTIFACT_DIR}/.status"
mkdir -p "${PHASE_STATUS_DIR}"

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log() {
    printf '[%s] %s\n' "$(ts)" "$*" >&2
}

log_step() {
    printf '\n=== [%s] %s ===\n' "$(ts)" "$*" | tee -a "${PHASE_LOG:-/dev/null}" >&2
}

# run_logged <human-readable description> -- <cmd> [args...]
# Streams stdout+stderr of cmd into the active phase log with timestamps,
# AND echoes to the terminal. Returns the command's exit status.
run_logged() {
    local desc="$1"; shift
    [[ "${1:-}" == "--" ]] && shift
    log_step "RUN: ${desc}"
    log_step "CMD: $*"
    set -o pipefail
    "$@" 2>&1 \
        | awk -v ts_cmd="date -u +%Y-%m-%dT%H:%M:%SZ" '{ ts_cmd | getline t; close(ts_cmd); printf "[%s] %s\n", t, $0; fflush() }' \
        | tee -a "${PHASE_LOG:-/dev/null}"
    local rc=${PIPESTATUS[0]}
    log_step "RC: ${rc}"
    return "${rc}"
}

require_cmd() {
    local missing=()
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    if (( ${#missing[@]} > 0 )); then
        log "missing required commands: ${missing[*]}"
        return 1
    fi
}

phase_done() {
    local phase="$1"
    touch "${PHASE_STATUS_DIR}/${phase}.done"
}

phase_is_done() {
    local phase="$1"
    [[ -f "${PHASE_STATUS_DIR}/${phase}.done" ]]
}

phase_skip_if_done() {
    local phase="$1"
    if phase_is_done "${phase}"; then
        log "phase ${phase} already marked done in ${ARTIFACT_DIR}; skipping. Delete ${PHASE_STATUS_DIR}/${phase}.done to force."
        return 0
    fi
    return 1
}

# Initialize a phase log; call once at the top of each phase script.
init_phase() {
    local phase="$1"
    PHASE_LOG="${ARTIFACT_DIR}/phase_${phase}.log"
    export PHASE_LOG
    : > "${PHASE_LOG}"
    log_step "phase ${phase} start"
}

# Append a row to arch_report.md, creating the file/header if absent.
arch_report_append() {
    local kind="$1" name="$2" channel_or_tag="$3" s390x="$4" note="$5"
    if [[ ! -s "${ARCH_REPORT}" ]]; then
        cat > "${ARCH_REPORT}" <<'EOF'
# s390x availability report

| kind | name | channel/tag | s390x | note |
|------|------|-------------|-------|------|
EOF
    fi
    printf '| %s | %s | %s | %s | %s |\n' \
        "${kind}" "${name}" "${channel_or_tag}" "${s390x}" "${note}" \
        >> "${ARCH_REPORT}"
}
