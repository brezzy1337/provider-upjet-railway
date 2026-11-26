# Roadmap and status

_Last updated 2026-11-26._

## End goal

A Crossplane control plane hosted on Railway provisions Kubernetes clusters on DigitalOcean (then
AWS and GCP). Inside those clusters will run [Hermes](https://hermes-agent.nousresearch.com) AI agent
instances, to be reached from the user's Railway-hosted application over the cluster's ingress.
Nothing of that is built yet. Hermes is a Kubernetes workload, not a Railway service, so this provider's job is the Railway side only:
the control-plane service itself and the user application. See
[Architecture](architecture/control-plane.md).

## Where things stand

| Area | Status |
|------|--------|
| Code generation | Done. Nine resources generated from `terraform-community-providers/railway` 0.6.2 with Upjet v2.4.1 (pre-release build). `make generate` re-run 2026-11-20 reproduces the committed tree exactly. |
| Build and unit tests | Passed 2026-11-20 on Go 1.26.11: `go build`, `go test`, `golangci-lint` with 0 issues. The patched Terraform provider builds from `hack/upstream/` and its tests pass. |
| Live verification | `Project` create → visible in Railway → delete → gone, via kind + Crossplane 2.2.1 + the provider out-of-cluster (2026-08-25, repeated through the native control plane 2026-08-26, and over the internet from the Railway-hosted control plane 2026-11-25). No other kind has been exercised live. |
| Upstream dependency | Blocked on [PR #93](https://github.com/terraform-community-providers/terraform-provider-railway/pull/93) (open, no activity since 2026-08-25). Upstream shipped 0.6.3 on 2026-10-19 **without** the fix. We build from a patch; see [The not-found patch](upstream/not-found-patch.md). |
| Control plane | Phase 1 done; merged to `main` 2026-11-21 (PR #3): `cluster/images/control-plane/` and `hack/native-cluster.sh`. Results and review findings in the [Phase 1 review](reports/phase-1-review.md). Phase 2 started 2026-11-21: B1 (PR #5), B2 (PR #6), B3 (PR #7), B4 (PR #8), B5 (PR #9) and etcd client authentication (PR #10) done and reviewed in the [Phase 2 review](reports/phase-2-review.md). **Deployed to Railway 2026-11-25** (project `do-k8-crossplane-control-plane`, service `control-plane`, sfo): boots in 16 s, reachable over the internet through the TCP proxy, `Project` smoke test passed; two deploy-day fixes, PR #13 (Dockerfile for Railway's validator) and PR #14 (token character set). Phase 2 done; see the [2026-11-25 report](reports/2026-11-25.md). |
| Package publishing | No xpkg or image has been pushed to a registry yet. CI workflows exist from the Upjet template but have not been exercised for a release. |

## Decisions

1. **0.6.2 + patch, or 0.6.3 + rebased patch.** Resolved for Phase 2 (2026-11-21): stay on 0.6.2 +
   patch. 0.6.3 reshapes `railway_service` (adds `start_command`, health check, restart policy, build
   settings, updatable regions) and adds `target_port` to `railway_service_domain`; none of that is
   needed to host the control plane (image, volume, TCP proxy, env vars). Revisit when a Railway
   service needs those fields or when upstream merges the not-found fix. Moving means rebasing
   `hack/upstream/0001-*.patch`, regenerating, and re-reviewing the `Service` schema.
2. **Railway plan and sizing.** Resolved by use (2026-11-25): the service runs in the user's Pro
   workspace, project `do-k8-crossplane-control-plane` (created 2026-08-27 for Phase 1 and reused),
   with the plan's 24 GB / 24 vCPU limit and a 50 GB volume; idle usage is about 0.9 GB. A smaller
   explicit limit is a later tuning question.
3. Registry for the xpkg and control-plane image (ghcr.io assumed).
4. **Where the control plane lives.** Resolved 2026-11-21: in this repository
   (`cluster/images/control-plane/`), merged from the `phase-1/control-plane-image` branch. A
   Railway service can build from a subdirectory, so a separate repository is not needed for
   Phase 2; revisit only if the control plane becomes a product on its own.

## Phases

### Phase 1: control-plane image. Done

A single container running etcd, kube-apiserver, kube-controller-manager (node-independent
controllers only), Crossplane core and this provider as supervised processes. Proven natively,
17 checks at the time (16 before the namespaced-CRD count, 21 after B1 added state-root and
identity checks), including restart on persisted etcd data; re-verified on `main` 2026-11-21.
`hack/native-cluster.sh` is also the way to run the full stack in an environment without Docker,
such as the current codespace. The [Phase 1 review](reports/phase-1-review.md) records what
was verified, what the review found, and what Phase 2 must fix before deploying (B1 to B5: PKI on
the volume, volume ownership, secrets encryption and audit, token handling, etcd quota).

### Phase 2: deploy to Railway. Done

Service from the image, one volume mounted at `CP_STATE_DIR` (etcd data, PKI and `VERSION` stamp;
B1, done 2026-11-21 in PR #5; ownership of that volume handled by the image itself, B2, done
2026-11-22 in PR #6; Secrets at rest, audit and credential lifetimes, B3, done 2026-11-22 in PR #7;
the Railway token out of every component's environment, B4, done 2026-11-22 in PR #8, its character
set widened 2026-11-25 after the first deploy refused a post-incident token; etcd quota,
snapshots and GOMEMLIMIT, B5, done 2026-11-22 in PR #9; etcd client authentication, the B3 leftover,
done 2026-11-22 in PR #10), TCP proxy on 6443, env vars for the Railway token, `CP_ENCRYPTION_KEY`
and API-server credential material. Nothing from the Phase 1 review blocks the first deploy any
more; the procedure is [Deploy the control plane to Railway](getting-started/deploy-to-railway.md),
and since PR #12 the service configures its own endpoint from Railway's variables. **Deployed
2026-11-25 and the `Project` smoke test passed over the internet**, which was the exit criterion; the
day needed two fixes, the Dockerfile for Railway's validator (PR #13) and the B4 token character set
for Railway's post-incident tokens (PR #14). Details in the [2026-11-25 report](reports/2026-11-25.md).
Still open from this phase: connecting the service to the GitHub repository instead of uploading
the tree, and revisiting Railway's Infrastructure as Code once its reference covers the TCP proxy
and the Dockerfile path. Publishing the deploy as a Railway template is **deferred until Phase 3 is
built and tested** (decided 2026-11-25): a template named for Kubernetes clusters must deliver them,
and the series will be one template per platform, the first being the Railway-provider-only plane. Consider
provisioning the service with this provider once it exists. First spike of Phase 3: a composition
function as a supervised process, since every XRD depends on it.

### Phase 3: first cloud and the workload catalogue. Next

Decided 2026-11-26. In order:

1. **Composition functions as supervised processes.** Every Composition needs one, and a function is
   a gRPC server that must serve a certificate signed by Crossplane's root CA, in a plane with no
   pods to run it in. The spike runs one function as a supervised process with its endpoint written
   by hand and proves a Composition through it. Candidates: `function-go-templating` or
   `function-kcl` for rendering and branching, `function-auto-ready` for readiness; keep the count
   low, each is a process.
2. **DigitalOcean.** The DigitalOcean provider as another supervised process, a `KubernetesCluster`
   XRD with a DOKS Composition, a real cluster provisioned, its kubeconfig read back as a connection
   Secret, and from that Secret a per-cluster `ProviderConfig` for provider-kubernetes and
   provider-helm, which also join the plane as supervised processes. Check the DigitalOcean
   provider's maintenance status first; it is a hand-written native provider, not an Upjet one.
3. **The `Workload` XRD with presets.** One namespaced composite resource (Crossplane 2.x: used
   directly, no claim) instead of a `HermesAgent` XRD: `spec.clusterRef` names the
   `KubernetesCluster`, `spec.preset` picks a Composition (by label through
   `spec.crossplane.compositionSelector`, or by a function branching on the field), and the schema
   enforces one block per preset with CEL validation rules. Every preset renders to the same two kinds, provider-helm's `Release`
   and provider-kubernetes's `Object`, so a new preset is a new Composition, not an API change.
   - `hermes`, first: model-provider key, channel tokens, volume size, replicas; renders a
     Deployment, a PersistentVolumeClaim, a Service and an Ingress (the mount path `/opt/data`, the
     port 8642 and the image come from the Hermes Docker guidance and are confirmed in the preset
     spike, not before).
   - `helm`, custom: chart repository, name, version, values; one `Release`.
   - `manifests`, custom: a list of Kubernetes objects inline or by Git or OCI reference; one
     `Object` per manifest.
   - Guardrails for the custom presets from day one, since they apply arbitrary manifests with the
     target cluster's admin credentials: the namespace is written by the Composition, not taken from
     the manifest; a CEL deny list (no `hostPath`, no privileged containers, no cluster-scoped kinds
     without an explicit flag); a reduced-RBAC kubeconfig per workload when tenants differ from the
     operator.
   - Optional later: a thin `HermesAgent` XRD that composes a `Workload` with `preset: hermes`, so
     both front doors exist on one implementation.
   The same model applies to `KubernetesCluster`: a namespaced composite resource, no claim.
4. **The endpoint written back** to the application's Railway service as a `Variable` through this
   provider, closing the loop described in the [Introduction](architecture/introduction.md).

Done when a `Workload` with `preset: hermes` on a provisioned DOKS cluster answers on the cluster's
ingress, and a `helm` or `manifests` workload lands beside it. The per-platform Railway templates
follow this phase (see Phase 2). The work is kicked off from the handoff
`.claude/handoff/phase-3-functions-spike.md`.

### Phase 4: more clouds

Decided 2026-11-26 to keep out of Phase 3: **EKS and GKE** as additional `KubernetesCluster`
Composition variants using the Upjet family providers (`provider-aws-eks`, `provider-aws-ec2`,
`provider-aws-iam`; `provider-gcp-container`, `provider-gcp-compute`), each with its own credentials
wired the way the Railway token is. The AWS family providers add a large CRD set to the API server
and the 2 to 4 GB memory budget the Architecture page names, so this waits until the DigitalOcean
path works end to end and the `Workload` catalogue is in use.

## Provider backlog

* Live-test `Service` and `Variable`; they exercise the patched not-found paths with real IDs.
* Hand-written `examples/` per kind (today only `examples-generated/` exists, and the generated
  `Variable` example still references an `upbound-system` namespace from the template).
* `uptest` end-to-end suite.
* Import support: per-resource `GetIDFn` so existing Railway objects can be adopted; see
  [External names and import](concepts/external-names.md).
* Standalone `railway_volume` and `railway_deployment` do not exist upstream; contribute them there,
  then regenerate.
* CI: build and push the xpkg and image to ghcr.io on tag.
* Refresh the 2026-08 handoff in `.claude/handoff/`; it describes an extraction to a separate
  repository that never happened.
