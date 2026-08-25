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

1. Point the Makefile `TERRAFORM_PROVIDER_*` vars at `terraform-community-providers/railway`.
2. Configure provider auth in `config/provider.go` / `internal/clients/railway.go` (Railway token → `token` attr).
3. Generate; get `Project` end-to-end (CRD → `kubectl apply` → live Railway) before adding the rest.
4. Add remaining resources; example manifests; uptest.
5. Volumes / deployments: contribute standalone resources upstream, then regenerate.
