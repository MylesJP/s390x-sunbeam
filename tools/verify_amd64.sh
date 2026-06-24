#!/usr/bin/env bash
# Run the full workflow on an amd64 verification host with gates between phases.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

export TARGET_ARCH=amd64
export CHARM_SOURCE=charmhub
: "${LB_CIDR:?Set LB_CIDR to a reserved, L2-routable address range (for example 10.0.0.240-10.0.0.250)}"
export LB_CIDR

if [[ -n "${PROXY_URL:-}" ]]; then
    NO_PROXY_VAL="${NO_PROXY_DEFAULT:-localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.cluster.local}"
    export http_proxy="${PROXY_URL}" https_proxy="${PROXY_URL}"
    export HTTP_PROXY="${PROXY_URL}" HTTPS_PROXY="${PROXY_URL}"
    export no_proxy="${NO_PROXY_VAL}" NO_PROXY="${NO_PROXY_VAL}"
fi

RUN_ID="${RUN_ID:-amd64-$(date -u +%Y%m%dT%H%M%SZ)}"
ARTIFACT_DIR="${REPO_ROOT}/artifacts/${RUN_ID}"

run_phase() {
    "${REPO_ROOT}/run.sh" --run-id "${RUN_ID}" "$1"
}

finalize_on_error() {
    local rc=$?
    trap - EXIT
    if (( rc != 0 )); then
        run_phase 05 || true
        run_phase 99 || true
    fi
    exit "${rc}"
}
trap finalize_on_error EXIT

gate_k8s() {
    sudo k8s kubectl wait --for=condition=Ready node --all --timeout=300s
    sudo k8s kubectl get storageclass
    test -s "${ARTIFACT_DIR}/lb_cidr"
    grep -q '| k8s-substrate | storage .* yes (amd64)' "${ARTIFACT_DIR}/arch_report.md"
    grep -q '| k8s-substrate | loadbalancer .* yes (amd64)' "${ARTIFACT_DIR}/arch_report.md"
}

gate_model() {
    local model="$1"
    juju status -m "sunbeam-controller:${model}" --format=json |
        jq -e '
          ((.applications | length) > 0) and
          (([.applications[].units // {} | .[] | .["juju-status"].current])
           | all(. != "error"))
        ' >/dev/null
}

gate_cloud() {
    local openrc="${ARTIFACT_DIR}/cloud-admin-openrc"
    local osc="${ARTIFACT_DIR}/.osc-venv/bin/openstack"
    # shellcheck disable=SC1090
    source "${openrc}"
    "${osc}" token issue >/dev/null
    "${osc}" catalog list
    "${osc}" image show ubuntu >/dev/null
    "${osc}" network show external-network >/dev/null
    test "$("${osc}" hypervisor list -f value -c "Hypervisor Hostname" | wc -l)" -ge 1
}

run_phase 00
run_phase 01
run_phase 02
run_phase 02b
gate_k8s
run_phase 03
gate_model openstack
run_phase 03b
gate_model machines
run_phase 04
gate_cloud
run_phase 04b
run_phase 05
run_phase 06
run_phase 99

# Verify idempotent phase short-circuiting using the same run ID.
run_phase 00
run_phase 01
run_phase 04b

trap - EXIT
echo "amd64 verification complete"
echo "artifacts: ${ARTIFACT_DIR}"
