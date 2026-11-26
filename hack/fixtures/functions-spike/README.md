# functions-spike fixtures

Harness fixtures for `hack/native-cluster.sh verify` (Phase 3, item 1: composition functions as
supervised processes). They are **not a product API**: the group `harness.railway.crossplane.io`
exists only so the harness can prove that a Composition pipeline runs through the functions the
control plane supervises (`function-go-templating`, `function-auto-ready`).

| File               | What it is                                                                                     |
|--------------------|------------------------------------------------------------------------------------------------|
| `xrd.yaml`         | Namespaced `apiextensions.crossplane.io/v2` XRD `XRailwayProject` with one field, `spec.name`.  |
| `composition.yaml` | Pipeline: `render` (go-templating, one `railway.m.crossplane.io/v1alpha1` `Project`), `ready`.  |
| `xr.yaml`          | XR `spike` in namespace `functions-spike`, `spec.name: upjet-functions-spike`.                  |

`verify` applies the XRD and Composition, waits for the CompositionRevision to report
`ValidPipeline=True` (the proof that each function's `FunctionRevision` carries the `composition`
capability), creates the namespace, applies the XR, and waits for a `Project` labelled
`crossplane.io/composite=spike` whose `spec.forProvider.name` equals the XR's `spec.name`. With a
real `RAILWAY_TOKEN` the XR then reaches `Ready=True`; with the fake token the provider is refused
by Railway and verify prints a SKIP for that step. The XR is deleted at the end and the Project
must disappear.

Validate structurally with:

```sh
.work/native/bin/kubectl apply --dry-run=client -f hack/fixtures/functions-spike/
```
