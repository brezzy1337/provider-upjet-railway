# Upstream patches for terraform-community-providers/railway

Patches applied on top of the pinned `TERRAFORM_PROVIDER_VERSION` tag before
building the Terraform provider binary used by this Crossplane provider.

Apply and build:

```console
git clone --branch v0.6.2 https://github.com/terraform-community-providers/terraform-provider-railway
cd terraform-provider-railway && git am ../hack/upstream/*.patch
go build -o <mirror>/registry.terraform.io/terraform-community-providers/railway/0.6.2/linux_amd64/terraform-provider-railway_v0.6.2 .
```

Locally, point Terraform at the mirror with `TF_CLI_CONFIG_FILE` (see
`cluster/images/provider-upjet-railway/terraformrc.hcl` for the layout).
Each patch should be submitted upstream; drop it here once released.
