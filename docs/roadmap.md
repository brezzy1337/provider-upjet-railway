# Roadmap and status

_Last updated 2026-11-19._

## Where things stand

| Area | Status |
|------|--------|
| Code generation | Done. Nine resources generated from `terraform-community-providers/railway` 0.6.2 with Upjet v2.4.1 (pre-release build). |
| Build and unit tests | Passed as of 2026-08-26. Not re-run since; see [Development](getting-started/development.md) for the toolchain. |
| Live verification | `Project` create → visible in Railway → delete → gone, via kind + Crossplane 2.2.1 + the provider out-of-cluster (2026-08-25, repeated through the native control plane 2026-08-26). No other kind has been exercised live. |
| Upstream dependency | Blocked on [PR #93](https://github.com/terraform-community-providers/terraform-provider-railway/pull/93) (open, no activity since 2026-08-25). Upstream shipped 0.6.3 on 2026-10-19 **without** the fix. We build from a patch; see [The not-found patch](upstream/not-found-patch.md). |
| Control plane | Phase 1 done and extracted to its own repository (`brezzy1337/DigitalOcean-K8-Crossplane-Control-Plane`). Phase 2 not started. See [Architecture](architecture/control-plane.md). |
| Package publishing | No xpkg or image has been pushed to a registry yet. CI workflows exist from the Upjet template but have not been exercised for a release. |

## Decisions pending

1. **0.6.2 + patch, or 0.6.3 + rebased patch.** 0.6.3 reshapes `railway_service` (build and deploy
   settings, updatable regions) and adds `target_port` to `railway_service_domain`. Moving means
   rebasing `hack/upstream/0001-*.patch`, regenerating, and re-reviewing the `Service` schema. Staying
   costs nothing today but widens the gap.
2. Railway plan and sizing for the control-plane service (2–4 GB RAM plus a volume) and which
   workspace hosts it.
3. Registry for the xpkg and control-plane image (ghcr.io assumed).

## Phases

### Phase 1: control-plane image. Done

A single container running etcd, kube-apiserver, kube-controller-manager (node-independent
controllers only), Crossplane core and this provider as supervised processes. Proven natively,
16/16 checks, including restart on persisted etcd data. Moved to the control-plane repository on
2026-08-26.

### Phase 2: deploy to Railway. Next

Service from the image, volume at etcd's data directory, TCP proxy on 6443, env vars for the Railway
token and API-server credential material. Done when the `Project` smoke test passes over the internet.
Consider provisioning the service with this provider once it exists.

### Phase 3: first cloud, DigitalOcean

Add the DigitalOcean provider as another supervised process, write a `KubernetesCluster` XRD with a
DOKS Composition, provision a real cluster, read its kubeconfig back as a connection secret. Then
EKS and GKE as additional Composition variants using the family providers. Open problem: Compositions
need a Function, which is a gRPC server that must serve a certificate signed by Crossplane's root CA.

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
* Refresh the 2026-08 handoff in `.claude/handoff/`; it references paths that moved to the
  control-plane repository.
