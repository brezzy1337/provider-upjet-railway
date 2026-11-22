# Railway-hosted control plane

This provider is one part of a larger system. The goal is a **Crossplane control plane that runs on
Railway** and provisions Kubernetes clusters on DigitalOcean, AWS and GCP. A user applies a
cloud-agnostic `KubernetesCluster` claim; a Composition picks the DOKS, EKS or GKE implementation; the
new cluster's kubeconfig comes back as a Crossplane connection secret. The workloads those clusters
exist for are [Hermes](https://hermes-agent.nousresearch.com) AI agent instances (one long-running
gateway process per agent, persistent volume, a model-provider key and channel tokens as Secrets,
expected to need roughly 4 GB and 2 CPUs each per the Hermes Docker guidance), reached from the user's Railway-hosted application. A later
`HermesAgent` XRD will compose them onto a provisioned cluster through provider-kubernetes or
provider-helm; it depends on the same composition-function work as the cluster XRD.

The control plane lives in this repository, under `cluster/images/control-plane/` (Dockerfile,
Makefile, the `control-plane.sh` supervisor) with `hack/native-cluster.sh` as its Docker-less test
harness. The original plan was a separate repository, on the theory that a Railway template is
derived from a GitHub repository; since a Railway service can build from a subdirectory that split
is not needed for Phase 2 and was dropped on 2026-11-21 (see the [roadmap](../roadmap.md)). The
image is self-contained: it builds the provider from this tree, Crossplane core from its tag, and
the patched Terraform provider from `hack/upstream/`, so `package/crds/`, the patch and
`cluster/images/provider-upjet-railway/terraformrc.hcl` are inputs to the image build and should be
treated as a contract. The [Phase 1 review](phase-1-review.md) records the verification results and
the open findings.

## Design

**Nodeless Kubernetes in one Railway service.** A single unprivileged container runs, as supervised
processes:

| Process                   | Role                                                                 |
|---------------------------|----------------------------------------------------------------------|
| `etcd`                    | State, on the Railway volume under `CP_STATE_DIR` (see below)        |
| `kube-apiserver`          | The API, serving its own TLS end-to-end                              |
| `kube-controller-manager` | Only node-independent controllers: garbage collector, namespace, service accounts, resource quota, TTL |
| `crossplane core`         | XRDs and Compositions, started with `--package-runtime=External`    |
| Providers                 | This one and, later, the cloud providers, each a binary plus its CRDs applied at boot |

There are no kubelets and no scheduler because nothing here runs pods: providers reconcile objects
straight into cloud APIs. That is also why providers run as processes rather than Crossplane packages.
The package manager would create Deployments that could never schedule.

**Exposure.** Railway HTTP domains terminate TLS at the edge, so the API server sits behind a Railway
TCP proxy on 6443 with the proxy hostname in its serving certificate. Authentication is a static
bearer token or client certificates. Anonymous access is off.

**Secrets.** Cloud credentials arrive as Railway environment variables and are written into
`ProviderConfig` Secrets by the boot script. Nothing is baked into the image.

**Keep the API server small.** Use family providers, never monoliths: `provider-aws-eks` plus
`provider-aws-ec2` plus `provider-aws-iam`, `provider-gcp-container` plus `provider-gcp-compute`, and
`crossplane-contrib/provider-digitalocean` (its maintenance status needs checking). Budget 2–4 GB of
RAM once AWS is in.

## What Phase 1 proved

The whole stack was run as bare processes on a box with no container runtime and passed 16 of 16
checks, including a restart on the same etcd data: TLS on the API server, anonymous rejected,
client-cert and bearer-token kubeconfigs from outside, all CRDs established, Crossplane core healthy,
21 provider controllers running, Terraform resolving the patched provider mirror.

Lessons that changed the design, in brief (the full list is in
`.claude/handoff/railway-control-plane-handoff.md`):

* kube-controller-manager is required after all; cascading deletion is its garbage collector's job.
* Crossplane's `init` races itself on a fresh API server; apply the CRDs with `kubectl` first.
* `crossplane core start` needs a client certificate directory even when no Functions run.
* Webhooks are off, which disables the Usage protection controllers. A hand-written EndpointSlice
  pointing at the container's own IP is the probable fix, untested.
* Compositions need a Function, which is a gRPC server with mTLS; it will run as another supervised
  process with a certificate signed by Crossplane's root CA.
* Railway containers are dual-stack and `hostname -i` returns IPv6 first; the supervisor prefers IPv4.
* A separate front-proxy CA is required or kube-controller-manager logs errors forever.

## Phases

See the [roadmap](../roadmap.md). Phase 1 is done; Phase 2 (deploy to Railway, smoke test over the
internet) is next; Phase 3 adds DigitalOcean, then EKS and GKE.

## The state root

Everything that must survive a redeploy lives under one directory, `CP_STATE_DIR` (default
`/var/lib/control-plane/state`), which is the single volume mount: `etcd/` (the data), `pki/` (cluster
CA, service-account signing key, front-proxy CA, admin client cert and bearer token) and `VERSION`.
Keeping only etcd persistent, as Phase 1 did, meant every redeploy minted a new CA against old data
and invalidated every kubeconfig ever issued (finding B1 of the [Phase 1 review](phase-1-review.md)).

