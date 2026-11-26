# The control-plane image on Railway's builder

_Last updated 2026-11-26 (the composition functions and the Go pin); the build observations are
from the first build of the image on Railway, 2026-11-25. The [Architecture](control-plane.md)
page says what runs inside the image; this page is about getting it built, and in particular about
what Railway's builder accepts._

The control plane ships as one container image built from
`cluster/images/control-plane/Dockerfile` with the repository root as the build context; what the
image contains and why it is self-contained is in [Architecture](control-plane.md). Railway builds it
straight from the uploaded tree or from the GitHub repository, with no `make` step and no registry to
configure; the same file builds locally with `docker build` from the repository root (see the
comment at the top of the Dockerfile).

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
downloads the Go modules again; the first build, with nothing cached, was quick enough (table below)
for that to be acceptable. Railway's builder exported a layer cache of its own at the end of the
build (`exporting cache to Amazon S3`); whether a later build of the same service hits it has not
been timed. Local `docker build` runs lose the mounts too.

**No `VOLUME` instruction.** The Dockerfile declared `VOLUME` on the state root as documentation of
where the persistent mount belongs. Railway rejects the instruction outright and mounts volumes
from the service configuration instead. The line is gone; the state root, its guards and the
required mount path are in [The state root](control-plane.md#the-state-root), and the supervisor
refuses to boot when nothing is mounted there.

Neither change alters what the image does on Railway. One local difference: a plain `docker run`
without `-v` used to get an anonymous Docker volume at the state root and now gets the container
layer, which the persistence guard rejects, so pass `-v` or set `CP_REQUIRE_PERSISTENT=false` for a
throwaway run.

## What the first build showed

One build, deployment `12255d3e` on 2026-11-25; the numbers are that build's and will drift.

| Observation | Value |
|-------------|-------|
| Upload of the working tree (`railway up`) | 317 kB snapshot, so `.gitignore` is honoured and `.work/` stays home |
| Dockerfile path | from the `RAILWAY_DOCKERFILE_PATH` service variable, context at the repository root |
| Upload to container start | 2 min 40 s with no cache, `linux/amd64`; the image push itself took 5 s |
| Builder | BuildKit; `# syntax=docker/dockerfile:1` accepted; a layer cache exported to S3 at the end |
| First supervisor log line | `started as root: taking ownership for 65532:65532, then dropping privileges`, as designed |

A rebuild is also what a change to the service's volume configuration triggers: moving the volume's
mount path redeployed the service from its stored code snapshot, not from a new upload, so the
snapshot has to contain the Dockerfile the `RAILWAY_DOCKERFILE_PATH` variable names. The
[deploy runbook](../getting-started/deploy-to-railway.md) has the order of operations.

## Keeping the Dockerfile portable

- Pins (Go, Alpine, Kubernetes, etcd, Crossplane, Terraform, the Terraform provider, the two
  composition functions) are `ARG`s at the top of the file; keep them in step with
  `hack/native-cluster.sh` and the repository Makefile.
- The composition functions (`function-go-templating`, `function-auto-ready`; see
  [Composition functions](control-plane.md#composition-functions)) are built from their GitHub tags
  in the `functions-build` stage, a plain `go build` at the root of each cloned module, and copied
  beside the other binaries so the supervisor finds each `CP_FUNCTIONS` entry by name.
- The Go pin follows the newest `go` directive among the modules the image builds: the stages set
  `GOTOOLCHAIN=local`, which refuses to download a newer toolchain, and both functions' `go.mod`
  require 1.26.11, which moved `GO_VERSION` from 1.26.7 to 1.26.11 on 2026-11-26. Check a function's
  `go.mod` before bumping its version, and check that its function-sdk-go still ignores a failed
  metrics bind on `:8080`: the functions start after Crossplane core so that Crossplane owns that
  port (see [Composition functions](control-plane.md#composition-functions)). The functions add no
  `EXPOSE`; they listen on loopback only, and `EXPOSE 8080` remains Crossplane's metrics.
- Anything the image needs from the tree (`package/crds/`, `hack/upstream/*.patch`,
  `cluster/images/provider-upjet-railway/terraformrc.hcl`) is copied by path; moving those files
  breaks the build.
- `.dockerignore` keeps credentials, `.work/` and `.git/` out of the context whether the build runs
  locally or on Railway.
- Before adding a BuildKit feature, check it against Railway's validator by uploading once with
  `railway up --detach`; the validator answers in seconds and costs nothing.
