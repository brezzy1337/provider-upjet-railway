---
description: Ship the current branch — preflight (build, test, lint, regenerate check), open a PR against main, run the five-lens review panel, merge, and notify Slack — with human approval gates before opening and before merging
argument-hint: [one-line summary of the change]
allowed-tools: Bash(git status:*), Bash(git diff:*), Bash(git branch:*), Bash(git log:*), Bash(git merge-base:*), Bash(git fetch:*), Bash(gh auth status:*), Bash(gh pr view:*), Bash(gh pr list:*), Bash(gh pr checks:*), Bash(go build:*), Bash(go vet:*), Bash(go test:*), Bash(golangci-lint run:*), Bash(make generate:*), Read, Grep, Glob, Agent
---

# Ship

Context (gathered for you):
- Branch: !`git branch --show-current`
- Status: !`git status --short`
- Commits ahead of main: !`git log --oneline origin/main..HEAD`
- Diff stat vs main: !`git diff --stat origin/main...HEAD | tail -1`
- Existing PR for this branch: !`gh pr view --json number,url,state,title 2>/dev/null || echo none`

Run the ship pipeline for the current branch against base branch **`main`**. Treat $ARGUMENTS as
an optional one-line summary of the change. The chain is sequential and you, the central thread,
own it: sub-agents cannot spawn sub-agents. Slack destination and state rules are in the
"Ship workflow" section of `CLAUDE.md`.

**Refuse to run on `main`.** If the current branch is `main`, stop and say that `/ship` needs a
feature branch (`git switch -c <name>`), then exit. Nothing below applies.

**Resume, don't restart.** If a PR already exists for this branch, read its body with
`gh pr view --json body`: pick up the Slack thread marker (`<!-- slack-thread: <ts> -->`) and skip
to the first stage that is not yet recorded there.

1. **Preflight.** Run, in order, and stop on the first failure:
   - `go build ./...`
   - `go test ./...`
   - `golangci-lint run ./...` if the binary is available; otherwise `go vet ./...` and say that
     full lint will run in CI.
   - If the diff touches `config/`, `go.mod`, or the `TERRAFORM_PROVIDER_VERSION` line of the
     `Makefile`: run `make generate` and then `git status --short`. Any resulting change means the
     committed generated tree is stale; stop and report (do not commit it yourself).
   - If `go.mod` or `go.sum` changed, delegate to the `dependency-auditor` sub-agent and stop on
     NO-GO.
   A red preflight halts the pipeline. Report what failed and stop; never work around it.

2. **Draft the PR.** Delegate to the `pr-author` sub-agent for a title and body.
   **GATE 1: do not open the PR.** Show me the draft and the base branch and wait for my explicit
   "yes". `git push` and `gh pr create` are not pre-authorized, so they will prompt; that prompt is
   the gate. After opening, delegate to `slack-notifier` with `PR_OPENED`, then append the returned
   `<!-- slack-thread: <ts> -->` marker to the PR body with `gh pr edit --body`.

3. **Review: fan out, then consolidate.** Scale the panel to the diff:
   - Docs-only or a one-line change: run `factual-reviewer` alone, or skip and say why.
   - Anything touching `config/`, `internal/`, `hack/`, `cluster/`, `.github/` or `go.mod`:
     dispatch all five read-only lenses **in parallel** in one message: `factual-reviewer`,
     `architecture-reviewer`, `security-reviewer`, `consistency-reviewer`, `redundancy-checker`.
   Then consolidate yourself: merge the findings, resolve conflicts between lenses, de-duplicate,
   rank by impact, and post ONE prioritized review to the PR with `gh pr comment` under a single
   overall verdict (APPROVE, APPROVE WITH NOTES, or CHANGES REQUESTED). Summarize the blocking
   issues for me. Delegate to `slack-notifier` with `REVIEW_POSTED`.

4. **GATE 2: do not merge.** Show me the consolidated review and your merge recommendation and wait
   for my explicit "yes". `gh pr merge` is not pre-authorized and will prompt. Merge with
   `gh pr merge --squash --delete-branch`. If CI checks are still running (`gh pr checks`), say so
   and wait for them rather than merging on red or unknown.

5. **Notify.** Delegate to `slack-notifier` with `MERGED`. All three updates go in the same thread.

Never work around a gate, a red preflight, a blocking review, or failing CI to ship faster. If
something blocks, stop and tell me the reason.
