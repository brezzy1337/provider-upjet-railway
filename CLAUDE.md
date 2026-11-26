# CLAUDE.md — provider-upjet-railway

Crossplane provider for Railway, generated with **Upjet v2** from
`terraform-community-providers/railway`. Bun/Theurgy conventions do not apply here; this is a Go
(1.26) / Crossplane / Terraform-plugin project using the standard Upjet layout
(`config/` hand-written config, `apis/` + `internal/controller/` + `package/crds/` generated).

Start with `docs/README.md` (GitBook-synced documentation: concepts, roadmap, architecture) and then
`.claude/handoff/railway-control-plane-handoff.md`, the 2026-08 record of what was verified and the
lessons learned building the control plane. When status changes, update `docs/roadmap.md`; when a
session ships something, add or extend the day's report under `docs/reports/` (conventions in its README).

Commands: `make generate` (regenerate after touching `config/`), `go build ./...`, `go test ./...`,
`hack/dev-cluster.sh` (kind + Crossplane + CRDs), `hack/run-provider.sh` (provider out-of-cluster).
Never commit tokens; `RAILWAY_TOKEN` must be a workspace/account token. Generated files
(`zz_*.go`, `package/crds/*.yaml`, `examples-generated/`) are committed but never hand-edited.

## Ship workflow

Changes land through `/ship`, not by pushing to `main`. The command runs a sequential pipeline
on the current feature branch: preflight -> open PR -> review -> merge -> notify. The central
thread owns the chain (sub-agents cannot spawn sub-agents); it runs each stage and passes output
to the next.

Stages and ownership:
- **Preflight**: `go build ./...`, `go test ./...`, `golangci-lint run ./...` (or `go vet` when
  the linter is absent), and `make generate` + clean `git status` whenever `config/`, `go.mod` or
  the Terraform provider version changed. If `go.mod`/`go.sum` changed, `dependency-auditor` must
  return GO. A red preflight stops the pipeline.
- **Open PR**: `pr-author` drafts the title and body; **opening requires human approval** (`git
  push` and `gh pr create` are not pre-authorized, so they prompt; `.claude/settings.json` also
  lists them under `permissions.ask` so the gate holds in auto mode).
- **Review**: fan out to the read-only panel in parallel, scaled to the diff:
  `factual-reviewer`, `architecture-reviewer`, `security-reviewer`, `consistency-reviewer`,
  `redundancy-checker`. The central thread then consolidates the reports into one prioritized
  review with a single verdict and posts it to the PR. Docs-only changes get `factual-reviewer`
  alone.
- **Merge**: **merging requires human approval** (`gh pr merge` is not pre-authorized). Squash
  merge, delete the branch, never merge on red or unfinished CI.
- **Notify**: `slack-notifier` posts each transition to one thread in Slack channel
  **`#railway-upjet-provider`** via the Slack MCP. Change the channel here and nowhere else.

Keep the review lenses distinct: one dimension each, no overlapping roles. Each reviewer returns
findings in the same shape (severity, file, issue, fix, verdict) so consolidation is mechanical.
Reviewers never comment on generated `zz_*` files except to flag a hand edit; they review the
`config/` cause instead.

State lives outside the session: the PR body holds the change summary, the consolidated review and
a trailing `<!-- slack-thread: <ts> -->` marker; the Slack thread holds running status. If the
pipeline is interrupted, re-run `/ship`: it reads the PR and the marker and resumes rather than
starting over.

Gates are not optional. Never work around a red preflight, a blocking review, failing CI, or a
merge gate to ship faster; surface it to a human with the reason.

## Sub-Agent Orchestration

The main session is the orchestrator: it routes work to sub-agents and assembles the results, and
the result is only as good as the routing and the brief. Sub-agents cannot spawn sub-agents, so
every chain is driven from the main session.

### Routing: parallel, sequential, or background

Default to the safest pattern that fits; when unsure, go sequential (a wrong parallel split
conflicts on files, a wrong sequence only costs time). **Parallel** only when the slices sit in
different domains below, none needs another's output, and no two touch the same file.
**Sequential** when one slice consumes another's output, slices share a file, or the scope has to
be understood first. **Background** for research and analysis that edits nothing (reading upstream
source, confirming a tag or flag, auditing a dependency).

### Domain boundaries (parallel splits)

A parallel split is safe only across these; two slices in one domain are sequential.

