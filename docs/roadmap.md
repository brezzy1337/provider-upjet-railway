# Roadmap and status

_Last updated 2026-11-22._

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
| Live verification | `Project` create → visible in Railway → delete → gone, via kind + Crossplane 2.2.1 + the provider out-of-cluster (2026-08-25, repeated through the native control plane 2026-08-26). No other kind has been exercised live. |
| Upstream dependency | Blocked on [PR #93](https://github.com/terraform-community-providers/terraform-provider-railway/pull/93) (open, no activity since 2026-08-25). Upstream shipped 0.6.3 on 2026-10-19 **without** the fix. We build from a patch; see [The not-found patch](upstream/not-found-patch.md). |
| Control plane | Phase 1 done; merged to `main` 2026-11-21 (PR #3): `cluster/images/control-plane/` and `hack/native-cluster.sh`. Results and review findings in the [Phase 1 review](architecture/phase-1-review.md). Phase 2 started 2026-11-21: B1 (PR #5), B2 (PR #6), B3 (PR #7), B4 (PR #8) and B5 (PR #9) done; see Phase 2 below for what remains. |
| Package publishing | No xpkg or image has been pushed to a registry yet. CI workflows exist from the Upjet template but have not been exercised for a release. |

## Decisions

1. **0.6.2 + patch, or 0.6.3 + rebased patch.** Resolved for Phase 2 (2026-11-21): stay on 0.6.2 +
   patch. 0.6.3 reshapes `railway_service` (adds `start_command`, health check, restart policy, build
   settings, updatable regions) and adds `target_port` to `railway_service_domain`; none of that is
   needed to host the control plane (image, volume, TCP proxy, env vars). Revisit when a Railway
   service needs those fields or when upstream merges the not-found fix. Moving means rebasing
   `hack/upstream/0001-*.patch`, regenerating, and re-reviewing the `Service` schema.
2. Railway plan and sizing for the control-plane service (2–4 GB RAM plus a volume) and which
   workspace hosts it.
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
such as the current codespace. The [Phase 1 review](architecture/phase-1-review.md) records what
was verified, what the review found, and what Phase 2 must fix before deploying (B1 to B5: PKI on
the volume, volume ownership, secrets encryption and audit, token handling, etcd quota).

### Phase 2: deploy to Railway. Next

Service from the image, one volume mounted at `CP_STATE_DIR` (etcd data, PKI and `VERSION` stamp;
B1, done 2026-11-21 in PR #5; ownership of that volume handled by the image itself, B2, done
2026-11-22 in PR #6; Secrets at rest, audit and credential lifetimes, B3, done 2026-11-22 in PR #7;
the Railway token out of every component's environment, B4, done 2026-11-22 in PR #8; etcd quota,
snapshots and GOMEMLIMIT, B5, done 2026-11-22 in PR #9), TCP proxy on 6443, env vars for the Railway
token, `CP_ENCRYPTION_KEY` and API-server credential material. Still to do before the first deploy:
etcd client authentication, the B3 leftover. First spike after that: a composition function as a
supervised process, since every XRD depends on it. Done when the `Project` smoke test passes over
the internet.
Consider provisioning the service with this provider once it exists.

### Phase 3: first cloud, DigitalOcean

Add the DigitalOcean provider as another supervised process, write a `KubernetesCluster` XRD with a
DOKS Composition, provision a real cluster, read its kubeconfig back as a connection secret. Then
EKS and GKE as additional Composition variants using the family providers. Then a `HermesAgent` XRD
that composes a Hermes instance onto a provisioned cluster via provider-kubernetes or provider-helm.
Open problem: Compositions need a Function, which is a gRPC server that must serve a certificate
signed by Crossplane's root CA.

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
