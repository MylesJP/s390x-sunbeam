#!/usr/bin/env bash
# Phase 03b: deploy the MACHINE plane (hypervisor + cinder-volume + microceph +
# sunbeam-machine) into a second Juju model on a MANUAL cloud whose only machine
# is this LPAR, and wire it to the control plane via cross-model offers.
#
# Runs after phase 03 (control-plane bundle + its offers must already exist).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../tools/lib.sh
source "${SCRIPT_DIR}/../tools/lib.sh"

PHASE=03b_deploy_machine_plane
init_phase "${PHASE}"

phase_skip_if_done "${PHASE}" && exit 0

# Manual-machine provisioning downloads the Juju agent stream from the client
# shell before the machine exists. Keep that request off a proxy which rejects
# streams.canonical.com.
if [[ -n "${PROXY_URL:-}" && -n "${NO_PROXY_DEFAULT:-}" ]]; then
    export NO_PROXY="${NO_PROXY_DEFAULT}"
    export no_proxy="${NO_PROXY_DEFAULT}"
    log "using NO_PROXY=${NO_PROXY_DEFAULT} for Juju agent stream access"
fi

CONTROLLER="${JUJU_CONTROLLER:-sunbeam-controller}"
K8S_MODEL="${K8S_MODEL:-openstack}"
MACHINE_MODEL="${MACHINE_MODEL:-machines}"
MANUAL_CLOUD="${MANUAL_CLOUD:-lpar-manual}"
# Charm source: 'charmhub' (default) or 'local' (our s390x .charm builds from
# ./charms, via the *-local.yaml bundle). Explicit BUNDLE=... override still wins.
CHARM_SOURCE="${CHARM_SOURCE:-charmhub}"
case "${CHARM_SOURCE}" in
    charmhub) _m_bundle="machine-lpar-s390x.yaml" ;;
    local)    _m_bundle="machine-lpar-s390x-local.yaml" ;;
    hybrid)
        python3 "${REPO_ROOT}/tools/render_hybrid_bundles.py" \
            --repo "${REPO_ROOT}" --output-dir "${ARTIFACT_DIR}"
        _m_bundle="${ARTIFACT_DIR}/machine-lpar-s390x-hybrid.yaml"
        ;;
    *) log "FATAL: CHARM_SOURCE must be 'charmhub', 'hybrid', or 'local' (got '${CHARM_SOURCE}')"; exit 2 ;;
