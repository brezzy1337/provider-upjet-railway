#!/usr/bin/env bash
# Run the provider out-of-cluster against the current kube context, using the
# patched Terraform provider from .work/provider-mirror (see hack/upstream/).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(grep -E '^export TERRAFORM_PROVIDER_VERSION' Makefile | awk -F'= ' '{print $2}')"
MIRROR=".work/provider-mirror/registry.terraform.io/terraform-community-providers/railway/${VERSION}/linux_amd64/terraform-provider-railway_v${VERSION}"
[ -x "$MIRROR" ] || { echo "missing $MIRROR — build the patched provider first (hack/upstream/README.md)"; exit 1; }
[ -f .work/terraformrc.hcl ] || cat > .work/terraformrc.hcl <<RC
provider_installation {
  filesystem_mirror {
    path    = "$PWD/.work/provider-mirror"
    include = ["*/*"]
  }
  direct {
    exclude = ["*/*"]
  }
}
RC
go build -o .work/provider ./cmd/provider
TF_CLI_CONFIG_FILE="$PWD/.work/terraformrc.hcl" \
TF_PLUGIN_CACHE_DIR="$PWD/.work/plugin-cache" \
TERRAFORM_VERSION="$(grep -E '^export TERRAFORM_VERSION' Makefile | awk -F'= ' '{print $2}')" \
TERRAFORM_PROVIDER_SOURCE=terraform-community-providers/railway \
TERRAFORM_PROVIDER_VERSION="$VERSION" \
exec ./.work/provider --debug "$@"
