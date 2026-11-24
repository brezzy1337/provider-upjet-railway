# Deploy the control plane to Railway

_Written 2026-11-24, before the first deploy. The steps below are what the image was built for;
anything marked **to confirm** is a Railway behaviour that has not been observed yet. The page is
updated as the first deploy teaches us otherwise._

The control plane is one Railway service built from this repository's Dockerfile, with one volume
and one TCP proxy. Everything the service needs to know about itself, Railway tells it; the only
values a person supplies are two secrets.

## What the service needs

| Item | Value | Why |
|------|-------|-----|
| Source | this repository, `main`, Dockerfile at `cluster/images/control-plane/Dockerfile` | The build is self-contained and needs the repository root as its context, so the service's root directory stays `/` and `RAILWAY_DOCKERFILE_PATH` points at the subdirectory |
| Volume | mounted at `/var/lib/control-plane/state` | etcd data, PKI and the `VERSION` stamp. Railway mounts volumes root-owned; the image starts as root, takes ownership and drops privileges (B2) |
| TCP proxy | application port `6443` | The API server serves its own TLS, which an HTTP domain would terminate at the edge. Railway assigns the public `domain:port` |
| `RAILWAY_TOKEN` | a Railway **workspace or account** token, sealed | Written into the `railway-creds` Secret at boot; project tokens are rejected by the Terraform provider |
| `CP_ENCRYPTION_KEY` | `openssl rand -base64 32`, sealed | Secrets at rest; the image refuses to boot without it. Never on the volume |
| `RAILWAY_DEPLOYMENT_DRAINING_SECONDS` | `60` | Railway's default SIGTERM-to-SIGKILL window is 0 s; a clean stop of the five components needs up to 50 s |
| `CP_MEMORY_LIMIT_BYTES` | optional | Set only if the boot log says no cgroup limit was found; then `GOMEMLIMIT` is derived from it |

Nothing else. The supervisor reads `RAILWAY_TCP_PROXY_DOMAIN` and `RAILWAY_TCP_PROXY_PORT` and puts
the proxy hostname into the API server's serving certificate and `domain:port` into the exported
kubeconfig. It warns if the volume is mounted somewhere other than `CP_STATE_DIR`, if the drain
window is shorter than the shutdown, and if the service has no TCP proxy yet.

Sizing: the etcd quota defaults to half the volume (at most 2 GiB) and the `GOMEMLIMIT` shares to
the container's memory limit, so the same image fits a small plan and a large one. The native
harness ran the whole plane in well under 2 GB; the first deploy should look at Railway's memory
graph before choosing a limit.

## The first deploy, with the CLI

Install the CLI and sign in; the codespace has no browser, so use the device-code flow:

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

Set the two secrets in the dashboard (service, Variables, add as sealed), or from a shell where the
values do not land in history:

```bash
railway variable set --service control-plane "CP_ENCRYPTION_KEY=$(openssl rand -base64 32)"
# RAILWAY_TOKEN: paste it in the dashboard as a sealed variable
```

Deploy the working tree (the first build compiles Crossplane, the provider and the patched Terraform
provider from source and takes several minutes) and watch the boot:

```bash
railway up --service control-plane --detach
railway logs --service control-plane
```

The boot log ends with `control plane UP` and the external URL. Pull the exported kubeconfig out of
the container and use it:

```bash
railway service files download /var/lib/control-plane/kubeconfig-external ./kubeconfig-external \
  --service control-plane
kubectl --kubeconfig ./kubeconfig-external get --raw=/version
```

The kubeconfig is a 90-day cluster-admin credential (B3); keep it out of git.

## The smoke test over the internet

```bash
kubectl --kubeconfig ./kubeconfig-external apply -f examples-generated/cluster/railway/v1alpha1/project.yaml
kubectl --kubeconfig ./kubeconfig-external get project.railway.crossplane.io example -w   # until READY
# the project appears in the Railway dashboard, then:
kubectl --kubeconfig ./kubeconfig-external delete project.railway.crossplane.io example      # and it is gone
```

That is the Phase 2 exit criterion. Record the result in the day's report.

## Later deploys

Connect the service to the repository so pushes to `main` deploy, instead of uploading the tree:

```bash
railway service source connect --service control-plane --repo brezzy1337/provider-upjet-railway --branch main
```

A redeploy keeps the volume, so the cluster identity and data survive (B1); the supervisor's
`VERSION` stamp refuses an older image on newer state. Secrets rotation and the encryption-key
rotation are described in the [Architecture](../architecture/control-plane.md) page; an etcd
snapshot is taken on the volume at boot and every six hours (B5).

## Publishing it as a template

A Railway template is composed in the dashboard (Workspace settings, Templates, New Template, or
"Generate Template from Project" on a working project) and holds the same shape as above:

- Service source: this public repository, branch `main`, root directory `/`, variable
  `RAILWAY_DOCKERFILE_PATH=cluster/images/control-plane/Dockerfile`.
- Volume at `/var/lib/control-plane/state`; TCP proxy on `6443`.
- Variables: `RAILWAY_TOKEN` left for the deployer to fill (with a description saying workspace or
  account token), `RAILWAY_DEPLOYMENT_DRAINING_SECONDS=60`, and `CP_ENCRYPTION_KEY` generated at
  deploy time by a template function that produces exactly the base64 of 32 bytes, which is what the
  image accepts:

```
${{secret(43, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/")}}=
```

Publishing adds it to the marketplace and provides a `Deploy on Railway` button for the README.
Open-source templates with support engagement earn a kickback. **To confirm:** whether the template
composer accepts a Dockerfile path for a GitHub source as a variable (it is a plain service variable,
so it should), and what the deployer sees for the proxy hostname before the first boot (nothing is
needed from them, since the supervisor reads it at runtime).

Railway's newer Infrastructure as Code (`.railway/railway.ts`, applied with `railway config apply`)
can describe the service, the volume and the variables, but not yet the TCP proxy or the Dockerfile
path, and it needs Node.js for its SDK; the CLI steps above do not. Revisit once it covers both.
