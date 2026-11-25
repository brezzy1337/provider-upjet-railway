# Phase 2 review: hardening the control plane for Railway

_Last updated 2026-11-22. Covers PRs #5 to #10, merged to `main` between 2026-11-21 and 2026-11-22
(`db2c0d3` through `00d5605`). The [Phase 1 review](phase-1-review.md) is the document this one
answers; the mechanics it refers to live in [Architecture](control-plane.md); the per-session record,
including every number below, is in the [development reports](../reports/README.md)._

## What Phase 2 set out to do

Phase 1 produced an image that boots a complete nodeless control plane. Its review found five
things that had to change before that image could be deployed to Railway (B1 to B5) and left one
item of B3 open. Phase 2 was defined as fixing those, deploying, and passing the `Project` smoke test
over the internet. This page covers the first part: every finding is fixed, merged and reviewed. The
deploy itself has not happened yet and is the next step.

## What Phase 2 delivered

| Finding | PR, merge | What changed | Harness checks after |
|---------|-----------|--------------|----------------------|
| B1, PKI on the ephemeral filesystem | #5, `db2c0d3`, 2026-11-21 | One persistent state root, `CP_STATE_DIR`, holding `etcd/`, `pki/` and a `VERSION` high-water stamp; boot guards (not `CP_HOME`, writable, 0700, `CP_REQUIRE_PERSISTENT`, etcd data without its PKI refused); `CP_ALLOW_DOWNGRADE`; `umask 077`; `CP_ADMIN_TOKEN` rotation | 21 |
| B2, volume ownership | #6, `9e2c845` | The image starts as root only to take ownership of the platform-mounted volume, then re-execs itself through `su-exec` as `CP_RUN_UID`; recursive chown only when some inode is mis-owned; refuses uid or gid 0, non-numeric ids, dangerous paths; `CP_STAY_ROOT` opt-out | 22 |
| B3, secrets, audit, credentials | #7, `118bf73` | Secretbox encryption of Secrets under `CP_ENCRYPTION_KEY` with a fingerprint stamp and rotation via `CP_ENCRYPTION_KEY_PREVIOUS`; JSON audit log at `Metadata` level; the exported admin certificate lives 90 days and the in-container identities are minted every boot; the static bearer token is off in the image; hourly expiry watchdog | 28 |
| B4, `RAILWAY_TOKEN` handling | #8, `2d0024d` | The token is read once before any component starts, trimmed, checked against `[A-Za-z0-9-]`, and removed from the environment; the Secret is built on `kubectl`'s stdin and server-side applied; kubectl's diagnostics are masked on failure | 35 |
| B5, etcd quota and memory | #9, `d282731` | `CP_ETCD_QUOTA_BYTES` (`auto`: half the volume, at most 2 GiB) checked against the volume at boot; a background maintenance pass (defrag when fragmented, snapshot to `state/snapshots`, prune) at boot, every 6 h and on `SIGUSR1`; a 60 s alarm poll that compacts, defragments and disarms a NOSPACE alarm; `GOMEMLIMIT` per Go component as a share of the cgroup limit; `etcdutl` in the image | 41 |
| B3 leftover, etcd client authentication | #10, `00d5605` | A dedicated etcd CA; TLS with a client certificate required on both etcd listeners, client and peer; per-boot client identities for the API server and the supervisor; one atomic signing path for every certificate the supervisor issues | 49 |

Across the six PRs the supervisor grew from about 800 to 1 660 lines and the harness's `verify`
from 17 to 49 checks. Twenty-five `CP_*` variables were added; each is documented where it is set
and in the Architecture page section that owns it.

## Verification

Everything was verified with the native harness on this repository's codespace (Alpine 3.23,
2 vCPU, 8 GB, no Docker, `sudo` available). Each PR's report lists every scenario; the ones that
matter most, with their results on the final code of each PR:

