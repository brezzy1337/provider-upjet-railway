# functions-spike fixtures

Harness fixtures for `hack/native-cluster.sh verify` (Phase 3, item 1: composition functions as
supervised processes). They are **not a product API** and the control plane never depends on them:
the group `harness.railway.crossplane.io` exists only so the harness can prove that a Composition
pipeline runs through the functions the control plane supervises (`function-go-templating`,
`function-auto-ready`). Nothing in `cluster/images/control-plane/` reads this directory.

| File                              | What it is                                                                                              |
|-----------------------------------|---------------------------------------------------------------------------------------------------------|
| `xrd.yaml`                        | Namespaced `apiextensions.crossplane.io/v2` XRD `XSpike` (`xspikes`) with one field, `spec.name`.       |
| `composition.yaml`                | **Default.** `xspike-configmap`: `render` (go-templating, one core `v1 ConfigMap`, `data.name`), `ready`. |
| `xr.yaml`                         | XR `spike` in namespace `functions-spike`, selects `xspike-configmap`.                                   |
| `composition-railway-project.yaml`| **Opt-in.** `xspike-railway-project`: `render` (one `railway.m.crossplane.io/v1alpha1` `Project`), `ready`. |
| `xr-railway-project.yaml`         | XR `spike-railway` in namespace `functions-spike`, selects `xspike-railway-project`.                     |

Both XRs carry `spec.name: upjet-functions-spike` and select their Composition by
`spec.crossplane.compositionRef.name`.

## Default path (hermetic, every `verify`)

`verify` applies the XRD and both Compositions, waits for the XRD to be `Established` and for both
CompositionRevisions to report `ValidPipeline=True` (the proof that each function's
`FunctionRevision` carries the `composition` capability), creates the namespace, applies `xr.yaml`,
and waits for a `ConfigMap` labelled `crossplane.io/composite=spike` whose `data.name` equals the
XR's `spec.name`, then for the XR to reach `Ready=True` (function-auto-ready has a ConfigMap health
check, so no provider is involved). The XR is deleted at the end and the ConfigMap must disappear.
Nothing leaves the local API server.

## Opt-in path (`VERIFY_LIVE_RAILWAY=1`, talks to Railway)

```sh
VERIFY_LIVE_RAILWAY=1 hack/native-cluster.sh verify
```

adds the `Project` round trip with `xr-railway-project.yaml`: the `Project` labelled
`crossplane.io/composite=spike-railway` must carry `spec.forProvider.name` equal to `spec.name`, the
XR must reach `Ready=True`, and after deleting the XR the `Project` must disappear. This path talks
to the real Railway API: with a real `RAILWAY_TOKEN` it creates and deletes a project in your
workspace; with the harness's fake token it was observed (2026-11-26) to still reach `Ready` with a
UUID external name, which looks like Railway creating an unowned temporary project for an
unauthenticated request (an inference, not verified with Railway). `verify` prints a SKIP for the
Ready step only when the provider reports an authorization error on the `Project`. Without
`VERIFY_LIVE_RAILWAY=1` the whole path is one SKIP line.

Validate structurally with:

```sh
.work/native/bin/kubectl apply --dry-run=client -f hack/fixtures/functions-spike/
```
