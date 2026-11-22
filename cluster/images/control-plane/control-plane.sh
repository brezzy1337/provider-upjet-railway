#!/usr/bin/env bash
# ==============================================================================
# Nodeless Crossplane control plane supervisor.
#
# Boots, in order, gating every step on the previous one being READY (not merely
# started):
#
#   1. etcd
#   2. kube-apiserver          (own end-to-end TLS on $CP_APISERVER_PORT)
#   3. kube-controller-manager (optional; garbage collector + namespace only)
#   4. CRDs                    (Crossplane core via `crossplane core init`,
#                               plus this provider's package/crds)
#   5. crossplane core start   (out-of-cluster, package manager set to External)
#   6. provider-upjet-railway  (out-of-cluster, patched Terraform mirror)
#
# There is no kubelet and no scheduler: nothing in this control plane runs Pods.
# Providers are supervised processes, not Crossplane Packages, precisely because
# the package manager would create Deployments that could never be scheduled.
#
# Secrets are never baked into the image: $RAILWAY_TOKEN arrives as an
# environment variable and is written into a Secret + ProviderConfig at boot.
#
# The same script drives the container image and the native (Docker-less) proof
# in hack/native-cluster.sh, so the flags proven there are the flags shipped.
# ==============================================================================
set -euo pipefail
# Everything this script writes is credential material or cluster state.
umask 077

# ------------------------------------------------------------------------------
# Configuration (every value overridable from the environment)
# ------------------------------------------------------------------------------
CP_HOME="${CP_HOME:-/var/lib/control-plane}"
CP_BIN_DIR="${CP_BIN_DIR:-/usr/local/bin}"
CP_LOG_DIR="${CP_LOG_DIR:-${CP_HOME}/log}"
CP_RUN_DIR="${CP_RUN_DIR:-${CP_HOME}/run}"

# One state root on one volume. Everything that must survive a redeploy lives
# under it: etcd data AND the PKI (cluster CA, SA signing key, admin
# credentials). Keeping only etcd persistent, as Phase 1 did, meant every
# redeploy minted a new CA against old etcd state and invalidated every
# kubeconfig ever issued. Mount the platform volume here (Railway: set the
# service volume mount path to this directory; Dockerfile VOLUME is ignored).
CP_STATE_DIR="${CP_STATE_DIR:-${CP_HOME}/state}"
CP_PKI_DIR="${CP_PKI_DIR:-${CP_STATE_DIR}/pki}"
CP_ETCD_DATA_DIR="${CP_ETCD_DATA_DIR:-${CP_STATE_DIR}/etcd}"
# Refuse to start an older image on newer stored state (etcd and kube-apiserver
# do not support downgrade). Set to true to override once, knowingly; the stamp
# keeps its high-water mark, so every later boot of the older image needs it too.
CP_ALLOW_DOWNGRADE="${CP_ALLOW_DOWNGRADE:-false}"
# When true, refuse to boot if the state root is on the same filesystem as
# CP_HOME, i.e. no volume is mounted there. The image sets this; the native
# harness, which has no mount, leaves it unset and gets an informational line.
CP_REQUIRE_PERSISTENT="${CP_REQUIRE_PERSISTENT:-false}"
# The image starts as root so it can take ownership of a platform-mounted,
# root-owned volume, then re-execs itself as this uid:gid via su-exec before
# anything else runs. Nothing below this block ever runs as root unless
# CP_STAY_ROOT=true is set deliberately.
CP_RUN_UID="${CP_RUN_UID:-65532}"
CP_RUN_GID="${CP_RUN_GID:-${CP_RUN_UID}}"
CP_STAY_ROOT="${CP_STAY_ROOT:-false}"
# Force the recursive chown even when no mismatched file is found.
CP_FORCE_CHOWN="${CP_FORCE_CHOWN:-false}"

