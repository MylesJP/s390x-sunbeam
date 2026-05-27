#!/usr/bin/env bash
# Phase 02b: bootstrap Canonical K8s with cilium disabled, install Calico from
# the vendored pe-ibm manifest, enable required addons and rewrite their image
# references to upstream registries that have s390x builds.
#
# Runs between phase 02 (snap install) and phase 03 (sunbeam cluster bootstrap)
# so that when Sunbeam attempts to bring k8s up, it finds a working cluster.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../tools/lib.sh
source "${SCRIPT_DIR}/../tools/lib.sh"

PHASE=02b_setup_s390x_cni
init_phase "${PHASE}"

phase_skip_if_done "${PHASE}" && exit 0

VENDOR_DIR="${REPO_ROOT}/vendor/pe-ibm"
CALICO_YAML="${VENDOR_DIR}/calico.yaml"

if [[ ! -s "${CALICO_YAML}" ]]; then
    log "FATAL: ${CALICO_YAML} missing. Run ./tools/refresh_pe_ibm.sh first to vendor it from canonical/pe-ibm-microk8s-validation."
    exit 1
fi

if ! command -v k8s >/dev/null 2>&1; then
    log "FATAL: 'k8s' CLI missing. Did phase 02 (sunbeam prepare-node-script) complete?"
    exit 1
fi

# 1. Write the k8s bootstrap config: disable the bundled CNI so Calico can
#    take over. pod-cidr and svc-cidr left as snap defaults; if the vendored
#    calico.yaml hard-codes a different pod CIDR you'll see calico pods fail
#    and need to add `pod-cidr` overrides here.
k8s_cfg="${ARTIFACT_DIR}/k8s-bootstrap.yaml"
log_step "writing ${k8s_cfg}"
cat > "${k8s_cfg}" <<'EOF'
cluster-config:
  network:
    enabled: false
EOF

# 2. Bootstrap k8s.
if sudo k8s status >/dev/null 2>&1; then
    log "k8s already bootstrapped; skipping bootstrap step"
else
    if ! run_logged "k8s bootstrap (cilium disabled)" -- sudo k8s bootstrap --file "${k8s_cfg}"; then
        log "FATAL: k8s bootstrap failed"
        exit 1
    fi
fi

# 3. Apply vendored Calico.
log_step "applying vendored Calico from ${CALICO_YAML}"
if ! run_logged "kubectl apply -f calico.yaml" -- sudo k8s kubectl apply -f "${CALICO_YAML}"; then
    log "FATAL: calico apply failed"
    exit 1
fi

log_step "waiting for calico pods Ready (up to 5 min)"
sudo k8s kubectl wait --for=condition=Ready pods -A -l k8s-app=calico-node --timeout=300s 2>&1 \
    | tee -a "${PHASE_LOG}" \
    || log "WARN: not all calico-node pods reached Ready"
sudo k8s kubectl wait --for=condition=Ready pods -A -l k8s-app=calico-kube-controllers --timeout=300s 2>&1 \
    | tee -a "${PHASE_LOG}" \
    || log "WARN: calico-kube-controllers did not reach Ready"

# 4. Enable required K8s addons and rewrite their images.
# Sunbeam typically needs: dns (coredns), local-storage, load-balancer, gateway.
# We enable conservatively; extend as Sunbeam's requirements firm up.
ADDONS=(dns local-storage load-balancer)
for addon in "${ADDONS[@]}"; do
    log_step "enabling addon: ${addon}"
    run_logged "k8s enable ${addon}" -- sudo k8s enable "${addon}" || \
        log "WARN: k8s enable ${addon} returned non-zero"
    # Even if enable failed, attempt rewrite -- the workloads may exist but be
    # CrashLooping due to image pulls.
    "${SCRIPT_DIR}/../tools/rewrite_k8s_addon_images.sh" "${addon}" || \
        log "WARN: rewrite_k8s_addon_images for ${addon} reported unmapped images"
done

# 5. Smoke-test: schedule an arbitrary s390x pod and confirm it reaches Ready.
log_step "smoke test: scheduling an ubuntu pod"
sudo k8s kubectl delete pod s390x-smoke --ignore-not-found
if sudo k8s kubectl run s390x-smoke --image=ubuntu --restart=Never --command -- sleep 30 2>&1 | tee -a "${PHASE_LOG}"; then
    if sudo k8s kubectl wait --for=condition=Ready pod/s390x-smoke --timeout=120s 2>&1 | tee -a "${PHASE_LOG}"; then
        log "smoke pod reached Ready -- pod networking and image pull work on this LPAR"
        arch_report_append k8s-smoke s390x-smoke ubuntu yes "scheduled+pulled+ready"
    else
        log "WARN: smoke pod did not reach Ready"
        sudo k8s kubectl describe pod s390x-smoke 2>&1 | tee -a "${PHASE_LOG}" || true
        arch_report_append k8s-smoke s390x-smoke ubuntu no "scheduled but not Ready -- see phase log"
    fi
    sudo k8s kubectl delete pod s390x-smoke --ignore-not-found
else
    arch_report_append k8s-smoke s390x-smoke ubuntu no "kubectl run failed"
fi

phase_done "${PHASE}"
log_step "phase ${PHASE} complete"
