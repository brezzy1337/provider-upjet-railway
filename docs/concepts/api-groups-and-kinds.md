# API groups and kinds

Every object in Kubernetes is identified by a **Group**, a **Version** and a **Kind** (GVK). You see
the first two in `apiVersion` and the third in `kind`:

```yaml
apiVersion: railway.crossplane.io/v1alpha1   # group / version
kind: Project                                # kind
```

The GVK is not cosmetic. It decides the CRD name (`projects.railway.crossplane.io`), what you type
after `kubectl get`, how RBAC rules are written, how Compositions select resources, and the Go
package layout of the generated code. Changing a group or kind after a release is a breaking API
change, so it is worth getting right before anything ships. This page explains what Upjet would have
produced on its own, what this provider does instead, and why.

## How Upjet names things by default

Upjet derives the group and kind from the Terraform resource name. The rule lives in
`pkg/config/common.go` (`DefaultResource`) and is simple: split the name on `_`, use the **second**
word as the group and CamelCase **everything after it** as the kind. If the name has only two words,
the first word is the group and the second is the kind.

```go
words := strings.Split(name, "_")
group := words[1]
kind := tjname.NewFromSnake(strings.Join(words[2:], "_")).Camel
if len(words) < 3 {
    group = words[0]
    kind = tjname.NewFromSnake(words[1]).Camel
}
```

That rule was designed for large providers whose names carry a service segment:
`aws_rds_cluster_parameter_group` becomes group `rds`, kind `ClusterParameterGroup`. The short group is
then prefixed to the provider's **root group** (`pkg/pipeline/run.go`):

```go
group := pc.RootGroup
if resource.ShortGroup != "" {
    group = strings.ToLower(resource.ShortGroup) + "." + pc.RootGroup
}
```

So `rds` plus a root group of `aws.upbound.io` yields `rds.aws.upbound.io`. The generated Go package
and controller directories take the first label of the full group (`apis/<shortgroup>/<version>`).

## What that rule does to Railway's names

Railway's resource names do not have a service segment. The second word is just part of the noun.
Applying the default rule to our nine resources, with the root group `railway.crossplane.io`:

| Terraform resource            | Default group                  | Default kind | You would write                        |
|-------------------------------|--------------------------------|--------------|----------------------------------------|
| `railway_project`             | `railway.railway.crossplane.io` | `Project`    | `kind: Project` in a doubled group     |
| `railway_environment`         | `railway.railway.crossplane.io` | `Environment` | same                                  |
| `railway_service`             | `railway.railway.crossplane.io` | `Service`    | same                                   |
| `railway_variable`            | `railway.railway.crossplane.io` | `Variable`   | same                                   |
| `railway_variable_collection` | `variable.railway.crossplane.io` | `Collection` | `kind: Collection`                    |
| `railway_shared_variable`     | `shared.railway.crossplane.io`  | `Variable`   | a second `Variable` in another group   |
| `railway_custom_domain`       | `custom.railway.crossplane.io`  | `Domain`     | `kind: Domain`                         |
| `railway_service_domain`      | `service.railway.crossplane.io` | `Domain`     | a second `Domain` in another group     |
| `railway_tcp_proxy`           | `tcp.railway.crossplane.io`     | `Proxy`      | `kind: Proxy`                          |

Three things are wrong with that outcome:

* **The kinds lose their meaning.** `Collection`, `Domain` and `Proxy` say nothing on their own, and
  two different resources are both called `Domain` and two are both called `Variable`. They do not
  collide because the groups differ, but a reader of a manifest has to look at `apiVersion` to know
  what the object is.
* **The two-word names produce a doubled group.** `railway` becomes the short group and is prefixed to
  a root group that already starts with `railway`.
* **Nine kinds get spread over six groups** for a provider that is small enough to be one group.
  Every extra group is another `kubectl api-resources` line, another RBAC entry and another Go package.

## What this provider does instead

`config/provider.go` installs one default resource option that runs for every resource before any
per-resource configuration:

```go
func groupKindOverrides() ujconfig.ResourceOption {
    return func(r *ujconfig.Resource) {
        r.ShortGroup = ""
        r.Kind = name.NewFromSnake(strings.TrimPrefix(r.Name, resourcePrefix+"_")).Camel
    }
}
```

Two lines, two effects:

1. **`ShortGroup = ""`** tells the pipeline to use the root group as-is. All nine resources land in
   `railway.crossplane.io`. The generated package directory takes the first label of that group, which
   is why the code lives in `apis/cluster/railway/v1alpha1/` and
   `internal/controller/cluster/railway/`.
