# Plan

Source provider: `terraform-community-providers/terraform-provider-railway`
(Plugin Framework v1.2, registry v0.6.2, HEAD a751535 2026-08-18).

## Upstream resource coverage (verified from `internal/provider/provider.go`)

| Terraform resource            | Status                          |
|-------------------------------|---------------------------------|
| `railway_project`             | present                         |
| `railway_environment`         | present                         |
| `railway_service`             | present (volume is a nested attribute of service) |
| `railway_variable`            | present (triggers redeploy)     |
| `railway_variable_collection` | present                         |
| `railway_shared_variable`     | present                         |
| `railway_custom_domain`       | present                         |
| `railway_service_domain`      | present                         |
| `railway_tcp_proxy`           | present                         |
| `railway_volume`              | **absent** as a standalone resource (upstream #75 closed; PRs #84/#87/#88 open) |
| `railway_deployment`          | **absent** — redeploy is only an internal side effect |

## Steps

1. ~~Point the Makefile `TERRAFORM_PROVIDER_*` vars at `terraform-community-providers/railway`~~ (0.6.2, GitHub release assets).
2. ~~Configure provider auth~~ — `ProviderConfig` credentials JSON `{"token": "..."}` → TF `token` attr (`internal/clients/railway.go`).
3. ~~Generate~~ — all 9 resources generated into a single group `railway.crossplane.io` (cluster) /
   `railway.m.crossplane.io` (namespaced) with Kinds `Project`, `Environment`, `Service`, `Variable`,
   `VariableCollection`, `SharedVariable`, `CustomDomain`, `ServiceDomain`, `TCPProxy`
   (`config/provider.go` `groupKindOverrides`). Cross-resource refs for `project_id` / `service_id` /
   `environment_id` (`config/railway/config.go`).
4. **Next:** `Project` end-to-end — kind cluster → install Crossplane → `make run` → `kubectl apply`
   `examples-generated/cluster/railway/v1alpha1/project.yaml` against a throwaway Railway workspace.
5. Then `Service` + `Variable` live; hand-written `examples/` per resource; uptest.
6. Import support: external names are `IdentifierFromProvider`; upstream import IDs are colon-composites
   (see `config/external_name.go`) and need per-resource `GetIDFn` before `crossplane import`/adopt works.
7. Volumes / deployments: contribute standalone resources upstream, then regenerate.
