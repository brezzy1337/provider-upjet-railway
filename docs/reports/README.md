# Development reports

One report per working session that ships something. Each report says what landed on `main`, how it
was verified, what was decided, and what was left open, so the project's history reads from here
rather than from Slack threads or git archaeology.

Reports complement, not replace, the other pages: [Roadmap and status](../roadmap.md) is the
current truth and gets edited in place; a report is a dated record whose existing text is not
rewritten afterwards except to fix errors. Design reviews that outlive a session, such as the
[Phase 1 review](../architecture/phase-1-review.md), live under Architecture and are linked from the
report that produced them.

## Conventions

- File name `YYYY-MM-DD.md`, one per day worked; a second session on the same day appends a new
  dated section. A report may cover the preceding days when they had no report of their own.
- Sections, in order: **Summary**, **Shipped** (PRs with merge commits), **Verified** (what was
  actually run and the result), **Decided**, **Found** (problems discovered, fixed or not),
  **Open** (what the next session should pick up).
- Facts only: numbers come from a run, not from memory; anything not run is listed as not verified.
- Add the new report to `SUMMARY.md` under this section, newest first.
- A PR that carries the report itself cannot know its own merge commit; write "this PR" in the
  Merge column and let the next session fill in the SHA.

## Reports

| Date | Summary |
|------|---------|
| [2026-11-21](2026-11-21.md) | Toolchain restored, GitBook docs live, `/ship` pipeline in use, Phase 1 control plane merged and reviewed; session 2: Phase 2 B1, one persistent state root |