# ---- B3: secrets at rest, audit, credential lifetimes ------------------------
# Rationale and behaviour: docs/architecture/control-plane.md, "Secrets, audit
# and credential lifetimes". Only what each variable does is noted here.
# Secretbox key for Secrets in etcd (32 random bytes, base64; openssl rand -base64 32).
CP_ENCRYPTION_KEY="${CP_ENCRYPTION_KEY:-}"
# The key the data is currently under, when rotating to CP_ENCRYPTION_KEY.
CP_ENCRYPTION_KEY_PREVIOUS="${CP_ENCRYPTION_KEY_PREVIOUS:-}"
# true (the image): refuse to boot without CP_ENCRYPTION_KEY; false: generate one under pki/.
CP_REQUIRE_EXTERNAL_KEY="${CP_REQUIRE_EXTERNAL_KEY:-false}"
CP_AUDIT_ENABLED="${CP_AUDIT_ENABLED:-true}"
# "-" sends the audit log to the API server's stdout (CP_LOG_DIR/kube-apiserver.log).
CP_AUDIT_LOG_PATH="${CP_AUDIT_LOG_PATH:-${CP_LOG_DIR}/audit.log}"
CP_AUDIT_LOG_MAXSIZE_MB="${CP_AUDIT_LOG_MAXSIZE_MB:-20}"
CP_AUDIT_LOG_MAXBACKUP="${CP_AUDIT_LOG_MAXBACKUP:-3}"
CP_AUDIT_LOG_MAXAGE_DAYS="${CP_AUDIT_LOG_MAXAGE_DAYS:-7}"
# Lifetime of the admin certificate in the EXPORTED kubeconfig (renewed at boot past the midpoint).
CP_CLIENT_CERT_DAYS="${CP_CLIENT_CERT_DAYS:-90}"
# Lifetime of the certificates the in-container clients use; minted fresh every boot, never exported.
CP_INTERNAL_CERT_DAYS="${CP_INTERNAL_CERT_DAYS:-3650}"
CP_SERVING_CERT_DAYS="${CP_SERVING_CERT_DAYS:-365}"
# Static admin bearer token; false in the image (client certificates only).
CP_ADMIN_TOKEN_ENABLED="${CP_ADMIN_TOKEN_ENABLED:-true}"
CP_TLS_MIN_VERSION="${CP_TLS_MIN_VERSION:-VersionTLS12}"
for _v in CP_CLIENT_CERT_DAYS CP_INTERNAL_CERT_DAYS CP_SERVING_CERT_DAYS CP_AUDIT_LOG_MAXSIZE_MB CP_AUDIT_LOG_MAXBACKUP CP_AUDIT_LOG_MAXAGE_DAYS; do
  [[ "${!_v}" =~ ^[1-9][0-9]*$ ]] || { printf '%s [control-plane] FATAL: %s must be a positive integer (got "%s")\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_v" "${!_v}" >&2; exit 1; }
done
unset _v
CP_KCM_PORT="${CP_KCM_PORT:-10257}"   # kube-controller-manager secure/health port, loopback only
CP_ETCD_CLIENT_PORT="${CP_ETCD_CLIENT_PORT:-2379}"
CP_ETCD_PEER_PORT="${CP_ETCD_PEER_PORT:-2380}"

# kube-apiserver serves its own TLS end to end. Railway HTTP domains terminate
# TLS at the edge, so this port is meant to sit behind a Railway *TCP* proxy.
CP_APISERVER_BIND_ADDRESS="${CP_APISERVER_BIND_ADDRESS:-0.0.0.0}"
CP_APISERVER_PORT="${CP_APISERVER_PORT:-6443}"
CP_APISERVER_ADVERTISE_ADDRESS="${CP_APISERVER_ADVERTISE_ADDRESS:-}"
CP_SERVICE_CLUSTER_IP_RANGE="${CP_SERVICE_CLUSTER_IP_RANGE:-10.96.0.0/24}"
# Comma-separated extra SANs for the serving cert. Put the future public
# hostname (Railway TCP proxy) here, e.g. "monorail.proxy.rlwy.net".
CP_APISERVER_CERT_SANS="${CP_APISERVER_CERT_SANS:-}"
# Public URL clients outside the container should use. Defaults to the first
# extra SAN if one was given, otherwise to the advertise address.
CP_EXTERNAL_URL="${CP_EXTERNAL_URL:-}"

CP_CROSSPLANE_NAMESPACE="${CP_CROSSPLANE_NAMESPACE:-crossplane-system}"
CP_CROSSPLANE_METRICS_PORT="${CP_CROSSPLANE_METRICS_PORT:-8080}"
CP_CROSSPLANE_HEALTH_PORT="${CP_CROSSPLANE_HEALTH_PORT:-8081}"
CP_CROSSPLANE_WEBHOOK_PORT="${CP_CROSSPLANE_WEBHOOK_PORT:-9443}"
# Webhooks are off by default: Crossplane's webhook configurations point at a
# Service, and with no Pods nothing ever populates that Service's EndpointSlice.
# (kube-apiserver resolves webhook Services itself, so a hand-written
# EndpointSlice aimed at this container's own IP would work -- but that is an
# unproven path, so it is opt-in.) Cost of leaving this off: the Usage/
# protection controllers and the Usage admission webhook do not run, so
# deletion-ordering protection is unavailable.
CP_ENABLE_WEBHOOKS="${CP_ENABLE_WEBHOOKS:-false}"
# The Kubernetes garbage collector is what deletes composed resources when an
# XR goes away. It lives in kube-controller-manager, so we run a stripped-down
# kube-controller-manager with only the node-independent controllers enabled.
CP_ENABLE_CONTROLLER_MANAGER="${CP_ENABLE_CONTROLLER_MANAGER:-true}"
CP_CONTROLLERS="${CP_CONTROLLERS:-garbagecollector,namespace,serviceaccount,serviceaccount-token,resourcequota,ttl-after-finished}"

CP_PROVIDER_METRICS_PORT="${CP_PROVIDER_METRICS_PORT:-8090}"
CP_PROVIDER_ARGS="${CP_PROVIDER_ARGS:-}"

# CRD source directories, colon separated. The image ships both; the native
# proof points these at a checkout.
CP_CRD_DIRS="${CP_CRD_DIRS:-${CP_HOME}/crds/railway}"
CP_CROSSPLANE_CRDS_DIR="${CP_CROSSPLANE_CRDS_DIR:-${CP_HOME}/crds/crossplane}"
CP_WEBHOOK_CONFIGS_DIR="${CP_WEBHOOK_CONFIGS_DIR:-${CP_HOME}/crds/webhookconfigurations}"

# Terraform wiring, mirroring cluster/images/provider-upjet-railway.
TERRAFORM_VERSION="${TERRAFORM_VERSION:-1.5.7}"
TERRAFORM_PROVIDER_SOURCE="${TERRAFORM_PROVIDER_SOURCE:-terraform-community-providers/railway}"
TERRAFORM_PROVIDER_VERSION="${TERRAFORM_PROVIDER_VERSION:-0.6.2}"

CP_READY_TIMEOUT="${CP_READY_TIMEOUT:-180}"

KUBECONFIG_INTERNAL="${CP_HOME}/kubeconfig"
KUBECONFIG_EXTERNAL="${CP_HOME}/kubeconfig-external"
KUBECONFIG_EXTERNAL_TOKEN="${CP_HOME}/kubeconfig-external-token"

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
log()  { printf '%s [control-plane] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
fail() { log "FATAL: $*"; exit 1; }

PIDS=()
NAMES=()

# Wait until a predicate succeeds, or die. This is the "READY, not merely
# started" gate: every boot step goes through here.
wait_ready() {
  local desc="$1" timeout="$2"; shift 2
  local deadline=$(( $(date +%s) + timeout ))
  log "waiting for ${desc} (timeout ${timeout}s)"
  until "$@" >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      log "---- last 60 lines of ${CP_LOG_DIR} ----"
      tail -n 60 "${CP_LOG_DIR}"/*.log >&2 2>/dev/null || true
      fail "${desc} did not become ready within ${timeout}s"
    fi
    sleep 1
  done
  log "READY: ${desc}"
}

start_bg() {
  local name="$1"; shift
  log "starting ${name}"
  # Own process group per component so shutdown can signal its children too.
  # Side effect in native mode: Ctrl-C on the terminal no longer reaches the
  # components directly; the supervisor's INT trap stops them. If the
  # supervisor itself is SIGKILLed they survive; `native-cluster.sh down` copes.
  if ! command -v setsid >/dev/null 2>&1 && [ -z "${_CP_WARNED_SETSID:-}" ]; then
    log "WARNING: setsid not found; children of ${name} will not be signalled on shutdown"
    _CP_WARNED_SETSID=1
  fi
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" >>"${CP_LOG_DIR}/${name}.log" 2>&1 &
  else
    "$@" >>"${CP_LOG_DIR}/${name}.log" 2>&1 &
  fi
  local pid=$!
  PIDS+=("$pid")
  NAMES+=("$name")
  log "${name} pid=${pid} log=${CP_LOG_DIR}/${name}.log"
}

# Stop in reverse start order, one component at a time: TERM the process group
# (so terraform grandchildren forked by the provider go too), give it
# CP_SHUTDOWN_TIMEOUT seconds, then KILL. Observed without this: kube-apiserver
# outlived the supervisor by a quarter of an hour after a failed boot.
# The budget is per component, so the worst case is 5 x CP_SHUTDOWN_TIMEOUT;
# keep the platform's drain window (Railway: RAILWAY_DEPLOYMENT_DRAINING_SECONDS)
# above that. A clean stop of all five took 7 s in testing.
CP_SHUTDOWN_TIMEOUT="${CP_SHUTDOWN_TIMEOUT:-10}"
[[ "${CP_SHUTDOWN_TIMEOUT}" =~ ^[0-9]+$ ]] || CP_SHUTDOWN_TIMEOUT=10
shutdown() {
  local rc=$?
  trap - EXIT TERM INT
  log "shutting down"
  local i pid t
  for (( i=${#PIDS[@]}-1; i>=0; i-- )); do
    pid="${PIDS[$i]}"
    kill -0 "$pid" 2>/dev/null || continue
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    for (( t=0; t<CP_SHUTDOWN_TIMEOUT; t++ )); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
      log "${NAMES[$i]} (pid $pid) ignored TERM for ${CP_SHUTDOWN_TIMEOUT}s -- killing"
      kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
  done
  exit "$rc"
}

kc() { "${CP_BIN_DIR}/kubectl" --kubeconfig "${KUBECONFIG_INTERNAL}" "$@"; }

# ------------------------------------------------------------------------------
# Step -2: root only long enough to own the volume (B2)
#
# Railway mounts volumes root-owned. A container that starts unprivileged can
# never fix that, so the image starts as root, chowns the state root and the
# ephemeral dirs to CP_RUN_UID, and re-execs this same script as that uid with
# the same arguments and environment. The whole control plane then runs
# unprivileged. The chown is recursive only for a tree in which some inode is
# not owned by the target uid:gid (an interim root-run deployment leaves
# root-owned pki/ and etcd/ behind); a healthy tree costs one short find.
# ------------------------------------------------------------------------------
# Layout guard, shared by the root phase (so nothing is chowned recursively on
# a misconfigured path) and prepare_state_dir.
check_layout() {
  case "${CP_STATE_DIR%/}" in
    ""|"/") fail "CP_STATE_DIR must be a real directory, not '${CP_STATE_DIR}'" ;;
    "${CP_HOME%/}") fail "CP_STATE_DIR must not equal CP_HOME (${CP_HOME}); mount the volume at a subdirectory such as ${CP_HOME}/state" ;;
  esac
  local d
  for d in "${CP_LOG_DIR}" "${CP_RUN_DIR}" "${CP_HOME}/cache"; do
    case "${d%/}/" in "${CP_STATE_DIR%/}/"*) fail "CP_STATE_DIR (${CP_STATE_DIR}) must not contain ephemeral dir ${d}" ;; esac
  done
}

# safe_root_path DIR: refuse to run root-time mkdir/chown on anything that is
# not a plain data directory: /, a system tree, or anything holding CP_BIN_DIR.
safe_root_path() {
  local d r b
  d="$1"; r="$(readlink -f "$d" 2>/dev/null || printf '%s' "$d")"; b="$(readlink -f "${CP_BIN_DIR}" 2>/dev/null || printf '%s' "${CP_BIN_DIR}")"
  case "${r}" in
    ""|/|/usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/etc|/etc/*|/lib|/lib/*|/lib64|/lib64/*|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/boot|/boot/*|/root|/root/*)
      fail "refusing to take ownership of ${d} (resolves to '${r}'); CP_STATE_DIR/CP_HOME/CP_LOG_DIR/CP_RUN_DIR must be plain data directories" ;;
  esac
  case "${b}/" in "${r%/}/"*) fail "refusing to take ownership of ${d}: it contains CP_BIN_DIR (${CP_BIN_DIR})" ;; esac
}

# own_tree DIR: chown -R DIR to CP_RUN_UID:CP_RUN_GID if any inode in it (on
# the same filesystem) has a different owner or group, or if CP_FORCE_CHOWN.
# A healthy tree costs one short find; a tree left root-owned by an earlier
# root-run boot gets fixed wholesale. -xdev keeps a chown of CP_HOME from
# descending into the state volume mounted under it (that one is done on its own).
own_tree() {
  local d="$1"
  [ -d "$d" ] || return 0
  if [ "${CP_FORCE_CHOWN}" = "true" ] \
     || find "$d" -xdev \( ! -user "${CP_RUN_UID}" -o ! -group "${CP_RUN_GID}" \) -print -quit 2>/dev/null | grep -q .; then
    log "chown -R ${CP_RUN_UID}:${CP_RUN_GID} $d"
    chown -hR "${CP_RUN_UID}:${CP_RUN_GID}" "$d"   # -h: never follow a symlink operand
  fi
}

drop_privileges_if_root() {
  [ "$(id -u)" = "0" ] || return 0
  if [ "${CP_STAY_ROOT}" = "true" ]; then
    log "WARNING: CP_STAY_ROOT=true: everything, the internet-facing API server included, runs as root"
    return 0
  fi
  # System tools first while we are root; the harness prepends its own bin dir.
  PATH="/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"
  [ -z "${CP_PRIVS_DROPPED:-}" ] \
    || fail "still uid 0 after dropping privileges to ${CP_RUN_UID}:${CP_RUN_GID}; refusing to loop. Set CP_STAY_ROOT=true only if you accept running as root"
  [[ "${CP_RUN_UID}" =~ ^[0-9]+$ ]] && [[ "${CP_RUN_GID}" =~ ^[0-9]+$ ]] \
    || fail "CP_RUN_UID and CP_RUN_GID must be numeric (got '${CP_RUN_UID}' / '${CP_RUN_GID}')"
  { [ "${CP_RUN_UID}" != "0" ] && [ "${CP_RUN_GID}" != "0" ]; } \
    || fail "CP_RUN_UID/CP_RUN_GID=0 would keep root privileges; set CP_STAY_ROOT=true if that is really what you want"
  command -v su-exec >/dev/null 2>&1 \
    || fail "running as root but su-exec is not installed (apk add su-exec); set CP_STAY_ROOT=true only if you accept running everything as root"
  check_layout
  log "started as root: taking ownership for ${CP_RUN_UID}:${CP_RUN_GID}, then dropping privileges"
  # Create only what the unprivileged process could not create itself (the
  # mount and its parents); main() makes the ephemeral dirs after the drop.
  local d
  for d in "${CP_STATE_DIR}" "${CP_HOME}" "${CP_LOG_DIR}" "${CP_RUN_DIR}"; do
    safe_root_path "$d"
  done
  for d in "${CP_STATE_DIR}" "${CP_HOME}" "${CP_LOG_DIR}" "${CP_RUN_DIR}"; do
    mkdir -p "$d"
  done
  own_tree "${CP_STATE_DIR}"
  own_tree "${CP_HOME}"
  own_tree "${CP_LOG_DIR}"
  own_tree "${CP_RUN_DIR}"
  local self; self="$(readlink -f "${BASH_SOURCE[0]}")"
  exec su-exec "${CP_RUN_UID}:${CP_RUN_GID}" env HOME="${CP_HOME}" CP_PRIVS_DROPPED=1 "${self}" "$@"
}

# ------------------------------------------------------------------------------
# Step -1: the state root
#
# Create or adopt $CP_STATE_DIR, refuse to run if it is not writable, warn if
# the PKI or etcd directories were pointed somewhere else, and keep a VERSION
# stamp so an accidental rollback of the image onto newer stored state fails
# before etcd or the API server get a chance to corrupt it.
# ------------------------------------------------------------------------------
# stamp_read FILE -> contents or ""; stamp_write FILE VALUE: atomic. Used by the
# VERSION and ENCRYPTION stamps in the state root.
stamp_read()  { [ -f "$1" ] && cat "$1" || true; }
stamp_write() { printf '%s' "$2" > "$1.tmp" && mv -f "$1.tmp" "$1"; }

component_versions() {
  printf 'etcd=%s\n' "$("${CP_BIN_DIR}/etcd" --version 2>/dev/null | awk '/etcd Version/{print $3; exit}')"
  printf 'kubernetes=%s\n' "$("${CP_BIN_DIR}/kube-apiserver" --version 2>/dev/null | awk 'NR==1{print $2}')"
}

# kv "<multi-line k=v text>" key  -> value
kv() { printf '%s\n' "$1" | awk -F= -v k="$2" '$1==k{print $2; exit}'; }

# Pre-release suffixes (v1.35.8-rc.1) sort AFTER the release in sort -V, so
# compare the numeric core only; rc -> GA is then not a downgrade.
version_core() { local v="${1%%-*}"; printf '%s' "${v%%+*}"; }
# version_lt A B -> true when A sorts strictly before B
version_lt() {
  local a b; a="$(version_core "$1")"; b="$(version_core "$2")"
  [ "$a" != "$b" ] && [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -1)" = "$a" ]
}
minor_of() { local v; v="$(version_core "$1")"; v="${v#v}"; printf '%s' "${v#*.}" | cut -d. -f1; }

prepare_state_dir() {
  check_layout
  local d

  mkdir -p "${CP_STATE_DIR}" 2>/dev/null || true
  [ -d "${CP_STATE_DIR}" ] || fail "state dir ${CP_STATE_DIR} does not exist and cannot be created"
  [ -w "${CP_STATE_DIR}" ] || fail "state dir ${CP_STATE_DIR} is not writable by uid $(id -u) (root-owned mount? see Step -2: start as root and the supervisor chowns it)"
  chmod 700 "${CP_STATE_DIR}" 2>/dev/null || true
  [ "$(stat -c %a "${CP_STATE_DIR}")" = "700" ] || fail "state dir ${CP_STATE_DIR} is mode $(stat -c %a "${CP_STATE_DIR}"), not 700, and chmod failed (owner uid $(stat -c %u "${CP_STATE_DIR}"), we are $(id -u))"
  mkdir -p "${CP_PKI_DIR}" "${CP_ETCD_DATA_DIR}"
  for d in "${CP_PKI_DIR}" "${CP_ETCD_DATA_DIR}"; do
    [ -w "$d" ] || fail "$d is not writable by uid $(id -u)"
  done
  # Re-tighten modes on state created by an earlier boot with a looser umask.
  chmod -R go-rwx "${CP_PKI_DIR}" "${CP_ETCD_DATA_DIR}" 2>/dev/null || true

  # Is anything actually mounted here? If the state root shares a filesystem
  # with CP_HOME it is on the ephemeral layer and B1 is back. The image sets
  # CP_REQUIRE_PERSISTENT=true so a forgotten volume fails the boot.
  local dev_state dev_home dev_pki dev_etcd
  dev_state="$(stat -c %d "${CP_STATE_DIR}")"; dev_home="$(stat -c %d "${CP_HOME}")"
  if [ "${dev_state}" = "${dev_home}" ]; then
    if [ "${CP_REQUIRE_PERSISTENT}" = "true" ]; then
      fail "${CP_STATE_DIR} is on the same filesystem as ${CP_HOME}: no volume is mounted there, so state would not survive a redeploy. Mount the service volume at ${CP_STATE_DIR}, or set CP_REQUIRE_PERSISTENT=false for a throwaway run"
    fi
    log "note: ${CP_STATE_DIR} is on the same filesystem as ${CP_HOME} (no volume mounted); fine for a local or throwaway run"
  fi
  dev_pki="$(stat -c %d "${CP_PKI_DIR}")"; dev_etcd="$(stat -c %d "${CP_ETCD_DATA_DIR}")"
  if [ "${dev_pki}" != "${dev_state}" ] || [ "${dev_etcd}" != "${dev_state}" ]; then
    log "WARNING: CP_PKI_DIR (${CP_PKI_DIR}) and CP_ETCD_DATA_DIR (${CP_ETCD_DATA_DIR}) are not on the same filesystem as CP_STATE_DIR (${CP_STATE_DIR})."
    log "         A redeploy that keeps one but not the other invalidates every issued kubeconfig."
  fi

  # Partially populated root. etcd data without the PKI that signed what is in
  # it is exactly the B1 failure: refuse rather than mint a new CA over it.
  if [ -d "${CP_ETCD_DATA_DIR}/member" ] && [ ! -f "${CP_PKI_DIR}/ca.crt" ]; then
    fail "etcd data exists under ${CP_ETCD_DATA_DIR} but ${CP_PKI_DIR}/ca.crt is missing. Restore the pki/ directory from backup, or move the etcd data away to start a fresh cluster"
  fi
  if [ -f "${CP_PKI_DIR}/ca.crt" ] && [ ! -d "${CP_ETCD_DATA_DIR}/member" ]; then
    log "PKI present but no etcd data: same cluster identity, fresh (empty) etcd"
  fi

  # VERSION stamp: a high-water mark of the etcd and Kubernetes versions that
  # have ever written this state. An image older than the mark is refused.
  local stamp="${CP_STATE_DIR}/VERSION" current stored k cur old keep=""
  current="$(component_versions)"
  for k in etcd kubernetes; do
    cur="$(kv "${current}" "$k")"
    [ -n "${cur}" ] || fail "could not determine the ${k} version from its binary; refusing to run with a blind downgrade guard"
  done
  stored="$(stamp_read "${stamp}")"
  for k in etcd kubernetes; do
    cur="$(kv "${current}" "$k")"; old="$(kv "${stored}" "$k")"
    if [ -n "${old}" ] && version_lt "${cur}" "${old}"; then
      if [ "${CP_ALLOW_DOWNGRADE}" = "true" ]; then
        log "WARNING: ${k} ${cur} is older than the ${old} that wrote ${stamp}; continuing because CP_ALLOW_DOWNGRADE=true (the stamp keeps ${old})"
      else
        fail "${k} ${cur} in this image is older than ${old} recorded in ${stamp}. Downgrades are unsupported; deploy an image >= ${old}, or set CP_ALLOW_DOWNGRADE=true if you accept the risk"
      fi
      keep="${keep}${k}=${old}"$'\n'
    else
      [ -n "${old}" ] && version_lt "${old}" "${cur}" && log "state written by ${k} ${old}, now running ${cur} (upgrade)"
      if [ "$k" = "kubernetes" ] && [ -n "${old}" ]; then
        local dm; dm=$(( $(minor_of "${cur}") - $(minor_of "${old}") ))
        [ "${dm}" -le 1 ] || log "WARNING: Kubernetes minor version jumped by ${dm} (${old} -> ${cur}); upstream supports one minor at a time"
      fi
      keep="${keep}${k}=${cur}"$'\n'
    fi
  done
  [ -n "${stored}" ] || log "new state root at ${CP_STATE_DIR}"
  stamp_write "${stamp}" "${keep}"
  log "state root ${CP_STATE_DIR} ready: $(printf '%s' "${keep}" | tr '\n' ' ')"
}

# ------------------------------------------------------------------------------
# Step 0: PKI + auth material
#
# Written under $CP_PKI_DIR in the persistent state root (see CP_STATE_DIR).
# Material found there is reused; the serving certificate is regenerated
# whenever the requested SAN set changes (e.g. once the Railway TCP proxy
# hostname is known).
# ------------------------------------------------------------------------------
# All local addresses, one per line. `hostname -I` is GNU; busybox only has -i.
host_addrs() {
  { hostname -I 2>/dev/null || hostname -i 2>/dev/null || true; } | tr ' ' '\n' | sed '/^$/d'
}

# IPv4 literal / IPv6 literal / DNS name -- openssl needs to be told which.
san_family() {
  case "$1" in
    *:*)                      echo IP6 ;;
    [0-9]*.[0-9]*.[0-9]*.[0-9]*)
      case "$1" in *[!0-9.]*) echo DNS ;; *) echo IP4 ;; esac ;;
    *)                        echo DNS ;;
  esac
}

san_entry() {
  case "$(san_family "$1")" in
    DNS) printf 'DNS:%s' "$1" ;;
    *)   printf 'IP:%s'  "$1" ;;
  esac
}

bootstrap_pki() {
  mkdir -p "${CP_PKI_DIR}"
  chmod 700 "${CP_PKI_DIR}"

  # kube-apiserver refuses to start unless --service-cluster-ip-range is in the
  # same address family as the advertise address. Railway containers are
  # dual-stack and `hostname -i` hands back the IPv6 address first, so prefer a
  # routable IPv4 and only fall back to IPv6 (switching the service CIDR with
  # it). Nothing here ever allocates a ClusterIP -- there are no Pods -- so the
  # range only has to be self-consistent.
  local advertise="${CP_APISERVER_ADVERTISE_ADDRESS}"
  if [ -z "${advertise}" ]; then
    advertise="$( { ip -4 route get 1.1.1.1 2>/dev/null || true; } \
                  | awk '{for (i=1;i<NF;i++) if ($i=="src") {print $(i+1); exit}}' )"
    [ -n "${advertise}" ] || advertise="$(host_addrs | grep -E '^[0-9]+(\.[0-9]+){3}$' | head -1)"
    [ -n "${advertise}" ] || advertise="$(host_addrs | grep -E '^[0-9a-fA-F:]+:' | head -1)"
    [ -n "${advertise}" ] || advertise="127.0.0.1"
  fi
  CP_APISERVER_ADVERTISE_ADDRESS="${advertise}"

  if [ "$(san_family "${advertise}")" = "IP6" ] && \
     [ "${CP_SERVICE_CLUSTER_IP_RANGE}" = "10.96.0.0/24" ]; then
    log "advertise address ${advertise} is IPv6; switching service CIDR to fd00:10:96::/112"
    CP_SERVICE_CLUSTER_IP_RANGE="fd00:10:96::/112"
  fi

  # ---- CA -------------------------------------------------------------------
  if [ ! -f "${CP_PKI_DIR}/ca.key" ]; then
    log "generating cluster CA"
    openssl genrsa -out "${CP_PKI_DIR}/ca.key" 4096 2>/dev/null
    openssl req -x509 -new -nodes -key "${CP_PKI_DIR}/ca.key" -sha256 -days 3650 \
      -subj "/CN=control-plane-ca" -out "${CP_PKI_DIR}/ca.crt" 2>/dev/null
  fi

  # ---- front-proxy CA -------------------------------------------------------
  # Without --requestheader-client-ca-file the API server publishes an
  # incomplete `extension-apiserver-authentication` ConfigMap, and every
  # component that uses delegated authentication (kube-controller-manager here)
  # spams "missing content for CA bundle" forever. A CA of its own rather than
  # the cluster CA: anything signed by the requestheader CA can impersonate any
  # user through the aggregation layer, so it must not be the same trust root
  # that ordinary client certificates come from.
  if [ ! -f "${CP_PKI_DIR}/front-proxy-ca.key" ]; then
    log "generating front-proxy CA"
    openssl genrsa -out "${CP_PKI_DIR}/front-proxy-ca.key" 4096 2>/dev/null
    openssl req -x509 -new -nodes -key "${CP_PKI_DIR}/front-proxy-ca.key" -sha256 -days 3650 \
      -subj "/CN=front-proxy-ca" -out "${CP_PKI_DIR}/front-proxy-ca.crt" 2>/dev/null
  fi
  if [ ! -f "${CP_PKI_DIR}/front-proxy-client.crt" ]; then
    log "issuing front-proxy client certificate"
    openssl genrsa -out "${CP_PKI_DIR}/front-proxy-client.key" 2048 2>/dev/null
    openssl req -new -key "${CP_PKI_DIR}/front-proxy-client.key" \
      -subj "/CN=front-proxy-client" -out "${CP_PKI_DIR}/front-proxy-client.csr" 2>/dev/null
    openssl x509 -req -in "${CP_PKI_DIR}/front-proxy-client.csr" \
      -CA "${CP_PKI_DIR}/front-proxy-ca.crt" -CAkey "${CP_PKI_DIR}/front-proxy-ca.key" -CAcreateserial \
      -out "${CP_PKI_DIR}/front-proxy-client.crt" -days 3650 -sha256 \
      -extfile <(printf 'extendedKeyUsage=clientAuth\n') 2>/dev/null
    rm -f "${CP_PKI_DIR}/front-proxy-client.csr"
  fi

  # ---- service account signing key -----------------------------------------
  if [ ! -f "${CP_PKI_DIR}/sa.key" ]; then
    log "generating service account signing key"
    openssl genrsa -out "${CP_PKI_DIR}/sa.key" 2048 2>/dev/null
    openssl rsa -in "${CP_PKI_DIR}/sa.key" -pubout -out "${CP_PKI_DIR}/sa.pub" 2>/dev/null
  fi

  # ---- apiserver serving certificate ---------------------------------------
  local sans="DNS:localhost,DNS:kubernetes,DNS:kubernetes.default,DNS:kubernetes.default.svc,DNS:kubernetes.default.svc.cluster.local,IP:127.0.0.1,IP:::1"
  local h; h="$(hostname 2>/dev/null || echo localhost)"
  sans="${sans},DNS:${h}"
  sans="${sans},$(san_entry "${advertise}")"
  if [ -n "${CP_APISERVER_CERT_SANS}" ]; then
    local extra s
    IFS=',' read -ra extra <<< "${CP_APISERVER_CERT_SANS}"
    for s in "${extra[@]}"; do
      s="$(echo "$s" | tr -d '[:space:]')"
      [ -n "$s" ] || continue
      sans="${sans},$(san_entry "$s")"
    done
  fi

  if [ ! -f "${CP_PKI_DIR}/apiserver.sans" ] || \
     [ "$(cat "${CP_PKI_DIR}/apiserver.sans")" != "${sans}" ] || \
     ! cert_within_policy "${CP_PKI_DIR}/apiserver.crt" "${CP_SERVING_CERT_DAYS}" $(( 30 * 86400 )); then
    log "issuing apiserver serving certificate (${CP_SERVING_CERT_DAYS} days) for ${sans}"
    openssl genrsa -out "${CP_PKI_DIR}/apiserver.key" 2048 2>/dev/null
    openssl req -new -key "${CP_PKI_DIR}/apiserver.key" \
      -subj "/CN=kube-apiserver" -out "${CP_PKI_DIR}/apiserver.csr" 2>/dev/null
    openssl x509 -req -in "${CP_PKI_DIR}/apiserver.csr" \
      -CA "${CP_PKI_DIR}/ca.crt" -CAkey "${CP_PKI_DIR}/ca.key" -CAcreateserial \
      -out "${CP_PKI_DIR}/apiserver.crt" -days "${CP_SERVING_CERT_DAYS}" -sha256 \
      -extfile <(printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\n' "${sans}") 2>/dev/null
    rm -f "${CP_PKI_DIR}/apiserver.csr"
    printf '%s' "${sans}" > "${CP_PKI_DIR}/apiserver.sans"
  fi

  # ---- client certificates --------------------------------------------------
  # admin: O=system:masters, which RBAC treats as superuser.
  # controller-manager: a distinct identity, also system:masters for simplicity
  #   in a single-tenant control plane.
  # admin: the identity in the EXPORTED kubeconfig; short-lived, renewed past the midpoint.
  # admin-internal / controller-manager: the in-container clients (supervisor,
  # Crossplane, provider, controller manager); minted fresh every boot and never
  # exported, so their lifetime is irrelevant to anything outside the container
  # and a long-running container never loses its own credentials.
  issue_client_cert admin              "control-plane-admin"            "system:masters" "${CP_CLIENT_CERT_DAYS}"
  issue_client_cert admin-internal     "control-plane-internal"         "system:masters" "${CP_INTERNAL_CERT_DAYS}" always
  issue_client_cert controller-manager "system:kube-controller-manager" "system:masters" "${CP_INTERNAL_CERT_DAYS}" always

  # ---- static bearer token --------------------------------------------------
  # Convenient for clients that cannot carry a client certificate. NEVER
  # anonymous: --anonymous-auth=false is passed to the apiserver.
  if [ "${CP_ADMIN_TOKEN_ENABLED}" != "true" ]; then
    CP_ADMIN_TOKEN=""
    rm -f "${CP_PKI_DIR}/tokens.csv"   # a disabled credential must not linger on the volume
    return 0
  fi
  # Persisted with the PKI. If CP_ADMIN_TOKEN is set in the environment it wins,
  # so changing the platform variable rotates the token on the next boot. Unset,
  # the stored token is reused (or generated on first boot) -- so removing the
  # variable does NOT rotate; set a new value to rotate. The value is never
  # logged (see CP_LOG_ADMIN_TOKEN).
  local tok="${CP_ADMIN_TOKEN:-}"
  if [ -n "${tok}" ] && ! [[ "${tok}" =~ ^[A-Za-z0-9._-]{32,}$ ]]; then
    fail "CP_ADMIN_TOKEN must be at least 32 characters of [A-Za-z0-9._-] (it is a cluster-admin bearer token written into tokens.csv)"
  fi
  if [ -z "${tok}" ] && [ -f "${CP_PKI_DIR}/tokens.csv" ]; then
    tok="$(cut -d, -f1 "${CP_PKI_DIR}/tokens.csv")"
  fi
  [ -n "${tok}" ] || tok="$(openssl rand -hex 32)"
  if [ ! -f "${CP_PKI_DIR}/tokens.csv" ] || [ "$(cut -d, -f1 "${CP_PKI_DIR}/tokens.csv")" != "${tok}" ]; then
    [ -f "${CP_PKI_DIR}/tokens.csv" ] && log "rotating admin bearer token from CP_ADMIN_TOKEN"
    printf '%s,control-plane-admin,control-plane-admin,"system:masters"\n' "${tok}" \
      > "${CP_PKI_DIR}/tokens.csv"
    chmod 600 "${CP_PKI_DIR}/tokens.csv"
  fi
  CP_ADMIN_TOKEN="${tok}"
}

# cert_fresh FILE SECONDS: true when FILE exists and is valid for at least SECONDS more.
cert_fresh() { [ -f "$1" ] && openssl x509 -checkend "$2" -noout -in "$1" >/dev/null 2>&1; }
# cert_within_policy FILE DAYS [MIN_SECONDS]: true when FILE exists, has at least
# MIN_SECONDS left (default half of DAYS), and does not outlive DAYS (so
# lowering the policy shortens an existing cert). The 60 s absorbs issuance skew.
cert_within_policy() {
  local min="${3:-$(( $2 * 86400 / 2 ))}"
  cert_fresh "$1" "${min}" && ! cert_fresh "$1" $(( $2 * 86400 + 60 ))
}

# issue_client_cert NAME CN ORG DAYS [always]: with "always", mint every boot.
issue_client_cert() {
  local name="$1" cn="$2" org="$3" days="$4" mode="${5:-policy}"
  if [ "${mode}" != "always" ]; then
    cert_within_policy "${CP_PKI_DIR}/${name}.crt" "${days}" && return 0
  fi
  log "issuing client certificate ${name} (CN=${cn}, O=${org}, ${days} days)"
  openssl genrsa -out "${CP_PKI_DIR}/${name}.key" 2048 2>/dev/null
  openssl req -new -key "${CP_PKI_DIR}/${name}.key" \
    -subj "/O=${org}/CN=${cn}" -out "${CP_PKI_DIR}/${name}.csr" 2>/dev/null
  openssl x509 -req -in "${CP_PKI_DIR}/${name}.csr" \
    -CA "${CP_PKI_DIR}/ca.crt" -CAkey "${CP_PKI_DIR}/ca.key" -CAcreateserial \
    -out "${CP_PKI_DIR}/${name}.crt" -days "${days}" -sha256 \
    -extfile <(printf 'extendedKeyUsage=clientAuth\n') 2>/dev/null
  rm -f "${CP_PKI_DIR}/${name}.csr"
}

write_kubeconfig() {
  local out="$1" server="$2" identity="$3"
  local ca crt key
  ca="$(base64 < "${CP_PKI_DIR}/ca.crt" | tr -d '\n')"
  crt="$(base64 < "${CP_PKI_DIR}/${identity}.crt" | tr -d '\n')"
  key="$(base64 < "${CP_PKI_DIR}/${identity}.key" | tr -d '\n')"
  cat > "${out}" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: control-plane
  cluster:
    server: ${server}
    certificate-authority-data: ${ca}
contexts:
- name: control-plane
  context:
    cluster: control-plane
    user: ${identity}
current-context: control-plane
users:
- name: ${identity}
  user:
    client-certificate-data: ${crt}
    client-key-data: ${key}
EOF
  chmod 600 "${out}"
}

# Bearer-token variant, for clients that would rather carry one string than a
# key pair (CI, `kubectl config set-credentials --token`). Same identity, same
# system:masters group -- it comes from the same static token file.
write_kubeconfig_token() {
  local out="$1" server="$2"
  local ca; ca="$(base64 < "${CP_PKI_DIR}/ca.crt" | tr -d '\n')"
  cat > "${out}" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: control-plane
  cluster:
    server: ${server}
    certificate-authority-data: ${ca}
contexts:
- name: control-plane
  context:
    cluster: control-plane
    user: control-plane-admin
current-context: control-plane
users:
- name: control-plane-admin
  user:
    token: ${CP_ADMIN_TOKEN}
EOF
  chmod 600 "${out}"
}

# ------------------------------------------------------------------------------
# Step 1: etcd
# ------------------------------------------------------------------------------
start_etcd() {
  # Existence, ownership and mode of ${CP_ETCD_DATA_DIR} were checked in
  # prepare_state_dir.
  start_bg etcd "${CP_BIN_DIR}/etcd" \
    --name control-plane \
    --data-dir "${CP_ETCD_DATA_DIR}" \
    --listen-client-urls "http://127.0.0.1:${CP_ETCD_CLIENT_PORT}" \
    --advertise-client-urls "http://127.0.0.1:${CP_ETCD_CLIENT_PORT}" \
    --listen-peer-urls "http://127.0.0.1:${CP_ETCD_PEER_PORT}" \
    --initial-advertise-peer-urls "http://127.0.0.1:${CP_ETCD_PEER_PORT}" \
    --initial-cluster "control-plane=http://127.0.0.1:${CP_ETCD_PEER_PORT}" \
    --initial-cluster-state new \
    --auto-compaction-retention 1 \
    --quota-backend-bytes 8589934592 \
    --log-level warn

  wait_ready "etcd" "${CP_READY_TIMEOUT}" \
    "${CP_BIN_DIR}/etcdctl" \
      --endpoints "http://127.0.0.1:${CP_ETCD_CLIENT_PORT}" endpoint health
}

# ------------------------------------------------------------------------------
# Step 1b: secrets at rest and audit policy (B3)
#
# Files under CP_RUN_DIR, written each boot. See docs/architecture/control-plane.md.
# ------------------------------------------------------------------------------
key_fp() { printf '%s' "$1" | sha256sum | cut -c1-16; }
# Exactly the base64 of 32 bytes: 43 base64 characters and one '=' pad. Anything
# else (whitespace, extra lines, odd padding) is refused before it can reach the
# YAML below; the decode check is belt and braces.
key_ok() {
  [[ "$1" =~ ^[A-Za-z0-9+/]{43}=$ ]] \
    && [ "$(printf '%s' "$1" | base64 -d 2>/dev/null | wc -c | tr -d ' ')" = "32" ]
}

ENCRYPTION_CONFIG="${CP_RUN_DIR}/encryption-config.yaml"
ENCRYPTION_STAMP="${CP_STATE_DIR}/ENCRYPTION"
ENCRYPTION_REWRAP=false
ENCRYPTION_FP=""

prepare_encryption() {
  local key prev keyfile="${CP_PKI_DIR}/encryption.key"
  key="$(printf '%s' "${CP_ENCRYPTION_KEY}" | tr -d '[:space:]')"
  prev="$(printf '%s' "${CP_ENCRYPTION_KEY_PREVIOUS}" | tr -d '[:space:]')"
  # Never let the key material reach the components' environments.
  unset CP_ENCRYPTION_KEY CP_ENCRYPTION_KEY_PREVIOUS
  if [ -z "${key}" ]; then
    if [ "${CP_REQUIRE_EXTERNAL_KEY}" = "true" ]; then
      fail "CP_ENCRYPTION_KEY is unset. Generate one with 'openssl rand -base64 32', store it in the platform's secret store (never on the volume), and pass it as CP_ENCRYPTION_KEY"
    fi
    if [ -f "${keyfile}" ]; then
      key="$(cat "${keyfile}")"
    else
      key="$(openssl rand -base64 32)"
      printf '%s' "${key}" > "${keyfile}"; chmod 600 "${keyfile}"
      log "generated a secrets encryption key at ${keyfile}"
    fi
    log "WARNING: the secrets encryption key lives at ${keyfile}, on the same volume as the data it protects; pass CP_ENCRYPTION_KEY from a secret store for a real deployment"
  fi
  key_ok "${key}" || fail "CP_ENCRYPTION_KEY must be exactly the base64 of 32 random bytes (openssl rand -base64 32)"
  [ -z "${prev}" ] || key_ok "${prev}" || fail "CP_ENCRYPTION_KEY_PREVIOUS must be exactly the base64 of 32 random bytes"
  [ "${prev}" != "${key}" ] || prev=""   # same key twice is not a rotation

  ENCRYPTION_FP="$(key_fp "${key}")"
  local prev_fp=""; [ -z "${prev}" ] || prev_fp="$(key_fp "${prev}")"
  local stored; stored="$(stamp_read "${ENCRYPTION_STAMP}")"
  if [ -z "${stored}" ]; then
    ENCRYPTION_REWRAP=true   # first boot with encryption: rewrite any plaintext Secrets
  elif [ "${stored}" != "${ENCRYPTION_FP}" ]; then
    if [ -n "${prev}" ] && [ "${prev_fp}" = "${stored}" ]; then
      log "rotating the secrets encryption key (${stored} -> ${ENCRYPTION_FP}); Secrets are re-encrypted once the API server is up"
      ENCRYPTION_REWRAP=true
    else
      fail "Secrets in etcd were encrypted with key ${stored}, but CP_ENCRYPTION_KEY has fingerprint ${ENCRYPTION_FP}. Restore the right key, or pass the old one as CP_ENCRYPTION_KEY_PREVIOUS to rotate"
    fi
  fi

  {
    printf 'apiVersion: apiserver.config.k8s.io/v1\nkind: EncryptionConfiguration\nresources:\n  - resources: [secrets]\n    providers:\n      - secretbox:\n          keys:\n'
    printf '            - name: key-%s\n              secret: %s\n' "${ENCRYPTION_FP}" "${key}"
    [ -z "${prev}" ] || printf '            - name: key-%s\n              secret: %s\n' "${prev_fp}" "${prev}"
    printf '      - identity: {}\n'
  } > "${ENCRYPTION_CONFIG}"
  chmod 600 "${ENCRYPTION_CONFIG}"
  log "secrets encryption at rest: secretbox, key ${ENCRYPTION_FP}${prev_fp:+ (+ previous ${prev_fp} for reading)}"
}

# After the API server is ready: rewrite every Secret so it is stored under the
# current key (covers first enablement and rotation), then move the stamp.
finish_encryption() {
  [ "${ENCRYPTION_REWRAP}" = "true" ] || return 0
  # A failed list must fail the boot (a wrong key on unstamped data shows up
  # here as decryption errors); an empty list is a valid result.
  local names; names="$(kc get secrets -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}')" \
    || fail "could not list Secrets to re-encrypt them; not moving the encryption stamp"
  local n=0 failed=0 ns name attempt
  for ref in ${names}; do
    ns="${ref%%/*}"; name="${ref#*/}"; n=$((n+1))
    for attempt in 1 2 3; do
      # get-then-replace per object: a 409 means something rewrote it after our
      # read, and every new write is already under the current key.
      if kc -n "${ns}" get secret "${name}" -o json 2>/dev/null | kc replace -f - >/dev/null 2>&1; then break; fi
      kc -n "${ns}" get secret "${name}" >/dev/null 2>&1 || break   # deleted meanwhile: fine
      [ "${attempt}" -lt 3 ] && sleep 1 || { failed=$((failed+1)); log "WARNING: could not re-encrypt ${ref} after 3 attempts"; }
    done
  done
  [ "${failed}" -eq 0 ] || fail "${failed} of ${n} Secret(s) could not be re-encrypted under key ${ENCRYPTION_FP}; the stamp stays at the previous key, keep CP_ENCRYPTION_KEY_PREVIOUS set and retry"
  [ "${n}" -eq 0 ] || log "re-encrypted ${n} Secret(s) under key ${ENCRYPTION_FP}"
  stamp_write "${ENCRYPTION_STAMP}" "${ENCRYPTION_FP}"
}

AUDIT_POLICY="${CP_RUN_DIR}/audit-policy.yaml"
write_audit_policy() {
  cat > "${AUDIT_POLICY}" <<'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages: ["RequestReceived"]
rules:
  # Health, discovery and metrics: never.
  - level: None
    nonResourceURLs: ["/healthz*", "/readyz*", "/livez*", "/metrics", "/version", "/openapi*", "/api", "/api/*", "/apis", "/apis/*"]
  # The in-container controllers read Secrets on every reconcile; that is
  # machine noise, not evidence. Humans and everything else: logged below.
  - level: None
    users: ["control-plane-internal", "system:kube-controller-manager"]
    verbs: ["get", "list", "watch"]
    resources:
      - group: ""
        resources: ["secrets"]
  # Any other access to Secrets: who, what, when (never the body).
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets"]
  # Reads of everything else: the controllers watch constantly; not logged.
  - level: None
    verbs: ["get", "list", "watch"]
  # Every write: Metadata.
  - level: Metadata
EOF
  chmod 600 "${AUDIT_POLICY}"
}

apiserver_audit_flags() {
  [ "${CP_AUDIT_ENABLED}" = "true" ] || return 0
  printf -- '--audit-policy-file=%s\n--audit-log-path=%s\n--audit-log-format=json\n' "${AUDIT_POLICY}" "${CP_AUDIT_LOG_PATH}"
  [ "${CP_AUDIT_LOG_PATH}" = "-" ] || printf -- '--audit-log-maxsize=%s\n--audit-log-maxbackup=%s\n--audit-log-maxage=%s\n' \
    "${CP_AUDIT_LOG_MAXSIZE_MB}" "${CP_AUDIT_LOG_MAXBACKUP}" "${CP_AUDIT_LOG_MAXAGE_DAYS}"
}

apiserver_token_flags() {
  [ "${CP_ADMIN_TOKEN_ENABLED}" = "true" ] || return 0
  printf -- '--token-auth-file=%s\n' "${CP_PKI_DIR}/tokens.csv"
}

# ------------------------------------------------------------------------------
# Step 2: kube-apiserver
#
# Nodeless notes:
#   * --anonymous-auth=false, RBAC + Node authorizers, client-cert and (optional)
#     static token authn. Nothing is reachable unauthenticated.
#   * ServiceAccount admission needs the SA key pair even though nothing here
#     mounts a token into a Pod.
#   * No --enable-aggregator-routing: there is no kube-proxy to route to.
# ------------------------------------------------------------------------------
start_apiserver() {
  # The policy is written here, in the parent shell, so a failure is fatal
  # instead of silently starting the API server without audit.
  if [ "${CP_AUDIT_ENABLED}" = "true" ]; then
    write_audit_policy
    [ -s "${AUDIT_POLICY}" ] || fail "audit policy ${AUDIT_POLICY} was not written"
  fi
  local extra=()
  mapfile -t extra < <(apiserver_audit_flags; apiserver_token_flags)
  start_bg kube-apiserver "${CP_BIN_DIR}/kube-apiserver" \
    --etcd-servers "http://127.0.0.1:${CP_ETCD_CLIENT_PORT}" \
    --bind-address "${CP_APISERVER_BIND_ADDRESS}" \
    --secure-port "${CP_APISERVER_PORT}" \
    --advertise-address "${CP_APISERVER_ADVERTISE_ADDRESS}" \
    --tls-cert-file "${CP_PKI_DIR}/apiserver.crt" \
    --tls-private-key-file "${CP_PKI_DIR}/apiserver.key" \
    --client-ca-file "${CP_PKI_DIR}/ca.crt" \
    --encryption-provider-config "${ENCRYPTION_CONFIG}" \
    --tls-min-version "${CP_TLS_MIN_VERSION}" \
    --service-account-key-file "${CP_PKI_DIR}/sa.pub" \
    --service-account-signing-key-file "${CP_PKI_DIR}/sa.key" \
    --service-account-issuer "https://kubernetes.default.svc.cluster.local" \
    --api-audiences "https://kubernetes.default.svc.cluster.local" \
    --service-cluster-ip-range "${CP_SERVICE_CLUSTER_IP_RANGE}" \
    --requestheader-client-ca-file "${CP_PKI_DIR}/front-proxy-ca.crt" \
    --requestheader-allowed-names front-proxy-client \
    --requestheader-username-headers X-Remote-User \
    --requestheader-group-headers X-Remote-Group \
    --requestheader-extra-headers-prefix X-Remote-Extra- \
    --proxy-client-cert-file "${CP_PKI_DIR}/front-proxy-client.crt" \
    --proxy-client-key-file "${CP_PKI_DIR}/front-proxy-client.key" \
    --authorization-mode Node,RBAC \
    --anonymous-auth=false \
    --allow-privileged=false \
    --profiling=false \
    --enable-priority-and-fairness=true \
    --v=1 \
    "${extra[@]}"

  wait_ready "kube-apiserver /readyz" "${CP_READY_TIMEOUT}" \
    kc get --raw=/readyz
  finish_encryption
}

# ------------------------------------------------------------------------------
# Step 3: kube-controller-manager (garbage collector)
#
# Crossplane deletes composed resources by owner reference, and owner-reference
# cascading deletion is implemented by the garbage collector, which lives in
# kube-controller-manager -- not in the API server. Without it, deleting an XR
# leaves its composed managed resources behind forever. Everything enabled here
# is node-independent; the node/endpoint/deployment controllers stay off.
# ------------------------------------------------------------------------------
start_controller_manager() {
  [ "${CP_ENABLE_CONTROLLER_MANAGER}" = "true" ] || { log "kube-controller-manager disabled"; return 0; }

  write_kubeconfig "${CP_RUN_DIR}/controller-manager.kubeconfig" \
    "https://127.0.0.1:${CP_APISERVER_PORT}" controller-manager

  start_bg kube-controller-manager "${CP_BIN_DIR}/kube-controller-manager" \
    --kubeconfig "${CP_RUN_DIR}/controller-manager.kubeconfig" \
    --authentication-kubeconfig "${CP_RUN_DIR}/controller-manager.kubeconfig" \
    --authorization-kubeconfig "${CP_RUN_DIR}/controller-manager.kubeconfig" \
    --controllers "${CP_CONTROLLERS}" \
    --leader-elect=false \
    --use-service-account-credentials=false \
    --root-ca-file "${CP_PKI_DIR}/ca.crt" \
    --service-account-private-key-file "${CP_PKI_DIR}/sa.key" \
    --bind-address 127.0.0.1 \
    --secure-port "${CP_KCM_PORT}" \
    --profiling=false \
    --v=1

  # Probe the controller manager itself, not the API server. /healthz is in
  # kube-controller-manager's default --authorization-always-allow-paths, so no
  # credential is needed; -k because it serves a self-signed cert.
  wait_ready "kube-controller-manager /healthz" "${CP_READY_TIMEOUT}" \
    curl -fsSk "https://127.0.0.1:${CP_KCM_PORT}/healthz"
}

# ------------------------------------------------------------------------------
# Step 4: CRDs
#
# `crossplane core init` installs Crossplane's own CRDs, creates the Lock
# object, the default DeploymentRuntimeConfig and ManagedResourceActivationPolicy
# and -- crucially for step 5 -- the TLS CA/client Secrets that
# `crossplane core start` refuses to boot without.
#
# It cannot, however, install a CRD and then immediately create an instance of
# it: its REST mapper caches discovery, so on a brand new API server `core init`
# fails with `no matches for kind "Lock" in version "pkg.crossplane.io/v1beta1"`
# the moment after it applied that very CRD. So we apply the CRDs with kubectl
# and wait for them to be Established *first*; `core init` then re-applies
# no-ops and gets on with the rest.
# ------------------------------------------------------------------------------
crd_established() {
  kc get crd "$1" -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null \
    | grep -q True
}

apply_crd_dir() {
  local d="$1"
  # Every configured CRD dir is required: silently skipping one just moves
  # the failure to a 120s "not Established" timeout with no explanation.
  [ -d "$d" ] || fail "CRD dir $d does not exist (CP_CROSSPLANE_CRDS_DIR / CP_CRD_DIRS)"
  log "applying CRDs from $d"
  # Server-side apply: several of these CRDs are far too large for the
  # last-applied-configuration annotation that client-side apply writes.
  kc apply --server-side --force-conflicts -f "$d" >/dev/null
}

apply_crds() {
  kc create namespace "${CP_CROSSPLANE_NAMESPACE}" \
    --dry-run=client -o yaml | kc apply -f - >/dev/null

  apply_crd_dir "${CP_CROSSPLANE_CRDS_DIR}"
  wait_ready "crossplane core CRDs established" 120 \
    bash -c "$(declare -f kc crd_established); \
             CP_BIN_DIR='${CP_BIN_DIR}' KUBECONFIG_INTERNAL='${KUBECONFIG_INTERNAL}'; \
             crd_established locks.pkg.crossplane.io \
             && crd_established compositions.apiextensions.crossplane.io \
             && crd_established deploymentruntimeconfigs.pkg.crossplane.io"

  local d dirs
  IFS=':' read -ra dirs <<< "${CP_CRD_DIRS}"
  for d in "${dirs[@]}"; do apply_crd_dir "$d"; done

  wait_ready "railway CRDs established" 120 \
    bash -c "$(declare -f kc crd_established); \
             CP_BIN_DIR='${CP_BIN_DIR}' KUBECONFIG_INTERNAL='${KUBECONFIG_INTERNAL}'; \
             crd_established projects.railway.crossplane.io \
             && crd_established providerconfigs.railway.crossplane.io"

  local init_args=(
    core init
    --namespace "${CP_CROSSPLANE_NAMESPACE}"
    --cr-ds-path "${CP_CROSSPLANE_CRDS_DIR}"
    --tlsca-secret-name crossplane-root-ca
    --tls-client-secret-name crossplane-tls-client
  )
  if [ "${CP_ENABLE_WEBHOOKS}" = "true" ]; then
    init_args+=(
      --webhook-enabled=true
      --tls-server-secret-name crossplane-tls-server
      --webhook-service-name crossplane-webhooks
      --webhook-service-namespace "${CP_CROSSPLANE_NAMESPACE}"
      --webhook-service-port "${CP_CROSSPLANE_WEBHOOK_PORT}"
      --webhook-configurations-path "${CP_WEBHOOK_CONFIGS_DIR}"
    )
  else
    init_args+=(--webhook-enabled=false)
  fi

  log "running crossplane core init"
  local attempt
  for attempt in 1 2 3 4 5; do
    if KUBECONFIG="${KUBECONFIG_INTERNAL}" \
       POD_NAMESPACE="${CP_CROSSPLANE_NAMESPACE}" \
       XPKG_CACHE_DIR="${CP_HOME}/cache/xpkg" \
       "${CP_BIN_DIR}/crossplane" "${init_args[@]}" \
       >>"${CP_LOG_DIR}/crossplane-init.log" 2>&1; then
      log "READY: crossplane core init"
      break
    fi
    [ "${attempt}" -lt 5 ] || { tail -n 40 "${CP_LOG_DIR}/crossplane-init.log" >&2
                                fail "crossplane core init failed after 5 attempts"; }
    log "crossplane core init attempt ${attempt} failed; retrying"
    sleep 5
  done

  log "CRDs installed: $(kc get crd -o name | wc -l) total, $(kc get crd -o name | grep -c railway) railway"
}

# ------------------------------------------------------------------------------
# Step 5: crossplane core
#
# `crossplane core start` unconditionally loads an mTLS client certificate --
# it is the identity it presents to composition Functions over gRPC -- and
# fails to start if the files are missing. `core init` puts them in a Secret;
# out of cluster there is no projected volume, so unpack the Secret to disk.
#
# --package-runtime=External stops the package manager from ever creating a
# Deployment for a Provider or Function package: nothing could schedule it.
# ------------------------------------------------------------------------------
unpack_tls_secret() {
  local secret="$1" dir="$2"
  mkdir -p "${dir}"
  local k
  for k in tls.crt tls.key ca.crt; do
    # go-template rather than jsonpath: the keys contain dots, and quoting the
    # jsonpath escape through two layers of shell is a reliable way to get
    # silently-empty output.
    kc -n "${CP_CROSSPLANE_NAMESPACE}" get secret "${secret}" \
      -o "go-template={{index .data \"${k}\"}}" | base64 -d > "${dir}/${k}"
    [ -s "${dir}/${k}" ] || fail "secret ${secret} has no ${k}"
  done
  chmod 600 "${dir}"/*
}

start_crossplane() {
  wait_ready "crossplane TLS client secret" 60 \
    kc -n "${CP_CROSSPLANE_NAMESPACE}" get secret crossplane-tls-client
  unpack_tls_secret crossplane-tls-client "${CP_RUN_DIR}/tls/client"

  local args=(
    core start
    --namespace "${CP_CROSSPLANE_NAMESPACE}"
    --tls-client-certs-dir "${CP_RUN_DIR}/tls/client"
    --package-runtime External
    --leader-election=false
    --metrics-port "${CP_CROSSPLANE_METRICS_PORT}"
    --health-probe-port "${CP_CROSSPLANE_HEALTH_PORT}"
  )
  if [ "${CP_ENABLE_WEBHOOKS}" = "true" ]; then
    unpack_tls_secret crossplane-tls-server "${CP_RUN_DIR}/tls/server"
    args+=(
      --webhook-enabled=true
      --tls-server-certs-dir "${CP_RUN_DIR}/tls/server"
      --webhook-port "${CP_CROSSPLANE_WEBHOOK_PORT}"
    )
  else
    args+=(--webhook-enabled=false)
  fi

  start_bg crossplane env \
    KUBECONFIG="${KUBECONFIG_INTERNAL}" \
    POD_NAMESPACE="${CP_CROSSPLANE_NAMESPACE}" \
    XPKG_CACHE_DIR="${CP_HOME}/cache/xpkg" \
    XFN_CACHE_DIR="${CP_HOME}/cache/xfn" \
    "${CP_BIN_DIR}/crossplane" "${args[@]}"

  wait_ready "crossplane core /readyz" "${CP_READY_TIMEOUT}" \
    curl -fsS "http://127.0.0.1:${CP_CROSSPLANE_HEALTH_PORT}/readyz"
}

# ------------------------------------------------------------------------------
# Step 6: credentials + provider
#
# $RAILWAY_TOKEN must be a Railway *workspace or account* token. Project tokens
# fail with "Not Authorized" because the Terraform provider only ever sends an
# `Authorization: Bearer` header.
# ------------------------------------------------------------------------------
write_railway_credentials() {
  if [ -z "${RAILWAY_TOKEN:-}" ]; then
    log "WARNING: RAILWAY_TOKEN is unset -- skipping Secret/ProviderConfig."
    log "         The provider will start but every reconcile will fail until"
    log "         a ProviderConfig with valid credentials exists."
    return 0
  fi
  log "writing railway-creds Secret and ProviderConfig/default"
  kc -n "${CP_CROSSPLANE_NAMESPACE}" create secret generic railway-creds \
    --from-literal=credentials="{\"token\":\"${RAILWAY_TOKEN}\"}" \
    --dry-run=client -o yaml | kc apply -f - >/dev/null
  kc apply -f - >/dev/null <<EOF
apiVersion: railway.crossplane.io/v1beta1
kind: ProviderConfig
metadata:
  name: default
spec:
  credentials:
    source: Secret
    secretRef:
      namespace: ${CP_CROSSPLANE_NAMESPACE}
      name: railway-creds
      key: credentials
EOF
}

start_provider() {
  mkdir -p "${CP_HOME}/tf" "${CP_HOME}/cache/tf-plugins"
  start_bg provider-upjet-railway env \
    KUBECONFIG="${KUBECONFIG_INTERNAL}" \
    POD_NAMESPACE="${CP_CROSSPLANE_NAMESPACE}" \
    TMPDIR="${CP_HOME}/tf" \
    TF_CLI_CONFIG_FILE="${TF_CLI_CONFIG_FILE:-/terraform/.terraformrc}" \
    TF_PLUGIN_CACHE_DIR="${CP_HOME}/cache/tf-plugins" \
    TERRAFORM_VERSION="${TERRAFORM_VERSION}" \
    TERRAFORM_PROVIDER_SOURCE="${TERRAFORM_PROVIDER_SOURCE}" \
    TERRAFORM_PROVIDER_VERSION="${TERRAFORM_PROVIDER_VERSION}" \
    "${CP_BIN_DIR}/provider" \
      --metrics-bind-address ":${CP_PROVIDER_METRICS_PORT}" \
      --no-leader-election \
      --certs-dir="" \
      ${CP_DEBUG:+--debug} \
      ${CP_PROVIDER_ARGS}

  # The provider exposes no health probe endpoint, so readiness has to come off
  # the metrics server: it only starts serving once mgr.Start() has brought the
  # caches up. (Note the flags: kingpin rejects `--leader-election=false` with
  # "unexpected false" -- the negative form is `--no-leader-election`. And
  # --certs-dir defaults to /tls/server, so it must be blanked explicitly or
  # the provider tries to serve webhooks from a directory that does not exist.)
  wait_ready "provider metrics endpoint" "${CP_READY_TIMEOUT}" \
    curl -fsS "http://127.0.0.1:${CP_PROVIDER_METRICS_PORT}/metrics"

  # Then wait for the per-controller worker gauges to be registered, which is
  # what "the controllers are actually running" looks like from outside.
  # Log-scraping is not an option: without --debug the provider installs a
  # no-op controller-runtime logger and prints nothing at all.
  wait_ready "provider controllers running" 120 bash -c \
    "curl -fsS 'http://127.0.0.1:${CP_PROVIDER_METRICS_PORT}/metrics' \
       | grep -q '^controller_runtime_active_workers.*railway'"

  local n
  n="$(curl -fsS "http://127.0.0.1:${CP_PROVIDER_METRICS_PORT}/metrics" \
       | grep -c '^controller_runtime_active_workers.*railway' || true)"
  log "provider controllers registered: ${n}"
}

# ------------------------------------------------------------------------------
# Boot
# ------------------------------------------------------------------------------
main() {
  drop_privileges_if_root "$@"
  mkdir -p "${CP_HOME}" "${CP_LOG_DIR}" "${CP_RUN_DIR}" "${CP_HOME}/cache"
  # Separate handlers so a platform stop exits 143/130; the EXIT trap then runs
  # shutdown with that status instead of whatever command happened to be running.
  trap 'exit 143' TERM
  trap 'exit 130' INT
  trap shutdown EXIT

  prepare_state_dir
  bootstrap_pki

  local external="${CP_EXTERNAL_URL}"
  if [ -z "${external}" ]; then
    local first_san="${CP_APISERVER_CERT_SANS%%,*}"
    first_san="$(echo "${first_san}" | tr -d '[:space:]')"
    if [ -n "${first_san}" ]; then
      external="https://${first_san}:${CP_APISERVER_PORT}"
    else
      external="https://${CP_APISERVER_ADVERTISE_ADDRESS}:${CP_APISERVER_PORT}"
    fi
  fi

  write_kubeconfig "${KUBECONFIG_INTERNAL}" "https://127.0.0.1:${CP_APISERVER_PORT}" admin-internal
  write_kubeconfig "${KUBECONFIG_EXTERNAL}" "${external}" admin
  if [ "${CP_ADMIN_TOKEN_ENABLED}" = "true" ]; then
    write_kubeconfig_token "${KUBECONFIG_EXTERNAL_TOKEN}" "${external}"
  else
    rm -f "${KUBECONFIG_EXTERNAL_TOKEN}"
  fi
  prepare_encryption

  start_etcd
  start_apiserver
  start_controller_manager
  apply_crds
  start_crossplane
  write_railway_credentials
  start_provider

  log "=============================================================="
  log "control plane UP"
  log "  api server (external): ${external}"
  log "  kubeconfig (external): ${KUBECONFIG_EXTERNAL}      (client cert)"
  if [ "${CP_ADMIN_TOKEN_ENABLED}" = "true" ]; then
    log "  kubeconfig (external): ${KUBECONFIG_EXTERNAL_TOKEN} (bearer token)"
  else
    log "  bearer token:          disabled (CP_ADMIN_TOKEN_ENABLED=false)"
  fi
  log "  client cert validity:  ${CP_CLIENT_CERT_DAYS} days (renewed on restart past the midpoint)"
  # The token is a cluster-admin credential and this log stream is usually the
  # platform's deploy log, so print it only when explicitly asked. It is always
  # in the token kubeconfig above and in ${CP_PKI_DIR}/tokens.csv.
  if [ "${CP_ADMIN_TOKEN_ENABLED}" = "true" ]; then
    if [ "${CP_LOG_ADMIN_TOKEN:-false}" = "true" ]; then
      log "  bearer token:          ${CP_ADMIN_TOKEN}"
    else
      log "  bearer token:          <hidden; set CP_LOG_ADMIN_TOKEN=true to print>"
    fi
  fi
  log "  logs:                  ${CP_LOG_DIR}"
  log "=============================================================="

  # Supervise: if any component dies, take the whole container down so the
  # platform restarts it. Partial control planes are worse than dead ones.
  local i tick=0
  while true; do
    for i in "${!PIDS[@]}"; do
      if ! kill -0 "${PIDS[$i]}" 2>/dev/null; then
        log "component ${NAMES[$i]} (pid ${PIDS[$i]}) exited -- tearing down"
        tail -n 40 "${CP_LOG_DIR}/${NAMES[$i]}.log" >&2 2>/dev/null || true
        exit 1
      fi
    done
    # Hourly: the in-container identities and the serving cert must stay valid
    # for at least 7 more days; if not, exit so the platform restarts us and the
    # boot path reissues them. A silently expiring plane is worse than a restart.
    tick=$((tick+1))
    if [ $((tick % 720)) -eq 0 ]; then
      local c
      for c in admin-internal controller-manager apiserver; do
        cert_fresh "${CP_PKI_DIR}/${c}.crt" $(( 7 * 86400 )) \
          || { log "certificate ${c} expires within 7 days -- restarting to reissue"; exit 1; }
      done
    fi
    sleep 5
  done
}

main "$@"
