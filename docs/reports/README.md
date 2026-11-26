# Development reports

One report per working session that ships something. Each report says what landed on `main`, how it
was verified, what was decided, and what was left open, so the project's history reads from here
rather than from Slack threads or git archaeology.

Reports complement, not replace, the other pages: [Roadmap and status](../roadmap.md) is the
current truth and gets edited in place; a report is a dated record whose existing text is not
rewritten afterwards except to fix errors. Each phase of the [roadmap](../roadmap.md) also gets a
**phase review**, written when the phase closes: what it set out to do, what it delivered, how it
was verified, how the reviews changed the design, and what remains. The phase reviews live here
beside the dated reports; each dated report says at its top which phase review it belongs to, and
each phase review lists its reports.

## Conventions

- File name `YYYY-MM-DD.md`, one per day worked; a second session on the same day appends a new
  dated section. A report may cover the preceding days when they had no report of their own.
- Sections, in order: **Summary**, **Shipped** (PRs with merge commits), **Verified** (what was
  actually run and the result), **Decided**, **Found** (problems discovered, fixed or not),
  **Open** (what the next session should pick up).
- Facts only: numbers come from a run, not from memory; anything not run is listed as not verified.
- Add the new report to `SUMMARY.md` under this section, newest first, and to the table below with
  the phase it belongs to; write the phase line under the report's title.
- A PR that carries the report itself cannot know its own merge commit; write "this PR" in the
  Merge column and let the next session fill in the SHA.

## Phase reviews

| Review | Covers | Reports |
|--------|--------|---------|
| [Phase 2 review](phase-2-review.md) | B1 to B5 and etcd client authentication (PRs #5 to #10); the deploy that closed the phase (PRs #13 to #15) is recorded in the 2026-11-25 report | [2026-11-21](2026-11-21.md) (B1), [2026-11-22](2026-11-22.md), [2026-11-24](2026-11-24.md), [2026-11-25](2026-11-25.md) |
| [Phase 1 review](phase-1-review.md) | the control-plane image proven natively (2026-08), merged 2026-11-21 (PR #3) | [2026-11-21](2026-11-21.md) |

## Reports

| Date | Phase | Summary |
|------|-------|---------|
| [2026-11-26](2026-11-26.md) | 3 | Planning: Phase 3's workload layer becomes a `Workload` XRD with presets and Phase 3 is rewritten as an ordered plan; session 2: composition functions as supervised processes, proven on the harness and on Railway after a first deploy that crash-looped on port 8080, then the review fixes; Phase 3 item 1 done |
| [2026-11-25](2026-11-25.md) | [2](phase-2-review.md) | First deploy to Railway: the Phase 1 project reused, two deploy-day fixes (Dockerfile validator, token character set), the control plane up and the `Project` smoke test passed over the internet; Phase 2 done |
| [2026-11-24](2026-11-24.md) | [2](phase-2-review.md) | Preparing the first Railway deploy: the supervisor configures its public endpoint from Railway's own variables; the deploy and template runbook |
| [2026-11-22](2026-11-22.md) | [2](phase-2-review.md) | Phase 2 B2: start as root to own the volume, then drop privileges via `su-exec`; session 2: B3, secrets at rest, audit, 90-day exported credentials; session 3: B4, the Railway token out of every component's environment; session 4: B5, etcd quota, snapshots on the volume, GOMEMLIMIT per process; session 5: etcd client authentication, the last Phase 1 finding; session 6: the Phase 2 review page |
| [2026-11-21](2026-11-21.md) | [1](phase-1-review.md), [2](phase-2-review.md) | Toolchain restored, GitBook docs live, `/ship` pipeline in use, Phase 1 control plane merged and reviewed; session 2: Phase 2 B1, one persistent state root |
