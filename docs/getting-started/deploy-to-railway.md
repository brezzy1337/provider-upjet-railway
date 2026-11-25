# Deploy the control plane to Railway

_Last updated 2026-11-24, ahead of the first deploy. The steps below are what the image was built
for; the CLI commands were checked against Railway's CLI reference on that date but have not been
run, and anything marked **to confirm** is a Railway behaviour not yet observed. The page is updated
as the first deploy teaches us otherwise._

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
| `CP_MEMORY_LIMIT_BYTES` | expected; the service's memory limit in bytes | Railway is not known to expose the limit through the cgroup (**to confirm** from the boot line `memory limit ... (cgroup ...)`); without it no `GOMEMLIMIT` is set and B5's memory shares do nothing |

The supervisor reads `RAILWAY_TCP_PROXY_DOMAIN` and `RAILWAY_TCP_PROXY_PORT` and puts the proxy
hostname into the API server's serving certificate and `domain:port` into the exported kubeconfig.
It warns if the volume is mounted somewhere other than `CP_STATE_DIR`, if the drain window is
shorter than the shutdown, and if the service has no TCP proxy yet. No Railway healthcheck is
configured, deliberately: Railway's check is HTTP against the service port, and the API server's
`/readyz` needs a client certificate (D6 of the Phase 1 review). One replica only: the plane has one
etcd, and a volume pins a service to one instance (**to confirm**). The restart policy can stay at
Railway's default; the supervisor exits when a component dies and relies on being restarted.

## The first deploy, with the CLI

Install the CLI (Railway's script is curl-to-shell; the GitHub release binaries, Homebrew and npm
are the alternatives) and sign in; the codespace has no browser, so use the device-code flow:

```bash
bash <(curl -fsSL railway.com/install.sh)
railway login --browserless
```

Create the project and an empty service, then give the service its volume and proxy before the
first build, so the first boot already sees them:

```bash
railway init --name crossplane-control-plane
railway add --service control-plane \
  --variables RAILWAY_DOCKERFILE_PATH=cluster/images/control-plane/Dockerfile \
  --variables RAILWAY_DEPLOYMENT_DRAINING_SECONDS=60
railway volume add --service control-plane --mount-path /var/lib/control-plane/state
railway tcp-proxy create --service control-plane --port 6443
```

Set the two secrets in the dashboard (service, Variables, add, then seal them), and set
`CP_MEMORY_LIMIT_BYTES` to the service's memory limit. Generate the key locally and paste it; a
`railway variable set` on a command line would put it in the process list and shell history, and a
variable created by the CLI is not sealed until sealed in the dashboard. Keep a copy of the key in a
password manager. Never paste `railway logs` or `railway variable list` output into a report.

Deploy the working tree from a clean, committed checkout, so the deployed code is a known commit
(the first build compiles Crossplane, the provider and the patched Terraform provider from source
and takes several minutes; Railway's build time and builder memory limits are **to confirm**, and if
they bite, the fallback is to build the image in CI, push it to GHCR and point the service at the
image instead). Then watch the boot:

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
`VERSION` stamp refuses an older image on newer state. A volume can be attached to one running
container, so Railway should stop the old deployment before starting the new one rather than
overlapping them (**to confirm**; two containers on one etcd directory would be fatal). Secrets
rotation and the encryption-key rotation are described in the
[Architecture](../architecture/control-plane.md) page; an etcd snapshot is taken on the volume at
boot and every six hours (B5).

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

- `CP_MEMORY_LIMIT_BYTES` cannot be known by the template; it is a variable the deployer sets, or is
  left unset at the cost of `GOMEMLIMIT`.

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
