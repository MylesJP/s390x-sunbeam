# Sunbeam s390x single-LPAR core-charm verifier (2026.1 Gazpacho)

A set of idempotent shell scripts that deploy the **core Sunbeam charms** on a
single Z LPAR **as plain Juju bundles** (no `sunbeam` CLI), capture every
architecture-availability signal along the way, and run an upstream Tempest pass.

This is **diagnostic-first**: the scripts bring up Canonical K8s, deploy two Juju
bundles (a K8s control plane + a machine plane), and record what worked and what
didn't (including which snaps/OCI images have no s390x build), producing a tarball
of artifacts whether or not the deployment fully succeeds.

> **Why bundles instead of `sunbeam`?** The Sunbeam CLI couples the whole exercise
> to snap-openstack working end-to-end on s390x — exactly the thing that isn't ready
> — so it obscures whether the *charms themselves* work. Deploying the charms
> directly with `juju deploy <bundle>` lets us verify the core charms and feed
> precise per-image/per-snap arch gaps back upstream.

> **Realistic outcome:** Canonical K8s on s390x is not officially validated, and the
> OpenStack charm OCI images at `ghcr.io/canonical/...` plus the machine-side snaps
> (`openstack-hypervisor`, `microceph`, `cinder-volume`) are published from pipelines
> that do not all build z/power artifacts yet. So the headline deliverable of a run
> is most often a precise arch-availability report (`arch_report.md`) listing exactly
> what needs to be built before Sunbeam-on-s390x is viable. Tempest is best-effort
> downstream of that. See [K8s s390x prerequisites](#k8s-s390x-prerequisites) below.

## What gets deployed

Two Juju models on one controller (mirrors how Sunbeam splits things internally):

- **`openstack`** — a CAAS model on the Canonical K8s cloud, from
  [manifests/control-plane-k8s-s390x.yaml](manifests/control-plane-k8s-s390x.yaml):
  `mysql`, `rabbitmq`, `self-signed-certificates`, `traefik`, `ovn-central`,
  `ovn-relay`, `keystone`, `glance`, `placement`, `nova`, `neutron`, `cinder`
  (+`cinder-router`). Exports cross-model **offers** (amqp, identity-*, send-ca-cert,
  ovsdb-cms, certificates, nova-service, cinder-database).
- **`machines`** — an IAAS model on a **manual** cloud whose machine `0` is this LPAR,
  from [manifests/machine-lpar-s390x.yaml](manifests/machine-lpar-s390x.yaml):
  `sunbeam-machine`, `openstack-hypervisor`, `microceph`, `cinder-volume`,
  `cinder-volume-ceph`. Consumes the control-plane offers and exports
  `storage-backend` back to `cinder`.

The set mirrors the previous charmed-OpenStack LPAR validation bundle
([zopenstack noble-flamingo-edge](https://github.com/ubuntu-openstack/zopenstack/blob/main/bundles/lpar/noble-flamingo-edge.yaml))
— keystone/glance/nova/neutron/placement/cinder + a real compute hypervisor + ceph
block storage — but with the Sunbeam charms. **No feature charms** (horizon, heat,
octavia, magnum, manila, barbican, designate, ironic, telemetry, object storage). And
**no `tempest-k8s`** in the bundle: that charm has no s390x OCI image, so Tempest runs
via upstream `tox` (phase 06) instead.

## Runs on amd64 too (dry-run)

The whole workflow is arch-aware and also runs on **amd64**, so you can shake out
the orchestration while s390x artifacts are still publishing. The deploy
architecture is auto-detected (`dpkg --print-architecture`) and overridable with
`TARGET_ARCH`. The only real difference is phase 02b:

- **s390x** — bootstraps K8s with cilium disabled, installs the vendored pe-ibm
  Calico, and rewrites addon images to upstream registries (cilium + several
  `ghcr.io/canonical` addon images have no z/power build).
- **amd64** — bootstraps stock Canonical K8s (cilium enabled), no Calico, no image
  rewrites.

Everything else (juju bootstrap, the two bundles, configure, tempest) is identical;
the bundles carry no `arch:` constraints so Juju picks the right charm revisions,
and phase 04 selects the matching Ubuntu cloud image (`...-cloudimg-<arch>.img`) and
glance `architecture` property automatically. On amd64 the `arch_report.md` rows
will all read `yes (amd64)`; the s390x gap discovery happens when you run on the
actual LPAR.

## Prerequisites

- Ubuntu 24.04 LTS (Noble) **or** 26.04 LTS (Resolute), on s390x **or** amd64.
- A user with passwordless `sudo` **and** key-based SSH back to the host (phase 02
  sets this up — it's needed to enrol the LPAR as a Juju manual machine).
- Outbound internet (Snap Store, ghcr.io, docker.io, charmhub) — see "Behind a proxy".
- ~32 GB RAM, ~200 GB disk.
- `/dev/kvm` (s390x KVM) for Nova to actually launch instances. Phase 02 records
  whether it's present.

## Behind a proxy

Set `PROXY_URL` before running anything; the phase scripts configure shell env,
`/etc/environment`, apt, snap, and the K8s snap's containerd via
[tools/setup_proxy.sh](tools/setup_proxy.sh):

```bash
export PROXY_URL=http://squid.ps6.internal:3128
./run.sh all
```

On ps6 the Squid allowlist must cover the OCI registries (`ghcr.io`, `docker.io`,
`registry.k8s.io`, `quay.io`). The `ps6_s390x_openstack` ACL in
[canonical-is-internal-proxy-configs](https://launchpad.net/canonical-is-internal-proxy-configs)
already covers special18-22 (10.103.192.218-.222); other LPARs need a follow-up MP.

## Quickstart

```bash
cd s390x-sunbeam
./run.sh all
```

This creates `artifacts/<UTC-timestamp>/`, runs every phase in order, and on
completion gives `artifacts/<run-id>/sunbeam-s390x-<run-id>.tar.zst`.

### Running a single phase

```bash
./run.sh 00          # host-fitness check
./run.sh 02b         # K8s + Calico bring-up
./run.sh 03          # control-plane bundle deploy
./run.sh 03b         # machine-plane bundle deploy
./run.sh --run-id 20260617T120000Z 04   # re-run configure in an existing run dir
```

Phases are idempotent: each writes `.status/<phase>.done` and short-circuits on
re-run unless you delete the sentinel.

## Phases

| #   | Script                          | Does                                                                                  |
|-----|---------------------------------|---------------------------------------------------------------------------------------|
| 00  | `00_check_host.sh`              | Assert s390x + Ubuntu, dump env/network/KVM facts                                     |
| 01  | `01_install_prereqs.sh`         | `snap install juju`; s390x arch check for juju/k8s/hypervisor/microceph/cinder-volume |
| 02  | `02_prepare_node.sh`            | Host prep (kernel modules, `/dev/kvm` check) + key-based SSH-to-self for manual cloud |
| 02b | `02b_setup_s390x_cni.sh`        | Bootstrap K8s (cilium disabled), apply Calico, rewrite addon images, **configure LB pool** |
| 03  | `03_bootstrap.sh`               | `juju add-k8s` + `bootstrap` + `add-model openstack` + deploy control-plane bundle    |
| 03b | `03b_deploy_machine_plane.sh`   | Manual cloud + `machines` model + enrol LPAR as machine 0 + deploy machine bundle + wire `storage-backend` |
| 04  | `04_configure.sh`               | openrc via `keystone get-admin-account`; external network, flavors, s390x image (openstack CLI) |
| 05  | `05_capture_state.sh`           | Per-model `juju export bundle`/`status`/`offers`, k8s dump, OCI/snap s390x sweep       |
| 06  | `06_validate_tempest.sh`        | Upstream tempest: `discover-tempest-config` → `tempest.conf`, `tox -e smoke`, failures |
| 99  | `99_collect_artifacts.sh`       | Tar everything into `sunbeam-s390x-<run-id>.tar.zst`, print summary                   |

In `./run.sh all` mode, a failure in 01–04 still proceeds through 05 + 99 so you
always get a post-mortem tarball.

## Key files

- [run.sh](run.sh) — entry point (LC_ALL=C sort runs `03` before `03b`, `02` before `02b`)
- [manifests/control-plane-k8s-s390x.yaml](manifests/control-plane-k8s-s390x.yaml) —
  K8s control-plane bundle + cross-model offers
- [manifests/machine-lpar-s390x.yaml](manifests/machine-lpar-s390x.yaml) — machine-plane
  bundle (consumes offers, exports `storage-backend`)
- [tools/lib.sh](tools/lib.sh) — logging, idempotency, `juju_wait_settle`, arch-report helpers
- [tools/check_snap_arch.sh](tools/check_snap_arch.sh) / [tools/check_oci_arch.sh](tools/check_oci_arch.sh) —
  s390x availability per snap channel / per OCI image
- [tools/extract_oci_images.sh](tools/extract_oci_images.sh) — scrape image refs from the exported bundle
- [tools/refresh_pe_ibm.sh](tools/refresh_pe_ibm.sh) — re-vendor the Calico manifest + coredns rewrite
  from [canonical/pe-ibm-microk8s-validation](https://github.com/canonical/pe-ibm-microk8s-validation)
- [tools/rewrite_k8s_addon_images.sh](tools/rewrite_k8s_addon_images.sh) — patch addon
  `ghcr.io/canonical/...` images to upstream registries with s390x builds
- [tools/run_tempest_test.sh](tools/run_tempest_test.sh) — re-run a single tempest test
- [vendor/pe-ibm/](vendor/pe-ibm/), [vendor/zopenstack/](vendor/zopenstack/) — pinned snapshots

> The old `manifests/sunbeam-2026.1-s390x.yaml` was a *Sunbeam manifest* for the
> retired CLI path; it's kept only as a channel-pin reference. The live channel pins
> now live in the two bundle files.

## Useful environment overrides

| Variable | Default | Used by |
|----------|---------|---------|
| `TARGET_ARCH` | `dpkg --print-architecture` (amd64/s390x) | all (CNI path, arch checks, guest image) |
| `PROXY_URL` | unset | all (proxy setup) |
| `LB_CIDR` | derived `<host /24>.240-.250` | 02b load-balancer pool |
| `K8S_CHANNEL` | `latest/edge` | 01/02b |
| `JUJU_CHANNEL` | `3/stable` | 01 |
| `JUJU_CONTROLLER` / `K8S_MODEL` / `MACHINE_MODEL` / `MANUAL_CLOUD` | `sunbeam-controller` / `openstack` / `machines` / `lpar-manual` | 03/03b/04/05/06 |
| `DEPLOY_TIMEOUT` | `3600` | 03/03b settle wait |
| `EXT_NET_NAME` / `EXT_SUBNET_RANGE` / `EXT_SUBNET_GW` / `EXT_SUBNET_POOL` / `EXT_PHYSNET` | external-network / 172.16.2.0/24 / .1 / .50-.200 / physnet1 | 04 |
| `IMAGE_URL` | noble s390x cloud image | 04 |

## Artifact bundle contents

Each `artifacts/<run-id>/` contains:

- `env.txt`, `arch_report.md` (the headline s390x availability matrix)
- `phase_<N>_<name>.log` — per-phase timestamped output
- `juju_bundle_<model>.yaml`, `juju_status_<model>.txt`, `juju_status_relations_<model>.txt`, `juju_offers.txt`
- `juju_status_watch.log` — background status during deploy
- `k8s_resources.yaml`, `k8s_events.txt`, `k8s_nodes_describe.txt`, `snaps.txt`
- `manual-cloud.yaml`, `manual_host_ip`, `lb_cidr`, `get-admin-account.json`
- `cloud-admin-openrc`, `ca_bundle.pem` (if 04 ran)
- `tempest/` + `tempest_report/` (if 06 ran)
- `sunbeam-s390x-<run-id>.tar.zst`

## Load-balancer (most likely stall point)

`traefik-k8s` needs an external `LoadBalancer` IP, or keystone's `public_endpoint`
(hence the openrc `OS_AUTH_URL`) never resolves and phase 04/06 are unusable. Phase
02b enables the Canonical K8s load-balancer addon and sets an L2 pool (`LB_CIDR`). The
bundle's traefik `metallb.universe.tf/address-pool=public` annotation is a no-op for
that addon — we rely on the addon's own pool. If the addon's L2 announcer (Cilium
based) does not function under Calico on your LPAR, install MetalLB and create a pool
named `public` to match the annotation. Verify with `sudo k8s kubectl get svc -A`
before trusting phase 04.

## Reset between runs

```bash
juju destroy-controller sunbeam-controller --destroy-all-models --no-prompt || true
juju remove-cloud lpar-manual --client || true
juju remove-cloud sunbeam-k8s --client || true
sudo k8s kubectl delete pod s390x-smoke --ignore-not-found || true
sudo snap remove --purge k8s juju openstack-hypervisor microceph cinder-volume || true
sudo rm -rf /var/snap/k8s ~/.local/share/juju
```

Then start fresh: `./run.sh all`.

## K8s s390x prerequisites

The Canonical K8s snap does not work out-of-the-box on s390x — its default CNI
(cilium) has no z/power build, and several bundled addon images at
`ghcr.io/canonical/...` are also not published for s390x. The Performance Engineering /
IBM Z alliances team has a working recipe in
[canonical/pe-ibm-microk8s-validation](https://github.com/canonical/pe-ibm-microk8s-validation)
(branch `c-k8s-and-calico-experimental`). Phase 02b encodes it:

1. `sudo k8s bootstrap --file <cfg>` with `network.enabled: false` (no cilium).
2. `sudo k8s kubectl apply -f vendor/pe-ibm/calico.yaml` — the *patched* Calico manifest.
3. `sudo k8s enable <addon>` for dns, local-storage, load-balancer, then
   `tools/rewrite_k8s_addon_images.sh` swaps each `ghcr.io/canonical/<x>` image to its
   upstream s390x-capable equivalent.
4. A smoke pod confirms scheduling, image pull, and pod networking on the LPAR.

### Vendoring workflow

Before the first run, populate `vendor/pe-ibm/`:

```bash
./tools/refresh_pe_ibm.sh
```

## Tempest

Phase 06 follows the [zopenstack](https://github.com/ubuntu-openstack/zopenstack)
workflow shape (`tox -e smoke --notest`, full smoke run, `grep FAILED`, per-test
re-runs) with two Sunbeam-appropriate substitutions:

1. **`tempest.conf` is generated by upstream `python-tempestconf`** against the live
   cloud via the openrc phase 04 produced — no charmed-OpenStack template.
2. **No K8s-charm-specific bits.** Per-service diagnostics use the openrc +
   `openstack` CLI instead of parsing `juju status keystone`.

With compute + block storage deployed, full smoke (boot an instance, create a volume)
is meaningful. We vendor only the **exclude-list** from zopenstack (under
[vendor/zopenstack/](vendor/zopenstack/)); re-evaluate those keystone-policy
exclusions for keystone-k8s after the first run.

### Re-running a single test

```bash
./tools/run_tempest_test.sh 'test_dashboard_basic_ops.TestDashboardBasicOps.test_basic_scenario'
```

Defaults to the most recent run-id; pass `--run-id <id>` to target a specific one.

## Channel pins (subject to change)

Set in the two bundle files (and the `*_CHANNEL` defaults in
[scripts/01_install_prereqs.sh](scripts/01_install_prereqs.sh)) if Sunbeam publishes
2026.1 to a non-edge risk level.

| Component             | Default                |
|-----------------------|------------------------|
| `juju` snap           | `3/stable`             |
| `k8s` snap            | `latest/edge`          |
| Core `*-k8s` charms   | `2026.1/edge`          |
| `ovn-*-k8s` charms    | `26.03/edge`           |
| `mysql-k8s`           | `8.0/stable`           |
| `mysql-router-k8s`    | `8.0/edge`             |
| `rabbitmq-k8s`        | `3.12/edge`            |
| `traefik-k8s`         | `latest/candidate`     |
| `self-signed-certificates` | `1/beta`          |
| `openstack-hypervisor`/`cinder-volume`/`cinder-volume-ceph`/`sunbeam-machine` | `2026.1/edge` |
| `microceph` snap      | `squid/stable`         |
