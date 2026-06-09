#!/usr/bin/env bash
# Configure HTTP proxy across all the places that matter for a Sunbeam/K8s
# deploy: shell env, /etc/environment, apt, snap, and (if installed) the
# K8s snap's k8sd systemd unit. Idempotent.
#
# Driven by $PROXY_URL (preferred) or $http_proxy. If neither is set the
# script logs that and exits 0 so it's safe to call unconditionally from
# phase scripts on hosts that don't need a proxy.
#
# Usage: PROXY_URL=http://squid.ps6.internal:3128 ./tools/setup_proxy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

PROXY_URL="${PROXY_URL:-${http_proxy:-}}"
NO_PROXY_VAL="${NO_PROXY_DEFAULT:-localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.cluster.local}"

if [[ -z "${PROXY_URL}" ]]; then
    log "no PROXY_URL or http_proxy set; nothing to configure"
    exit 0
fi

log_step "configuring proxy: ${PROXY_URL}"

# 1. /etc/environment -- so every new login + systemd unit picks it up.
if ! grep -qxF "https_proxy=${PROXY_URL}" /etc/environment 2>/dev/null; then
    log_step "writing proxy env to /etc/environment"
    sudo tee -a /etc/environment >/dev/null <<EOF
http_proxy=${PROXY_URL}
https_proxy=${PROXY_URL}
HTTP_PROXY=${PROXY_URL}
HTTPS_PROXY=${PROXY_URL}
no_proxy=${NO_PROXY_VAL}
NO_PROXY=${NO_PROXY_VAL}
EOF
fi

# 2. apt -- needed for any apt-get install during phase 01.
apt_conf=/etc/apt/apt.conf.d/95proxy
if [[ ! -f "${apt_conf}" ]] || ! grep -qF "${PROXY_URL}" "${apt_conf}"; then
    log_step "writing apt proxy config to ${apt_conf}"
    sudo tee "${apt_conf}" >/dev/null <<EOF
Acquire::http::Proxy "${PROXY_URL}";
Acquire::https::Proxy "${PROXY_URL}";
EOF
fi

# 3. snap -- the Snap Store and snap downloads.
current_http=$(sudo snap get system proxy.http 2>/dev/null || true)
if [[ "${current_http}" != "${PROXY_URL}" ]]; then
    log_step "configuring snap proxy"
    sudo snap set system proxy.http="${PROXY_URL}"
    sudo snap set system proxy.https="${PROXY_URL}"
    sudo systemctl restart snapd
fi

# 4. K8s snap's k8sd unit -- containerd inside k8sd needs the proxy for
# image pulls. Only relevant once the k8s snap is installed; safe to skip
# otherwise.
if systemctl list-unit-files 'snap.k8s.k8sd.service' 2>/dev/null | grep -q snap.k8s.k8sd.service; then
    drop_in_dir=/etc/systemd/system/snap.k8s.k8sd.service.d
    drop_in="${drop_in_dir}/proxy.conf"
    if [[ ! -f "${drop_in}" ]] || ! grep -qF "${PROXY_URL}" "${drop_in}"; then
        log_step "writing k8sd proxy drop-in to ${drop_in}"
        sudo mkdir -p "${drop_in_dir}"
        sudo tee "${drop_in}" >/dev/null <<EOF
[Service]
Environment="HTTP_PROXY=${PROXY_URL}"
Environment="HTTPS_PROXY=${PROXY_URL}"
Environment="NO_PROXY=${NO_PROXY_VAL}"
EOF
        sudo systemctl daemon-reload
        sudo systemctl restart snap.k8s.k8sd.service
    fi
else
    log "k8s snap not installed yet; skipping k8sd systemd drop-in"
fi

log_step "proxy setup complete"
