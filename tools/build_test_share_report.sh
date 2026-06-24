#!/usr/bin/env bash
# Build a compact, human-reviewable report modelled on
# openstack-charmers/test-share's s390x validation directories.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

REPORT_DIR="${ARTIFACT_DIR}/test-share"
CONTROLLER="${JUJU_CONTROLLER:-sunbeam-controller}"
K8S_MODEL="${K8S_MODEL:-openstack}"
MACHINE_MODEL="${MACHINE_MODEL:-machines}"
OPENRC="${ARTIFACT_DIR}/cloud-admin-openrc"
OSC="${ARTIFACT_DIR}/.osc-venv/bin/openstack"
mkdir -p "${REPORT_DIR}"

capture() {
    local output="$1"
    shift
    {
        printf '+'
        printf ' %q' "$@"
        printf '\n'
        "$@"
    } > "${REPORT_DIR}/${output}" 2>&1 || true
}

{
    echo "+ juju status -m ${CONTROLLER}:${K8S_MODEL}"
    juju status -m "${CONTROLLER}:${K8S_MODEL}" --relations --color=false 2>&1 || true
    echo
    echo "+ juju status -m ${CONTROLLER}:${MACHINE_MODEL}"
    juju status -m "${CONTROLLER}:${MACHINE_MODEL}" --relations --color=false 2>&1 || true
} > "${REPORT_DIR}/juju_status.txt"

{
    echo "Sunbeam 2026.1 validation on $(target_arch)"
    echo
    echo "Run ID: ${RUN_ID}"
    echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Host: $(hostname -f 2>/dev/null || hostname)"
    echo "Kernel: $(uname -srmo)"
    if git -C "${REPO_ROOT}" rev-parse HEAD >/dev/null 2>&1; then
        echo "Repository revision: $(git -C "${REPO_ROOT}" rev-parse HEAD)"
    fi
    echo
    echo "This directory is the compact, publishable validation result. The full"
    echo "diagnostic archive remains alongside it as sunbeam-$(target_arch)-${RUN_ID}.tar.zst."
    echo
    echo "## Result"
    echo
    if [[ -s "${ARTIFACT_DIR}/tempest/failures.txt" ]]; then
        echo "Tempest smoke: FAILED"
        echo
        sed 's/^/- /' "${ARTIFACT_DIR}/tempest/failures.txt"
    elif [[ -f "${ARTIFACT_DIR}/.status/06_validate_tempest.done" ]]; then
        totals=$(grep -A8 '^Totals' "${ARTIFACT_DIR}/tempest/smoke_output.txt" 2>/dev/null || true)
        echo "Tempest smoke: PASSED"
        echo
        printf '```text\n%s\n```\n' "${totals}"
    else
        echo "Tempest smoke: not completed. See phase status and diagnostics."
    fi
    if [[ -r "${TEST_SHARE_NOTES_FILE:-}" ]]; then
        echo
        echo "## Notes and known issues"
        echo
        cat "${TEST_SHARE_NOTES_FILE}"
    fi
    echo
    echo "## Contents"
    echo
    echo "- Juju status for both models"
    echo "- OpenStack catalog, image, network, agent, extension, and hypervisor inventories"
    echo "- Instance launch and floating-IP SSH proof"
    echo "- MicroCeph/Ceph health and pool evidence"
    echo "- Tempest smoke output"
    echo "- Exported Juju bundles and Kubernetes state"
} > "${REPORT_DIR}/README.md"

if [[ -r "${OPENRC}" && -x "${OSC}" ]]; then
    (
        # shellcheck disable=SC1090
        source "${OPENRC}"
        capture catalog_list.txt "${OSC}" catalog list
        capture hypervisor_list.txt "${OSC}" hypervisor list
        capture image_list.txt "${OSC}" image list
        capture network_list.txt "${OSC}" network list
        capture network_agent_list.txt "${OSC}" network agent list
        capture network_extension_list.txt "${OSC}" extension list --network
        capture volume_service_list.txt "${OSC}" volume service list
        capture server_list.txt "${OSC}" server list --all-projects
        capture volume_list.txt "${OSC}" volume list --all-projects
    )
else
    for f in catalog_list hypervisor_list image_list network_list \
             network_agent_list network_extension_list volume_service_list \
             server_list volume_list; do
        echo "OpenStack client/openrc unavailable; phase 04 did not complete." \
            > "${REPORT_DIR}/${f}.txt"
    done
fi

{
    echo "+ snap list"
    snap list 2>&1 || true
    echo
    echo "+ juju applications and channels"
    for model in "${K8S_MODEL}" "${MACHINE_MODEL}"; do
        echo "=== ${model} ==="
        juju status -m "${CONTROLLER}:${model}" --format=json 2>/dev/null |
            jq -r '.applications | to_entries[] |
                [.key, .value.charm, (.value.channel // ""),
                 (.value.version // ""), (.value["charm-rev"] // "")] | @tsv' 2>/dev/null || true
    done
} > "${REPORT_DIR}/openstack_origin.txt"

{
    echo "+ sudo microceph status"
    sudo microceph status 2>&1 || true
    echo
    for args in "status" "health detail" "osd lspools" "osd df"; do
        echo "+ sudo microceph.ceph ${args}"
        # shellcheck disable=SC2086
        sudo microceph.ceph ${args} 2>&1 || true
        echo
    done
    mapfile -t ceph_pools < <(
        sudo microceph.ceph osd lspools 2>/dev/null |
            awk '{$1=""; sub(/^ /, ""); print}' |
            grep -vE '^(\.mgr)?$' || true
    )
    for pool in "${ceph_pools[@]}"; do
        echo "+ sudo microceph.rbd -p ${pool} ls"
        sudo microceph.rbd -p "${pool}" ls 2>&1 || true
        echo
    done
} > "${REPORT_DIR}/ceph_tests.txt"

if [[ -r "${ARTIFACT_DIR}/smoke_instance_launch.txt" ]]; then
    sed -E 's/(adminPass[[:space:]]*\|[[:space:]]*).*/\1<redacted> |/' \
        "${ARTIFACT_DIR}/smoke_instance_launch.txt" \
        > "${REPORT_DIR}/instance_launch.txt"
else
    echo "Instance launch proof unavailable; phase 04b did not complete." \
        > "${REPORT_DIR}/instance_launch.txt"
fi
cp -f "${ARTIFACT_DIR}/smoke_instance_ssh.txt" \
    "${REPORT_DIR}/instance_ssh.txt" 2>/dev/null || \
    echo "Instance SSH proof unavailable; phase 04b did not complete." \
        > "${REPORT_DIR}/instance_ssh.txt"
cp -f "${ARTIFACT_DIR}/tempest/smoke_output.txt" \
    "${REPORT_DIR}/tempest_smoke.txt" 2>/dev/null || \
    echo "Tempest output unavailable; phase 06 did not complete." \
        > "${REPORT_DIR}/tempest_smoke.txt"

for f in arch_report.md juju_bundle_openstack.yaml juju_bundle_machines.yaml \
         k8s_events.txt k8s_nodes_describe.txt snaps.txt; do
    cp -f "${ARTIFACT_DIR}/${f}" "${REPORT_DIR}/${f}" 2>/dev/null || true
done

log "test-share report: ${REPORT_DIR}"
