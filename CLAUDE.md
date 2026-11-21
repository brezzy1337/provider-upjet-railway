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
