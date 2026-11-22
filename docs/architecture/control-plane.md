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
`ProviderConfig` Secrets by the boot script, which removes them from the environment before any
component starts (see Secrets, audit and credential lifetimes). Nothing is baked into the image.

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
CA, service-account signing key, front-proxy CA, client certs and, when enabled, the bearer token) and
`VERSION`.
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

When `CP_ADMIN_TOKEN_ENABLED=true`, the admin bearer token is persisted with the PKI. Setting `CP_ADMIN_TOKEN` (at least 32 characters of
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
under `run/` each boot, and the key is removed from the supervisor's environment before any
component starts, so no child process inherits it. A key that is not exactly the base64 of 32 bytes
is refused. A fingerprint of the key in use is stamped at `state/ENCRYPTION`; a boot with
a different key is refused unless the previous key is passed as `CP_ENCRYPTION_KEY_PREVIOUS`, in which
case the supervisor re-encrypts every Secret under the new key after the API server is up and moves
the stamp. First enablement follows the same path, so Secrets written before encryption was on are
rewritten too. A volume snapshot without the key yields ciphertext for Secrets; everything else in
etcd is plaintext, as in any Kubernetes cluster.

**Audit.** With `CP_AUDIT_ENABLED` (default on) the API server writes a JSON audit log to
`CP_AUDIT_LOG_PATH` (default `log/audit.log`, rotated at 20 MB, three backups, seven days). The
policy records every write and every human access to a Secret at `Metadata` level (who, what, when,
never the body). Reads of Secrets by the in-container identities (`control-plane-internal`,
`system:kube-controller-manager`) are excluded, since the controllers read them on every reconcile
and would drown the log; reads of other resources and the health, discovery and metrics endpoints are
not logged either. Failed authentication is never audited by the API server. The log lives on the
ephemeral filesystem and is lost on redeploy; `CP_AUDIT_LOG_PATH=-` sends it to the API server's
stdout instead for a platform log drain to keep (D6).

**Credential lifetimes.** Two kinds of client certificate exist. The `admin` certificate is the one
in the exported kubeconfig: valid `CP_CLIENT_CERT_DAYS` (default 90), reissued at boot once less than
half that remains or if it outlives the policy, so a kubeconfig handed to a person expires within 90
days and a restart past the midpoint hands out a renewed one. The in-container clients (the
supervisor, Crossplane, the provider, the controller manager) use separate `admin-internal` and
`controller-manager` certificates that are minted fresh on every boot with a long lifetime
(`CP_INTERNAL_CERT_DAYS`) and never leave the container, so a long-running container cannot lose its
own credentials. An hourly watchdog restarts the container if any in-container certificate or the
serving certificate has under seven days left. The serving certificate is valid
`CP_SERVING_CERT_DAYS` (default 365) and is reissued when its SAN set changes or within 30 days of
expiry. The two CAs stay long-lived. `CP_TLS_MIN_VERSION` defaults to TLS 1.2.

Two limits to be plain about. Nothing revokes a certificate: a kubeconfig issued before this change,
or one that leaks, stays valid until its own expiry against the same CA, and rotating the CA is the
only revocation. And `ca.key` lives on the volume next to the data, so whoever holds the volume can
mint any credential; the 90-day limit protects against a leaked kubeconfig, not a leaked volume.

**Bearer token.** The static admin token is a cluster-admin credential with no expiry and no
revocation path, so `CP_ADMIN_TOKEN_ENABLED` is `false` in the image: no token file is passed to the
API server, no token kubeconfig is written, and a token file left by an earlier boot is removed. The
native harness keeps it on. When on, `CP_ADMIN_TOKEN` rotates it as described above.

**The Railway token.** `RAILWAY_TOKEN` is read once before any component starts, right after the
privilege drop: leading and trailing whitespace is dropped, anything else outside `[A-Za-z0-9-]`
(interior whitespace included) is refused with a fatal error that does not echo the value, and the
variable is removed from the environment, so etcd, the API server, the controller manager,
Crossplane, the provider and the terraform processes it forks never inherit it (B4). Refusal is
fail-fast: a malformed value stops the boot, and on Railway that means a restart loop until the
variable is fixed, the same trade as `CP_ENCRYPTION_KEY`. The `railway-creds` Secret is built from
the value by a builtin `printf` piped into `kubectl create secret --from-file=credentials=/dev/stdin`
and written with server-side apply, so the token is on no command line, in no file, and not
duplicated into a last-applied-configuration annotation; the character check is what makes the
hand-built JSON safe (the image has no `jq`). kubectl's diagnostics on a failed write are logged
with the token and its base64 form masked. A boot without a token warns and leaves any Secret from
an earlier boot in place.

Two copies of the token remain and are accepted. The root phase's short-lived helpers (`find`,
`chown`, `su-exec`) run before the drop and inherit it; they run as root, which can read anything
anyway. And bash's `unset` does not scrub a process's own exec-time environment block, so
`/proc/<supervisor pid>/environ` holds the token for the life of the container. Every process in
the container runs as the same uid and can read the cluster-admin kubeconfig, and with it the Secret,
so that copy gives a same-uid process no extra reach. The justification is the single-uid model: if
the provider ever gets its own uid, or etcd client authentication separates privileges, scrub it, which
takes a re-exec of the supervisor with the token handed over on a pipe. The harness pins the residual
with a positive control, so closing it without updating this page fails `verify`. The `verify`
checks for all of this run when it is given the same `RAILWAY_TOKEN` as `up`.

