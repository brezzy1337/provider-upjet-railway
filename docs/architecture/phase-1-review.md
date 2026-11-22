# Phase 1 review: the nodeless control-plane image

_Last updated 2026-11-21. Reviewed against commit `3e52d25` of branch `phase-1/control-plane-image`,
merged to `main` the same day via PR #3 with the fixes listed below._

## What Phase 1 delivered

One container image that runs a complete Crossplane control plane with no Kubernetes nodes:

| Component | Version | Role |
|-----------|---------|------|
| etcd | 3.6.14 | State, on the persistent volume |
| kube-apiserver | 1.35.8 | The API, TLS on 6443, client-cert and bearer-token auth, RBAC |
| kube-controller-manager | 1.35.8 | Node-independent controllers only: garbage collector, namespace, service account, token, resource quota, TTL |
| Crossplane core | 2.2.1 | `core init` then `core start --package-runtime=External`, webhooks off |
| provider-upjet-railway | this tree | Run as a process with the admin kubeconfig; its CRDs applied by `kubectl` at boot |

The pieces are:

- `cluster/images/control-plane/Dockerfile`: self-contained multi-stage build. Fetches the Kubernetes,
  etcd and Terraform binaries, builds the provider from this tree, Crossplane core from its tag, and
  the patched Terraform provider from `hack/upstream/`. Railway can build it from the repository
  with no prior `make` step.
- `cluster/images/control-plane/control-plane.sh`: the supervisor. Generates the PKI, writes
  kubeconfigs, starts each component in order with a readiness gate, applies CRDs, unpacks
  Crossplane's TLS client secret to disk, writes the Railway `ProviderConfig`, then watches the
  processes and exits if any dies so the platform restarts the container.
- `hack/native-cluster.sh`: runs the same supervisor against bare processes, for machines without a
  container runtime. `build`, `up`, `verify`, `down`, `clean`.

## Verification on 2026-11-21

All runs were on this repository's codespace (Alpine 3.23, 2 vCPU, 8 GB, no Docker), using the
native harness against the code that is now on `main`. The provider code was unchanged since the
branch point, so this exercised exactly what Phase 1 built.

| Step | Result |
|------|--------|
| `build` | Fetched etcd 3.6.14, Kubernetes 1.35.8, Terraform 1.5.7; built Crossplane 2.2.1 and the provider; applied the not-found patch to terraform-provider-railway 0.6.2 |
| First `up` | **Failed** at "crossplane core CRDs established" after 120 s. Root cause: `clean` removes the staged CRD copies and `up` did not restage them; the supervisor logged "skipping missing CRD dir" and waited for CRDs it never applied. Fixed (below). |
| Second `up` | Cold boot to `control plane UP` in **14 s**; 44 CRDs Established |
| `verify` | **16/16 pass** |
| Supervisor `SIGTERM` | All five components gone in **7 s**, no kill escalation needed |
| Third `up` on the persisted state | Ready in **13 s**, same cluster CA as before, **16/16 pass** |
| Final `SIGTERM` | All components gone in 8 s, no leftover processes |
| Fourth `up`, after the review follow-up commit | Ready in 12 s; **17/17** (the namespaced CRD count added); `SIGTERM` exited **143**; all components gone in 9 s |

The failed first boot also exposed two things the harness had been hiding: the API server survived
the supervisor's shutdown for a quarter of an hour, and `verify` reported passes against a plane
whose etcd was already dead. Both are fixed below.

What was **not** verified: the Docker image build itself (no Docker here), anything on Railway, and
the live `Project` round trip (needs `RAILWAY_TOKEN`; it passed on 2026-08-26 through this same
stack).

## Changes made in the merge

Small fixes applied on top of `3e52d25` before merging, all found by the review or by the runs above:

1. **Controller-manager readiness probed the wrong process.** The gate ran `kubectl get --raw=/readyz`
   against the API server, which was already ready, so it passed instantly whatever the controller
   manager was doing. It now probes `https://127.0.0.1:10257/healthz`.
2. **Missing CRD directory is fatal.** `apply_crd_dir` skipped a missing directory and let the boot
   fail later with an unhelpful timeout. It now fails immediately and names the variable to set.
3. **Shutdown escalates.** Components are stopped one at a time in reverse start order, each in its
   own process group (`setsid`), with `CP_SHUTDOWN_TIMEOUT` (10 s per component, so 50 s worst case;
   keep the platform drain window above that) before `SIGKILL`. `SIGTERM` and `SIGINT` now exit 143
   and 130. Side effect of `setsid` in native mode: Ctrl-C reaches the components through the
   supervisor's trap rather than directly, and if the supervisor itself is `SIGKILL`ed the
   components survive; `native-cluster.sh down` handles that case. The `SIGKILL` escalation path has
   not been exercised, since every observed shutdown completed on `SIGTERM`.
