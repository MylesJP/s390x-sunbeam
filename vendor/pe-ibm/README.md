# vendor/pe-ibm/

Vendored, pinned-by-commit snapshot of files from the Performance Engineering /
IBM Z validation effort:

- Upstream: [canonical/pe-ibm-microk8s-validation](https://github.com/canonical/pe-ibm-microk8s-validation)
- Branch: `c-k8s-and-calico-experimental`

These files are required by [`scripts/02b_setup_s390x_cni.sh`](../../scripts/02b_setup_s390x_cni.sh)
to bootstrap Canonical K8s on s390x: the default cilium CNI does not run on Z,
so K8s is bootstrapped with `network.enabled: false` and Calico is installed
from `calico.yaml` in this directory. Each K8s addon (coredns, etc.) then needs
its image source rewritten away from `ghcr.io/canonical/...` (which has no
s390x builds) to an upstream registry — `rewrite-coredns.sh` is the reference
implementation, generalized by [`tools/rewrite_k8s_addon_images.sh`](../../tools/rewrite_k8s_addon_images.sh).

## Why vendored

This repo must be runnable on an LPAR where cloning extra repos at deploy time
is awkward, and the source branch is experimental — pinning to a known commit
keeps runs reproducible. The trade-off is staleness; refresh when the upstream
branch advances and you want to pick up changes.

## Refreshing

```bash
./tools/refresh_pe_ibm.sh
```

This re-clones the upstream branch, copies the tracked files in over the top,
writes the new upstream commit SHA to [`COMMIT`](COMMIT), and leaves you with
a `git diff` to review and commit.

## Attribution

Original work by the Canonical Performance Engineering / IBM Z alliances team.
See upstream repository for license and authorship.
