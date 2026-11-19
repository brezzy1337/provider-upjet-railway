# External names and import

Crossplane records the identity of the real-world object behind a managed resource in the annotation
`crossplane.io/external-name`. Upjet needs to know, per resource, where that identity comes from and
how it maps to Terraform's `id`.

## Identifier from provider

Every Railway object gets a server-generated UUID. Nothing in the manifest can predict it, so every
resource in this provider uses `config.IdentifierFromProvider` (`config/external_name.go`). On the
first successful create the provider copies Terraform's `id` into the annotation, and from then on it
is the key used for observe, update and delete.

```console
$ kubectl get project example -o jsonpath='{.metadata.annotations.crossplane\.io/external-name}'
4f9c2c2e-...-...
```

Until the annotation is set, the resource does not exist as far as Crossplane is concerned. This is
the moment the upstream Terraform provider used to break: asked to read an object with an empty ID
it returned an error instead of "not found". See [The not-found patch](../upstream/not-found-patch.md).

## Why import does not work yet

The external name is what `kubectl annotate ... crossplane.io/external-name=<id>` would use to adopt
an existing Railway object. For most Upjet providers that works unchanged because the external name
*is* the Terraform import ID. Railway's Terraform provider uses colon-joined composite import IDs for
most resources, and those do not match the bare `id`:

| Resource                      | Terraform import ID                                   |
|-------------------------------|-------------------------------------------------------|
| `railway_project`             | `<project_id>`                                        |
| `railway_environment`         | `<project_id>:<name>`                                 |
| `railway_service`             | `<service_id>`                                        |
| `railway_variable`            | `<service_id>:<environment_name>:<name>`              |
| `railway_variable_collection` | `<service_id>:<environment_name>:<name1>:<name2>:...` |
| `railway_shared_variable`     | `<project_id>:<environment_name>:<name>`              |
| `railway_custom_domain`       | `<service_id>:<environment_name>:<domain>`            |
| `railway_service_domain`      | `<service_id>:<environment_name>:<domain>`            |
| `railway_tcp_proxy`           | `<service_id>:<environment_id>:<tcp_proxy_id>`        |

Adopting `Project` and `Service` by annotating the external name should work today, since their import
ID is the bare ID. For the others, each needs a `GetIDFn` in `config/external_name.go` that builds the
composite from `spec.forProvider` plus the external name, and a matching `GetExternalNameFn` that
extracts the bare ID back out. That is a backlog item; none of it is needed for the create-from-scratch
path the control plane uses.
