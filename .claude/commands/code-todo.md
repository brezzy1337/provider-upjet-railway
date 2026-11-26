---
description: Implement a change through domain-routed implementer sub-agents on a feature branch, verify it (go build/test/lint, make generate, the native harness when cluster/ or hack/ change), post the diff summary to Slack for review, then hand the approved branch to /ship
argument-hint: [the change to implement, or @file holding the todo]
allowed-tools: Bash(git status:*), Bash(git diff:*), Bash(git fetch:*), Bash(git branch --show-current:*), Bash(git branch --list:*), Bash(git switch:*), Bash(git add:*), Bash(git commit:*), Bash(git log:*), Bash(git merge-base:*), Bash(go build:*), Bash(go vet:*), Bash(go test:*), Bash(golangci-lint run:*), Bash(make generate:*), Bash(bash -n:*), Bash(hack/native-cluster-from-files.sh:*), Bash(hack/native-cluster.sh verify:*), Bash(hack/native-cluster.sh down:*), Read, Grep, Glob, Agent
---

# Code-todo

Context (gathered for you):
- Branch: !`git branch --show-current`
- Status: !`git status --short`
- Commits ahead of main: !`git log --oneline origin/main..HEAD 2>/dev/null`

Implement the change described in $ARGUMENTS (a sentence, a numbered todo, or an `@file` such as a
handoff under `.claude/handoff/`). You, the central thread, own the chain: sub-agents cannot spawn
sub-agents, so you route the work, brief each implementer completely, hold all git state, run the
gate and do the handoff. The routing rules, domain globs and briefing protocol are the
"Sub-Agent Orchestration" section of `CLAUDE.md`; the boundary with `/ship` is the "Feature
implementation (/code-todo)" section. Read both before step 2.

**Never on `main`.** Step 3 creates a feature branch; if the branch is already a feature branch
with commits for this change, resume from the branch (re-read `git log` and `git diff
origin/main...HEAD`) instead of re-implementing.

1. **Read the request.** Extract the concrete deliverables and the done-when. If the scope is
   unclear in a way that changes what gets built, ask me before routing: an implementer starts
   with a fresh context and cannot ask follow-ups. Anything that would create or delete Railway
   resources beyond the existing `control-plane` service, or spend money beyond it, is my
   decision, not this command's.

2. **Route by domain.** Match the change against the **Domain boundaries** in `CLAUDE.md`. One
   domain, one `implementer`. Several domains whose globs do not intersect and whose slices do not
   consume each other's output: implementers in parallel, in one message. Dependent slices (the
   **Dependency chains** in `CLAUDE.md`, for example a supervisor change before the harness check
   that proves it, or `config/` before `make generate`): a sequence you drive, handing each step's
   report to the next brief. When unsure, go sequential. Research that does not edit files (reading
   upstream source, confirming a tag or a flag) goes to a background `Explore` or
   `general-purpose` agent, or you do it yourself, before the first implementer is briefed. A
   slice in the pipeline-config domain (`.claude/**`, `.github/**`, `CLAUDE.md`) is yours to edit,
   not an implementer's: it changes what every later run may do.

3. **Prepare the branch.** `git fetch origin`, then `git switch -c <type>/<slug> origin/main`,
   where type is `docs`, `fix`, `chore` or `phase-N` (the merged history uses `docs/`, `fix/` and
   `phase-N/`; `chore/` is new with this command). Implementers edit on it; only you commit.

4. **Dispatch implementer(s).** Every brief carries the four parts (context, instructions, exact
   file references, success criteria) plus the slice's globs, the verification commands for that
   domain, and the standing rules from `CLAUDE.md` (generated files are never hand-edited; secrets
   never go on a command line, into a log or into a report; pins are declared in the Dockerfile
   `ARG`s and the repo `Makefile`, which the harness reads). A slice that needs a new or bumped Go
   module goes to `dependency-auditor` first and stops on NO-GO. Stop on red: an implementer that
   cannot meet its success criteria, or a verification that fails and cannot be fixed inside the
   slice, halts the chain; report what failed and why rather than working around it.

5. **Verify the whole.** With all slices in: `go build ./...`, `go test ./...`,
   `golangci-lint run ./...`; `make generate` and a clean `git status --short` whenever `config/`,
   `go.mod` or `TERRAFORM_PROVIDER_VERSION` changed; `bash -n` on every changed shell script. When
   `cluster/` or `hack/` changed, read the diff of those files yourself first (the harness runs
   them), then run the native harness through `hack/native-cluster-from-files.sh <keyfile>
   <tokenfile> up` in the background (it exports `CP_ENCRYPTION_KEY` and `RAILWAY_TOKEN` from the
   two files, so neither value is on a command line; use the documented fake token unless the
   change needs real Railway, since the round trip talks to the real API), then
   `hack/native-cluster.sh verify`, then `hack/native-cluster.sh down`. Record only the PASS, FAIL
   and SKIP counts and the text of any FAIL or SKIP line.

6. **Commit, then GATE 1: do not hand off.** Stage explicit paths (never `git add -A` or `.`),
   run `git diff --cached` and refuse to commit if it contains a token-shaped value, a kubeconfig,
   a key file or a Secret manifest with data. Commit with a conventional message (`feat:`, `fix:`,
   `docs:`, `chore:`, or `control-plane:` as the history uses) ending with the attribution line
   from the session's reminder. Summarise `git diff --stat origin/main...HEAD` by area in a few
   lines, delegate to `slack-notifier` with `DIFF_READY`, the branch name, that summary and the
   counts from step 5 (never command output), and keep the thread `ts` it returns. Then **stop and
   wait for my explicit "yes" here in the terminal**. Slack is where I read the diff; I approve in
   this session; do not poll Slack. On requested changes: re-brief, update the branch, commit,
   re-post in the same thread.

7. **Hand off to `/ship`.** Only after my yes: tell me to type `/ship <one-line summary>
   --slack-thread <ts>` on this branch, so `/ship` continues the same Slack thread. `/ship` owns
   the PR, the review panel, the merge gate and the PR notifications; this command never pushes,
   opens or merges (those tools are deliberately absent above). If `.claude/commands/ship.md` is
   missing, say the branch is ready for a PR by hand.

Never work around the review gate, a red verification, a `dependency-auditor` NO-GO or a decision
that is mine to make. If something blocks, stop and say why.