Ownership first: Railway mounts volumes root-owned, so the image starts as root (no `USER`), and
the supervisor's very first step takes ownership of the state root and the ephemeral directories for
`CP_RUN_UID:CP_RUN_GID` (default 65532), then re-execs itself through `su-exec` as that uid with the
same environment. A tree is chowned recursively only when some inode in it has a different owner or
group (a healthy tree costs one short `find`; `CP_FORCE_CHOWN=true` forces it), which also repairs
root-owned files left by an earlier root-run boot. Before touching anything as root the supervisor
refuses a uid or gid of 0, a non-numeric value, a path that resolves to `/` or a system directory,
and a layout where the state root is or contains `CP_HOME`; a sentinel in the environment makes a
second pass through the root phase fatal. Everything after the re-exec, etcd and the API server
included, runs unprivileged. `CP_STAY_ROOT=true` opts out, with a warning.

Guards at boot, in order: the root must not be `CP_HOME` or contain the ephemeral `log/`, `run/` or
`cache/`; it must be writable by the running uid; it is forced to mode 0700 and everything the
supervisor writes uses `umask 077`; with `CP_REQUIRE_PERSISTENT=true` (set in the image) a root on the same
filesystem as `CP_HOME`, meaning no volume is mounted, fails the boot; etcd data without the PKI that
signed it is refused rather than overwritten with a new CA.

`VERSION` is a high-water mark of the etcd and Kubernetes versions that have written the state. An
image older than the mark refuses to start; `CP_ALLOW_DOWNGRADE=true` lets one boot through with a
warning and leaves the mark unchanged. Pre-release suffixes are ignored in the comparison. Crossplane
keeps no local state (everything is in etcd), so it is not stamped; adding it is open.

Kubeconfigs, the Crossplane TLS material unpacked from its Secret, logs and caches (`xpkg`, `xfn`,
Terraform plugins) are derived or re-fetched every boot and stay on the ephemeral filesystem, so a
change of external URL or SAN needs no state migration and volume snapshots stay small.

The admin bearer token is persisted with the PKI. Setting `CP_ADMIN_TOKEN` (at least 32 characters of
`[A-Za-z0-9._-]`) rotates it on the next boot; removing the variable keeps the stored token. The
value is never logged unless `CP_LOG_ADMIN_TOKEN=true`.

There is no migration from Phase 1 layouts: a volume at the old `/var/lib/etcd` is not adopted. No
Railway deployment existed before this change.

## Secrets, audit and credential lifetimes

**Secrets at rest.** The API server encrypts `Secret` objects in etcd with secretbox
(`--encryption-provider-config`). The key is 32 random bytes, base64, supplied as `CP_ENCRYPTION_KEY`
from the platform's secret store; the image sets `CP_REQUIRE_EXTERNAL_KEY=true`, so a missing key
fails the boot there, while the native harness generates one under `pki/` with a warning. The key
itself never touches the volume when supplied externally: the EncryptionConfiguration is written
under `run/` each boot. A fingerprint of the key in use is stamped at `state/ENCRYPTION`; a boot with
a different key is refused unless the previous key is passed as `CP_ENCRYPTION_KEY_PREVIOUS`, in which
case the supervisor re-encrypts every Secret under the new key after the API server is up and moves
the stamp. First enablement follows the same path, so Secrets written before encryption was on are
rewritten too. A volume snapshot without the key yields ciphertext for Secrets; everything else in
etcd is plaintext, as in any Kubernetes cluster.

**Audit.** With `CP_AUDIT_ENABLED` (default on) the API server writes a JSON audit log to
`CP_AUDIT_LOG_PATH` (default `log/audit.log`, rotated at 20 MB, three backups, seven days). The
policy records every write and every access to a Secret at `Metadata` level (who, what, when, never
the body); reads of other resources and the health, discovery and metrics endpoints are not logged,
since the controllers watch constantly. The log lives on the ephemeral filesystem; shipping it out is
part of D6.

**Credential lifetimes.** The admin and controller-manager client certificates are valid for
`CP_CLIENT_CERT_DAYS` (default 90) and are reissued at boot once less than half that remains, so a
kubeconfig handed to a person lives at most 90 days and is renewed transparently by a restart after
the midpoint. The API server's serving certificate is valid for `CP_SERVING_CERT_DAYS` (default 365)
and is reissued when its SAN set changes or within 30 days of expiry. The two CAs stay long-lived.
`CP_TLS_MIN_VERSION` defaults to TLS 1.2.

**Bearer token.** The static admin token is a cluster-admin credential with no expiry and no
revocation path, so `CP_ADMIN_TOKEN_ENABLED` is `false` in the image and the token kubeconfig is not
written there. The native harness keeps it on. When on, the token file is passed to the API server
and `CP_ADMIN_TOKEN` rotates it as described above.

Still open from B3: etcd listens on loopback without client authentication, so any process in the
container can read and write etcd directly. Client certificates for etcd, or a Unix socket, are the
remaining item.

