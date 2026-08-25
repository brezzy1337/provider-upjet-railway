# provider-upjet-railway

A [Crossplane](https://crossplane.io/) provider for [Railway](https://railway.com), generated with
[Upjet](https://github.com/crossplane/upjet) from the community Terraform provider
[`terraform-community-providers/railway`](https://registry.terraform.io/providers/terraform-community-providers/railway).

It exposes Railway projects, environments, services, variables, domains and TCP proxies as
Kubernetes managed resources you `kubectl apply`.

> **Status:** scaffold. Nothing is generated yet. See `docs/PLAN.md`.

## Authentication

The `ProviderConfig` credentials Secret holds JSON with a single key:

```json
{ "token": "<Railway workspace or account token>" }
```

The token **must be a workspace or account token** (Railway → Account Settings →
Tokens, optionally scoped to one workspace). **Project tokens do not work**: the
underlying Terraform provider authenticates with `Authorization: Bearer`, which
Railway only accepts for workspace/account tokens.

## Known upstream issue: not-found handling

`terraform-community-providers/railway` ≤ 0.6.2 returns an error from `Read` when
a resource no longer exists instead of removing it from state. Crossplane/Upjet
relies on the removal to detect "does not exist yet" and "deleted", so the
provider cannot create or finish deleting anything against a stock binary. This
repo builds the Terraform provider from a patched fork until the fix lands
upstream (see `docs/PLAN.md`).

## Developing

This repo ships a devcontainer (Go 1.26, docker-in-docker, kubectl, kind, crossplane CLI, terraform).

```console
go run cmd/generator/main.go "$PWD"   # run the Upjet code-generation pipeline
make run                              # run the provider against the current kube context
make build                            # build the provider binary
make all                              # build, push and install the package
```

Upjet guide: https://github.com/crossplane/upjet/blob/main/docs/generating-a-provider.md

## License

Apache-2.0 — see [LICENSE](LICENSE).
