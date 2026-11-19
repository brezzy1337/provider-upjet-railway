# CLAUDE.md — provider-upjet-railway

Crossplane provider for Railway, generated with **Upjet v2** from
`terraform-community-providers/railway`. Bun/Theurgy conventions do not apply here; this is a Go
(1.26) / Crossplane / Terraform-plugin project using the standard Upjet layout
(`config/` hand-written config, `apis/` + `internal/controller/` + `package/crds/` generated).

Start with `docs/README.md` (GitBook-synced documentation: concepts, roadmap, architecture) and then
`.claude/handoff/railway-control-plane-handoff.md`, the 2026-08 record of what was verified and the
lessons learned building the control plane. When status changes, update `docs/roadmap.md`.

Commands: `make generate` (regenerate after touching `config/`), `go build ./...`, `go test ./...`,
`hack/dev-cluster.sh` (kind + Crossplane + CRDs), `hack/run-provider.sh` (provider out-of-cluster).
Never commit tokens; `RAILWAY_TOKEN` must be a workspace/account token. Generated files
(`zz_*.go`, `package/crds/*.yaml`, `examples-generated/`) are committed but never hand-edited.
