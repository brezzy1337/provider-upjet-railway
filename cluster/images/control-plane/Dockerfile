# syntax=docker/dockerfile:1
# ==============================================================================
# Nodeless Crossplane control plane: etcd + kube-apiserver + Crossplane core +
# provider-upjet-railway, supervised in one container.
#
# FULLY SELF-CONTAINED. The build context is nothing but this git tree, and
# every binary is compiled or fetched inside the image, so Railway (or any
# builder) can build straight from the GitHub repo with no `make` step first.
# This is deliberately unlike cluster/images/provider-upjet-railway/Dockerfile,
# which ADDs a binary the Makefile must cross-compile beforehand.
#
# Build from the REPOSITORY ROOT:
#   docker build -f cluster/images/control-plane/Dockerfile -t provider-upjet-railway-control-plane:dev .
#
# No BuildKit cache mounts and no VOLUME instruction: Railway's Dockerfile
# validator rejects both. Why, and what it costs, is in
# docs/architecture/control-plane-image.md.
# ==============================================================================

ARG GO_VERSION=1.26.7
ARG ALPINE_VERSION=3.23.4

# Pins. Keep in sync with hack/native-cluster.sh and the repo Makefile.
ARG KUBERNETES_VERSION=v1.35.8
ARG ETCD_VERSION=v3.6.14
ARG CROSSPLANE_VERSION=2.2.1
ARG TERRAFORM_VERSION=1.5.7
ARG TERRAFORM_PROVIDER_SOURCE=terraform-community-providers/railway
ARG TERRAFORM_PROVIDER_VERSION=0.6.2
ARG TERRAFORM_PROVIDER_REPO=https://github.com/terraform-community-providers/terraform-provider-railway
ARG TERRAFORM_NATIVE_PROVIDER_BINARY=terraform-provider-railway_v0.6.2

