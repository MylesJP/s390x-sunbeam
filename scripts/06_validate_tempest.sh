#!/usr/bin/env bash
# Phase 06: run Tempest against the deployed Sunbeam cloud, zopenstack-style.
#
# Workflow (adapted from ubuntu-openstack/zopenstack for Sunbeam):
#   1. Use the openrc Sunbeam produced (cloud-admin-openrc from phase 04).
#   2. Clone upstream openstack/tempest.
#   3. Use python-tempestconf (upstream, deployment-agnostic) to generate
#      tempest.conf from the live cloud's catalog.
#   4. Drop in the vendor/zopenstack/exclude-list.txt.
#   5. `tox -e smoke --notest` to set up the venv.
#   6. `tox -e smoke | tee smoke_output.txt` for the actual run.
#   7. Save FAILED lines into failures.txt.
#   8. Dump diagnostic state (openstack CLI: catalog, image list, etc.) into
#      a tempest_report/ directory.
#
# Single-test re-runs are not driven by this phase; use
# tools/run_tempest_test.sh once setup is complete.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../tools/lib.sh
source "${SCRIPT_DIR}/../tools/lib.sh"

PHASE=06_validate_tempest
init_phase "${PHASE}"

phase_skip_if_done "${PHASE}" && exit 0

OPENRC="${ARTIFACT_DIR}/cloud-admin-openrc"
if [[ ! -r "${OPENRC}" ]]; then
    log "FATAL: ${OPENRC} not found. Phase 04 (configure) must succeed first."
    exit 1
fi

TEMPEST_DIR="${ARTIFACT_DIR}/tempest"
REPORT_DIR="${ARTIFACT_DIR}/tempest_report"
mkdir -p "${TEMPEST_DIR}" "${REPORT_DIR}"

# Guest image for discover-tempest-config, matched to the deploy arch (an s390x
# image won't boot on an amd64 dry-run and vice versa). Overridable.
ARCH="$(target_arch)"
TEMPEST_IMAGE_URL="${TEMPEST_IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-${ARCH}.img}"

EXCLUDE_LIST="${REPO_ROOT}/vendor/zopenstack/exclude-list.txt"
if [[ ! -s "${EXCLUDE_LIST}" ]]; then
    log "WARN: ${EXCLUDE_LIST} missing or empty; tempest will run with no exclusions"
fi

# 1. Required CLI tooling. python3-venv is on Ubuntu by default; pip we'll
# use from inside the venv so no apt install is needed beyond it.
log_step "ensuring python3-venv and openstack client are available"
if ! command -v python3 >/dev/null 2>&1; then
    log "FATAL: python3 missing"
    exit 1
fi
if ! dpkg -s python3-venv >/dev/null 2>&1; then
    run_logged "apt install python3-venv" -- sudo apt-get install -y python3-venv
fi

# 2. Clone upstream tempest (if not already cloned).
if [[ ! -d "${TEMPEST_DIR}/tempest/.git" ]]; then
    log_step "cloning upstream openstack/tempest"
    run_logged "git clone tempest" -- \
        git clone https://github.com/openstack/tempest "${TEMPEST_DIR}/tempest"
else
    log "tempest repo already present; using existing checkout"
fi

# 3. Set up a venv with python-tempestconf + openstack client.
venv="${TEMPEST_DIR}/.venv"
if [[ ! -x "${venv}/bin/discover-tempest-config" ]]; then
    log_step "creating tempestconf venv at ${venv}"
    python3 -m venv "${venv}"
    "${venv}/bin/pip" install --upgrade pip
    "${venv}/bin/pip" install python-tempestconf python-openstackclient
fi

# 4. Generate tempest.conf with python-tempestconf, against the live cloud.
# discover-tempest-config talks to keystone/nova/glance/neutron via the
# openrc to figure out what's enabled and writes a working tempest.conf.
log_step "generating tempest.conf via python-tempestconf"
(
    # shellcheck disable=SC1090
    source "${OPENRC}"
    cd "${TEMPEST_DIR}/tempest"
    # Generate then drop into etc/.
    "${venv}/bin/discover-tempest-config" \
        --out "${TEMPEST_DIR}/tempest/etc/tempest.conf" \
        --debug \
        --create \
        --image "${TEMPEST_IMAGE_URL}" \
        --network-id "$(openstack network show external-network -f value -c id 2>/dev/null || true)"
) 2>&1 | tee "${TEMPEST_DIR}/tempestconf.log" || \
    log "WARN: discover-tempest-config returned non-zero; check ${TEMPEST_DIR}/tempestconf.log"

