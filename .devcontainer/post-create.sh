#!/usr/bin/env bash
# Toolchain for developing an Upjet-based Crossplane provider.
# Versions track the pins in the Makefile (KIND_VERSION, CROSSPLANE_VERSION, TERRAFORM_VERSION).
set -euo pipefail

KIND_VERSION="$(grep -E '^KIND_VERSION' Makefile | awk -F'= ' '{print $2}')"
CROSSPLANE_VERSION="$(grep -E '^CROSSPLANE_VERSION' Makefile | awk -F'= ' '{print $2}')"
TERRAFORM_VERSION="$(grep -E '^export TERRAFORM_VERSION' Makefile | awk -F'= ' '{print $2}')"

# kind
curl -sSLo /tmp/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
sudo install -m 0755 /tmp/kind /usr/local/bin/kind

# crossplane CLI
curl -sSL https://raw.githubusercontent.com/crossplane/crossplane/master/install.sh | XP_VERSION="v${CROSSPLANE_VERSION}" sh
sudo mv crossplane /usr/local/bin/crossplane

# terraform (Upjet generator + tests need the CLI + native provider binary)
curl -sSLo /tmp/tf.zip "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip"
sudo unzip -oq /tmp/tf.zip -d /usr/local/bin

# git submodules (crossplane/build) + go deps
git submodule update --init --recursive
go mod download

echo "---"; go version; kind version; crossplane version --client 2>/dev/null || crossplane --version; terraform version | head -1
