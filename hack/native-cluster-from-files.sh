#!/usr/bin/env bash
# ==============================================================================
# Run hack/native-cluster.sh with the two secrets read from files.
#
#   hack/native-cluster-from-files.sh KEYFILE TOKENFILE up|verify|...
#
# KEYFILE holds CP_ENCRYPTION_KEY (openssl rand -base64 32), TOKENFILE holds
# RAILWAY_TOKEN (the documented fake token unless the run must reach Railway).
# Why a wrapper: the harness takes both from the environment, and `verify`
# fails the run when the token appears on any process command line, so an
# `RAILWAY_TOKEN=... hack/native-cluster.sh up` invocation defeats its own
# check. Reading the files here keeps the values off every command line and
# out of the shell history. Everything else (CP_*, RAILWAY_* simulation
# variables) passes through from the caller's environment unchanged.
# ==============================================================================
set -euo pipefail
[ $# -ge 3 ] || { echo "usage: $0 KEYFILE TOKENFILE <native-cluster.sh arguments>" >&2; exit 2; }
keyfile="$1" tokenfile="$2"; shift 2
[ -r "${keyfile}" ]   || { echo "cannot read key file ${keyfile}" >&2; exit 2; }
[ -r "${tokenfile}" ] || { echo "cannot read token file ${tokenfile}" >&2; exit 2; }
CP_ENCRYPTION_KEY="$(cat "${keyfile}")"; export CP_ENCRYPTION_KEY
RAILWAY_TOKEN="$(cat "${tokenfile}")";   export RAILWAY_TOKEN
exec "$(dirname "$0")/native-cluster.sh" "$@"