# ==============================================================================
# Stage: fetch -- pinned upstream release artifacts
# ==============================================================================
FROM alpine:${ALPINE_VERSION} AS fetch
ARG TARGETOS
ARG TARGETARCH
ARG KUBERNETES_VERSION
ARG ETCD_VERSION
ARG TERRAFORM_VERSION
RUN apk add --no-cache curl tar unzip
WORKDIR /out
RUN set -eux; \
    curl -fsSLo kube-apiserver          "https://dl.k8s.io/release/${KUBERNETES_VERSION}/bin/${TARGETOS}/${TARGETARCH}/kube-apiserver"; \
    curl -fsSLo kube-controller-manager "https://dl.k8s.io/release/${KUBERNETES_VERSION}/bin/${TARGETOS}/${TARGETARCH}/kube-controller-manager"; \
    curl -fsSLo kubectl                 "https://dl.k8s.io/release/${KUBERNETES_VERSION}/bin/${TARGETOS}/${TARGETARCH}/kubectl"; \
    curl -fsSL "https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-${TARGETOS}-${TARGETARCH}.tar.gz" \
      | tar -xz --strip-components=1 \
          "etcd-${ETCD_VERSION}-${TARGETOS}-${TARGETARCH}/etcd" \
          "etcd-${ETCD_VERSION}-${TARGETOS}-${TARGETARCH}/etcdctl" \
          "etcd-${ETCD_VERSION}-${TARGETOS}-${TARGETARCH}/etcdutl"; \
    curl -fsSLo terraform.zip "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_${TARGETOS}_${TARGETARCH}.zip"; \
    unzip -q terraform.zip && rm terraform.zip; \
    chmod +x /out/*

# ==============================================================================
# Stage: provider-build -- this repository's Crossplane provider
# ==============================================================================
FROM golang:${GO_VERSION}-alpine AS provider-build
ARG TARGETOS
ARG TARGETARCH
ENV CGO_ENABLED=0 GOTOOLCHAIN=local
WORKDIR /src
# Download modules from the manifests alone, so a source edit reuses that layer.
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -o /out/provider ./cmd/provider

# ==============================================================================
# Stage: crossplane-build -- Crossplane core from source
#
# Crossplane publishes a container image, not a standalone binary, and its core
# CRDs live only in the source tree (cluster/crds). Building from the tag gives
# us both the `crossplane core start` binary and the CRDs to install at boot.
# ==============================================================================
FROM golang:${GO_VERSION}-alpine AS crossplane-build
ARG TARGETOS
ARG TARGETARCH
ARG CROSSPLANE_VERSION
ENV CGO_ENABLED=0 GOTOOLCHAIN=local
RUN apk add --no-cache git
RUN git clone --quiet --depth 1 --branch "v${CROSSPLANE_VERSION}" \
      https://github.com/crossplane/crossplane.git /src
WORKDIR /src
RUN GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -o /out/crossplane ./cmd/crossplane
RUN mkdir -p /out/crds /out/webhookconfigurations \
    && cp -r /src/cluster/crds/. /out/crds/ \
    && cp -r /src/cluster/webhookconfigurations/. /out/webhookconfigurations/

# ==============================================================================
# Stage: tfprovider-build -- patched terraform-provider-railway
#
# Upstream PR #93 (remove resources from state on not-found) is still open; the
# v0.6.3 release (2026-10-19) also lacks it, so every published binary breaks
# Upjet's observe on first reconcile and after delete. Build from the tag with our
# patch applied instead of downloading the release.
# ==============================================================================
FROM golang:${GO_VERSION}-alpine AS tfprovider-build
ARG TARGETOS
ARG TARGETARCH
ARG TERRAFORM_PROVIDER_REPO
ARG TERRAFORM_PROVIDER_VERSION
ARG TERRAFORM_NATIVE_PROVIDER_BINARY
ENV CGO_ENABLED=0 GOTOOLCHAIN=local
RUN apk add --no-cache git
RUN git clone --quiet --branch "v${TERRAFORM_PROVIDER_VERSION}" \
      "${TERRAFORM_PROVIDER_REPO}" /src
WORKDIR /src
COPY hack/upstream/*.patch /patches/
RUN git -c user.email=build@local -c user.name=build am /patches/*.patch \
    && git --no-pager log --oneline -1 \
    && test -f internal/provider/not_found.go   # fails loudly if the patch stopped applying
RUN GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -o "/out/${TERRAFORM_NATIVE_PROVIDER_BINARY}" .
# Assert we shipped the patched build, not the v0.6.2 release: gqlparser is a
# dependency only the patch introduces, and the module version is past the tag.
RUN go version -m "/out/${TERRAFORM_NATIVE_PROVIDER_BINARY}" \
      | tee /dev/stderr | grep -q "github.com/vektah/gqlparser"

# ==============================================================================
# Runtime
# ==============================================================================
FROM alpine:${ALPINE_VERSION}
ARG TARGETOS
ARG TARGETARCH
ARG TERRAFORM_VERSION
ARG TERRAFORM_PROVIDER_SOURCE
ARG TERRAFORM_PROVIDER_VERSION
ARG TERRAFORM_NATIVE_PROVIDER_BINARY

# bash: the supervisor uses arrays and process substitution.
# openssl: PKI bootstrap. curl: readiness probes. iproute2: address discovery.
# coreutils: GNU base64/hostname semantics the supervisor relies on.
# su-exec: start as root to own the volume, then drop to CP_RUN_UID (see
# control-plane.sh, Step -2).
RUN apk add --no-cache bash ca-certificates curl openssl iproute2 coreutils tzdata su-exec

ENV USER_ID=65532

# ---- Terraform environment (same layout as the provider image) --------------
ENV PLUGIN_DIR=/terraform/provider-mirror/registry.terraform.io/${TERRAFORM_PROVIDER_SOURCE}/${TERRAFORM_PROVIDER_VERSION}/${TARGETOS}_${TARGETARCH}
ENV TF_CLI_CONFIG_FILE=/terraform/.terraformrc
ENV TF_FORK=0
ENV TERRAFORM_VERSION=${TERRAFORM_VERSION}
ENV TERRAFORM_PROVIDER_SOURCE=${TERRAFORM_PROVIDER_SOURCE}
ENV TERRAFORM_PROVIDER_VERSION=${TERRAFORM_PROVIDER_VERSION}
ENV TERRAFORM_NATIVE_PROVIDER_PATH=${PLUGIN_DIR}/${TERRAFORM_NATIVE_PROVIDER_BINARY}

COPY cluster/images/provider-upjet-railway/terraformrc.hcl ${TF_CLI_CONFIG_FILE}
COPY --from=tfprovider-build /out/ ${PLUGIN_DIR}/

# ---- binaries ---------------------------------------------------------------
COPY --from=fetch             /out/           /usr/local/bin/
COPY --from=crossplane-build  /out/crossplane /usr/local/bin/crossplane
COPY --from=provider-build    /out/provider   /usr/local/bin/provider
COPY cluster/images/control-plane/control-plane.sh /usr/local/bin/control-plane.sh

# ---- CRDs to install at boot ------------------------------------------------
ENV CP_HOME=/var/lib/control-plane
COPY package/crds/                             ${CP_HOME}/crds/railway/
COPY --from=crossplane-build /out/crds/                 ${CP_HOME}/crds/crossplane/
COPY --from=crossplane-build /out/webhookconfigurations/ ${CP_HOME}/crds/webhookconfigurations/

# ---- writable state ---------------------------------------------------------
# CP_STATE_DIR is the one persistent mount (etcd, PKI, VERSION); the why and
# the guards are documented at CP_STATE_DIR in control-plane.sh. Mount the
# platform volume exactly here. CP_REQUIRE_PERSISTENT makes a forgotten mount
# fail the boot. Starts as root by design; see Step -2 in control-plane.sh.
ENV CP_STATE_DIR=${CP_HOME}/state
ENV CP_REQUIRE_PERSISTENT=true
ENV CP_RUN_UID=${USER_ID}
# B3: the secrets encryption key must come from the platform's secret store,
# and the static admin bearer token is off; client certificates only.
ENV CP_REQUIRE_EXTERNAL_KEY=true
ENV CP_ADMIN_TOKEN_ENABLED=false
RUN mkdir -p ${CP_HOME}/log ${CP_HOME}/run ${CP_HOME}/cache ${CP_HOME}/tf ${CP_STATE_DIR} \
    && chmod +x /usr/local/bin/control-plane.sh \
    && chmod 700 ${CP_STATE_DIR} \
    && chown -R ${USER_ID}:${USER_ID} ${CP_HOME} /terraform

# Deliberately no USER: control-plane.sh (Step -2) drops to CP_RUN_UID itself
# after taking ownership of the volume.

# 6443 kube-apiserver (put a Railway *TCP* proxy in front: HTTP domains
#      terminate TLS at the edge and this API server serves its own TLS).
# 8080 crossplane core metrics, 8081 crossplane core health, 8090 provider metrics.
EXPOSE 6443 8080 8081 8090

ENTRYPOINT ["/usr/local/bin/control-plane.sh"]
