---
description: Implement a change through domain-routed implementer sub-agents on a feature branch, verify it (go build/test/lint, make generate, the native harness when cluster/ or hack/ change), post the diff summary to Slack for review, then hand the approved branch to /ship
argument-hint: [the change to implement, or @file holding the todo]
allowed-tools: Bash(git status:*), Bash(git diff:*), Bash(git branch:*), Bash(git switch:*), Bash(git checkout:*), Bash(git add:*), Bash(git commit:*), Bash(git log:*), Bash(git merge-base:*), Bash(git stash:*), Bash(go build:*), Bash(go vet:*), Bash(go test:*), Bash(golangci-lint run:*), Bash(make generate:*), Bash(hack/native-cluster.sh:*), Read, Grep, Glob, Agent
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
   unclear in a way that changes what gets built, ask before routing: an implementer starts with a
   fresh context and cannot ask follow-ups. Anything that would create or delete Railway resources
   beyond the existing `control-plane` service, or spend money beyond it, is a decision for the
   user, not for this command.

2. **Route by domain.** Match the change against the **Domain boundaries** in `CLAUDE.md`. One
   domain, one `implementer`. Several domains whose globs do not intersect and whose slices do not
   consume each other's output: implementers in parallel, in one message. Dependent slices (the
   **Dependency chains** in `CLAUDE.md`, for example a supervisor change before the harness check
   that proves it, or `config/` before `make generate`): a sequence you drive, handing each step's
   report to the next brief. When unsure, go sequential. Research that does not edit files (reading
   upstream source, confirming a tag or a flag) goes to a background `Explore` or
   `general-purpose` agent, or you do it yourself, before the first implementer is briefed.

3. **Prepare the branch.** `git switch -c <type>/<slug>` from an up-to-date `main` (`phase-3/...`,
   `fix/...`, `docs/...`, `chore/...`, matching the history). Implementers edit on it; only you
   commit.

4. **Dispatch implementer(s).** Every brief carries the four parts (context, instructions, exact
   file references, success criteria) plus the slice's globs, the verification commands for that
   domain, and the standing rules: generated `zz_*` files, `package/crds/*.yaml` and
   `examples-generated/` are never hand-edited; secrets never go on a command line or into a log;
   pins live in three places (`cluster/images/control-plane/Dockerfile` ARGs,
   `hack/native-cluster.sh`, the repo `Makefile`) and move together. A slice that needs a new or
   bumped Go module goes to `dependency-auditor` first and stops on NO-GO. Stop on red: an
   implementer that cannot meet its success criteria, or a verification that fails and cannot be
   fixed inside the slice, halts the chain; report what failed and why rather than working around it.

5. **Verify the whole.** With all slices in: `go build ./...`, `go test ./...`,
   `golangci-lint run ./...`; `make generate` and a clean `git status --short` whenever `config/`,
   `go.mod` or `TERRAFORM_PROVIDER_VERSION` changed; `bash -n` on every changed shell script; and
   when `cluster/` or `hack/` changed, the native harness (`hack/native-cluster.sh up` in the
   background with `CP_ENCRYPTION_KEY` and `RAILWAY_TOKEN` read from files inside a script, never on
   the command line, then `hack/native-cluster.sh verify`, then `down`). Record the pass count and
   any SKIP exactly as printed.

6. **Commit, post to Slack, GATE.** Commit to the branch with a conventional message (`feat:`,
   `fix:`, `docs:`, `chore:`, or `control-plane:` as the history uses) ending with the attribution
   line from the session's reminder. Summarise `git diff --stat origin/main...HEAD` by area in a
   few lines, then delegate to `slack-notifier` with `DIFF_READY`, the branch name, the summary and
   the verification result. Then **stop and wait for an explicit "yes" here in the terminal**.
   Slack is where the diff is read; approval comes back in this session; do not poll Slack. On
   requested changes: re-brief, update the branch, commit, re-post in the same thread.

7. **Hand off to `/ship`.** Only after the yes: tell the user to type `/ship <one-line summary>` on
   this branch. `/ship` owns the PR, the five-lens review, the merge gate and the PR notifications;
   this command never pushes, opens or merges (those tools are deliberately absent above). If
   `.claude/commands/ship.md` is missing, say the branch is ready for a PR by hand.

Never work around the review gate, a red verification, a `dependency-auditor` NO-GO or a user
decision to move faster. If something blocks, stop and say why.
