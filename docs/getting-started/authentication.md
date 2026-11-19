# Authentication

The provider authenticates to Railway's GraphQL API with a single bearer token, supplied through a
Crossplane `ProviderConfig` that points at a Kubernetes Secret.

## Which token

Railway issues three kinds of token. Only two of them work here.

| Token type                      | Works | Why                                                                 |
|---------------------------------|:-----:|---------------------------------------------------------------------|
| Account token                   | yes   | Sent as `Authorization: Bearer`, accepted for every project you can see |
| Workspace (team) token          | yes   | Same header, scoped to one workspace. **Preferred.**                |
| Project token                   | no    | Railway expects project tokens in a `Project-Access-Token` header; the Terraform provider only sends `Authorization: Bearer`, so every call fails with `Not Authorized` |

Create one under Railway → Account Settings → Tokens, and pick the workspace when offered. Treat it
like a cloud root credential: it can create and delete anything in that workspace.

## Secret format

The Secret's `credentials` key holds JSON with one field. `internal/clients/railway.go` unmarshals it
and passes `token` straight through to the Terraform provider's `token` attribute.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: railway-creds
  namespace: crossplane-system
type: Opaque
stringData:
  credentials: |
    {"token": "<workspace or account token>"}
```

Keep tokens out of git. `examples/*/providerconfig/secret.yaml.tmpl` is a template; the rendered
`secret.yaml` beside it is git-ignored. `hack/dev-cluster.sh` creates the Secret from `$RAILWAY_TOKEN`
so nothing is written to disk.

## ProviderConfig

Cluster-scoped resources (`railway.crossplane.io`) use a cluster-scoped `ProviderConfig`:

```yaml
apiVersion: railway.crossplane.io/v1beta1
kind: ProviderConfig
metadata:
  name: default
spec:
  credentials:
    source: Secret
    secretRef:
      name: railway-creds
      namespace: crossplane-system
      key: credentials
```

Namespaced resources (`railway.m.crossplane.io`) look up a `ProviderConfig` in their own namespace
first, and fall back to a `ClusterProviderConfig`:

```yaml
apiVersion: railway.m.crossplane.io/v1beta1
kind: ClusterProviderConfig
metadata:
  name: default
spec:
  credentials:
    source: Secret
    secretRef:
      name: railway-creds
      namespace: crossplane-system
      key: credentials
```

A managed resource selects its config with `spec.providerConfigRef.name`; it defaults to `default`.
Several configs with different tokens let one control plane manage several workspaces.

## Troubleshooting

* `Not Authorized` on every resource: almost always a project token. Replace it with a workspace token.
* `cannot extract credentials` / `must contain a non-empty "token" key`: the Secret key is not named
  `credentials`, or the JSON is malformed. Check `kubectl get secret railway-creds -o jsonpath='{.data.credentials}' | base64 -d`.
* Resources stuck with `Synced: False` and a Terraform "not found" error: that is the upstream bug,
  not auth. See [The not-found patch](../upstream/not-found-patch.md).