# 5. Drop in exclude-list and accounts (use upstream tempest's default accounts shape).
if [[ -s "${EXCLUDE_LIST}" ]]; then
    cp "${EXCLUDE_LIST}" "${TEMPEST_DIR}/tempest/exclude-list.txt"
    log "exclude-list copied to ${TEMPEST_DIR}/tempest/exclude-list.txt"
fi

# 6. tox -e smoke --notest (sets up the venv but doesn't run yet). Uses
# upstream tempest's own tox.ini.
log_step "tox -e smoke --notest (bootstrap tempest tox venv)"
(
    cd "${TEMPEST_DIR}/tempest"
    # Propagate proxy if set; the venv install pulls deps from pypi.
    run_logged "tox -e smoke --notest" -- \
        env -i HOME="${HOME}" PATH="${PATH}" \
            http_proxy="${http_proxy:-}" https_proxy="${https_proxy:-}" \
            HTTP_PROXY="${HTTP_PROXY:-}" HTTPS_PROXY="${HTTPS_PROXY:-}" \
            NO_PROXY="${NO_PROXY:-}" no_proxy="${no_proxy:-}" \
            tox -e smoke --notest
)

# 7. Actually run smoke.
smoke_out="${TEMPEST_DIR}/smoke_output.txt"
log_step "tox -e smoke (full smoke run) -> ${smoke_out}"
rc=0
(
    cd "${TEMPEST_DIR}/tempest"
    if [[ -s exclude-list.txt ]]; then
        TEMPEST_FLAGS="--exclude-list exclude-list.txt"
    else
        TEMPEST_FLAGS=""
    fi
    # `tox -e smoke` resolves to upstream tempest's smoke env which runs
    # tagged smoke tests. Pass extra args through TOX_TESTENV_PASSENV.
    tox -e smoke -- ${TEMPEST_FLAGS} 2>&1 | tee "${smoke_out}"
) || rc=$?

# 8. Extract FAILED lines.
failures="${TEMPEST_DIR}/failures.txt"
grep -E '^FAILED|\{.*\}.*FAILED' "${smoke_out}" > "${failures}" || true
log_step "failures: $(wc -l < "${failures}") (see ${failures})"

# 9. Sidecar diagnostic dumps (zopenstack-style report/), Sunbeam-flavor.
log_step "writing diagnostic dumps to ${REPORT_DIR}"
(
    # shellcheck disable=SC1090
    source "${OPENRC}"
    set +e
    openstack catalog list                > "${REPORT_DIR}/catalog_list.txt"      2>&1
    openstack endpoint list               > "${REPORT_DIR}/endpoint_list.txt"     2>&1
    openstack image list                  > "${REPORT_DIR}/image_list.txt"        2>&1
    openstack network list                > "${REPORT_DIR}/network_list.txt"      2>&1
    openstack network agent list          > "${REPORT_DIR}/network_agent_list.txt" 2>&1
    openstack hypervisor list             > "${REPORT_DIR}/hypervisor_list.txt"   2>&1
    openstack server list --all-projects  > "${REPORT_DIR}/server_list.txt"       2>&1
    openstack volume list --all-projects  > "${REPORT_DIR}/volume_list.txt"       2>&1
    _ctrl="${JUJU_CONTROLLER:-sunbeam-controller}"
    juju status -m "${_ctrl}:openstack" --format=yaml > "${REPORT_DIR}/juju_status_openstack.txt" 2>&1
    juju status -m "${_ctrl}:machines"  --format=yaml > "${REPORT_DIR}/juju_status_machines.txt"  2>&1
)

if (( rc != 0 )); then
    log "tempest smoke returned ${rc}; see ${smoke_out} and ${failures}"
    echo "${rc}" > "${ARTIFACT_DIR}/.status/${PHASE}.failed"
fi

phase_done "${PHASE}"
log_step "phase ${PHASE} complete"
log "NEXT: re-run any single failing test with:"
log "  ./tools/run_tempest_test.sh '<test-regex>'"
log "e.g. ./tools/run_tempest_test.sh 'test_dashboard_basic_ops.TestDashboardBasicOps.test_basic_scenario'"
exit "${rc}"