4. **Harness restages CRDs on every `up`** and checks for `openssl`, `curl`, `ip`, `hostname` and
   `base64` before booting; the codespace lacked `openssl`, which produced a bare "shutting down"
   with no reason.
5. **Verify probes are honest.** The garbage-collector probe fails when its setup fails instead of
   treating "child not found" as "collected"; the CRD counts for both API groups are derived from
   `package/crds/` instead of a hard-coded 11; the "built past the tag" check asserts positively
   for `(devel)` or a pseudo-version, since the Go toolchain reports `(devel)` for this build.
6. Comments corrected: the PKI directory is **not** persisted in the image (see below), and 0.6.3
   is no longer "not yet released".

## Review findings

Two read-only reviewers (architecture, security) went through the branch; the items below are the
consolidated, verified set. Severity reflects impact on the next phase, not on merging the code.

### Must fix before Phase 2 deploys to Railway

| # | Finding | Why it matters | Fix |
|---|---------|----------------|-----|
| B1 | **PKI on the ephemeral filesystem; only etcd on the volume.** `CP_PKI_DIR` defaulted to `/var/lib/control-plane/pki`; the only `VOLUME` was `/var/lib/etcd`. **Fixed 2026-11-21 (PR #5).** | Every redeploy minted a new cluster CA, service-account key and admin token while etcd kept Secrets and SA tokens signed by the old ones; every issued kubeconfig went stale. The 2026-08-25 restart test passed only because the native harness keeps both directories on disk. | `CP_STATE_DIR` is the one mount for `etcd/`, `pki/` and a `VERSION` high-water stamp; see the state-root section of [Architecture](control-plane.md) and Session 2 of the [2026-11-21 report](../reports/2026-11-21.md). |
| B2 | **Volume ownership.** The image runs as uid 65532; Railway mounts volumes root-owned. **Fixed 2026-11-22 (PR #6).** | First boot fails the writability check; a chown from the start command cannot work for a non-root `USER`. | Start as root, take ownership, drop via `su-exec`; see the state-root section of [Architecture](control-plane.md). |
| B3 | **Secrets unencrypted in etcd, no audit log, 10-year admin credentials.** No `--encryption-provider-config`, no `--audit-policy-file`; the admin client cert, CA and static bearer token all live 3650 days with no revocation path. **Fixed 2026-11-22 (PR #7).** | The Railway workspace token sits in plaintext on the volume; a leaked kubeconfig is permanent cluster-admin on an internet-facing endpoint. | Encryption at rest, audit, short exported credentials; see the Secrets, audit and credential lifetimes section of [Architecture](control-plane.md). etcd client authentication, the leftover, **fixed 2026-11-22 (PR #10)**: TLS with a client certificate from a dedicated etcd CA. |
| B4 | **`RAILWAY_TOKEN` handling.** It stays in the supervisor's environment (inherited by every child), is interpolated into JSON by hand, and passes through a `kubectl` command line. **Fixed 2026-11-22 (PR #8).** | Readable from `/proc/*/environ` and `ps` inside the container; breaks on a quote or backslash. | Read once and removed from the environment before any component starts; `[A-Za-z0-9-]` enforced; the Secret reaches `kubectl` on stdin, server-side applied. The supervisor's own exec-time environment block still holds it, by design; see the Secrets section of [Architecture](control-plane.md). Scope is the control-plane image; `hack/dev-cluster.sh`, the local kind helper, still uses `--from-literal`. |
| B5 | **etcd quota and memory.** `--quota-backend-bytes` is 8 GiB, likely larger than the volume; no defrag, no snapshot, no `GOMEMLIMIT` on any Go process. **Fixed 2026-11-22 (PR #9).** | Disk-full on the volume risks a corrupted etcd; an OOM kill picks an arbitrary victim. | `CP_ETCD_QUOTA_BYTES` (`auto`: half the volume, at most 2 GiB), a background maintenance pass (defrag, snapshot to `state/snapshots`, prune) at boot, every 6 h and on `SIGUSR1`, a 60 s alarm poll that recovers from NOSPACE, `GOMEMLIMIT` per component as a share of the cgroup limit; see the Capacity section of [Architecture](control-plane.md). |

### Design debt to pay before adding a sixth process

| # | Finding | Fix |
|---|---------|-----|
| D1 | **All-or-nothing supervision.** Any process exit tears down etcd and the API server and costs a full cold boot. Right for the core, wrong for providers and functions, which fork `terraform` per reconcile and are the likeliest OOM victims. Shutdown is sequential with a per-component budget, so a global deadline is also missing. | Give each component a criticality: core is fatal, providers and functions restart with backoff. Replace the `kill -0` poll with `wait -n -p` (bash 5.1+, Alpine ships 5.2) to map an exit back to a name. Add a total shutdown deadline, or stop non-etcd components concurrently and etcd last. |
| D2 | **No component abstraction.** Adding a provider means a new `start_*` function, a `main()` edit, port variables, CRD waits, a ProviderConfig block and a shutdown decision. Functions are not supported at all: nothing signs a leaf with the `crossplane-root-ca` Secret, and nothing writes `FunctionRevision.status.endpoint`. | A `components.d/<name>.sh` drop-in with `_start`, `_ready`, `_crds`, `_critical`; one `issue_cert` helper and one `sign_with_crossplane_ca` helper; ports allocated from a base. |
| D3 | **Everything runs as `system:masters`** under one uid, including the provider, Crossplane core and the controller manager (which already has its own RBAC bindings). | Per-component client certs and kubeconfigs; a ClusterRole for the provider scoped to its groups, Secrets in its namespace, and Events. |
| D4 | **Package manager bypassed.** CRDs are applied by `kubectl`, so no `Provider` or `ProviderRevision` object exists and Crossplane's dependency resolution cannot see the provider. | Decide, and write down, whether future providers install as a Provider package (for CRDs and dependency metadata) plus an external process, or stay on the CRD-directory path. |
| D5 | **Two build paths, one "keep in sync" comment.** The Dockerfile hard-codes versions as `ARG`s; the native harness defaults some and reads others from the Makefile; the supervisor defaults the provider version again. The harness re-implements fetching, the patched build, the mirror layout and `terraformrc.hcl`. Native mode is hard-wired to `linux/amd64`. | One `versions.env` consumed by the Makefile, the harness and the image build; shared `fetch-binaries.sh` and `build-tfprovider.sh`; `uname -m` for the arch; `docker build` and `shellcheck` in CI. |
| D6 | **No Railway-facing health check.** Health is "process exists"; a hung process is undetected. The API server and the metrics ports bind all interfaces. | A small HTTP health endpoint the supervisor serves from its own readiness state; loopback binds for metrics. |

### Supply chain (hardening, schedule it)

- Downloaded binaries (Kubernetes, etcd, Terraform) are not checksum-verified; base images are
  pinned by tag, not digest; `git clone --branch <tag>` for Crossplane and the Terraform provider
  trusts a mutable tag. Pin SHA-256 sums as `ARG`s, pin images by digest, assert the clone's commit.
- `.dockerignore` does not exclude `.env*`, `*.kubeconfig`, `*.key`, `*.pem` or `.claude/`. The
  runtime image copies only built artifacts, so nothing leaks today, but the builder context and
  cache would carry them.

### Verified sound

- API server: anonymous auth off, `Node,RBAC`, separate front-proxy CA, service-account signing
  keys, `--profiling=false`, TLS on a high port behind a Railway TCP proxy (not an HTTP domain, which
  would terminate TLS at the edge).
- etcd listens on loopback only.
- Readiness gating in order: etcd, API server, controller manager, CRDs Established, `core init`,
  TLS secret unpacked, `core start`, provider metrics, then the per-controller worker gauges.
- The admin bearer token is hidden from the deploy log unless `CP_LOG_ADMIN_TOKEN=true`.
- `--package-runtime=External` is the right Crossplane setting: it never registers the controllers
  that would try to create Deployments for packages.
- The garbage collector genuinely runs nodeless; owner-reference cascading deletion works, which is
  what Crossplane's composed-resource cleanup depends on.

## Open questions carried into Phase 2

1. **Composition functions.** Crossplane 2 Compositions are pipeline-only. A function is a gRPC
   server that must present a certificate signed by the `crossplane-root-ca` Secret, and under the
   External runtime nothing sets `FunctionRevision.status.endpoint`. Running the function as another
   supervised process and writing the endpoint ourselves is the plan; it is untested. This blocks the
   `KubernetesCluster` XRD and, later, a `HermesAgent` XRD equally, so it is the first Phase 2 spike.
2. **Webhooks.** Off because the webhook configurations point at a Service with no endpoints. The
   cost is no Usage protection. A hand-written `EndpointSlice` at the container's own IP is the
   untested fix.
3. **Where the Railway TCP proxy hostname enters the serving certificate.** The supervisor reissues
   the serving cert when `CP_APISERVER_CERT_SANS` changes, which works now that B1 is fixed.

## Reproducing the verification

```bash
sudo apk add openssl iproute2 coreutils curl git tar unzip   # Alpine; the harness checks these
hack/native-cluster.sh build        # several minutes the first time
hack/native-cluster.sh up           # foreground; Ctrl-C to stop
hack/native-cluster.sh verify       # in another shell, 21 checks (19 without go on PATH)
hack/native-cluster.sh down
```

State lives under `.work/native/` (gitignored): `state/` is the persistent root (etcd, pki,
`VERSION`), mirroring `CP_STATE_DIR` in the image. `clean` removes it and keeps the binaries;
`up` restages the CRDs, so `clean` followed by `up` is a valid cold-start test, and `down` followed
by `up` is the restart-on-persisted-state test.
