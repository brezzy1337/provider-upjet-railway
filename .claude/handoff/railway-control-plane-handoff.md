# Handoff — Railway-hosted Crossplane control plane

> **Correction (2026-11-21):** the extraction to a separate control-plane repository described below
> never happened. The Phase 1 code (`cluster/images/control-plane/`, `hack/native-cluster.sh`) is on
> `main` of this repo (merged 2026-11-21 via PR #3), not "historical". Current status is in
> `docs/roadmap.md` and the findings in `docs/architecture/phase-1-review.md`; the rest of this
> file is kept as the 2026-08 record.

**Written:** 2026-08-25, for a fresh Claude Code session working in this repo
(`brezzy1337/provider-upjet-railway`, branch `main`).
**Status:** the Railway provider works end-to-end. Phase 1 (control-plane image + supervisor) is
built and proven natively, and the live smoke test passed on 2026-08-26: a `Project` reconciled to
Ready, was confirmed in Railway independently, and deleting it removed it upstream. See
"Phase 1 status" below.

## Where we are (verified, not assumed)

- This repo is a Crossplane provider for Railway generated with Upjet v2.4.1 from
  `terraform-community-providers/railway` 0.6.2. Nine kinds in group `railway.crossplane.io`
  (`Project`, `Environment`, `Service`, `Variable`, `VariableCollection`, `SharedVariable`,
  `CustomDomain`, `ServiceDomain`, `TCPProxy`) plus namespaced twins under `railway.m.crossplane.io`.
- **Live-verified 2026-08-25:** `Project` create → visible in Railway → delete → gone, via kind +
  Crossplane 2.2.1 + the provider run out-of-cluster. Only `Project` has been tested live.
- **Upstream bug + patch:** the Terraform provider never removed resources from state on not-found,
  which breaks Upjet's observe on first reconcile and after delete. Fixed for all nine resources;
  upstream PR https://github.com/terraform-community-providers/terraform-provider-railway/pull/93.
  Until released, build the Terraform provider from `hack/upstream/0001-*.patch` at tag v0.6.2 into
  the filesystem mirror (`hack/upstream/README.md`); `hack/run-provider.sh` wires it in.
  **Watch PR #93** — when merged/released, bump `TERRAFORM_PROVIDER_VERSION`, regenerate, drop the patch.
- **Auth:** `ProviderConfig` credentials JSON `{"token": ...}` must be a Railway **workspace or
  account** token (Account Settings → Tokens, pick the workspace). Project tokens fail with
  "Not Authorized" because the provider only sends `Authorization: Bearer`.
- Scripts: `hack/dev-cluster.sh` (kind + Crossplane + CRDs + ProviderConfig from `$RAILWAY_TOKEN`),
  `hack/run-provider.sh` (out-of-cluster provider with the patched mirror),
  `hack/native-cluster.sh` (the whole control plane as bare processes, no container runtime).
- Environment notes: the Theurgy codespace used so far is disk-starved (32 GB, ~13 GB base image);
  it holds a kind cluster `railway-dev` that is safe to delete (recreate with `hack/dev-cluster.sh`).
  The codespace's built-in GitHub token is scoped to Theurgy only; pushes to this repo used a classic
  PAT via `git -c credential.helper='!gh auth git-credential'` with `GH_TOKEN` set.

## The goal

A **Crossplane control plane hosted on Railway** that provisions Kubernetes clusters on
**DigitalOcean, AWS, and GCP** (and Railway resources via this provider). Users `kubectl apply` a
cloud-agnostic `KubernetesCluster` claim; a Composition picks the DOKS/EKS/GKE implementation; the
new cluster's kubeconfig comes back as a Crossplane connection secret.

## Design (decided)

**Nodeless Kubernetes in one Railway service:** `etcd` + `kube-apiserver` + **Crossplane core** +
provider processes, supervised in a single container, etcd data on a Railway volume. There are no
kubelets/scheduler and none are needed — nothing here runs pods; providers reconcile objects
straight into cloud APIs. All of this runs unprivileged (Docker/kind would not).

- **Providers run as supervised processes**, not Crossplane packages: the package manager creates
  Deployments that can never schedule on a nodeless API server. Each provider = binary + its CRDs
  applied at boot. Ours: `cmd/provider` (out-of-cluster mode, as `hack/run-provider.sh`).
- **Crossplane core** runs out-of-cluster too (`crossplane core start`) — required for XRDs and
  Compositions; package manager unused.
- **Keep the API server small:** use *family* providers, never the monoliths —
  `provider-aws-eks` + `provider-aws-ec2` + `provider-aws-iam`; `provider-gcp-container` +
  `provider-gcp-compute`; DO: `crossplane-contrib/provider-digitalocean` (**verify maintenance
  status before depending on it**). `provider-upjet-aws` monolith ≈ 1,000 CRDs and gigabytes of RAM.
  Budget 2–4 GB RAM once AWS is in.
- **Exposure:** kube-apiserver must serve its own TLS end-to-end. Railway HTTP domains terminate
  TLS at the edge, so put the API server behind a **Railway TCP proxy** (6443), with the proxy
  hostname in the serving cert SANs; bearer-token (static token file) or client-cert auth. Never
  anonymous.
- **Secrets:** cloud credentials arrive as Railway env vars → written into `ProviderConfig`
  Secrets by the boot script (never baked into the image). Provisioned clusters' kubeconfigs are
  read back as connection secrets with `kubectl`.
- **Reuse:** `cluster/images/provider-upjet-railway/Dockerfile` already builds provider + terraform
  + plugin mirror (`terraformrc.hcl` layout); the control-plane image extends that pattern.

## Phase 1 status (2026-08-25) — built, and proven without Docker

> **Superseded.** This section originally claimed a move to a separate repository on 2026-08-26.
> That never happened; see the correction at the top and `docs/architecture/control-plane.md`.

`cluster/images/control-plane/{Dockerfile,control-plane.sh,Makefile}` exist. The Dockerfile is
fully self-contained (multi-stage: builds `cmd/provider`, Crossplane core v2.2.1 from source, and
the patched Terraform provider; fetches etcd/kube-apiserver/kube-controller-manager/kubectl/
terraform at pinned versions) so Railway can build it straight from the repo — unlike
`cluster/images/provider-upjet-railway/Dockerfile`, which needs `make build` first.

`hack/native-cluster.sh` runs the **same supervisor script** against bare processes on a box with
no container runtime (`build` / `up` / `verify` / `down` / `clean`). Verified 16/16 checks, and
again after a restart on the same etcd data: etcd, apiserver TLS on a high port, anonymous
rejected, client-cert *and* bearer-token kubeconfigs from outside, all 44 CRDs Established,
`crossplane core start` healthy, 21 provider controllers running, terraform resolving the patched
mirror. The Railway `Project` create/delete smoke test is **not** done — it needs `RAILWAY_TOKEN`.

Things learned that change the design:

- **kube-controller-manager is required after all.** Owner-reference cascading deletion is the
  garbage collector's job and the GC lives in kube-controller-manager, not the API server. Without
  it, deleting an XR orphans every composed resource forever. The supervisor runs it with only
  node-independent controllers (`garbagecollector,namespace,serviceaccount,serviceaccount-token,
  resourcequota,ttl-after-finished`) — proven working nodeless.
- **`crossplane core start --package-runtime=External`** is the right setting: with it, Crossplane
  never registers the controllers that create Deployments/Services for Provider and Function
  packages. Installing a package for its CRDs while running the binary as a process becomes viable.
- **`crossplane core start` will not boot without `--tls-client-certs-dir`.** It unconditionally
  loads an mTLS client cert (its identity to composition Functions). `crossplane core init` puts
  that material in a Secret; out of cluster there is no projected volume, so the supervisor unpacks
  the Secret to disk between the two steps.
- **`crossplane core init` races itself on a brand new API server** — it applies the CRDs then
  immediately creates a `Lock`, and its cached REST mapper 404s. The supervisor applies the CRDs
  with `kubectl` and waits for Established *first*.
- **Webhooks are off** (`--webhook-enabled=false` for both init and start). Crossplane's webhook
  configurations point at a Service, and with no Pods nothing populates its EndpointSlice. Cost:
  the Usage/protection controllers and the Usage admission webhook do not run, so deletion-ordering
  protection is unavailable. Probable fix, untested: hand-write an EndpointSlice pointing at the
  container's own IP — kube-apiserver resolves webhook Services itself, no kube-proxy needed.
- **Compositions need a Function, and Functions are gRPC servers.** The XR pipeline dials
  `FunctionRevision.status.endpoint` — an arbitrary gRPC target. Under `External` runtime nothing
  sets it, so Phase 3 can run e.g. `function-patch-and-transform` as another supervised process and
  write `status.endpoint` itself. Caveat: the runner always uses mTLS, so the function must serve a
  cert signed by the `crossplane-root-ca` Secret.
- **Railway containers are dual-stack and `hostname -i` returns the IPv6 address first**, which
  makes kube-apiserver refuse to start ("service IP family must match public address family"). The
  supervisor prefers a routable IPv4 and switches the service CIDR to IPv6 only if it has to.
- A **front-proxy CA** is needed (`--requestheader-client-ca-file` and friends). Without it the
  `extension-apiserver-authentication` ConfigMap is incomplete and kube-controller-manager logs
  "missing content for CA bundle" forever. It must be a separate CA from the cluster CA.
- Flag traps: the provider's kingpin rejects `--leader-election=false` ("unexpected false") — use
  `--no-leader-election`; `--certs-dir` defaults to `/tls/server` and must be blanked. Crossplane's
  kong renders `CRDsPath` as `--cr-ds-path` and `TLSCASecretName` as `--tlsca-secret-name`.
- Without `--debug` the provider installs a no-op controller-runtime logger and prints nothing, so
  readiness has to come off `controller_runtime_active_workers` on the metrics port, not the log.

## Phases

1. **Control-plane image (local first).** `cluster/images/control-plane/Dockerfile` + supervisor
   script: etcd → kube-apiserver → apply CRDs (ours + Crossplane's) → crossplane core →
   provider-upjet-railway. Prove with `docker run` and `kubectl` from outside; repeat the `Project`
   create/delete smoke test through it. This replaces kind as the dev cluster.
   Done = `kubectl --kubeconfig <generated> apply -f examples-generated/cluster/railway/v1alpha1/project.yaml`
   goes Ready and the project appears in Railway; delete removes it.
2. **Deploy to Railway.** Service from the image, volume at etcd's data dir, TCP proxy on 6443,
   env: `RAILWAY_TOKEN`, API token/cert material. Same smoke test over the internet.
   Consider provisioning the service *with this provider* once it exists (dogfood).
3. **First cloud: DigitalOcean.** Add its provider as a process + CRDs; `KubernetesCluster` XRD with a
   DOKS Composition; provision a real cluster; read back its kubeconfig. Then EKS and GKE as
   additional Composition variants using the family providers.

## Also on the list

- Live-test `Service` + `Variable` (exercises the patched not-found paths for real); hand-written
  `examples/` per resource; uptest.
- Import support: external names are `IdentifierFromProvider`; upstream import IDs are colon
  composites (`config/external_name.go`) — needs per-resource `GetIDFn` for adopting existing objects.
- Volumes/deployments are absent upstream (volume is only nested in `railway_service`) — contribute
  standalone `railway_volume`/`railway_deployment` resources upstream later.
- CI: build + push xpkg / control-plane image to ghcr.io.

## Open questions for the user
- Railway service sizing/plan for 2–4 GB RAM and a volume; which Railway workspace hosts it.
- DigitalOcean credentials (API token) for phase 3; AWS/GCP later.
- Public or private image registry (ghcr.io assumed).
