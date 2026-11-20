# Railway-hosted control plane

This provider is one part of a larger system. The goal is a **Crossplane control plane that runs on
Railway** and provisions Kubernetes clusters on DigitalOcean, AWS and GCP. A user applies a
cloud-agnostic `KubernetesCluster` claim; a Composition picks the DOKS, EKS or GKE implementation; the
new cluster's kubeconfig comes back as a Crossplane connection secret.

The plan is for the control plane to live in its own repository, because a Railway template is
derived from a GitHub repository and the control plane is a separate product that merely *runs*
providers; its Dockerfile would clone this repository at a pinned ref for the provider binary, CRDs,
upstream patch and Terraform CLI configuration. **As of 2026-11-20 that split has not happened**:
the code is on branch `phase-1/control-plane-image` of this repository, under
`cluster/images/control-plane/` (Dockerfile, Makefile, the `control-plane.sh` supervisor) and
`hack/native-cluster.sh`. See the [roadmap](../roadmap.md) for the pending decision.

## Design

**Nodeless Kubernetes in one Railway service.** A single unprivileged container runs, as supervised
processes:

| Process                   | Role                                                                 |
|---------------------------|----------------------------------------------------------------------|
| `etcd`                    | State, on a Railway volume                                           |
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