| Scenario | Result |
|----------|--------|
| Cold boot on an empty state root | 17 to 38 s to provider ready, depending on the day's load; every check passing |
| Restart on persisted state | 10 to 17 s; cluster CA and admin token unchanged, asserted by `verify` |
| Image older than the `VERSION` stamp | refused; `CP_ALLOW_DOWNGRADE=true` boots with a warning and keeps the mark |
| Started as root on a root-owned state root | ownership taken, every process including the supervisor at uid 1000 afterwards; `CP_RUN_UID=0`, `CP_STATE_DIR=/` and the like refused before any filesystem change |
| Encryption key rotation `KA` to `KB` | every Secret re-encrypted after the API server is up; a boot with the wrong key refused by fingerprint; a key that is not the base64 of 32 bytes refused |
| Fake `RAILWAY_TOKEN` through a live reconcile | neither `terraform init` nor `terraform apply`, captured while running, had the token among their 86 environment variables; malformed tokens refused before anything starts |
| etcd filled past a 100 MiB quota | NOSPACE raised at 105 MB; after deleting the objects the alarm cleared on the next pass, at boot or on signal, database 100 to 1 MiB |
| Live data over 90% of the quota, restart | refused with the two ways out; a restart with a larger quota cleared the alarm at boot in 18 s |
| etcd without a certificate, with a cluster-CA certificate, or in plaintext | each refused with a TLS alert or a dropped connection, on both ports; the etcd CA rotated by removing its files and rebooting |
| Shutdown | all components gone within about 10 s every time, no kill escalation observed |

Two defects were found by running rather than by reading, both in B5: under a NOSPACE alarm the
API server cannot compact (its compactor writes a bookkeeping key first, and that write is refused),
and `etcdctl endpoint health` reports an alarmed member unhealthy, which wedged the original
readiness gate. Both would have made a full etcd on Railway unrecoverable without a shell.

What was **not** verified in Phase 2: the Docker image build (no Docker here), anything on Railway,
a real cgroup-limited container (only the explicit-limit and no-limit paths of `GOMEMLIMIT` ran),
`etcdutl snapshot restore` end to end, the certificate-expiry watchdog path, and the live `Project`
round trip.

## How the reviews changed the design

Every PR went through the read-only review panel before merge (factual, architecture, security,
consistency and redundancy for anything touching `cluster/` or `hack/`), and the panel's findings
were fixed before merging. The findings that changed the design rather than the wording:

- **B1.** The version stamp was rewritten unconditionally, so a boot with a missing binary would have
  lowered it and disarmed the guard; a Makefile comment on the `STATE_DIR` line would have mounted
  the volume at the wrong path; a forgotten mount was undetectable until `CP_REQUIRE_PERSISTENT`.
- **B2.** `CP_RUN_UID=0` re-exec'd forever; the ownership test looked at the top directory only; the
  layout guard ran after the drop, so `CP_STATE_DIR=/` would have been chowned as root first.
- **B3.** The in-container clients shared the exported 90-day certificate, so a container up past
  day 90 would have lost its own credentials. The identities were split: short-lived exported,
  per-boot internal, plus the hourly watchdog. A crafted key could have injected YAML into the
  encryption configuration; a failed Secret list during re-encryption moved the stamp anyway.
- **B4.** Interior whitespace was stripped from the token, so `abc 123` would have been accepted as
  `abc123`; client-side apply stored the token a second time in an annotation; the environ probe
  could not see `terraform` (its `argv[0]` is just `terraform`) and passed vacuously on an unreadable
  file.
- **B5.** The first maintenance pass ran under `set -e` with plain pipelines, so an empty `etcdctl`
  reply would have killed the supervisor; it ran synchronously, so a hung etcd would have blocked
  `SIGTERM` handling; a fixed 2 GiB quota would have crash-looped on a small Railway volume. The
  pass became a background job that cannot fail the supervisor, the quota became `auto`, and a boot
  snapshot no longer rotates good snapshots away in a crash loop. The reviewer's suggestion of a
  non-fatal gate for an alarmed etcd was tried and rejected by test: `crossplane core init` needs
  writes.