- **Upjet config**: `config/**`. Its outputs (`apis/**/zz_*.go`, generated controllers under
  `internal/controller/**`, `package/crds/*.yaml`, `examples-generated/**`) are regenerated with
  `make generate`, never edited, and belong to this domain.
- **Provider runtime**: `cmd/**`, `internal/clients/**`, `internal/features/**`,
  `internal/version/**`, `examples/**`.
- **Control-plane image**: `cluster/images/**` (the Dockerfile, the `control-plane.sh` supervisor,
  the image Makefile).
- **Harness and scripts**: `hack/**` (the native harness, `dev-cluster.sh`, `run-provider.sh`, the
  upstream patch).
- **Docs**: `docs/**`, `README.md`, `SUMMARY.md` entries.
- **Pipeline config**: `.claude/**`, `.github/**`, `CLAUDE.md`.

### Dependency chains (sequential order)

- `config/` -> `make generate` -> provider runtime that uses the new types.
- Supervisor (`control-plane.sh`) -> harness check that proves it (`hack/native-cluster.sh
  verify`) -> docs that describe it. The pins in the Dockerfile, the harness and the `Makefile`
  move together, so a pin bump is one sequential slice across those files.
- Upstream Terraform provider version -> patch rebase (`hack/upstream/`) -> regenerate.
- Research (upstream source, Crossplane behaviour) -> implement -> harness -> docs.

### Invocation protocol (every dispatch)

A sub-agent starts with a fresh context and cannot ask follow-ups; a thin brief is the usual cause
of a bad result. Every dispatch carries: **context** (what is going on, which constraints must
survive, for this repo at least: generated files are never hand-edited, secrets never go on a
command line, pins move together), **instructions** (the change, narrowly), **file references**
(exact paths), **success criteria** (the commands that prove it and the expected result).

Weak: "add the function to the supervisor". Strong: "In `cluster/images/control-plane/control-plane.sh`
add `start_functions` after `start_crossplane`, starting `${CP_BIN_DIR}/function-go-templating`
with `--address 127.0.0.1:${CP_FUNCTION_GOTPL_PORT}` and `--tls-server-certs-dir`; done when
`bash -n` passes and `hack/native-cluster.sh verify` reports the new `function-go-templating
process serving mTLS` check PASS".

### Guardrails

- A single-domain change is one implementer, not three; group small related edits.
- Four independent read-only analyses run in parallel, not one by one.
- Reviewers never comment on generated `zz_*` files except to flag a hand edit.
- `CLAUDE_CODE_SUBAGENT_MODEL` may route focused slices to a lighter model; a per-agent `model`
  field overrides it.

### Dependency safety

Go modules (`go.mod`, `go.sum`), and the pinned upstream artifacts (Kubernetes, etcd, Crossplane,
Terraform, the Terraform provider, composition functions) are the supply chain. Before adding or
bumping any of them: confirm the module or tag exists at its canonical source, prefer a release at
least 7 days old unless it is a security fix, and run `dependency-auditor` (GO or NO-GO) for any
`go.mod` change. Pins are exact tags, never floating. Renovate (`.github/renovate.json5`) opens the
bump PRs; it has no release-age cooldown configured yet, so the 7-day rule is applied by hand at
review until one is added. Escalate rather than bypass: a sub-7-day version or a disabled check is
a decision for a human, stated with the reason.

## Feature implementation (/code-todo)

`/code-todo` is the implement-and-review front half; `/ship` is the PR half. It reads a change
request, routes it by the Domain boundaries above, dispatches `implementer` sub-agents with the
full four-part brief, verifies the whole (build, test, lint, `make generate` when `config/`
changed, the native harness when `cluster/` or `hack/` changed), commits to a feature branch
(`<type>/<slug>`, as in `phase-3/functions-spike`), posts the diff summary to Slack through
`slack-notifier` (`DIFF_READY`, same channel as `/ship`), and **waits for an explicit "yes" in the
terminal**. Slack is where the diff is read; approval comes back in the session; the run does not
poll Slack. On the yes it hands the branch to `/ship`, which opens the PR (its own gate), runs the
review panel, gates the merge and notifies.

Boundaries that keep the halves clean: `/code-todo` has no `git push`, `gh pr create` or `gh pr
merge` in its tools; only the central thread commits; implementers edit and verify inside their
globs and report a cross-domain need instead of reaching across; a new or bumped dependency goes
through `dependency-auditor` first. State lives on the branch and in the Slack thread, so an
interrupted run resumes from the branch.
