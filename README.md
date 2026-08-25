# provider-upjet-railway

A [Crossplane](https://crossplane.io/) provider for [Railway](https://railway.com), generated with
[Upjet](https://github.com/crossplane/upjet) from the community Terraform provider
[`terraform-community-providers/railway`](https://registry.terraform.io/providers/terraform-community-providers/railway).

It exposes Railway projects, environments, services, variables, domains and TCP proxies as
Kubernetes managed resources you `kubectl apply`.

> **Status:** scaffold. Nothing is generated yet. See `docs/PLAN.md`.

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
