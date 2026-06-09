# Sunbeam s390x single-node reproducer (2026.1 Gazpacho)

A set of idempotent shell scripts to deploy Sunbeam on a single Z LPAR against
the 2026.1/edge tracks, capture every architecture-availability signal along
the way, and run a core-only Tempest pass.

This is **diagnostic-first**: the scripts walk the documented install path,
record what worked and what didn't (including which snaps/OCI images have no
s390x build), and produce a tarball of artifacts whether or not the deployment
fully succeeds.

> **Realistic outcome:** Canonical K8s on s390x is not officially validated, and
> the OpenStack charm OCI images at `ghcr.io/canonical/...` are published from a
> pipeline that does not currently build z/power images. So the headline
> deliverable of a run is most often a precise per-image arch-availability
> report (`arch_report.md`) listing exactly what needs to be built or sourced
> from upstream before Sunbeam-on-s390x is viable. Tempest is best-effort
> downstream of that. See [K8s s390x prerequisites](#k8s-s390x-prerequisites)
> below for the workaround we use to get K8s itself up.

## Prerequisites

- Ubuntu 24.04 LTS (Noble) **or** 26.04 LTS (Resolute) on s390x. Sunbeam 2026.1
  publishes charm revisions for both bases, and K8s + Calico (phases 00, 02b)
  work identically on either.
- A user with passwordless `sudo`
- Outbound internet (Snap Store, ghcr.io, charmhub) — see "Behind a proxy" below
  if you're on a restricted-egress host
- ~32 GB RAM, ~200 GB disk (single-node Sunbeam with hypervisor)
- `/dev/kvm` if you want Nova to actually launch instances

## Behind a proxy

Set `PROXY_URL` in your shell before running anything, and the phase scripts
will configure shell env, `/etc/environment`, apt, snap, and the K8s snap's
containerd to use it (via [tools/setup_proxy.sh](tools/setup_proxy.sh)).
Verified on Canonical's ps6 LPARs:

```bash
export PROXY_URL=http://squid.ps6.internal:3128
./run.sh all
```

On ps6 the Squid allowlist also needs to cover the OCI registries
(`ghcr.io`, `docker.io`, `registry.k8s.io`, `quay.io`). The
`ps6_s390x_openstack` ACL in
[canonical-is-internal-proxy-configs](https://launchpad.net/canonical-is-internal-proxy-configs)
already covers special18-22 (10.103.192.218-.222). Other LPARs need a
follow-up MP adding their IPs to that ACL.

## Quickstart

```bash
cd deploy-s390x
./run.sh all
```

This creates `artifacts/<UTC-timestamp>/` and runs every phase in order. On
completion you get `artifacts/<run-id>/sunbeam-s390x-<run-id>.tar.zst`.

### Running a single phase

```bash
./run.sh 00          # just the host-fitness check
./run.sh 01          # just the snap install + s390x diagnostics
./run.sh --run-id 20260526T120000Z 03    # re-run bootstrap in an existing run dir
```

Phases are idempotent: each writes `.status/<phase>.done` and short-circuits on
re-run unless you delete the sentinel.

## Phases

| #  | Script                          | Does                                                                       |
|----|---------------------------------|----------------------------------------------------------------------------|
| 00 | `00_check_host.sh`              | Assert s390x + 26.04, dump env/network/KVM facts                           |
| 01 | `01_install_prereqs.sh`         | `snap install openstack`, s390x arch check for all required snaps          |
| 02 | `02_prepare_node.sh`            | Run `sunbeam prepare-node-script`, re-check installed snap archs           |
| 02b| `02b_setup_s390x_cni.sh`        | Bootstrap K8s (cilium disabled), apply Calico, rewrite addon images        |
| 03 | `03_bootstrap.sh`               | `sunbeam cluster bootstrap` with the 2026.1 manifest (core only)           |
| 04 | `04_configure.sh`               | `sunbeam configure --accept-defaults`                                      |
| 05 | `05_capture_state.sh`           | `juju export bundle`, `juju status`, k8s dump, OCI s390x check (always 0)  |
| 06 | `06_validate_tempest.sh`        | `sunbeam enable validation`, `sunbeam validation run smoke`                |
| 99 | `99_collect_artifacts.sh`       | Tar everything into `sunbeam-s390x-<run-id>.tar.zst`, print summary        |

In `./run.sh all` mode, a failure in 01–04 still proceeds to 05 + 99 so you
always get a post-mortem tarball.

## Key files

- [run.sh](run.sh) — entry point
- [manifests/sunbeam-2026.1-s390x.yaml](manifests/sunbeam-2026.1-s390x.yaml) —
  charm/snap pins. Regenerate the skeleton with `sunbeam manifest generate`
  before each release cycle and re-pin.
- [tools/lib.sh](tools/lib.sh) — logging + idempotency helpers
- [tools/check_snap_arch.sh](tools/check_snap_arch.sh) — `snap info` →
  s390x yes/no per channel
- [tools/check_oci_arch.sh](tools/check_oci_arch.sh) — `skopeo inspect --raw`
  → s390x manifest entry yes/no per image
- [tools/extract_oci_images.sh](tools/extract_oci_images.sh) — scrape image
  refs from the exported juju bundle
- [tools/refresh_pe_ibm.sh](tools/refresh_pe_ibm.sh) — re-vendor the calico
  manifest and coredns rewrite script from
  [canonical/pe-ibm-microk8s-validation](https://github.com/canonical/pe-ibm-microk8s-validation)
  (branch `c-k8s-and-calico-experimental`)
- [tools/rewrite_k8s_addon_images.sh](tools/rewrite_k8s_addon_images.sh) —
  patch a K8s addon's `ghcr.io/canonical/...` images to upstream registries
- [tools/setup_proxy.sh](tools/setup_proxy.sh) — configure HTTP proxy for env,
  apt, snap, and the K8s snap's containerd; idempotent, no-ops when
  `PROXY_URL`/`http_proxy` unset. Called automatically from phases 01 and 02b.
- [vendor/pe-ibm/](vendor/pe-ibm/) — pinned snapshot of the pe-ibm files used
  by phase 02b

## Artifact bundle contents

Each `artifacts/<run-id>/` contains:

- `env.txt` — host inventory from phase 00
- `phase_<N>_<name>.log` — per-phase timestamped output
- `arch_report.md` — s390x availability matrix for every snap and OCI image
  the deployment touched (this is the headline diagnostic)
- `juju_bundle.yaml` — `juju export bundle` output
- `juju_status.txt`, `juju_status_relations.txt`, `juju_status_watch.log`
- `k8s_resources.yaml`, `k8s_events.txt`, `k8s_nodes_describe.txt`
- `snaps.txt` — `snap list` + `snap info --verbose` per relevant snap
- `tempest_report.yaml` (if 06 ran) and `tempest_pod.log`
- `cloud-admin-openrc` (if 04 ran)
- `sunbeam-s390x-<run-id>.tar.zst` — bundled tarball

## Reset between runs

```bash
sudo sunbeam cluster remove --force || true
sudo snap remove --purge openstack openstack-hypervisor k8s juju || true
sudo rm -rf /var/snap/openstack* /var/snap/k8s* ~/snap/openstack
```

Then start fresh: `./run.sh all`.

## K8s s390x prerequisites

The Canonical K8s snap does not work out-of-the-box on s390x — its default CNI
(cilium) has no z/power build, and several of its bundled addon images at
`ghcr.io/canonical/...` are also not published for s390x. The Performance
Engineering / IBM Z alliances team has a working recipe captured in the
[canonical/pe-ibm-microk8s-validation](https://github.com/canonical/pe-ibm-microk8s-validation)
repo on branch `c-k8s-and-calico-experimental`.

Phase 02b encodes that recipe:

1. `sudo k8s bootstrap --file <cfg>` with `network.enabled: false` so cilium
   doesn't get installed.
2. `sudo k8s kubectl apply -f vendor/pe-ibm/calico.yaml` — the *patched* Calico
   manifest from pe-ibm (do not substitute upstream Calico; it needs the
   pe-ibm tweaks for the K8s snap's IPAM expectations).
3. `sudo k8s enable <addon>` for each addon Sunbeam needs (dns, local-storage,
   load-balancer at a minimum), followed by `tools/rewrite_k8s_addon_images.sh`
   which swaps each `ghcr.io/canonical/<x>` image to its upstream equivalent
   (e.g. `registry.k8s.io/coredns/coredns:v1.11.3`). The mapping table lives
   inside `tools/rewrite_k8s_addon_images.sh` — extend it as you find correct
   upstream images for additional addons.
4. A smoke pod (`kubectl run s390x-smoke --image=ubuntu ...`) confirms pod
   scheduling, image pull, and pod networking all work on this LPAR.

### Vendoring workflow

Before the first run, populate `vendor/pe-ibm/` from upstream:

```bash
./tools/refresh_pe_ibm.sh
```

This clones the upstream branch, copies `calico.yaml` and the coredns rewrite
script into `vendor/pe-ibm/`, and pins the commit SHA in `vendor/pe-ibm/COMMIT`.
Re-run when you want to pick up upstream changes; review the resulting `git
diff` before committing.

### Sunbeam ↔ pre-bootstrapped K8s

Phase 03 (`sunbeam cluster bootstrap`) may or may not gracefully detect the
K8s cluster 02b leaves behind. If it tries to re-bootstrap and fails, see the
comment block in [`manifests/sunbeam-2026.1-s390x.yaml`](manifests/sunbeam-2026.1-s390x.yaml)
for the mitigations to try in order. Whatever happens, record the exact error
in the phase log — that finding itself is valuable feedback to the Sunbeam
upstream team.

## Tempest scoping

The manifest enables only the **core** services (Keystone, Glance, Nova,
Neutron, Placement, Cinder, Horizon, OVN, MySQL, RabbitMQ, Traefik, TLS). No
`sunbeam enable {heat,octavia,magnum,barbican,...}` is invoked. Because of
that, `tempest-k8s` discovers only the core-service Tempest plugins and the
smoke run skips the feature-set suites (volume types beyond basic, share, LB,
orchestration, etc.).

If the smoke report shows `tempest.api.{share,load_balancer,orchestration}`
results, a feature was enabled somewhere — check phase 06's pod log.

## Channel pins (subject to change)

Reset these in `manifests/sunbeam-2026.1-s390x.yaml` and the `*_CHANNEL`
defaults in `scripts/01_install_prereqs.sh` if/when Sunbeam publishes 2026.1
to a non-edge risk level or you want to try a fallback cycle:

| Component             | Default                |
|-----------------------|------------------------|
| `openstack` snap      | `2026.1/edge`          |
| `k8s` snap            | `latest/edge`          |
| `openstack-hypervisor`| `2026.1/edge`          |
| `juju` snap           | `3/stable`             |
| Core charms           | `2026.1/edge`          |
| `ovn-*-k8s` charms    | `26.03/edge`           |
| `microceph` snap      | `squid/stable`         |
