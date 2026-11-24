# provider-upjet-railway

`provider-upjet-railway` is a [Crossplane](https://crossplane.io) provider that manages
[Railway](https://railway.com) resources from Kubernetes. You describe a Railway project, service or
variable as a Kubernetes object, and the provider keeps Railway in sync with it.

It is generated with [Upjet](https://github.com/crossplane/upjet) from the community Terraform
provider for Railway. Upjet wraps each Terraform resource in a Kubernetes custom resource and a
controller that drives Terraform under the hood, so the provider inherits the Terraform provider's
schema, behaviour and bugs.

## What you get

| Kind                 | Railway object                          |
|----------------------|-----------------------------------------|
| `Project`            | A project                               |
| `Environment`        | An environment inside a project         |
| `Service`            | A service (image or repo based)         |
| `Variable`           | One service variable in one environment |
| `VariableCollection` | Several service variables at once       |
| `SharedVariable`     | A project-level shared variable         |
| `CustomDomain`       | A custom domain on a service            |
| `ServiceDomain`      | A Railway-provided `*.up.railway.app` domain |
| `TCPProxy`           | A TCP proxy in front of a service       |

All kinds live in `railway.crossplane.io/v1alpha1` (cluster-scoped) and `railway.m.crossplane.io/v1alpha1`
(namespaced). [API groups and kinds](concepts/api-groups-and-kinds.md) explains why.

## Why it exists

The provider is the first building block of a
[Crossplane control plane hosted on Railway](architecture/control-plane.md) (and its
[Phase 1 review](architecture/phase-1-review.md) and [Phase 2 review](architecture/phase-2-review.md)): a nodeless Kubernetes
API server plus Crossplane running inside a single Railway service, provisioning Kubernetes clusters
on DigitalOcean, AWS and GCP from cloud-agnostic claims. This provider lets that control plane manage
Railway itself, including, eventually, its own hosting.

## Where to go next

* [Authentication](getting-started/authentication.md): which Railway token works and how to wire it.
* [Development](getting-started/development.md): toolchain, scripts and the generate loop.
* [Deploy the control plane to Railway](getting-started/deploy-to-railway.md): the service, volume,
  TCP proxy and two secrets; the smoke test; publishing it as a template.
* [Resources](resources/overview.md): every kind, its references and what has been tested live.
* [Roadmap](roadmap.md): current status and the phased plan.
* [Development reports](reports/README.md): dated records of what each working session shipped,
  verified, decided and left open.
