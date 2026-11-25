# Deploy the control plane to Railway

_Last updated 2026-11-25, after the first deploy. The deploy and the `Project` smoke test over the
internet passed that day (the [2026-11-25 report](../reports/2026-11-25.md) has every number);
what the page states about Railway's behaviour was observed on it, read from the service's own
configuration, or carries the date it was checked in Railway's documentation, unless marked
**to confirm**._

The control plane is one Railway service built from this repository's Dockerfile, with one volume
and one TCP proxy. Everything the service needs to know about its network, Railway tells it; the
only secrets a person supplies are two, plus three ordinary settings.

## What the service needs

| Item | Value | Notes |
|------|-------|-------|
| Source | this repository, `main`, `RAILWAY_DOCKERFILE_PATH=cluster/images/control-plane/Dockerfile` | the build needs the repository root as its context, so the root directory stays `/`; the Dockerfile is written for Railway's validator, see [The control-plane image on Railway's builder](../architecture/control-plane-image.md) |
| Volume | mounted at `/var/lib/control-plane/state`; a few GB is plenty | the [state root](../architecture/control-plane.md#the-state-root); root-owned mounts are handled by the image; the etcd quota sizes itself to half the volume ([Capacity](../architecture/control-plane.md#capacity-etcd-quota-snapshots-and-memory)); snapshots live on the same volume and are not a backup |
| TCP proxy | application port `6443`, created **before the first deploy** | the API server serves its own TLS; Railway assigns the public `domain:port` |
| `RAILWAY_TOKEN` | a Railway workspace (team) or account token, **sealed** | see [Authentication](authentication.md); project tokens are rejected |
| `CP_ENCRYPTION_KEY` | `openssl rand -base64 32`, **sealed**, and backed up elsewhere | the image refuses to boot without it; a sealed variable cannot be read back, and losing the key makes every Secret in etcd unreadable |
| `RAILWAY_DEPLOYMENT_DRAINING_SECONDS` | `60` recommended | Railway's default SIGTERM-to-SIGKILL window is 0 s; a clean stop takes about 10 s, the worst case 50 s |
| `CP_MEMORY_LIMIT_BYTES` | not needed | Railway exposes the limit through cgroup v2 (`memory.max`); the boot line read `memory limit 22888 MiB (cgroup v2 memory.max)` on a Pro workspace |

The supervisor reads `RAILWAY_TCP_PROXY_DOMAIN` and `RAILWAY_TCP_PROXY_PORT` and puts the proxy
hostname into the API server's serving certificate and `domain:port` into the exported kubeconfig.
It warns if the volume is mounted somewhere other than `CP_STATE_DIR`, if the drain window is
shorter than the shutdown, and if the service has no TCP proxy yet. No Railway healthcheck is
configured, deliberately: Railway's check is HTTP against the service port, and the API server's
`/readyz` needs a client certificate (D6 of the Phase 1 review). One replica only: the plane has one
etcd, and a volume pins a service to one instance (**to confirm**; the service ran with one replica
throughout). The restart policy can stay at Railway's default (`ON_FAILURE` with 10 retries, as the
service's manifest showed); the
supervisor exits when a component dies and relies on being restarted. A boot that fails its
configuration checks therefore restarts about every two seconds until the retry cap, and the
deployment's status stays `SUCCESS` the whole time, because that status means the container
started, not that the application is up: read the deploy log, not the status.

## The first deploy, with the CLI

Install the CLI (Railway's script is curl-to-shell; the GitHub release binaries, Homebrew and npm
are the alternatives) and sign in; the codespace has no browser, so use the device-code flow:

```bash
bash <(curl -fsSL railway.com/install.sh)
railway login --browserless
```

Create the project and an empty service, then give the service its volume and proxy before the
first build, so the first boot already sees them (the first deploy on 2026-11-25 reused a project
and service that already existed, so `init` and `add` were not run; the volume was moved with
`railway volume update --mount-path` and the proxy already existed):

```bash
railway init --name crossplane-control-plane
railway add --service control-plane \
  --variables RAILWAY_DOCKERFILE_PATH=cluster/images/control-plane/Dockerfile \
  --variables RAILWAY_DEPLOYMENT_DRAINING_SECONDS=60
railway volume add --service control-plane --mount-path /var/lib/control-plane/state
railway tcp-proxy create --service control-plane --port 6443
```

Set the two secrets in the dashboard (service, Variables, add, then seal them). Generate the key
locally and paste it; a `railway variable set` on a command line would put it in the process list
and shell history, and a variable created by the CLI is not sealed until sealed in the dashboard.
Paste the token alone: a current Railway token is not a UUID and contains underscores, and the image
checks its character set at boot (see [Authentication](authentication.md)). Keep a copy of the key
in a password manager. Never paste `railway logs` or `railway variable list` output into a report.
Two things seen on the first deploy: a variable edited or deleted, by the dashboard or the CLI, did
not redeploy the service by itself (`railway service redeploy --yes` reuses the built image and
takes about a minute to a running container), and a `railway ssh` shell receives every service
variable, sealed ones included, in its environment, so SSH access to the service is access to both
secrets.

Deploy the working tree from a clean, committed checkout, so the deployed code is a known commit
(the build compiles Crossplane, the provider and the patched Terraform provider from source; the
first one on Railway took under three minutes with no cache, see
[The control-plane image on Railway's builder](../architecture/control-plane-image.md), which also
records what Railway's Dockerfile validator rejects). Then watch the boot:

```bash
git status --short            # must be empty
railway up --service control-plane --detach
railway logs --service control-plane
```

The boot log ends with `control plane UP` and the external URL. Pull the exported kubeconfig out of
the container into the gitignored `.work/` directory and use it:

```bash
railway service files download /var/lib/control-plane/kubeconfig-external .work/kubeconfig-external \
  --service control-plane
kubectl --kubeconfig .work/kubeconfig-external get --raw=/version
```

The kubeconfig is a 90-day cluster-admin credential (B3). `.gitignore` and `.dockerignore` exclude
`kubeconfig-external*`, `*.kubeconfig`, `*.key`, `*.pem` and `.env*`, so neither git nor a build
context picks it up; `railway ssh -- cat /var/lib/control-plane/kubeconfig-external` is the fallback
if the file download is not available.

## The smoke test over the internet

```bash
kubectl --kubeconfig ./kubeconfig-external apply -f
examples-generated/cluster/railway/v1alpha1/project.yaml
kubectl --kubeconfig ./kubeconfig-external get project.railway.crossplane.io example -w   # until
READY
# the project appears in the Railway dashboard, then:
kubectl --kubeconfig ./kubeconfig-external delete project.railway.crossplane.io example      # and
it is gone
```

That is the Phase 2 exit criterion. Record the result in the day's report.

## Later deploys

Connect the service to the repository so pushes to `main` deploy, instead of uploading the tree:

```bash
railway service source connect --service control-plane --repo brezzy1337/provider-upjet-railway
--branch main
```

A redeploy keeps the volume, so the cluster identity and data survive (B1); the supervisor's
`VERSION` stamp refuses an older image on newer state. Railway stops the old container before it
starts the new one: on the 2026-11-25 redeploy the old supervisor logged `shutting down` ten seconds
before the new container mounted the volume, and the API server answered again fourteen seconds
after the shutdown began, with the same kubeconfig (same CA) and the state root reused. Two
containers never shared the etcd directory. A failed replacement does not keep the old container
either: when a build failed after a volume change, Railway removed the running deployment anyway,
so a redeploy on a live plane is a short outage at best and a longer one if the build breaks.
Changing the volume's mount path also redeploys, from the service's stored code snapshot rather
than a new upload. Secrets rotation and the encryption-key rotation are described in the
[Architecture](../architecture/control-plane.md) page; an etcd snapshot is taken on the volume at
boot and every six hours (B5), and `etcdutl snapshot restore` works in the image (drilled offline
into a scratch directory on 2026-11-25; a live restore still needs the service stopped and has not
been done).

**If the proxy changes.** A proxy added, deleted or recreated after a boot changes the hostname or
port the service is told about. The serving certificate carries the new hostname only after the next
boot, which reissues it because the SAN set changed; until then clients through the new proxy see a
certificate name mismatch. Redeploy, then download the kubeconfig again: the CA is unchanged, so an
existing kubeconfig only needs its server URL updated.

## Publishing it as a template

A Railway template is composed in the dashboard (Workspace settings, Templates, New Template, or
"Generate Template from Project" on a working project) and has the same shape as the table above,
with three differences:

- `RAILWAY_TOKEN` is left for the deployer to fill, with a description saying which token kinds work.
- `CP_ENCRYPTION_KEY` is generated at deploy time by a template function. Railway's own example for
  the base64 of 32 bytes is `secret(43, <base64 alphabet>)` followed by `=`, but a random 43rd
  character is canonical base64 only one time in four; decoders still yield the 32 bytes and the
  image accepts the key (checked), so prefer the strictly canonical form anyway:

```
${{secret(42, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/")}}${{secret(1, "AEIMQUYcgkosw048")}}=
```

- `CP_MEMORY_LIMIT_BYTES` is not needed: the cgroup supplies the limit (a deployer may still override
  it).

**To confirm** on the composer: that a template can carry the TCP proxy (if not, creating it is the
deployer's one post-deploy step and the next boot picks it up), and that `RAILWAY_DOCKERFILE_PATH`
as a plain variable is honoured for a GitHub source. Publishing adds the template to the marketplace
and provides a `Deploy on Railway` button for the README; open-source templates with support
engagement earn a kickback.

Railway's newer Infrastructure as Code (`.railway/railway.ts`, applied with `railway config apply`)
describes services, volumes and variables. As of 2026-11-24 its reference documents neither a TCP
proxy nor a Dockerfile path, and the generally available TypeScript path needs Node.js for its SDK
(Python and Go authoring are in beta). The CLI steps above need none of that; revisit when the
reference covers the proxy and the Dockerfile path.
