# Development

## Toolchain

The repository ships a devcontainer (`.devcontainer/`) based on the Go 1.26 image with
docker-in-docker and kubectl. Its post-create script installs kind, the crossplane CLI and terraform at
the versions pinned in the `Makefile`, initialises the `build` submodule (Crossplane's shared make
library) and downloads Go modules.

If a shell has no `go`, `kubectl` or `kind`, the devcontainer was not built from that definition.
Rebuild the container, or install by hand. The following worked on an Alpine-based codespace on
2026-11-20 and gives everything except a container runtime:

```console
sudo apk add github-cli bash curl unzip make gcc musl-dev git openssl iproute2 coreutils
curl -sSLo /tmp/go.tgz https://go.dev/dl/go1.26.11.linux-amd64.tar.gz && sudo tar -C /usr/local -xzf /tmp/go.tgz
echo 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin' >> ~/.profile
export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin   # for this shell; later lines need it
curl -sSLo /tmp/tf.zip https://releases.hashicorp.com/terraform/1.5.7/terraform_1.5.7_linux_amd64.zip && sudo unzip -oq /tmp/tf.zip -d /usr/local/bin
curl -sSL https://raw.githubusercontent.com/golangci/golangci-lint/HEAD/install.sh | sudo sh -s -- -b /usr/local/bin v2.13.0
curl -sSL https://raw.githubusercontent.com/crossplane/crossplane/master/install.sh | XP_VERSION=v2.2.1 sh && sudo mv crossplane /usr/local/bin/
git submodule update --init --recursive
go install golang.org/x/tools/cmd/goimports   # make generate shells out to it and fails mid-run without it
```

A shallow clone with an empty `build/` directory needs the submodule line before any `make` target
works, and `git fetch --unshallow` before `/ship` can compare branches.

**Without Docker** (no `/var/run/docker.sock`, as in a codespace built from a plain image), kind
and `hack/dev-cluster.sh` cannot run. Use `hack/native-cluster.sh` instead: it runs etcd,
kube-apiserver, Crossplane core and this provider as unprivileged bare processes and needs Go,
curl, git, tar, unzip, openssl, `ip` (iproute2) and GNU coreutils. `build` fetches the pinned
binaries and compiles Crossplane core (several minutes), `up` boots the plane in the foreground
(about 15 s), `verify` runs the 16 assertions against it, `down` stops it, `clean` also removes
the state while keeping the binaries. On this codespace the full cycle was run on 2026-11-21.

Pinned versions. These are read from the `Makefile`; the control-plane image and native harness
additionally pin Kubernetes (`v1.35.8`), etcd (`v3.6.14`) and the Alpine base in
`cluster/images/control-plane/Dockerfile` and `hack/native-cluster.sh` (see D5 in the Phase 1 review):

| Component                  | Version              |
|----------------------------|----------------------|
| Go                         | 1.26                 |
| Upjet                      | v2.4.1 (pre-release, `go.mod`) |
| Crossplane / crossplane CLI | 2.2.1               |
| Terraform CLI              | 1.5.7 (last MPL-licensed release) |
| Terraform provider         | `terraform-community-providers/railway` 0.6.2 |

## Layout

| Path                              | Hand-written? | Contents                                           |
|-----------------------------------|:-------------:|----------------------------------------------------|
| `config/`                         | yes           | Upjet configuration: root group, kind overrides, references, external names, embedded schema and docs |
| `internal/clients/railway.go`     | yes           | Turns the `ProviderConfig` Secret into Terraform provider configuration |
| `cmd/provider`, `cmd/generator`   | mostly generated | Provider entrypoint; the generator main        |
| `apis/{cluster,namespaced}/`      | generated     | Go types per kind (`zz_*_types.go`), scheme registration |
| `internal/controller/`            | generated     | One controller package per kind                    |
| `package/crds/`                   | generated     | CRD YAML, also what `hack/dev-cluster.sh` applies  |
| `examples-generated/`             | generated     | One example manifest per kind                      |
| `hack/`                           | yes           | Dev scripts and the upstream patch                 |
| `cluster/images/`                 | yes           | Dockerfile for the provider image                  |
| `docs/`                           | yes           | This documentation (GitBook-synced)                |

Never edit generated files. Change `config/` and regenerate.

## The generate loop

```console
make generate
```

runs the Upjet pipeline (`cmd/generator`): it downloads the Terraform provider schema for the pinned
version, pulls the registry docs, and regenerates `apis/`, `internal/controller/`, `package/crds/` and
`examples-generated/` for both the cluster and namespaced API surfaces. Commit the result together
with the `config/` change that caused it. CI's `check-diff` job fails if the generated tree is stale.

Then:

```console
go build ./...
go test ./...
```

## Running against a real Railway workspace

Two scripts cover the local loop. Both need `RAILWAY_TOKEN` set to a workspace or account token.

```console
hack/dev-cluster.sh    # kind cluster "railway-dev" + Crossplane 2.2.1 + our CRDs + ProviderConfig/default
hack/run-provider.sh   # builds cmd/provider and runs it out-of-cluster with --debug
```

`run-provider.sh` refuses to start unless the **patched** Terraform provider binary exists at
`.work/provider-mirror/...`. Build it once following `hack/upstream/README.md`; the script writes a
`terraformrc.hcl` that routes Terraform's provider installation to that filesystem mirror. Without the
patch, nothing can be created or deleted. See [The not-found patch](../upstream/not-found-patch.md).

Smoke test:

```console
kubectl apply -f examples-generated/cluster/railway/v1alpha1/project.yaml
kubectl get project example -w        # wait for SYNCED=True READY=True
kubectl delete project example        # confirm it disappears from the Railway dashboard
```

## Building the package

```console
make build        # provider binary + xpkg under _output/
make local-deploy # kind + Crossplane + install the local xpkg as a Provider package
make e2e          # local-deploy + uptest
```

Note that `cluster/images/provider-upjet-railway/Dockerfile` downloads the **stock** Terraform
provider release asset. Until the upstream fix lands, an image built from it will carry the not-found
bug; the control-plane image under `cluster/images/control-plane/` builds the patched binary itself
instead.

## Shipping a change

Work on a feature branch and run `/ship` in Claude Code. The pipeline builds, tests and lints, checks
that the generated tree is current, drafts a pull request against `main` for your approval, fans out
a five-lens read-only review panel, posts one consolidated review, waits for your approval to merge,
and reports each step to Slack. Opening and merging always prompt; the gates are enforced through
tool permissions in `.claude/settings.json`, not just prose. The pipeline and its agents live in
`.claude/commands/ship.md` and `.claude/agents/`; the `Ship workflow` section of `CLAUDE.md` is the
source of truth for the stages and the Slack channel. The `gh` CLI must be installed and
authenticated (`gh auth login`); the devcontainer includes it.
