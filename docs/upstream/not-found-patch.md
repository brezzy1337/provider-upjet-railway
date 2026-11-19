# The not-found patch

This provider cannot work against a stock build of `terraform-community-providers/railway`. The
reason, the fix, and how to build with it.

## The bug

Terraform's contract for `Read` is: if the remote object no longer exists, call
`resp.State.RemoveResource(ctx)` and return without error, so that the next plan recreates it. Every
resource in the Railway Terraform provider instead returns a diagnostic error such as
`Project not found`.

In plain Terraform that only hurts after an out-of-band deletion. Under Upjet it is fatal, because
Upjet's observe step is a `terraform refresh` and it relies on removal to answer two questions:

1. **Does this exist yet?** On the very first reconcile the external name is empty. Upjet refreshes
   with an empty ID, expects "gone", and then calls create. The stock provider errors, so nothing is
   ever created.
2. **Is it deleted yet?** After `terraform destroy`, Upjet refreshes again to confirm. The stock
   provider errors, so the finalizer never clears.

Upstream shipped 0.6.3 on 2026-10-19 with the same behaviour.

## The fix

`hack/upstream/0001-remove-resource-on-not-found.patch`, also open upstream as
[PR #93](https://github.com/terraform-community-providers/terraform-provider-railway/pull/93), adds
`internal/provider/not_found.go` with one helper and uses it in all nine `Read` implementations:

```go
func isNotFoundError(err error) bool
```

It returns true when the error is the package's own `errNotFound` sentinel (used by the helpers that
look an object up in a list: variables, domains, proxies) or when a GraphQL response error's message
contains "not found". Only GraphQL *response* errors are inspected, so internal sentinels such as
"deploy is not found", which mean partial data on an object that does exist, are not mistaken for
deletion. Each `Read` then does:

```go
if err != nil {
    if isNotFoundError(err) {
        resp.State.RemoveResource(ctx)
        return
    }
    resp.Diagnostics.AddError(...)
    return
}
```

The patch carries unit tests for the helper. It was verified live for `Project` on 2026-08-25.

## Building with it

The Crossplane provider talks to Terraform through a provider binary resolved by the Terraform CLI.
We point the CLI at a filesystem mirror that holds the patched binary instead of the registry.

```console
git clone --branch v0.6.2 https://github.com/terraform-community-providers/terraform-provider-railway
cd terraform-provider-railway && git am ../hack/upstream/*.patch
go build -o <mirror>/registry.terraform.io/terraform-community-providers/railway/0.6.2/linux_amd64/terraform-provider-railway_v0.6.2 .
```

`hack/run-provider.sh` expects the mirror at `.work/provider-mirror/` and writes the matching
`terraformrc.hcl` (`filesystem_mirror` included, `direct` excluded). The control-plane image does the
same at build time. See `hack/upstream/README.md` and
`cluster/images/provider-upjet-railway/terraformrc.hcl` for the layout.

## When upstream merges

1. Bump `TERRAFORM_PROVIDER_VERSION` in the `Makefile` to the release containing the fix.
2. `make generate`, review the schema diff (0.6.3 already changed `railway_service` and
   `railway_service_domain`), build and test.
3. Delete `hack/upstream/0001-*.patch`, drop the mirror logic from `hack/run-provider.sh`, and let the
   Dockerfile download the stock release asset again.
4. Update the control-plane repository's pinned `PROVIDER_REF`.

If upstream stays quiet, the alternative is to move to 0.6.3 now and rebase the patch onto it. The
patch touches one hunk per resource plus the new helper file, so the rebase is mechanical, but the
`Service` schema change needs a regenerate and review either way.