2. **`Kind` is the whole resource name** minus the `railway_` prefix, converted from snake_case to
   CamelCase. `railway_variable_collection` becomes `VariableCollection`, `railway_custom_domain`
   becomes `CustomDomain`. Upjet's `name` package knows common acronyms, so `railway_tcp_proxy`
   becomes `TCPProxy` rather than `TcpProxy`.

The root group itself is set once per provider with `ujconfig.WithRootGroup("railway.crossplane.io")`.
Without it Upjet would default to `railway.upbound.io`, which is Upbound's namespace, not ours.

The result:

| Terraform resource            | Group                   | Kind                 | CRD name                                     |
|-------------------------------|-------------------------|----------------------|----------------------------------------------|
| `railway_project`             | `railway.crossplane.io` | `Project`            | `projects.railway.crossplane.io`             |
| `railway_environment`         | `railway.crossplane.io` | `Environment`        | `environments.railway.crossplane.io`         |
| `railway_service`             | `railway.crossplane.io` | `Service`            | `services.railway.crossplane.io`             |
| `railway_variable`            | `railway.crossplane.io` | `Variable`           | `variables.railway.crossplane.io`            |
| `railway_variable_collection` | `railway.crossplane.io` | `VariableCollection` | `variablecollections.railway.crossplane.io`  |
| `railway_shared_variable`     | `railway.crossplane.io` | `SharedVariable`     | `sharedvariables.railway.crossplane.io`      |
| `railway_custom_domain`       | `railway.crossplane.io` | `CustomDomain`       | `customdomains.railway.crossplane.io`        |
| `railway_service_domain`      | `railway.crossplane.io` | `ServiceDomain`      | `servicedomains.railway.crossplane.io`       |
| `railway_tcp_proxy`           | `railway.crossplane.io` | `TCPProxy`           | `tcpproxies.railway.crossplane.io`           |

## The namespaced twin

Crossplane v2 introduced namespaced managed resources alongside the classic cluster-scoped ones. Upjet
generates both from the same configuration, once with `GetProvider()` and once with
`GetProviderNamespaced()`. The only difference that matters here is the root group:
`railway.m.crossplane.io`. The `.m.` label is the Crossplane convention marking the namespaced
("modern") API surface. The same `groupKindOverrides` option applies, so the namespaced kinds have the
same names and differ only in group and scope:

```yaml
apiVersion: railway.m.crossplane.io/v1alpha1
kind: Project
metadata:
  name: example
  namespace: team-a
```

Namespaced resources use a `ProviderConfig` in their own namespace or a cluster-wide
`ClusterProviderConfig`; see [Authentication](../getting-started/authentication.md).

## Where the choice shows up

* **kubectl.** `kubectl get projects.railway.crossplane.io`, or just `kubectl get projects` when no
  other CRD claims that plural. `kubectl get managed` and `kubectl get railway` work too, because
  every CRD carries the categories `crossplane`, `managed` and `railway`.
* **Discovery.** `kubectl api-resources --api-group=railway.crossplane.io` lists all nine kinds in
  one place.
* **RBAC.** One `apiGroups: ["railway.crossplane.io"]` entry covers the provider.
* **Compositions.** Composed resources reference `railway.crossplane.io/v1alpha1` kinds by name;
  readable kinds make the pipeline easier to review.
* **Code layout.** `apis/{cluster,namespaced}/railway/v1alpha1/zz_<kind>_types.go`,
  `internal/controller/{cluster,namespaced}/railway/<kind>/zz_controller.go`,
  `package/crds/railway.crossplane.io_<plural>.yaml`,
  `examples-generated/{cluster,namespaced}/railway/v1alpha1/<kind>.yaml`.

## When you would want short groups

Short groups earn their keep when a provider has hundreds of kinds and real service boundaries. The
AWS provider has around a thousand CRDs and splitting them into `ec2`, `rds`, `iam` and so on is the
only way to install a useful subset. The control-plane design leans on exactly that: it installs the
family providers (`provider-aws-eks`, `provider-aws-ec2`, `provider-aws-iam`) rather than the
monolith. A nine-kind provider has no such boundary, so a flat group is the better default.

## Changing this later

Treat the current GVKs as frozen once anything is published. Renaming a kind or moving a group creates
new CRDs; existing objects stay under the old ones with no controller watching them, and every
manifest and Composition that references them breaks. Upjet does support API version bumps with
conversion webhooks (`v1alpha1` to `v1beta1`), but that is a version change within a GVK, not a
rename. If a rename is ever unavoidable, do it before the first release tag.

## Verifying

```console
grep -h '^  name:' package/crds/railway.crossplane.io_*.yaml
kubectl api-resources --api-group=railway.crossplane.io
```

Both should list exactly the nine kinds above plus `providerconfigs` and `providerconfigusages`.
