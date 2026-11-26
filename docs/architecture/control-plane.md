# Railway-hosted control plane

This provider is one part of a larger system. The goal is a **Crossplane control plane that runs on
Railway** and provisions Kubernetes clusters on DigitalOcean, AWS and GCP. A user applies a
cloud-agnostic `KubernetesCluster` object (a namespaced Crossplane 2.x composite resource); a Composition picks the DOKS, EKS or GKE implementation; the
new cluster's kubeconfig comes back as a Crossplane connection secret. The workloads those clusters
exist for are [Hermes](https://hermes-agent.nousresearch.com) AI agent instances (one long-running
gateway process per agent, persistent volume, a model-provider key and channel tokens as Secrets,
expected to need roughly 4 GB and 2 CPUs each per the Hermes Docker guidance), reached from the user's Railway-hosted application. A later
`Workload` XRD, with a `hermes` preset first and custom chart and manifest presets beside it, will
compose them onto a provisioned cluster through provider-kubernetes or provider-helm; it depends on
the same composition-function work as the cluster XRD (see the [roadmap](../roadmap.md), Phase 3).

The control plane lives in this repository, under `cluster/images/control-plane/` (Dockerfile,
Makefile, the `control-plane.sh` supervisor) with `hack/native-cluster.sh` as its Docker-less test
harness. The original plan was a separate repository, on the theory that a Railway template is
derived from a GitHub repository; since a Railway service can build from a subdirectory that split
is not needed for Phase 2 and was dropped on 2026-11-21 (see the [roadmap](../roadmap.md)). The
image is self-contained: it builds the provider from this tree, Crossplane core from its tag, and
the patched Terraform provider from `hack/upstream/`, so `package/crds/`, the patch and
`cluster/images/provider-upjet-railway/terraformrc.hcl` are inputs to the image build and should be
treated as a contract. The [Phase 1 review](../reports/phase-1-review.md) records the verification results and
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
| Composition functions     | `function-go-templating` and `function-auto-ready`, gRPC servers on loopback behind mTLS from Crossplane's root CA, started after `crossplane core` so that Crossplane owns metrics port 8080 (see [Composition functions](#composition-functions)) |
| Providers                 | This one and, later, the cloud providers, each a binary plus its CRDs applied at boot |

There are no kubelets and no scheduler because nothing here runs pods: providers reconcile objects
straight into cloud APIs. That is also why providers and composition functions run as processes
rather than Crossplane packages. The package manager would create Deployments that could never
schedule.

