# ==============================================================================
# Control-plane image.
#
# Deliberately NOT wired into build/makelib/imagelight.mk the way
# cluster/images/provider-upjet-railway/Makefile is. That image is built from
# binaries the top-level Makefile cross-compiles into _output/bin first, which
# means `docker build` there cannot work from a bare git checkout. This image is
# self-contained by design -- Railway (or any CI) points at the Dockerfile with
# the repository root as context and nothing else -- so it needs no build
# machinery beyond docker itself, and it is not an xpkg.
#
# Run these from anywhere; the build targets use the repo root as context.
# ==============================================================================

IMAGE       ?= provider-upjet-railway-control-plane
TAG         ?= dev
PLATFORM    ?= linux/amd64
ROOT        := $(shell git -C $(CURDIR) rev-parse --show-toplevel)
DOCKERFILE  := cluster/images/control-plane/Dockerfile

# Container-side paths/ports, kept here so `run` matches the Dockerfile.
# The one volume: etcd + pki + VERSION. Must match ENV CP_STATE_DIR in the Dockerfile.
STATE_DIR ?= /var/lib/control-plane/state
APISERVER_PORT ?= 6443
KUBECONFIG_OUT ?= $(ROOT)/.work/control-plane.kubeconfig

.PHONY: build build-multiarch run shell push kubeconfig clean help

help:
	@echo "build           build $(IMAGE):$(TAG) for $(PLATFORM)"
	@echo "build-multiarch build+push linux/amd64,linux/arm64 (needs REGISTRY)"
	@echo "run             run it with a named volume at $(STATE_DIR), publishing $(APISERVER_PORT)"
	@echo "kubeconfig      copy the generated kubeconfig out of a running container"
	@echo "shell           interactive shell in the image"
	@echo "push            push $(REGISTRY)/$(IMAGE):$(TAG)"
	@echo "clean           remove the image and its state volume"

build:
	docker build --platform $(PLATFORM) -f $(DOCKERFILE) -t $(IMAGE):$(TAG) $(ROOT)

build-multiarch:
	@test -n "$(REGISTRY)" || { echo "set REGISTRY=ghcr.io/<org>"; exit 1; }
	docker buildx build --platform linux/amd64,linux/arm64 --push \
		-f $(DOCKERFILE) -t $(REGISTRY)/$(IMAGE):$(TAG) $(ROOT)

# RAILWAY_TOKEN must be a Railway workspace/account token -- project tokens are
# rejected by the upstream Terraform provider, which only sends Bearer auth.
# Without it the plane still boots; the provider just has no ProviderConfig.
run:
	docker run --rm -it --name $(IMAGE) \
		-p $(APISERVER_PORT):$(APISERVER_PORT) \
		-v $(IMAGE)-state:$(STATE_DIR) \
		-e RAILWAY_TOKEN \
		-e CP_APISERVER_CERT_SANS \
		-e CP_EXTERNAL_URL \
		$(IMAGE):$(TAG)

kubeconfig:
	docker cp $(IMAGE):/var/lib/control-plane/kubeconfig-external $(KUBECONFIG_OUT)
	@echo "wrote $(KUBECONFIG_OUT)"
	@echo "NOTE: its server URL is the container's own address. For a local"
	@echo "      docker run, rewrite it to https://127.0.0.1:$(APISERVER_PORT)"
	@echo "      -- 127.0.0.1 is already in the serving certificate's SANs:"
	@echo "  kubectl --kubeconfig $(KUBECONFIG_OUT) config set-cluster control-plane --server=https://127.0.0.1:$(APISERVER_PORT)"

shell:
	docker run --rm -it --entrypoint /bin/bash $(IMAGE):$(TAG)

push:
	@test -n "$(REGISTRY)" || { echo "set REGISTRY=ghcr.io/<org>"; exit 1; }
	docker tag $(IMAGE):$(TAG) $(REGISTRY)/$(IMAGE):$(TAG)
	docker push $(REGISTRY)/$(IMAGE):$(TAG)

clean:
	-docker rmi $(IMAGE):$(TAG)
	-docker volume rm $(IMAGE)-state