- **etcd client authentication.** The peer port was a second unauthenticated door, so it got TLS
  too; a crash between a key write and its certificate write would have wedged every later boot,
  which produced the shared atomic signing path; the harness refusal checks accepted any failure, a
  timeout included, and now assert the cause.

## Decisions

- **Fail fast on configuration, never on maintenance.** A malformed key, token, quota or memory
  value stops the boot before anything starts, which on Railway means a restart loop until the
  variable is fixed. The maintenance pass, by contrast, may never take the supervisor down.
- **Two certificate classes, three CAs.** Exported credentials are short-lived; in-container
  identities are minted every boot. The cluster CA, the front-proxy CA and the etcd CA each sign one
  kind of thing, so a certificate from one cannot be used against another.
- **One uid, stated plainly.** Everything in the container still runs as `CP_RUN_UID`. The
  Railway-token residual (the supervisor's own exec-time environment), the readable etcd client keys
  and the readable encryption configuration are all consequences of that, and the docs say so where
  each applies rather than claim a separation that does not exist. The uid split is the item that
  would change it, and Phase 2 made it possible: etcd now authenticates clients, and key files have
  owners worth separating.
- **Snapshots are a rollback aid, not a backup.** They live on the same volume as the database.
- **`auto` over fixed.** The quota and the `GOMEMLIMIT` shares derive from the container's own
  volume and memory limit, with explicit overrides, so the same image boots on a 0.5 GB trial volume
  and a 50 GB one.

## What remains

Nothing from the Phase 1 review blocks the deploy. In order:

1. **The deploy itself**, by the runbook
   [Deploy the control plane to Railway](../getting-started/deploy-to-railway.md). Done when the
   `Project` smoke test passes over the internet. The first deploy should also exercise
   `etcdutl snapshot restore` once and check the `GOMEMLIMIT` shares against observed usage under the
   real limit.
2. **The composition-function spike**, unchanged from Phase 1: a function as a supervised process
   with its endpoint written by hand. Every XRD depends on it.
3. **The uid split** for the provider and terraform: per-component ownership of key files and the
   etcd data directory, a PKI directory the provider cannot traverse, and a reduced RBAC identity in
   place of `system:masters` (D3 of the Phase 1 review).
4. **Design debt D1, D2, D4, D5 and D6** of the Phase 1 review are unchanged: all-or-nothing
   supervision, no component abstraction, the package manager bypassed, two build paths, no
   Railway-facing health check. The maintenance pass and the alarm poll were added to the existing
   supervise loop rather than to a new structure, so D1 and D2 grew slightly.
5. **Smaller items** surfaced along the way: checksum pinning for the fetched binaries (the Phase 1
   supply-chain note, still open); no watchdog for CA expiry at ten years; `hack/dev-cluster.sh`
   still builds its Secret with `--from-literal`; an unusable Railway token surfaces from the
   provider as a `prevent_destroy` error rather than "Not Authorized".

## Reproducing the verification

```bash
hack/native-cluster.sh build        # several minutes the first time
export CP_ENCRYPTION_KEY="$(openssl rand -base64 32)"
export RAILWAY_TOKEN=fake_token-for-test   # any [A-Za-z0-9._-] value; reconciles just fail
hack/native-cluster.sh up           # foreground; Ctrl-C to stop
hack/native-cluster.sh verify       # in another shell: 49 checks with the token
hack/native-cluster.sh down
```

`verify` reads `RAILWAY_TOKEN` from its own environment for the token checks and skips them with a
SKIP line otherwise (43 checks); `CP_MEMORY_LIMIT_BYTES=` (empty) exercises cgroup detection and
skips the `GOMEMLIMIT` check. The root path, which is what the image does on Railway, is
`sudo -E env PATH="$PATH" hack/native-cluster.sh up` on a state root first chowned to root. State
lives under `.work/native/` (gitignored); `clean` then `up` is the cold-start test, `down` then `up`
the restart test.
