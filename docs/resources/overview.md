# Resource overview

Nine kinds, each generated from one Terraform resource. Every kind exists cluster-scoped in
`railway.crossplane.io/v1alpha1` and namespaced in `railway.m.crossplane.io/v1alpha1` with an
identical `spec.forProvider`.

| Kind                 | Terraform resource            | References                   | Sensitive input                       | Live-tested |
|----------------------|-------------------------------|------------------------------|---------------------------------------|:-----------:|
| `Project`            | `railway_project`             |                              |                                       | yes, 2026-08-25 |
| `Environment`        | `railway_environment`         | project                      |                                       | no |
| `Service`            | `railway_service`             | project                      | `sourceImageRegistryPasswordSecretRef` | no |
| `Variable`           | `railway_variable`            | service, environment         | `valueSecretRef`                      | no |
| `VariableCollection` | `railway_variable_collection` | service, environment         | `variables[].valueSecretRef`          | no |
| `SharedVariable`     | `railway_shared_variable`     | project, environment         | `valueSecretRef`                      | no |
| `CustomDomain`       | `railway_custom_domain`       | service, environment         |                                       | no |
| `ServiceDomain`      | `railway_service_domain`      | service, environment         |                                       | no |
| `TCPProxy`           | `railway_tcp_proxy`           | service, environment         |                                       | no |

"Live-tested" means the kind was reconciled to `Ready` against a real Railway workspace and its
deletion was confirmed upstream. Everything else compiles, has a CRD and a controller, and is
expected to work, but the not-found paths in particular have only been exercised for `Project`.

## Sensitive fields

Terraform attributes marked sensitive become Secret references rather than plain fields. A `Variable`
value is therefore never written in the manifest:

```yaml
apiVersion: railway.crossplane.io/v1alpha1
kind: Variable
metadata:
  name: sentry-key
spec:
  forProvider:
    name: SENTRY_KEY
    serviceIdRef:
      name: api
    environmentIdRef:
      name: production
    valueSecretRef:
      name: api-secrets
      namespace: crossplane-system
      key: sentry-key
```

The provider reads the Secret at reconcile time and passes the value to Terraform. Rotating the
Secret does not trigger a reconcile on its own; the next scheduled poll picks it up.

## Generated examples

`examples-generated/{cluster,namespaced}/railway/v1alpha1/<kind>.yaml` holds one example per kind,
derived from the Terraform registry documentation. They are a starting point, not a tested suite:
the `Variable` example still references an `upbound-system` namespace inherited from the Upjet
template. Hand-written, tested examples under `examples/` are on the [roadmap](../roadmap.md).

## Not available

Railway volumes and deployments have no standalone Terraform resource. A volume can only be declared
as a nested attribute of `railway_service`, and a redeploy is a side effect of changing a variable.
Both need to be contributed upstream before they can appear here.

## Field reference

The authoritative field list for each kind is its CRD in `package/crds/`, or on a cluster:

```console
kubectl explain projects.railway.crossplane.io.spec.forProvider
```
