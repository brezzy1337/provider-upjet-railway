# provider-upjet-railway

A [Crossplane](https://crossplane.io/) provider for [Railway](https://railway.com), generated with
[Upjet v2](https://github.com/crossplane/upjet) from the community Terraform provider
[`terraform-community-providers/railway`](https://registry.terraform.io/providers/terraform-community-providers/railway)
(pinned to 0.6.2).

It exposes Railway projects, environments, services, variables, domains and TCP proxies as
Kubernetes managed resources you `kubectl apply`. Nine kinds live in the API group
`railway.crossplane.io` (cluster-scoped) with namespaced twins in `railway.m.crossplane.io`.

> **Status (2026-11):** generated, builds, and live-verified for `Project` create/delete against a
> real Railway workspace through Crossplane 2.2.1. The other kinds are generated and wired but not
> yet exercised live. The provider is one component of a larger
> [Railway-hosted Crossplane control plane](docs/architecture/control-plane.md), whose image lives
> in this repository under `cluster/images/control-plane/`. See [`docs/`](docs/README.md) for the full documentation and
> [`docs/roadmap.md`](docs/roadmap.md) for what is next.

## Quick start

```yaml
apiVersion: railway.crossplane.io/v1alpha1
kind: Project
metadata:
  name: example
spec:
  forProvider:
    name: my-project
```

The `ProviderConfig` credentials Secret holds JSON with a single key:

```json
{ "token": "<Railway workspace or account token>" }
```

The token **must be a workspace or account token**. Project tokens fail with "Not Authorized"
because the Terraform provider only sends `Authorization: Bearer`. Details in
[docs/getting-started/authentication.md](docs/getting-started/authentication.md).

## Known upstream issue: not-found handling

`terraform-community-providers/railway` (including the latest 0.6.3) returns an error from `Read`
when a resource no longer exists instead of removing it from state. Upjet relies on that removal to
detect "does not exist yet" and "deleted", so a stock binary can neither create nor finish deleting
anything. This repo builds the Terraform provider from a patch in `hack/upstream/` until
[upstream PR #93](https://github.com/terraform-community-providers/terraform-provider-railway/pull/93)
lands. See [docs/upstream/not-found-patch.md](docs/upstream/not-found-patch.md).

## Developing

The devcontainer provides Go 1.26, docker-in-docker, kubectl, kind, the crossplane CLI and terraform.

```console
make generate            # regenerate apis/, controllers, CRDs and examples after editing config/
go build ./... && go test ./...
hack/dev-cluster.sh      # kind + Crossplane + our CRDs + ProviderConfig from $RAILWAY_TOKEN
hack/run-provider.sh     # run the provider out-of-cluster with the patched Terraform mirror
make build               # build the provider binary and xpkg
```

Hand-written code is `config/`, `internal/clients/`, `hack/` and `cluster/`. Everything named
`zz_*.go`, `package/crds/*.yaml` and `examples-generated/` is generated and never edited by hand.
More in [docs/getting-started/development.md](docs/getting-started/development.md).

## License

Apache-2.0, see [LICENSE](LICENSE).
