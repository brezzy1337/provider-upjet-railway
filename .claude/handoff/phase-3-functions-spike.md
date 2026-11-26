# Handoff: Phase 3, item 1 — composition functions as supervised processes

_Written 2026-11-26 at the end of the session that deployed the control plane to Railway (PRs #13
to #17). Paste the prompt below into a fresh session. Everything in it is stated as of main
`3f0aefc` plus this file's PR; verify before relying on it._

## The prompt

Continue provider-upjet-railway: start Phase 3 with the composition-function spike, the item every
Composition depends on.

Context (verify before relying on it):
- Repo: brezzy1337/provider-upjet-railway, branch main. Read CLAUDE.md, then
  docs/architecture/introduction.md (the map), docs/architecture/control-plane.md (mechanics; note
  the Phase 1 lessons: Compositions need a Function, which is a gRPC server with mTLS whose
  certificate must be signed by Crossplane's root CA; `crossplane core start` loads an mTLS client
  certificate unconditionally and the supervisor already unpacks Crossplane's TLS material from its
  Secret; webhooks are off; `crossplane core init` races a fresh API server and is retried),
  docs/roadmap.md Phase 3 (the order and the done-when), docs/reports/2026-11-25.md and
  2026-11-26.md, and the Phase 2 review under docs/reports/. The memory directory records Railway
  facts and the live project.
- State: the control plane runs on Railway in the pre-existing project
  `do-k8-crossplane-control-plane`, service `control-plane`, environment `production`, region sfo,
  TCP proxy `ballast.proxy.rlwy.net:25942`; never create a second project. The Phase 2 exit
  criterion passed on 2026-11-25 (`Project` smoke test over the internet). The codespace directory
  is linked (`railway link` done); the CLI needs `source "$HOME/.railway/env"` in every shell; an SSH
  key is registered for `railway ssh` and `railway service files`. The exported kubeconfig is at
  `.work/kubeconfig-external` (gitignored, 90 days; re-download with
  `railway service files download /var/lib/control-plane/kubeconfig-external .work/kubeconfig-external --overwrite`).
  Secrets live sealed in the dashboard; never put them on a command line, never print
  `railway variable list` values.
- Environment: codespace on Alpine, no Docker, no Node.js, `sudo` available. The native harness
  (`hack/native-cluster.sh build|up|verify|down|clean`, 48 PASS + 1 SKIP with the Railway proxy
  variables and a fake token such as `fake_token-for-b4-test`) is the only local test; pass
  `CP_ENCRYPTION_KEY` and `RAILWAY_TOKEN` to it from files inside a script, never in the Bash
  command line, because its `verify` scans every process command line for the token. A cold start
  takes 40 to 55 s here, a restart 25 s. The Railway build takes under 3 min cold, about 70 s warm;
  deploy a committed tree with `railway up --service control-plane --detach --json` and read the
  boot log with `railway logs -d -n 400 <deployment id>`; deployment status `SUCCESS` means the
  container started, not that the plane is up.
- Process: `/code-todo` does not exist in this project yet; author it first with the
  `subagent-code-todo` skill (it builds on `subagent-orchestration` and the existing `/ship`
  pipeline and agents in `.claude/agents/`), then kick off the todo below with it. Branch per
  change; native harness before any PR when `cluster/` or `hack/` change; ship through `/ship`
  (preflight, PR, five-lens review, merge; both human gates need an explicit yes); Slack updates go
  to #railway-upjet-provider; when waiting on CI filter `gh run list --workflow CI` by the head SHA.
  Anything that creates or deletes Railway resources beyond the existing service, or spends money
  beyond it, is a decision to bring to the user first. A session that ships something adds or
  extends `docs/reports/<date>.md` per its README, with the phase line under the title (phase 3,
  no review yet), and updates `docs/roadmap.md` when status changes.

The todo, Phase 3 item 1 (done when a Composition that uses a function composes an object on the
live plane):
1. Pick the function and build it from source into the image like Crossplane core is
   (`function-go-templating` for rendering and branching, `function-auto-ready` for readiness;
   functions are shipped as xpkg images, so the binary comes from `go build` at a pinned tag, with
   the pin as a Dockerfile ARG and in `hack/native-cluster.sh` the same way the other pins are).
   No BuildKit cache mounts, no `VOLUME` (Railway's validator).
2. Supervise it: start each function as another process after Crossplane core is ready, with a
   serving certificate the supervisor issues and signs with Crossplane's root CA (the
   `crossplane-root-ca` Secret that `crossplane core init` creates; the supervisor already reads
   Crossplane's TLS Secret for the client side), listening on loopback; give it a `GOMEMLIMIT`
   share (add it to `GOMEMLIMIT_COMPONENTS`, keep the total at or under 100); stop it in the same
   shutdown order as the others.
3. Register it: with `--package-runtime=External` the package manager will not create a
   Deployment, so write the `Function` object and make its `FunctionRevision` report the loopback
   endpoint the way the Phase 1 notes describe ("endpoint written by hand"); confirm what Crossplane
   2.2.1 expects by reading its source for the External runtime rather than assuming.
4. Prove it: a throwaway XRD (for example `XRailwayProject`, namespaced, Crossplane 2.x, no claim)
   whose Composition is a pipeline using the function to render one Railway `Project`; apply an XR
   on the native harness, see the `Project` created and `Ready`, delete the XR, see it gone. Add
   harness checks for the function process, its certificate chain, the `FunctionRevision` endpoint
   and the round trip. Then the same on Railway over the internet.
5. Record: the lessons (what the External runtime really needs, memory of a function process,
   startup order) in docs/architecture/control-plane.md, the roadmap status, the day's report; the
   throwaway XRD stays as a harness fixture, not a product API.

Carry-overs, not part of this todo unless cheap: the serving-certificate SAN comparison looked
order-sensitive on the 2026-11-25 redeploy (hypothesis, harmless); a live `etcdutl snapshot restore`
with the service stopped has not been done; the service still deploys from an uploaded tree, not
from the GitHub repository (`railway service source connect`); checksum pinning for the fetched
binaries is still open; an empty untracked file literally named `*.txt` sits in the repo root.