Still open from B3: etcd listens on loopback without client authentication, so any process in the
container can read and write etcd directly. Client certificates for etcd, or a Unix socket, are the
remaining item.

## Capacity: etcd quota, snapshots and memory

**etcd quota.** `--quota-backend-bytes` is `CP_ETCD_QUOTA_BYTES`, default 2 GiB; Phase 1 shipped
etcd's 8 GiB maximum, larger than a small Railway volume (finding B5 of the
[Phase 1 review](phase-1-review.md)). The quota is what makes etcd refuse writes, with a NOSPACE
alarm, before the volume fills; a database that hits disk-full instead is how etcd gets corrupted.
At boot the supervisor refuses to run when the filesystem under the state root is smaller than the
quota, warns when less than the quota is free, and logs quota, filesystem size and free space.
Values outside 100 MiB to 8 GiB are refused. Kubernetes objects are small, so 2 GiB is far more than
this plane will hold; lower it for a small volume.

**Maintenance.** The API server compacts etcd every five minutes (its default), which frees old
revisions inside the database but returns nothing to the filesystem; `etcdctl defrag` does. The
supervisor runs a maintenance pass once etcd is ready and before the API server starts (nothing is
writing, and the snapshot it takes is the state as the previous run left it), then every
`CP_ETCD_MAINTENANCE_INTERVAL` seconds (default 6 h; 0 disables the periodic run), and whenever it
receives `SIGUSR1`. A pass defragments, checks alarms, writes `etcdctl snapshot save` to
`state/snapshots/etcd-<UTC time>.db` (file 0600, directory 0700) and keeps the newest
`CP_ETCD_SNAPSHOT_KEEP` (default 2). The snapshot is skipped with a warning when free space is under
twice the database size plus 64 MiB. A NOSPACE alarm is disarmed automatically once defrag has the
database under 90% of the quota; otherwise the pass logs what to do (delete objects, wait for
compaction, send `SIGUSR1`). Maintenance never fails the boot; problems are logged and the next pass
retries. The pass runs inside the supervise loop, so a defrag delays component-death detection by its
own duration: milliseconds at this plane's sizes, seconds near the quota.

**Restore.** The image ships `etcdutl`. To restore a snapshot: stop the service, move `state/etcd`
aside, run `etcdutl snapshot restore state/snapshots/<file> --data-dir state/etcd --name control-plane
--initial-cluster control-plane=http://127.0.0.1:2380 --initial-advertise-peer-urls
http://127.0.0.1:2380`, and start the service. The PKI on the same volume still matches the restored
data, which is what B1 bought. A snapshot taken before an encryption-key rotation holds Secrets under
the old key: boot with that key as `CP_ENCRYPTION_KEY_PREVIOUS` and remove `state/ENCRYPTION` so the
Secrets are re-encrypted under the current key. The restore path is not exercised end to end yet;
`etcdutl snapshot status` on every harness snapshot is.

**Memory.** Every component is a Go process, and a container at its memory limit gets an OOM kill of
whichever process the kernel picks. Each component is started with `GOMEMLIMIT` set to a fixed share
of the container's limit: kube-apiserver 35%, etcd 15%, the provider 15%, kube-controller-manager
10%, Crossplane 10%, leaving 15% for bash, the page cache and the terraform processes the provider
forks (they inherit the provider's value). The limit comes from `CP_MEMORY_LIMIT_BYTES` or, when that
is unset, from the cgroup (`memory.max`, then the v1 file); with no limit anywhere nothing is set and
the boot log says so. `CP_GOMEMLIMIT_ENABLED=false` turns it off. GOMEMLIMIT is a soft limit: the
runtime collects harder as it nears it and can still exceed it, so the shares are back-pressure, not
a guarantee, and sizing the container stays the operator's job; a limit under 1 GiB logs a warning.
etcd's database is memory-mapped, so a database near a 2 GiB quota also means up to 2 GiB of page
cache. The native harness host has no cgroup limit and passes 4 GiB by default.
