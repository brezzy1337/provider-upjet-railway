# Cross-resource references

Railway objects form a tree: a project owns environments and services, and a variable belongs to a
service in an environment. The Terraform provider expresses that with raw ID attributes such as
`project_id`. Upjet can replace each raw ID with a **reference** to another managed resource, so a
`Service` can name the `Project` object it belongs to instead of carrying a Railway UUID that only
exists after the project is created.

## What is generated

For each configured attribute Upjet emits three fields in `spec.forProvider`:

| Field                 | Meaning                                                                 |
|-----------------------|-------------------------------------------------------------------------|
| `projectId`           | The raw value. Set it directly if you already know the Railway ID.      |
| `projectIdRef.name`   | The name of a `Project` object. Resolved to its external name at runtime. |
| `projectIdSelector`   | Label selector (`matchLabels`, `matchControllerRef`) that picks a `Project`. |

Resolution runs before every reconcile. If the referenced object does not exist or has no external
name yet, the dependent resource waits (`Synced: False`, reason `ReferenceNotFound` or similar) and
retries, which is how ordering falls out of a single `kubectl apply` of a whole tree.

```yaml
apiVersion: railway.crossplane.io/v1alpha1
kind: Service
metadata:
  name: api
spec:
  forProvider:
    name: api
    projectIdRef:
      name: my-project
```

## Which attributes are wired

`config/railway/config.go` maps three Terraform attributes to the resource that owns them:

| Attribute        | Points at             |
|------------------|-----------------------|
| `project_id`     | `Project`             |
| `service_id`     | `Service`             |
| `environment_id` | `Environment`         |

The configurator loops over a list of resources and adds a reference only where the attribute exists
in that resource's Terraform schema, so listing a superset is harmless. The generated result per kind:

| Kind                 | `projectId` | `serviceId` | `environmentId` |
|----------------------|:-----------:|:-----------:|:---------------:|
| `Project`            |             |             |                 |
| `Environment`        | ref         |             |                 |
| `Service`            | ref         |             |                 |
| `Variable`           |             | ref         | ref             |
| `VariableCollection` |             | ref         | ref             |
| `SharedVariable`     | ref         |             | ref             |
| `CustomDomain`       |             | ref         | ref             |
| `ServiceDomain`      |             | ref         | ref             |
| `TCPProxy`           |             | ref         | ref             |

## The default environment gap

Every Railway project is created with a default environment (usually `production`), and the Terraform
examples reach it as `railway_project.example.default_environment.id`. That is a computed attribute on
`Project`, surfaced in `status.atProvider.defaultEnvironment[0].id`, not a separate `Environment`
object. An `environmentIdRef` can only point at an `Environment` managed resource, so today there are
two ways to target the default environment:

1. Read the ID from the project's status and set `environmentId` directly, or patch it in a
   Composition from `status.atProvider.defaultEnvironment[0].id`.
2. Create an explicit `Environment` for anything that needs a reference and ignore the default one.

A nicer answer, a reference that can resolve to a field of another object, is on the backlog.

## Deleting a tree

References do not create Kubernetes owner references, so deleting a `Project` object does not delete
its `Service` objects. Railway, however, deletes everything under a project when the project goes. The
provider will then observe each child as missing and remove it from state, which is exactly the path
that needs [the not-found patch](../upstream/not-found-patch.md) to work. Delete leaves before roots
if you want the deletion sequence to be explicit.