esac
if [[ "${_m_bundle}" = /* ]]; then
    BUNDLE="${BUNDLE:-${_m_bundle}}"
else
    BUNDLE="${BUNDLE:-${REPO_ROOT}/manifests/${_m_bundle}}"
fi
DEPLOY_TIMEOUT="${DEPLOY_TIMEOUT:-3600}"
ARCH="$(target_arch)"

if [[ ! -r "${BUNDLE}" ]]; then
    log "FATAL: machine bundle missing at ${BUNDLE}"
    exit 1
fi
command -v juju >/dev/null 2>&1 || { log "FATAL: juju CLI missing"; exit 1; }
if ! juju controllers --format=json 2>/dev/null | jq -e ".controllers | has(\"${CONTROLLER}\")" >/dev/null 2>&1; then
    log "FATAL: controller ${CONTROLLER} not found. Run phase 03 first."
    exit 1
fi

# SSH target for the manual machine = this LPAR (recorded by phase 02).
host_ip="$(cat "${ARTIFACT_DIR}/manual_host_ip" 2>/dev/null || true)"
if [[ -z "${host_ip}" ]]; then
    host_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
    host_ip="${host_ip:-127.0.0.1}"
    echo "${host_ip}" > "${ARTIFACT_DIR}/manual_host_ip"
fi
ssh_user="$(id -un)"
ssh_target="${ssh_user}@${host_ip}"
ssh-keyscan -H "${host_ip}" >> "${HOME}/.ssh/known_hosts" 2>>"${PHASE_LOG}" || true
cloud_yaml="${ARTIFACT_DIR}/manual-cloud.yaml"
cat > "${cloud_yaml}" <<EOF
clouds:
  ${MANUAL_CLOUD}:
    type: manual
    endpoint: ${ssh_target}
    regions:
      default: {}
EOF

# 1. Register a manual cloud pointing at this LPAR, on the existing controller.
if juju clouds --client 2>/dev/null | grep -qw "${MANUAL_CLOUD}"; then
    log "manual cloud ${MANUAL_CLOUD} already registered with juju client"
else
    log_step "adding manual cloud ${MANUAL_CLOUD} to client (endpoint ${ssh_target})"
    run_logged "juju add-cloud (client)" -- juju add-cloud --client "${MANUAL_CLOUD}" "${cloud_yaml}"
fi

if juju clouds --controller "${CONTROLLER}" 2>/dev/null | grep -qw "${MANUAL_CLOUD}"; then
    log "manual cloud ${MANUAL_CLOUD} already registered with controller ${CONTROLLER}"
else
    log_step "adding manual cloud ${MANUAL_CLOUD} to controller ${CONTROLLER}"
    run_logged "juju add-cloud (controller)" -- \
        juju add-cloud --controller "${CONTROLLER}" --force "${MANUAL_CLOUD}" "${cloud_yaml}" || \
        log "WARN: add-cloud to controller returned non-zero (may already be known)"
fi

# 2. Add the machine model on the manual cloud.
if juju models --format=json 2>/dev/null | jq -e ".models[] | select(.\"short-name\"==\"${MACHINE_MODEL}\")" >/dev/null 2>&1; then
    log "model ${MACHINE_MODEL} already exists"
else
    run_logged "juju add-model ${MACHINE_MODEL}" -- \
        juju add-model "${MACHINE_MODEL}" "${MANUAL_CLOUD}"
fi

run_logged "set ${MACHINE_MODEL} architecture constraint" -- \
    juju set-model-constraints -m "${CONTROLLER}:${MACHINE_MODEL}" "arch=${ARCH}"

if [[ -n "${PROXY_URL:-}" ]]; then
    NO_PROXY_VAL="${NO_PROXY_DEFAULT:-localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.cluster.local}"
    run_logged "configure Juju proxy (${MACHINE_MODEL})" -- \
        juju model-config -m "${CONTROLLER}:${MACHINE_MODEL}" \
            "juju-http-proxy=${PROXY_URL}" "juju-https-proxy=${PROXY_URL}" \
            "apt-http-proxy=${PROXY_URL}" "apt-https-proxy=${PROXY_URL}" \
            "snap-http-proxy=${PROXY_URL}" "snap-https-proxy=${PROXY_URL}" \
            "juju-no-proxy=${NO_PROXY_VAL}" "apt-no-proxy=${NO_PROXY_VAL}"
fi

# 3. Enrol this LPAR as machine 0 (manual provisioning over SSH). The first
#    machine added to an empty model becomes "0", which the bundle targets.
machine_count=$(juju machines -m "${CONTROLLER}:${MACHINE_MODEL}" --format=json 2>/dev/null \
    | jq '.machines | length' 2>/dev/null || echo 0)
if [[ "${machine_count}" == "0" ]]; then
    log_step "enrolling ${ssh_target} as machine 0 of ${MACHINE_MODEL}"
    if ! run_logged "juju add-machine ssh" -- \
            juju add-machine -m "${CONTROLLER}:${MACHINE_MODEL}" "ssh:${ssh_target}"; then
        log "FATAL: juju add-machine ssh:${ssh_target} failed. Check key-based SSH + passwordless sudo (phase 02)."
        exit 1
    fi
else
    log "machine model already has ${machine_count} machine(s); skipping add-machine"
fi

# 4. Deploy the machine bundle. Its saas: block consumes the control-plane offers
#    (admin/${K8S_MODEL}.*) created in phase 03.
log_step "deploying machine bundle (source=${CHARM_SOURCE}) into ${MACHINE_MODEL}: ${BUNDLE}"
# Deploy from the repo root so a 'local' bundle's `charm: ./charms/...` paths
# resolve (harmless for the charmhub bundle, which uses an absolute path).
cd "${REPO_ROOT}"
rc=0
run_logged "juju deploy machine bundle" -- \
    juju deploy -m "${CONTROLLER}:${MACHINE_MODEL}" "${BUNDLE}" \
        --map-machines=existing,0=0 || rc=$?
if (( rc != 0 )); then
    log "WARN: juju deploy (machine) returned ${rc}. Phase 05 will still capture state."
    echo "${rc}" > "${ARTIFACT_DIR}/.status/${PHASE}.failed"
    exit "${rc}"
fi

if [[ -n "${EXTERNAL_BRIDGE_ADDRESS:-}" ]]; then
    log_step "configuring routed provider bridge address ${EXTERNAL_BRIDGE_ADDRESS}"
    run_logged "configure hypervisor external bridge" -- \
        juju config -m "${CONTROLLER}:${MACHINE_MODEL}" hypervisor \
            "external-bridge-address=${EXTERNAL_BRIDGE_ADDRESS}"
fi

# 5. Wire the reverse offer: cinder-volume (machine model) exports
#    `storage-backend`; cinder-k8s (control plane) consumes it. The control-plane
#    bundle couldn't declare this saas because the offer didn't exist at phase 03.
log_step "consuming storage-backend offer into ${K8S_MODEL} and integrating with cinder"
if ! juju status -m "${CONTROLLER}:${K8S_MODEL}" --format=json 2>/dev/null \
        | jq -e '.["application-endpoints"]["storage-backend"] // .applications["storage-backend"]' >/dev/null 2>&1; then
    run_logged "juju consume storage-backend" -- \
        juju consume -m "${CONTROLLER}:${K8S_MODEL}" "admin/${MACHINE_MODEL}.storage-backend" storage-backend || \
        log "WARN: consume storage-backend failed (offer not ready yet?)"
fi
run_logged "juju integrate cinder:storage-backend" -- \
    juju integrate -m "${CONTROLLER}:${K8S_MODEL}" cinder:storage-backend storage-backend || \
    log "WARN: integrate cinder:storage-backend failed (will need a manual retry once cinder-volume is up)"

# 6. Wait for the machine plane to settle (blocks on missing s390x snaps are
#    expected and captured by phase 05).
log_step "waiting up to ${DEPLOY_TIMEOUT}s for ${MACHINE_MODEL} to settle"
juju_wait_settle "${CONTROLLER}:${MACHINE_MODEL}" "${DEPLOY_TIMEOUT}" || true

phase_done "${PHASE}"
log_step "phase ${PHASE} complete"
log "NEXT: ./run.sh 04 to configure the cloud (openrc + external network + image + flavors)."