**Exposure.** Railway HTTP domains terminate TLS at the edge, so the API server sits behind a Railway
TCP proxy on 6443 with the proxy hostname in its serving certificate; the supervisor reads the
hostname and the proxy port from Railway's own variables at boot, for the certificate and for the
exported kubeconfig (see [Deploy the control plane to
Railway](../getting-started/deploy-to-railway.md)). Authentication is a static
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
* Compositions need a Function, which is a gRPC server with mTLS. Done in Phase 3: two functions run
  as supervised processes with certificates signed by Crossplane's root CA, registered by hand
  because the External runtime registers nothing (see [Composition functions](#composition-functions)).
* function-sdk-go (v0.7.1) starts a metrics server on `:8080` in every function, with no flag or
  variable to move or disable it, and ignores a failed bind; Crossplane core's metrics default to
  8080 too, and it refuses to start when the port is taken. So the functions start after
  `crossplane core start`, never before: the first Railway deploy with the opposite order
  crash-looped (see [Composition functions](#composition-functions)).
* Railway containers are dual-stack and `hostname -i` returns IPv6 first; the supervisor prefers IPv4.
* A separate front-proxy CA is required or kube-controller-manager logs errors forever.

## Phases

See the [roadmap](../roadmap.md). Phase 1 is done ([Phase 1 review](../reports/phase-1-review.md)); Phase 2's
hardening, every finding of that review, is done ([Phase 2 review](../reports/phase-2-review.md)) and the plane
has run on Railway since 2026-11-25 with the smoke test passed over the internet
([runbook](../getting-started/deploy-to-railway.md)); Phase 3 is under way: its first item,
composition functions as supervised processes, is done on the harness and on Railway (2026-11-26,
[report](../reports/2026-11-26.md): a Composition composed a `Project` on the live plane over the
internet), and DigitalOcean and the `Workload` catalogue follow; EKS and GKE follow in Phase 4.

## The state root

Everything that must survive a redeploy lives under one directory, `CP_STATE_DIR` (default
`/var/lib/control-plane/state`), which is the single volume mount: `etcd/` (the data), `pki/` (cluster
CA, service-account signing key, front-proxy CA, client certs and, when enabled, the bearer token) and
`VERSION`.
Keeping only etcd persistent, as Phase 1 did, meant every redeploy minted a new CA against old data
and invalidated every kubeconfig ever issued (finding B1 of the [Phase 1 review](../reports/phase-1-review.md)).

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
etcd is unencrypted at rest, as in any Kubernetes cluster.

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
privilege drop: leading and trailing whitespace is dropped, anything else outside `[A-Za-z0-9._-]`
(interior whitespace included) is refused with a fatal error that does not echo the value, and the
variable is removed from the environment, so etcd, the API server, the controller manager,
Crossplane, the provider and the terraform processes it forks never inherit it (B4). Refusal is
fail-fast: a malformed value stops the boot, and on Railway that means a restart loop until the
variable is fixed, the same trade as `CP_ENCRYPTION_KEY`. The `railway-creds` Secret is built from
the value by a builtin `printf` piped into `kubectl create secret --from-file=credentials=/dev/stdin`
and written with server-side apply, so the token is on no command line, in no file, and not
duplicated into a last-applied-configuration annotation; the character check is what makes the
hand-built JSON safe (the image has no `jq`); the set is deliberately wider than any one token
format (see [Authentication](../getting-started/authentication.md)). kubectl's diagnostics on a
failed write are logged
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

**etcd client authentication.** Both of etcd's loopback listeners, client and peer, take TLS only
and demand a client certificate signed by a CA of its own, `pki/etcd-ca`, which signs nothing else:
a certificate from the cluster CA, `admin-internal` included, is refused. One server certificate
covers `localhost`, `127.0.0.1` and `::1` for both ports and follows the serving-certificate policy
(reissued within 30 days of expiry, or when its key no longer matches); the two client identities,
the API server's and the supervisor's own `etcdctl`, are minted every boot like the other
in-container identities and never leave the container. Keys and certificates are written to temp
names and moved into place, and a CA is regenerated when either of its files is missing, so a crash
mid-issue cannot wedge the next boot. Existing state migrates on the first boot: the CA and
certificates are generated, etcd restarts on the same data over TLS, and the member's recorded peer
URL is updated to `https` (the `--initial-*` flags are read only when the data directory is created).
Rotation is deliberate and simple: remove `etcd-ca.crt` and `etcd-ca.key` and reboot; every etcd
certificate is reissued and the data stays readable. Until then a leaked client certificate stays
valid, there being no revocation. What this does and does not buy, plainly: it closes the network
path, so nothing that merely reaches loopback can read, write or disrupt etcd, and it is a
prerequisite for running the provider under a uid of its own. In today's single-uid container every
process can read the client key files and `etcd-ca.key` itself, so it does not yet separate the
provider from etcd. That separation needs the uid split proper: per-component ownership of the key
files and the etcd data directory, a PKI directory the provider cannot traverse, and a reduced RBAC
identity for the provider in place of `system:masters`.

## Composition functions

Every Composition in Crossplane 2.x is a pipeline of functions, and a function is a gRPC server that
Crossplane dials over mTLS. The package manager runs functions as Deployments, which nothing here
could schedule, so they run the way the provider does: as supervised processes (Phase 3, item 1,
done 2026-11-26 on the harness and on Railway; the [2026-11-26 report](../reports/2026-11-26.md) has
both runs). Two are built into the image from their GitHub tags, `function-go-templating`
v0.13.3 and `function-auto-ready` v0.7.4, pinned by tag and by commit in the Dockerfile `ARG`s
(`FUNCTION_GO_TEMPLATING_VERSION` and `_COMMIT`, `FUNCTION_AUTO_READY_VERSION` and `_COMMIT`) and
in the Makefile, which the harness reads; the build and the harness fail when the tag no longer
resolves to the pinned commit (see [The control-plane
image](control-plane-image.md#keeping-the-dockerfile-portable)). Both modules require Go 1.26.11,
which moved the image's Go pin.

**Processes and ports.** `CP_FUNCTIONS` (default `function-go-templating function-auto-ready`)
names the functions, each a binary of that name under `CP_BIN_DIR`; the first listens on
`127.0.0.1:CP_FUNCTION_PORT_BASE` (default 9450; the harness uses 19450), the next on the port
after. Loopback only: the only caller is Crossplane core in the same container, and the SDK's own
metrics listener never binds (see **Order and drain** below). A name must be a
DNS label, since it becomes an object name and a certificate CN. `CP_FUNCTIONS=` (set empty)
disables functions: nothing is started or registered, and the boot log says so.

**The certificate chain.** Crossplane dials a function with the client certificate `crossplane core
init` wrote to Secret `crossplane-tls-client`, verifies the function's serving certificate against
the root CA in Secret `crossplane-root-ca` (keys `tls.crt`, `tls.key`) with ordinary hostname
verification, and the function verifies Crossplane's certificate against the same root CA. So the
supervisor unpacks the root CA to the ephemeral `run/tls/root-ca/` and, every boot, issues each
function a serving certificate signed by it: CN the function's name, SANs `localhost`, the name,
`127.0.0.1` and `::1` (the IP SAN is the one Crossplane checks), EKU `serverAuth`, valid
`CP_INTERNAL_CERT_DAYS`, written under `run/tls/functions/<name>/` beside a `ca.crt` that is the
root CA certificate. The cluster CA signs nothing here, and the harness checks that the serving
certificate verifies against the root CA and not against the cluster CA. The root CA key is
Crossplane's, borrowed only to sign, then deleted: once the last function certificate is signed
the supervisor removes `tls.key` from `run/tls/root-ca/` (only `tls.crt` stays, for the readiness
probe and the per-function `ca.crt` copies) and logs `root CA key removed from ... after signing 2
function certificate(s)`; it is never written to the volume, and the harness checks that the key is
absent and the certificate present. The hourly watchdog covers the functions' certificates like the
others.

**Readiness.** A function is ready when `openssl s_client -alpn h2`, presenting Crossplane's own
client certificate, reports `Verify return code: 0 (ok)` and `ALPN protocol: h2` and no `SSL alert`.
The verify line alone is not enough: under TLS 1.3 the handshake completes before the server has
seen the client certificate, so a rejected one arrives as an alert afterwards; and the gRPC server
refuses anything but h2. On the harness both functions were ready 1 s after start. The harness
adds two negative controls, no client certificate and a certificate from the cluster CA
(`admin-internal`), each refused with a TLS alert, and on the positive control also requires the
server's HTTP/2 SETTINGS frame, which only arrives once mTLS completed.

**What the External runtime needs**, read from Crossplane 2.2.1's source
(`internal/xfn/function_runner.go`, `internal/xfn/capabilities.go`,
`internal/controller/pkg/revision/reconciler.go`,
`internal/controller/apiextensions/composite/reconciler.go`), three lessons:

* The function runner finds the process to dial by listing `FunctionRevision`s labelled
  `pkg.crossplane.io/package=<name>` with `spec.desiredState: Active` and dialling
  `status.endpoint`, with mTLS and ordinary hostname verification (hence the `127.0.0.1` IP SAN).
* The composite reconciler refuses to compose until the `CompositionRevision` reports
  `ValidPipeline=True`, which the capability checker grants only when every active
  `FunctionRevision` of the pipeline carries `status.capabilities` containing `composition`.
* Under `--package-runtime=External` nothing writes either field; only the Deployment runtime's
  hooks do, through a Service. So the supervisor writes them.

**Registration and its limits.** Once the functions are ready (step 6, after `crossplane core
start`; see **Order and drain**), the supervisor applies, with server-side apply so a reboot re-asserts the same objects, a
`Function/<name>` and a `FunctionRevision/<name>-local` (label `pkg.crossplane.io/package=<name>`,
`desiredState: Active`, `revision: 1`), then patches `status.endpoint` (`127.0.0.1:<port>`) and
`status.capabilities` (`[composition]`) through the status subresource. The `Function` CRD's CEL
rule requires `spec.package` to look like `registry/repository:tag` (a first attempt with
`local://<name>` was refused at boot), so both objects carry the placeholder
`supervised.local/control-plane/<name>:process`, as `spec.package` and as `spec.image`; nothing
resolves it. Both carry `crossplane.io/paused: "true"`, so the package manager's reconcilers only
set a `ReconcilePaused` condition and never fetch the placeholder image or recompute the status.
Both also carry the label `app.kubernetes.io/managed-by: control-plane-supervisor`, and after
registering, the supervisor deletes every labelled `Function` or `FunctionRevision` whose name is
not in `CP_FUNCTIONS` (the harness checks the label on both objects). The prune is not tidiness:
ports are positional, so a name removed from or reordered in the list would leave the previous
boot's `FunctionRevision/<old>-local` pointing at a port another function now owns, and Crossplane
would route `<old>`'s pipeline steps to the wrong process without an error. Unlabelled objects
were not written by the supervisor and are never touched; a failed list or delete fails the boot.
Two limits to be plain about. `kubectl get functions` shows them without `INSTALLED` or `HEALTHY`,
because the reconcilers that set those columns are paused. And a Composition refers to a function
by this name (`functionRef.name`), so the names in `CP_FUNCTIONS` are part of the plane's API.

**Validation at boot.** Before anything starts, `CP_FUNCTIONS` is checked and a bad list is fatal
with a message naming the fix: a name that is not a DNS label; a name listed twice (the second
registration would silently win); a name equal to a core component (`etcd`, `kube-apiserver`,
`kube-controller-manager`, `crossplane`, `provider-upjet-railway`), since the name is also the log
file, the supervised-process name and the `GOMEMLIMIT` component; and a function port range
(`CP_FUNCTION_PORT_BASE` plus one port per entry) that overlaps any port the plane itself listens
on: `CP_APISERVER_PORT`, etcd's client and peer ports, `CP_KCM_PORT`, Crossplane's metrics, health
and webhook ports, and the provider's metrics port. Without the last check a function that lost
the race for, say, 8080 would die before readiness and fail the boot with a less direct message.

**Order and drain.** The boot order is etcd, kube-apiserver, kube-controller-manager, CRDs,
`crossplane core start`, the functions, the provider: the functions are step 6, after Crossplane
core (step 5), and deliberately not before it. function-sdk-go v0.7.1 (`Serve` in `sdk.go`) starts a
Prometheus metrics server on `DefaultMetricsAddress = ":8080"` in every function, on all interfaces,
with no flag or environment variable in either function's CLI to move or disable it, and it ignores
a failed bind (`_ = metricsServer.ListenAndServe() // Ignore errors`). Crossplane core's metrics
port defaults to 8080 as well, and Crossplane refuses to start when the port is taken; the first
Railway deploy with the functions started first crash-looped on exactly that, and the harness had
hidden the collision (the incident and the blind spot are in the [2026-11-26
report](../reports/2026-11-26.md)). With Crossplane first, it owns 8080, every function's metrics
bind fails silently, and the functions listen on their loopback gRPC port only; a dial Crossplane
attempts before a function is up is an ordinary reconcile error it retries. `EXPOSE 8080` in the
Dockerfile remains Crossplane's metrics. The harness keeps `CP_CROSSPLANE_METRICS_PORT` at 8080
(so 8080 must be free on the host) and checks both halves: `crossplane core owns its metrics port
8080 (controller-runtime metrics served there)` and, per function, `<fn> listens on loopback only
(its SDK metrics bind on :8080 lost to Crossplane core)`.

The alternative, moving Crossplane's metrics off 8080 so that the order no longer matters, was
considered at review and not taken: the first function to start would then win the bind and serve
its SDK metrics on all interfaces, unauthenticated, where today every function is loopback-only.
The order also fails loudly if the SDK ever changes: an SDK that made the lost bind fatal would
exit before the mTLS readiness gate, which fails the boot, so a function bump cannot pass silently.
The clean long-term fix stays a small upstream patch adding `--metrics-address` to the functions,
carried like `hack/upstream/`.

**Drain.** Shutdown is reverse start
order, so the functions stop before Crossplane, which costs Crossplane a few failed dials while it is
itself stopping. With two functions the plane has seven components and the worst-case shutdown is
7 x `CP_SHUTDOWN_TIMEOUT` = 70 s; the supervisor's Railway warning says `70 is recommended ...
worst case 7 components x CP_SHUTDOWN_TIMEOUT 10 s`, and the live service's
`RAILWAY_DEPLOYMENT_DRAINING_SECONDS` was raised from 60 to 70 on 2026-11-26
([runbook](../getting-started/deploy-to-railway.md)).

**Memory.** Every name in `CP_FUNCTIONS` gets a 3% `GOMEMLIMIT` share (membership in the list,
not a `function-` prefix, decides what a function is; `CP_GOMEMLIMIT_PCT_<NAME>` overrides one
share), which brings the total to 91% with the default two; five functions reach exactly 100% and a
sixth fails the boot, since the shares would promise more than the container has. When the
container's limit is known, a function whose share comes to under 64 MiB gets a boot warning that
names `CP_GOMEMLIMIT_PCT_<NAME>` as the knob: a function idles at about 30 MiB RSS (measured on the
harness; the per-process numbers are in the [2026-11-26 report](../reports/2026-11-26.md)), and a
limit below twice that leaves its GC collecting continuously. A warning, not a failure: the
function still works, only slower, and the fix is a bigger container.

**Compositions and the namespaced provider.** What a Composition composes in Crossplane 2.x is the
namespaced managed resource (`railway.m.crossplane.io`; its `Project` is served at `v1alpha1`),
whose `providerConfigRef` defaults to `kind: ClusterProviderConfig, name: default`. The supervisor
therefore writes `ClusterProviderConfig/default` (`railway.m.crossplane.io/v1beta1`) beside the
legacy `ProviderConfig/default`, from the same `railway-creds` Secret.

**Adding a function.** Build its binary into the image under `CP_BIN_DIR` (the `functions-build`
stage clones a tag, checks that it resolves to the pinned commit and runs `go build`; pin the tag
and the commit in the Dockerfile `ARG`s and the Makefile,
check that its `go.mod` does not require a newer Go than the image's pin, because
`GOTOOLCHAIN=local` refuses to download one, and check that its SDK still treats a failed metrics
bind on :8080 as a no-op, because an SDK that made it fatal would break the start order above), add
the name to `CP_FUNCTIONS`, and refer to it from
a Composition by that name. A listed name without an executable fails the boot with the two ways
out named. Keep the count low: each function is a process with a port, a certificate, a GOMEMLIMIT
share and 10 s of worst-case drain.

The harness proves the whole path through the fixture under `hack/fixtures/functions-spike/` (a
harness fixture, not a product API): the XRD `xspikes.harness.railway.crossplane.io` (kind
`XSpike`, one field, `spec.name`) and two Compositions with the same two-step pipeline (`render`
through function-go-templating, `ready` through function-auto-ready). The default,
`xspike-configmap`, is hermetic: the `CompositionRevision` reaches `ValidPipeline=True`, the XR
`spike` is rendered into a core `v1 ConfigMap` labelled `crossplane.io/composite=spike` whose
`data.name` is the XR's `spec.name`, function-auto-ready marks the XR Ready (no provider involved),
and deleting the XR removes the ConfigMap; nothing leaves the local API server. The second,
`xspike-railway-project`, renders a Railway `Project` and runs only with `VERIFY_LIVE_RAILWAY=1`,
because it creates and deletes a real Railway project; without it, that path is one SKIP line.

## Capacity: etcd quota, snapshots and memory

**etcd quota.** `--quota-backend-bytes` is `CP_ETCD_QUOTA_BYTES`. The default, `auto`, is half the
filesystem under the state root, at most 2 GiB (Phase 1 shipped etcd's 8 GiB maximum, larger than a
small Railway volume; finding B5 of the [Phase 1 review](../reports/phase-1-review.md)); the other half is for
the write-ahead log, a defrag copy and the snapshots. The quota is what makes etcd refuse writes,
with a NOSPACE alarm, before the volume fills; a database that hits disk-full instead is how etcd
gets corrupted. An explicit value must lie between 100 MiB and 8 GiB and fit the filesystem, or the
boot fails; under twice the quota, or with less than the quota free, the boot warns. A Railway Hobby
volume (5 GB) gets a 2 GiB quota; a 0.5 GB volume gets 256 MiB, which is still far more than this
plane's objects need. The quota, filesystem size and free space are logged at boot.

**Maintenance.** A pass defragments the database when it is fragmented (a quarter or more of the
file, or over 100 MiB, is free inside it) and there is a copy's worth of free space, prunes the
snapshot directory to `CP_ETCD_SNAPSHOT_KEEP - 1` files, then writes `etcdctl snapshot save` to
`state/snapshots/etcd-<UTC time>.db` (file 0600, directory 0700) unless free space is under twice
the database size plus 64 MiB. It runs once after etcd answers and before the API server starts
(nothing is writing, and the snapshot is the state as the previous run left it), then every
`CP_ETCD_MAINTENANCE_INTERVAL` seconds (default 6 h, quantised to the 5 s supervise tick; 0
disables it), and whenever the supervisor receives `SIGUSR1` (at most once a minute). After boot the
pass is a background job, one at a time, so a slow or hung etcd never delays signal handling or the
component-death check; a pass still running at shutdown is stopped first. The boot pass takes no new
snapshot while one under an hour old exists, so a crash loop cannot rotate every good snapshot away.
`CP_ETCD_SNAPSHOT_KEEP=0` takes none. The pass never fails the boot or the supervisor: every error is
a logged warning and the next pass retries. In the harness the boot pass on a 91 MiB database took
under a second; nothing larger has been measured.

**The NOSPACE alarm.** When the database reaches the quota, etcd raises `NOSPACE` and refuses every
write except deletes. The API server cannot repair this on its own: its compactor first writes a
bookkeeping key, and that write is refused, so the space freed by deleting objects is never
reclaimed (observed: 500 s after deleting everything, the database had not shrunk). The supervisor
polls the alarm list every 60 s and, at most every 10 minutes, runs a recovery pass: compact to the
current revision (Kubernetes tolerates this; watchers re-list once), defragment, and disarm the
alarm once the database is under 90% of the quota. Only `NOSPACE` is ever cleared; a `CORRUPT` alarm
stays raised for a human. On a running plane that is the whole recovery: delete objects and wait
for the next poll. At boot, an etcd still alarmed after the pass stops the boot with the ways out,
because live data then fills over 90% of the quota and nothing later in the boot can proceed without
writes (booting on through the alarm was tried: `crossplane core init` fails five attempts later).
The ways out are to raise `CP_ETCD_QUOTA_BYTES` (the volume permitting) and redeploy, after which
the boot pass clears the alarm and objects can be deleted, or to restore an older snapshot. etcd's
own `--auto-compaction-retention 1` would compact within the hour; the pass does not wait for it.

**Restore.** The image ships `etcdutl`. Snapshots live on the same volume as the database, so they
are a rollback aid, not a backup: anything that takes the volume takes them, and any volume backup
or export includes them (Secrets inside are secretbox ciphertext, everything else is plaintext).
Copy them off the volume for a real backup. To restore: stop the service, move `state/etcd` aside,
run, as the service user or followed by `chown -R` to `CP_RUN_UID` and `chmod 700`,

```
etcdutl snapshot restore state/snapshots/<file> --data-dir state/etcd --name control-plane \
  --initial-cluster control-plane=https://127.0.0.1:2380 --initial-advertise-peer-urls https://127.0.0.1:2380
```

and start the service. The PKI on the same volume still matches the restored data (what B1 bought;
`etcdutl` works on the file offline, so no etcd certificate is involved, and the etcd CA on the same
volume still signs the running member's certificates). A restore rewinds the
cluster: managed resources created after the snapshot vanish from the API while the Railway objects
they created still exist, and Crossplane will not adopt them, so reconcile against Railway by hand. A
snapshot taken before an encryption-key rotation holds Secrets under the old key: boot with that key
as `CP_ENCRYPTION_KEY_PREVIOUS` and remove `state/ENCRYPTION` so they are re-encrypted. The restore
path is not exercised end to end yet; `etcdutl snapshot status` on every harness snapshot is.

**Memory.** Every component is a Go process, and a container at its memory limit gets an OOM kill
of whichever process the kernel picks. Each component is started with `GOMEMLIMIT` set to a share of
the container's limit: kube-apiserver 35%, etcd 15%, the provider 15%, kube-controller-manager 10%,
Crossplane 10%, that is 85 for the five core processes, plus 3% per composition function (91 with
the default two), leaving the rest for bash, the page cache and the terraform processes;
`CP_GOMEMLIMIT_PCT_<NAME>` overrides one share, and the total must stay at or under 100. The limit comes from `CP_MEMORY_LIMIT_BYTES` or, when
that is unset, from the cgroup (`memory.max`, then the v1 file), which works where the container
sees its own cgroup (Railway exposes it, cgroup v2, seen on the first deploy); where it does not, the boot warns and sets nothing, and `CP_MEMORY_LIMIT_BYTES`
is the supported override. `CP_GOMEMLIMIT_ENABLED=false` turns it off. Three limits to be plain
about. GOMEMLIMIT is a GC hint, not a cap: a component whose live heap exceeds its share collects
harder (the runtime caps that work at half its CPU) and can still grow, so real OOM protection is the
container limit. The terraform processes the provider forks inherit the provider's value each, so
their total is bounded only by the provider's reconcile concurrency. And etcd's database is
memory-mapped, so a database near a 2 GiB quota also means up to 2 GiB of page cache. The native
harness host has no cgroup limit and passes 4 GiB by default.
