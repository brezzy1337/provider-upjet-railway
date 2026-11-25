# The control-plane image on Railway's builder

_Last updated 2026-11-25, from the first build of the image on Railway. The [Architecture](control-plane.md)
page says what runs inside the image; this page is about getting it built, and in particular about
what Railway's builder accepts._

The control plane ships as one container image built from
`cluster/images/control-plane/Dockerfile` with the repository root as the build context. The
Dockerfile is self-contained: it fetches pinned release binaries (etcd, kube-apiserver,
kube-controller-manager, kubectl, Terraform), compiles this provider from the tree, Crossplane core
from its tag and the patched Terraform provider from `hack/upstream/`, and assembles them on Alpine.
Railway builds it straight from the uploaded tree or from the GitHub repository, with no `make`
step and no registry in between; the same file builds locally with `docker build` from the repository
root (see the comment at the top of the Dockerfile).

## What Railway's validator rejects

Railway validates a Dockerfile before it builds it. The first upload on 2026-11-25 was refused in
seconds, before any stage ran, with:

```
dockerfile invalid: flag '--mount=type=cache,target=/go/pkg/mod' is missing an id argument at Line 63
dockerfile invalid: flag '--mount=type=cache,target=/go/pkg/mod' is missing an id argument at Line 65
dockerfile invalid: flag '--mount=type=cache,target=/go/pkg/mod' is missing an id argument at Line 84
dockerfile invalid: flag '--mount=type=cache,target=/go/pkg/mod' is missing an id argument at Line 113
dockerfile invalid: docker VOLUME at Line 182 is not supported, use Railway Volumes
```

Two rules follow, and the Dockerfile now keeps both.

**No BuildKit cache mounts.** The three Go stages used `--mount=type=cache` for the module cache and
the build cache, which speeds up repeated local builds. Railway's
[documented form](https://docs.railway.com/builds/dockerfiles#cache-mounts) is

```
--mount=type=cache,id=s/<service id>-<target path>,target=<target path>
```

with the service id written literally; variables are not allowed in the id. A Dockerfile that is
meant to be deployed by anyone, through a template or a fork, cannot carry one deployer's service
id, so the mounts were removed rather than given an id. The cost is that every Railway build
downloads the Go modules again. The first full build, with nothing cached, took under three minutes
from upload to pushed image, so the cost is small; Railway keeps its own layer cache between builds
of the same service (the build log ends with `exporting cache to Amazon S3`).

**No `VOLUME` instruction.** The Dockerfile declared `VOLUME` on the state root as documentation of
where the persistent mount belongs. Railway rejects the instruction outright and mounts volumes
from the service configuration instead. The line is gone; the state root, its guards and the
required mount path are documented at `CP_STATE_DIR` in `control-plane.sh` and in
[The state root](control-plane.md#the-state-root), and the supervisor refuses to boot when nothing is
mounted there (`CP_REQUIRE_PERSISTENT=true` in the image).

Neither change alters what the image does at runtime.

## What the first build showed

| Observation | Value |
|-------------|-------|
| Upload of the working tree (`railway up`) | 317 kB snapshot; `.gitignore` is honoured, so `.work/` stays home |
| Dockerfile path | from the `RAILWAY_DOCKERFILE_PATH` service variable, context at the repository root |
| Build, upload to pushed image | 2 min 40 s with no cache (2026-11-25, `amd64`) |
| Builder | BuildKit with Railway's layer cache on S3; `# syntax=docker/dockerfile:1` is accepted |
| Image start | the container starts as root and the supervisor's ownership step runs first, as designed |

A rebuild is also what a change to the service's volume configuration triggers: moving the volume's
mount path redeployed the service from its stored code snapshot, not from a new upload, so the
snapshot has to contain the Dockerfile the `RAILWAY_DOCKERFILE_PATH` variable names. The
[deploy runbook](../getting-started/deploy-to-railway.md) has the order of operations.

## Keeping the Dockerfile portable

- Pins (Go, Alpine, Kubernetes, etcd, Crossplane, Terraform, the Terraform provider) are `ARG`s at
  the top of the file; keep them in step with `hack/native-cluster.sh` and the repository Makefile.
- Anything the image needs from the tree (`package/crds/`, `hack/upstream/*.patch`,
  `cluster/images/provider-upjet-railway/terraformrc.hcl`) is copied by path; moving those files
  breaks the build.
- `.dockerignore` keeps credentials, `.work/` and `.git/` out of the context whether the build runs
  locally or on Railway.
- Before adding a BuildKit feature, check it against Railway's validator by uploading once with
  `railway up --detach`; the validator answers in seconds and costs nothing.
