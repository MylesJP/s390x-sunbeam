#!/usr/bin/env bash
# Phase 00: assert host suitability and capture environment.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../tools/lib.sh
source "${SCRIPT_DIR}/../tools/lib.sh"

PHASE=00_check_host
init_phase "${PHASE}"

phase_skip_if_done "${PHASE}" && exit 0

env_file="${ARTIFACT_DIR}/env.txt"
{
    echo "=== uname -a ==="
    uname -a
    echo
    echo "=== /etc/os-release ==="
    cat /etc/os-release 2>/dev/null || echo "missing"
    echo
    echo "=== lscpu ==="
    lscpu 2>/dev/null || echo "lscpu missing"
    echo
    echo "=== free -h ==="
    free -h
    echo
    echo "=== lsblk ==="
    lsblk 2>/dev/null || true
    echo
    echo "=== df -h ==="
    df -h
    echo
    echo "=== ip a ==="
    ip a
    echo
    echo "=== ip r ==="
    ip r
    echo
    echo "=== /dev/kvm ==="
    ls -l /dev/kvm 2>&1 || true
    echo
    echo "=== kvm modules ==="
    lsmod 2>/dev/null | grep -i kvm || echo "no kvm modules loaded"
    echo
    echo "=== /proc/cmdline ==="
    cat /proc/cmdline 2>/dev/null || true
} > "${env_file}"

log_step "wrote ${env_file}"

arch=$(uname -m)
if [[ "${arch}" != "s390x" ]]; then
    log "FATAL: expected s390x host, got ${arch}"
    exit 1
fi

if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "ubuntu" ]]; then
        log "WARN: expected Ubuntu, got ID=${ID:-unknown}"
    fi
    if [[ "${VERSION_ID:-}" != "26.04" ]]; then
        log "WARN: expected 26.04 Resolute, got VERSION_ID=${VERSION_ID:-unknown}. Sunbeam 2026.1 charms target ubuntu@26.04; older bases will resolve to mismatched charm revisions."
    fi
fi

mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
if (( mem_kb < 16 * 1024 * 1024 )); then
    log "WARN: only $((mem_kb / 1024 / 1024))GB RAM; single-node Sunbeam realistically wants 32GB+"
fi

if [[ ! -e /dev/kvm ]]; then
    log "WARN: /dev/kvm missing. KVM on Z requires LPAR with SIE enabled and kvm modules loaded; Nova will not be able to launch instances."
fi

phase_done "${PHASE}"
log_step "phase ${PHASE} complete"
