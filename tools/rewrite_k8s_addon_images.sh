#!/usr/bin/env bash
# Rewrite a K8s addon's image references from ghcr.io/canonical/... to an
# upstream registry that has s390x builds. Required because the Canonical K8s
# snap's bundled addon images aren't published for z/power.
#
# Usage: rewrite_k8s_addon_images.sh <addon-name>
#
# Seeded from vendor/pe-ibm/rewrite-coredns.sh; extend the IMAGE_MAP below as
# you learn the correct upstream image for each addon Sunbeam needs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

addon="${1:?addon name required, e.g. coredns, metrics-server, local-storage}"

# Mapping: ghcr.io/canonical/<X> -> upstream replacement
# Update as we learn each addon's correct upstream image + tag.
declare -A IMAGE_MAP=(
    ["ghcr.io/canonical/coredns"]="registry.k8s.io/coredns/coredns:v1.11.3"
    ["ghcr.io/canonical/metrics-server"]="registry.k8s.io/metrics-server/metrics-server:v0.7.2"
    # Add as discovered:
    #   ["ghcr.io/canonical/local-path-provisioner"]="docker.io/rancher/local-path-provisioner:v0.0.30"
    #   ["ghcr.io/canonical/cert-manager-controller"]="quay.io/jetstack/cert-manager-controller:v1.16.1"
)

# Namespace each addon lives in (best-effort defaults; the script also tries -A).
declare -A ADDON_NAMESPACE=(
    [coredns]="kube-system"
    [metrics-server]="kube-system"
    [local-storage]="kube-system"
    [load-balancer]="metallb-system"
)

if ! command -v sudo >/dev/null 2>&1 || ! sudo k8s kubectl version --client >/dev/null 2>&1; then
    log "FATAL: 'sudo k8s kubectl' not working; cannot rewrite addon images"
    exit 1
fi

ns="${ADDON_NAMESPACE[${addon}]:-}"
ns_flag="-A"
[[ -n "${ns}" ]] && ns_flag="-n ${ns}"

log_step "scanning ${addon} workloads (${ns_flag}) for ghcr.io/canonical/* images"

# Collect (kind, namespace, name, container, image) tuples for every workload
# currently using a ghcr.io/canonical/* image. Strict whitespace separation so
# we can `read` the columns back safely.
mapfile -t hits < <(
    # shellcheck disable=SC2086
    sudo k8s kubectl get ${ns_flag} deployments,daemonsets,statefulsets -o json 2>/dev/null \
      | python3 -c '
import json, sys
data = json.load(sys.stdin)
for item in data.get("items", []):
    kind = item["kind"].lower()
    ns_ = item["metadata"]["namespace"]
    name = item["metadata"]["name"]
    for ctr in item["spec"]["template"]["spec"].get("containers", []):
        img = ctr.get("image", "")
        if img.startswith("ghcr.io/canonical/"):
            print(f"{kind} {ns_} {name} {ctr['"'"'name'"'"']} {img}")
' || true
)

if (( ${#hits[@]} == 0 )); then
    log "no ghcr.io/canonical/* images found for addon ${addon}; nothing to rewrite"
    arch_report_append k8s-addon "${addon}" "" yes "no rewrite needed"
    exit 0
fi

rewrote=0
unmapped=0
for line in "${hits[@]}"; do
    read -r kind w_ns w_name container image <<<"${line}"
    # Strip the tag to look up the base.
    base="${image%:*}"
    target="${IMAGE_MAP[${base}]:-}"
    if [[ -z "${target}" ]]; then
        log "UNMAPPED: ${kind}/${w_name} container=${container} image=${image} -- add to IMAGE_MAP"
        arch_report_append k8s-addon "${w_name}/${container}" "${image}" no "no upstream mapping defined; edit rewrite_k8s_addon_images.sh"
        unmapped=$((unmapped + 1))
        continue
    fi
    log_step "rewriting ${kind}/${w_name} container=${container}: ${image} -> ${target}"
    sudo k8s kubectl -n "${w_ns}" set image "${kind}/${w_name}" "${container}=${target}"
    arch_report_append k8s-addon "${w_name}/${container}" "${target}" yes "rewritten from ${base}"
    rewrote=$((rewrote + 1))
done

log "addon ${addon}: rewrote ${rewrote} container(s), ${unmapped} unmapped"
exit $(( unmapped > 0 ? 2 : 0 ))
