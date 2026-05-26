# Sunbeam s390x single-node reproducer (2026.1 Gazpacho)

A set of idempotent shell scripts to deploy Sunbeam on a single Z LPAR against
the 2026.1/edge tracks, capture every architecture-availability signal along
the way, and run a core-only Tempest pass.

This is **diagnostic-first**: the scripts walk the documented install path,
record what worked and what didn't (including which snaps/OCI images have no
s390x build), and produce a tarball of artifacts whether or not the deployment
fully succeeds.

## Prerequisites

- Ubuntu 26.04 LTS (Resolute) on s390x
- A user with passwordless `sudo`
- Outbound internet (Snap Store, ghcr.io, charmhub)
- ~32 GB RAM, ~200 GB disk (single-node Sunbeam with hypervisor)
- `/dev/kvm` if you want Nova to actually launch instances

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
| `k8s` snap            | `1.32-classic/stable`  |
| `openstack-hypervisor`| `2026.1/edge`          |
| `juju` snap           | `3/stable`             |
| Core charms           | `2026.1/edge`          |
| `ovn-*-k8s` charms    | `26.03/edge`           |
| `microceph` snap      | `squid/stable`         |
