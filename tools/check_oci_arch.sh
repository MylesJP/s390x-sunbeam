#!/usr/bin/env bash
# Report whether an OCI image has an s390x manifest entry.
# Usage: check_oci_arch.sh <image-ref>
# Writes one row to arch_report.md and prints yes/no/unknown to stdout.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

image="${1:?image ref required, e.g. ghcr.io/canonical/keystone:2026.1-26.04_edge}"

if ! command -v skopeo >/dev/null 2>&1; then
    arch_report_append oci "${image}" "" unknown "skopeo not installed"
    echo unknown
    exit 0
fi

# Fetch raw manifest. For multi-arch images this is the index/manifest-list;
# for single-arch images it's the image manifest itself.
raw=$(skopeo inspect --raw "docker://${image}" 2>/dev/null || true)

if [[ -z "${raw}" ]]; then
    arch_report_append oci "${image}" "" unknown "skopeo inspect failed (unreachable or unauthorized)"
    echo unknown
    exit 0
fi

# Multi-arch manifest list: look for any manifest with architecture == s390x.
if grep -q '"manifests"' <<<"${raw}"; then
    if grep -qE '"architecture"[[:space:]]*:[[:space:]]*"s390x"' <<<"${raw}"; then
        arch_report_append oci "${image}" "" yes ""
        echo yes
    else
        archs=$(grep -oE '"architecture"[[:space:]]*:[[:space:]]*"[^"]+"' <<<"${raw}" | sort -u | tr '\n' ',' | sed 's/,$//')
        arch_report_append oci "${image}" "" no "manifests: ${archs}"
        echo no
    fi
    exit 0
fi

# Single-arch image: fall back to a non-raw inspect that surfaces Architecture.
single=$(skopeo inspect "docker://${image}" 2>/dev/null || true)
arch=$(grep -oE '"Architecture"[[:space:]]*:[[:space:]]*"[^"]+"' <<<"${single}" | head -n1 | sed -E 's/.*"([^"]+)"$/\1/')
if [[ "${arch}" == "s390x" ]]; then
    arch_report_append oci "${image}" "" yes "single-arch"
    echo yes
else
    arch_report_append oci "${image}" "" no "single-arch ${arch:-unknown}"
    echo no
fi
