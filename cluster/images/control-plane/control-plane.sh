#!/usr/bin/env bash
# ==============================================================================
# Nodeless Crossplane control plane supervisor.
#
# Boots, in order, gating every step on the previous one being READY (not merely
# started):
#
#   1. etcd                    (then a maintenance pass: defrag, snapshot)
#   2. kube-apiserver          (own end-to-end TLS on $CP_APISERVER_PORT)
#   3. kube-controller-manager (optional; garbage collector + namespace only)
#   4. CRDs                    (Crossplane core via `crossplane core init`,
#                               plus this provider's package/crds)
#   5. crossplane core start   (out-of-cluster, package manager set to External)
#   6. composition functions   (one process per CP_FUNCTIONS entry on loopback,
#                               mTLS from Crossplane's root CA, then a paused
#                               Function + FunctionRevision pointing at it)
#   7. provider-upjet-railway  (out-of-cluster, patched Terraform mirror)
#
# There is no kubelet and no scheduler: nothing in this control plane runs Pods.
# Providers and composition functions are supervised processes, not Crossplane
# Packages, precisely because the package manager would create Deployments that
# could never be scheduled.
#
# Secrets are never baked into the image: $RAILWAY_TOKEN arrives as an
# environment variable, is read once and removed from the environment before
# any component starts, and is written into a Secret + ProviderConfig at boot.
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
# Comma-separated extra SANs for the serving cert. On Railway the TCP proxy
# hostname is added automatically (apply_railway_defaults); this is for any
# other name clients will use, e.g. a custom domain in front of the proxy.
CP_APISERVER_CERT_SANS="${CP_APISERVER_CERT_SANS:-}"
# Public URL clients outside the container should use. Defaults to the first
# extra SAN if one was given, otherwise to the advertise address. On Railway
# both this and the SAN default from the service's own TCP proxy
# (RAILWAY_TCP_PROXY_DOMAIN:RAILWAY_TCP_PROXY_PORT); see apply_railway_defaults.
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

# Composition functions, space separated: each is a binary of that name under
# CP_BIN_DIR, started as its own supervised process (step 6) and registered as
# Function/<name> with FunctionRevision/<name>-local, so a Composition's
# pipeline refers to it by this name (functionRef.name). The package manager
# cannot run functions here (no Pods), hence processes, like the provider.
# Set to the empty string to disable functions: nothing is started or
# registered (hence "-" not ":-" below: unset means the default, empty means
# none). A name is a DNS label: it becomes an object name and the certificate CN.
CP_FUNCTIONS="${CP_FUNCTIONS-function-go-templating function-auto-ready}"
# The first listed function listens on 127.0.0.1:CP_FUNCTION_PORT_BASE, the
# next on the port after, in list order (function_port, step 6). Loopback
# only: the caller is Crossplane core in this same container.
CP_FUNCTION_PORT_BASE="${CP_FUNCTION_PORT_BASE:-9450}"
read -ra FUNCTION_NAMES <<< "${CP_FUNCTIONS}"
for _f in ${FUNCTION_NAMES[@]+"${FUNCTION_NAMES[@]}"}; do
  [[ "${_f}" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || { printf '%s [control-plane] FATAL: CP_FUNCTIONS entry "%s" is not a DNS label (lower-case letters, digits and dashes)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${_f}" >&2; exit 1; }
  # The name is also the log file, the supervised-process name and the
  # GOMEMLIMIT component; it must not be one of the five core processes.
  case "${_f}" in etcd|kube-apiserver|kube-controller-manager|crossplane|provider-upjet-railway)
    printf '%s [control-plane] FATAL: CP_FUNCTIONS entry "%s" is the name of a core component; rename the function binary\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${_f}" >&2; exit 1 ;;
  esac
done
unset _f
# Ports are positional, so a duplicate name would be two processes under one
# Function object; the second registration would silently win.
_dup="$(printf '%s\n' ${FUNCTION_NAMES[@]+"${FUNCTION_NAMES[@]}"} | sort | uniq -d | head -1 || true)"
[ -z "${_dup}" ] || { printf '%s [control-plane] FATAL: CP_FUNCTIONS lists "%s" more than once (got "%s")\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${_dup}" "${CP_FUNCTIONS}" >&2; exit 1; }
unset _dup
[[ "${CP_FUNCTION_PORT_BASE}" =~ ^[1-9][0-9]*$ ]] && [ "${CP_FUNCTION_PORT_BASE}" -ge 1024 ] \
  && [ $(( CP_FUNCTION_PORT_BASE + ${#FUNCTION_NAMES[@]} )) -le 65536 ] \
  || { printf '%s [control-plane] FATAL: CP_FUNCTION_PORT_BASE must be a port from 1024 with room for %s function(s) below 65536 (got "%s")\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${#FUNCTION_NAMES[@]}" "${CP_FUNCTION_PORT_BASE}" >&2; exit 1; }
# The function range must not include a port the plane itself listens on: a
# function that lost the race for, say, 8080 would die before readiness and
# fail the boot with a less direct message. Every CP_*_PORT above is defined
# by this point, which is why this block sits below them.
if [ "${#FUNCTION_NAMES[@]}" -gt 0 ]; then
  _lo="${CP_FUNCTION_PORT_BASE}"; _hi=$(( CP_FUNCTION_PORT_BASE + ${#FUNCTION_NAMES[@]} - 1 ))
  for _v in CP_APISERVER_PORT CP_ETCD_CLIENT_PORT CP_ETCD_PEER_PORT CP_KCM_PORT CP_CROSSPLANE_METRICS_PORT CP_CROSSPLANE_HEALTH_PORT CP_CROSSPLANE_WEBHOOK_PORT CP_PROVIDER_METRICS_PORT; do
    [[ "${!_v}" =~ ^[0-9]+$ ]] || continue   # a non-numeric port fails where it is used
    if [ "${!_v}" -ge "${_lo}" ] && [ "${!_v}" -le "${_hi}" ]; then
      printf '%s [control-plane] FATAL: the function port range 127.0.0.1:%s-%s (CP_FUNCTION_PORT_BASE=%s, one port per CP_FUNCTIONS entry) overlaps %s=%s; move CP_FUNCTION_PORT_BASE\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${_lo}" "${_hi}" "${CP_FUNCTION_PORT_BASE}" "${_v}" "${!_v}" >&2; exit 1
    fi
  done
  unset _lo _hi _v
fi

# CRD source directories, colon separated. The image ships both; the native
# proof points these at a checkout.
CP_CRD_DIRS="${CP_CRD_DIRS:-${CP_HOME}/crds/railway}"
CP_CROSSPLANE_CRDS_DIR="${CP_CROSSPLANE_CRDS_DIR:-${CP_HOME}/crds/crossplane}"
CP_WEBHOOK_CONFIGS_DIR="${CP_WEBHOOK_CONFIGS_DIR:-${CP_HOME}/crds/webhookconfigurations}"

# Terraform wiring, mirroring cluster/images/provider-upjet-railway.
TERRAFORM_VERSION="${TERRAFORM_VERSION:-1.5.7}"
TERRAFORM_PROVIDER_SOURCE="${TERRAFORM_PROVIDER_SOURCE:-terraform-community-providers/railway}"
TERRAFORM_PROVIDER_VERSION="${TERRAFORM_PROVIDER_VERSION:-0.6.2}"

# ---- B5: etcd quota, snapshots, memory ---------------------------------------
# Rationale and behaviour: docs/architecture/control-plane.md, "Capacity: etcd
# quota, snapshots and memory". Only what each variable does is noted here.
# etcd backend quota: "auto" (half the state-root filesystem, at most 2 GiB)
# or an integer number of bytes from 100 MiB to 8 GiB that must fit the volume.
CP_ETCD_QUOTA_BYTES="${CP_ETCD_QUOTA_BYTES:-auto}"
# Seconds between maintenance passes (defrag when fragmented, snapshot,
# prune), rounded up to the 5 s tick; 0 disables the periodic pass. SIGUSR1
# runs one now (at most once a minute). An alarm is polled for every 60 s
# regardless and triggers a recovery pass at most every 10 minutes.
CP_ETCD_MAINTENANCE_INTERVAL="${CP_ETCD_MAINTENANCE_INTERVAL:-21600}"
# Snapshots kept under CP_STATE_DIR/snapshots, newest first; 0 takes none.
CP_ETCD_SNAPSHOT_KEEP="${CP_ETCD_SNAPSHOT_KEEP:-2}"
# Container memory limit in bytes from which each Go component's GOMEMLIMIT is
# derived. Empty: read the cgroup (v2 memory.max, then v1); no limit there
# means no GOMEMLIMIT. false in CP_GOMEMLIMIT_ENABLED sets none. The share of
# one component is overridden with CP_GOMEMLIMIT_PCT_<NAME>, e.g.
# CP_GOMEMLIMIT_PCT_KUBE_APISERVER=50 (names upper-cased, dashes to underscores).
CP_MEMORY_LIMIT_BYTES="${CP_MEMORY_LIMIT_BYTES:-}"
CP_GOMEMLIMIT_ENABLED="${CP_GOMEMLIMIT_ENABLED:-true}"

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
  # B5: every component is a Go binary; give each a GOMEMLIMIT that is its
  # share of the container limit (gomemlimit_share), so the garbage collectors
  # back off before the kernel's OOM killer picks a victim.
  local -a prefix=()
  if [ "${CP_GOMEMLIMIT_ENABLED}" = "true" ] && [ -n "${MEMORY_LIMIT_BYTES}" ]; then
    local share; share="$(gomemlimit_share "${name}")"
    [ "${share}" -eq 0 ] || prefix=(env "GOMEMLIMIT=$(( MEMORY_LIMIT_BYTES * share / 100 / 1048576 ))MiB")
  fi
  if command -v setsid >/dev/null 2>&1; then
    setsid ${prefix[@]+"${prefix[@]}"} "$@" >>"${CP_LOG_DIR}/${name}.log" 2>&1 &
  else
    ${prefix[@]+"${prefix[@]}"} "$@" >>"${CP_LOG_DIR}/${name}.log" 2>&1 &
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
# The budget is per component, so the worst case is COMPONENT_COUNT x
# CP_SHUTDOWN_TIMEOUT: the five core processes plus one per composition
# function in CP_FUNCTIONS (7 x 10 s = 70 s with the default two). Keep the
# platform's drain window (Railway: RAILWAY_DEPLOYMENT_DRAINING_SECONDS) above
# that; apply_railway_defaults warns when it is not. A clean stop of the five
# core processes took 7 s in testing; a function stops at once.
CP_SHUTDOWN_TIMEOUT="${CP_SHUTDOWN_TIMEOUT:-10}"
[[ "${CP_SHUTDOWN_TIMEOUT}" =~ ^[0-9]+$ ]] || CP_SHUTDOWN_TIMEOUT=10
COMPONENT_COUNT=$(( 5 + ${#FUNCTION_NAMES[@]} ))
shutdown() {
  local rc=$?
  trap - EXIT TERM INT
  log "shutting down"
  local i pid t
  # A maintenance pass in flight (background subshell plus its etcdctl) goes
  # first; etcd is about to stop under it anyway.
  if [ -n "${MAINT_PID:-}" ] && kill -0 "${MAINT_PID}" 2>/dev/null; then
    pkill -TERM -P "${MAINT_PID}" 2>/dev/null || true
    kill -TERM "${MAINT_PID}" 2>/dev/null || true
  fi
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
# Step -1a: Railway platform defaults (before the state root is checked)
#
# What the platform tells the service about itself. The TCP proxy in
# front of the API server is known through RAILWAY_TCP_PROXY_DOMAIN and
# RAILWAY_TCP_PROXY_PORT: the proxy hostname is a platform fact, so it always
# joins the serving certificate's SANs, and unless CP_EXTERNAL_URL is set the
# exported kubeconfig points at domain:port. A template deploy then needs no
# networking variables at all. The rest are checks against the mistakes a
# deploy can make: the volume somewhere other than the state root (reported
# here with the fix, before prepare_state_dir fails on it), and a drain window
# shorter than the shutdown. Railway-specific on purpose and kept small.
# ------------------------------------------------------------------------------
apply_railway_defaults() {
  [ -n "${RAILWAY_SERVICE_ID:-}" ] || return 0     # not on Railway
  local dom="${RAILWAY_TCP_PROXY_DOMAIN:-}" port="${RAILWAY_TCP_PROXY_PORT:-}"
  # The hostname goes into the certificate's SAN list and the kubeconfig; a
  # value that is not a plain hostname is refused rather than interpolated.
  if [ -n "${dom}" ] && ! [[ "${dom}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]]; then
    fail "RAILWAY_TCP_PROXY_DOMAIN is not a hostname: '${dom}'"
  fi
  if [ -n "${dom}" ]; then
    if ! printf ',%s,' "${CP_APISERVER_CERT_SANS//[[:space:]]/}" | grep -qF ",${dom},"; then
      CP_APISERVER_CERT_SANS="${CP_APISERVER_CERT_SANS:+${CP_APISERVER_CERT_SANS},}${dom}"
      log "Railway TCP proxy ${dom} added to the serving certificate SANs"
    fi
    if [ -n "${CP_EXTERNAL_URL}" ]; then
      :   # an explicit URL wins
    elif [[ "${port}" =~ ^[0-9]+$ ]] && [ "${port}" -ge 1 ] && [ "${port}" -le 65535 ]; then
      CP_EXTERNAL_URL="https://${dom}:${port}"
      log "external URL defaults to ${CP_EXTERNAL_URL} (Railway TCP proxy)"
    else
      log "WARNING: RAILWAY_TCP_PROXY_PORT is '${port}', not a port; the exported kubeconfig will carry the API server's own port, which is wrong behind the proxy. Set CP_EXTERNAL_URL"
    fi
  else
    log "WARNING: this Railway service has no TCP proxy (RAILWAY_TCP_PROXY_DOMAIN unset); the API server is unreachable from outside until one exists on port ${CP_APISERVER_PORT}, and the serving certificate is reissued with its hostname on the boot after that"
  fi
  # The state root must be on the volume: equal to the mount path or under it.
  local mp="${RAILWAY_VOLUME_MOUNT_PATH:-}"
  if [ -n "${mp}" ]; then
    case "${CP_STATE_DIR%/}/" in
      "${mp%/}/"*) ;;
      *) log "WARNING: the Railway volume is mounted at ${mp} but CP_STATE_DIR is ${CP_STATE_DIR}; mount the volume at ${CP_STATE_DIR} (or set CP_STATE_DIR=${mp}). The persistence check below will fail" ;;
    esac
  fi
  local drain="${RAILWAY_DEPLOYMENT_DRAINING_SECONDS:-0}" need=$(( CP_SHUTDOWN_TIMEOUT * COMPONENT_COUNT ))
  [[ "${drain}" =~ ^[0-9]+$ ]] || drain=0
  [ "${drain}" -ge "${need}" ] \
    || log "WARNING: RAILWAY_DEPLOYMENT_DRAINING_SECONDS is ${drain} (Railway's default is 0); ${need} is recommended so a redeploy lets every component stop before SIGKILL (a clean stop takes about 10 s, the worst case ${COMPONENT_COUNT} components x CP_SHUTDOWN_TIMEOUT ${CP_SHUTDOWN_TIMEOUT} s)"
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
  ensure_ca ca control-plane-ca

  # ---- front-proxy CA -------------------------------------------------------
  # Without --requestheader-client-ca-file the API server publishes an
  # incomplete `extension-apiserver-authentication` ConfigMap, and every
  # component that uses delegated authentication (kube-controller-manager here)
  # spams "missing content for CA bundle" forever. A CA of its own rather than
  # the cluster CA: anything signed by the requestheader CA can impersonate any
  # user through the aggregation layer, so it must not be the same trust root
  # that ordinary client certificates come from.
  ensure_ca front-proxy-ca front-proxy-ca
  if ! keypair_ok "${CP_PKI_DIR}/front-proxy-client.crt" "${CP_PKI_DIR}/front-proxy-client.key"; then
    log "issuing front-proxy client certificate"
    sign_cert front-proxy-client front-proxy-ca "/CN=front-proxy-client" clientAuth "" 3650
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
     ! cert_within_policy "${CP_PKI_DIR}/apiserver.crt" "${CP_SERVING_CERT_DAYS}" $(( 30 * 86400 )) || \
     ! keypair_ok "${CP_PKI_DIR}/apiserver.crt" "${CP_PKI_DIR}/apiserver.key"; then
    log "issuing apiserver serving certificate (${CP_SERVING_CERT_DAYS} days) for ${sans}"
    sign_cert apiserver ca "/CN=kube-apiserver" serverAuth "${sans}" "${CP_SERVING_CERT_DAYS}"
    printf '%s' "${sans}" > "${CP_PKI_DIR}/apiserver.sans"
  fi

  # ---- etcd PKI -------------------------------------------------------------
  # etcd requires a client certificate on both loopback listeners (the B3
  # leftover). A CA of its own: the cluster CA signs Kubernetes identities, and
  # none of those may also open etcd. The server certificate covers loopback
  # only, serves the client and the peer port (hence both EKUs) and follows the
  # serving-cert policy; the two client identities (the API server, the
  # supervisor's etcdctl) are minted every boot like the other in-container
  # identities. Rotation: remove etcd-ca.crt and etcd-ca.key and reboot;
  # everything below is reissued and the data stays readable.
  ensure_ca etcd-ca etcd-ca
  if ! cert_within_policy "${CP_PKI_DIR}/etcd-server.crt" "${CP_SERVING_CERT_DAYS}" $(( 30 * 86400 )) \
     || ! keypair_ok "${CP_PKI_DIR}/etcd-server.crt" "${CP_PKI_DIR}/etcd-server.key" \
     || ! openssl verify -CAfile "${CP_PKI_DIR}/etcd-ca.crt" "${CP_PKI_DIR}/etcd-server.crt" >/dev/null 2>&1; then
    issue_etcd_cert etcd-server etcd-server "serverAuth,clientAuth" "DNS:localhost,IP:127.0.0.1,IP:::1" "${CP_SERVING_CERT_DAYS}"
  fi
  issue_etcd_cert etcd-client-apiserver  kube-apiserver           clientAuth "" "${CP_INTERNAL_CERT_DAYS}"
  issue_etcd_cert etcd-client-supervisor control-plane-supervisor clientAuth "" "${CP_INTERNAL_CERT_DAYS}"

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

# ensure_ca PREFIX CN: a self-signed CA at PREFIX.key/.crt, generated when
# either file is missing (a crash between the two writes must not leave a
# key without its certificate). Both files land atomically; the key is 0600.
ensure_ca() {
  local prefix="${CP_PKI_DIR}/$1" cn="$2"
  [ -f "${prefix}.key" ] && [ -f "${prefix}.crt" ] && return 0
  log "generating ${cn}"
  openssl genrsa -out "${prefix}.key.tmp" 4096 2>/dev/null
  chmod 600 "${prefix}.key.tmp"
  openssl req -x509 -new -nodes -key "${prefix}.key.tmp" -sha256 -days 3650 \
    -subj "/CN=${cn}" -out "${prefix}.crt.tmp" 2>/dev/null
  mv -f "${prefix}.key.tmp" "${prefix}.key"
  mv -f "${prefix}.crt.tmp" "${prefix}.crt"
}

# keypair_ok CRT KEY: both exist and the certificate carries the key's public key.
keypair_ok() {
  [ -f "$1" ] && [ -f "$2" ] \
    && [ "$(openssl x509 -noout -pubkey -in "$1" 2>/dev/null)" = "$(openssl pkey -pubout -in "$2" 2>/dev/null)" ]
}

# sign_cert NAME CA SUBJ EKU SANS DAYS: a key and certificate at NAME.key/.crt
# signed by CA. Both are prefixes under the PKI dir, or absolute prefixes when
# they start with "/" (the composition functions' serving certificates live
# under the ephemeral run dir and are signed by Crossplane's root CA unpacked
# there, not by anything in the PKI dir). Written to temp names and moved into
# place, so a crash leaves either the old pair or the new one.
sign_cert() {
  local name="$1" ca="$2" subj="$3" eku="$4" sans="$5" days="$6"
  [[ "${name}" = /* ]] || name="${CP_PKI_DIR}/${name}"
  [[ "${ca}" = /* ]]   || ca="${CP_PKI_DIR}/${ca}"
  openssl genrsa -out "${name}.key.tmp" 2048 2>/dev/null
  chmod 600 "${name}.key.tmp"
  openssl req -new -key "${name}.key.tmp" -subj "${subj}" -out "${name}.csr" 2>/dev/null
  openssl x509 -req -in "${name}.csr" -CA "${ca}.crt" -CAkey "${ca}.key" -CAcreateserial \
    -out "${name}.crt.tmp" -days "${days}" -sha256 \
    -extfile <(printf 'extendedKeyUsage=%s\n' "${eku}"; [ -z "${sans}" ] || printf 'subjectAltName=%s\n' "${sans}") 2>/dev/null
  rm -f "${name}.csr"
  mv -f "${name}.key.tmp" "${name}.key"
  mv -f "${name}.crt.tmp" "${name}.crt"
}

# issue_etcd_cert NAME CN EKU SANS DAYS: a certificate from the etcd CA.
issue_etcd_cert() {
  log "issuing etcd certificate $1 (CN=$2, $5 days)"
  sign_cert "$1" etcd-ca "/CN=$2" "$3" "$4" "$5"
}

# issue_client_cert NAME CN ORG DAYS [always]: a Kubernetes client identity
# from the cluster CA; reissued when outside policy, or every boot with "always".
issue_client_cert() {
  local name="$1" cn="$2" org="$3" days="$4" mode="${5:-policy}"
  if [ "${mode}" != "always" ]; then
    cert_within_policy "${CP_PKI_DIR}/${name}.crt" "${days}" \
      && keypair_ok "${CP_PKI_DIR}/${name}.crt" "${CP_PKI_DIR}/${name}.key" && return 0
  fi
  log "issuing client certificate ${name} (CN=${cn}, O=${org}, ${days} days)"
  sign_cert "${name}" ca "/O=${org}/CN=${cn}" clientAuth "" "${days}"
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
# Step 1a: capacity (B5)
#
# etcd's quota must fit the volume; the database is defragmented when it is
# fragmented and snapshotted to the volume by a maintenance pass; a NOSPACE
# alarm is polled for and recovered from; every Go process gets a GOMEMLIMIT.
# After boot the pass runs in the background from the supervise loop, so a
# slow or hung etcd never blocks signal handling or death detection. See
# docs/architecture/control-plane.md, "Capacity: etcd quota, snapshots and
# memory".
# ------------------------------------------------------------------------------
# fs_bytes DIR -> "<total> <available>" bytes of the filesystem holding DIR.
fs_bytes() { df -Pk "$1" | awk 'NR==2{print $2*1024, $4*1024}'; }
mib() { printf '%s' "$(( $1 / 1048576 ))"; }

ETCD_QUOTA_MIN=104857600     # 100 MiB
ETCD_QUOTA_MAX=8589934592    # 8 GiB, etcd's own ceiling
check_capacity() {
  [[ "${CP_ETCD_MAINTENANCE_INTERVAL}" =~ ^[0-9]+$ ]] && [[ "${CP_ETCD_SNAPSHOT_KEEP}" =~ ^[0-9]+$ ]] \
    || fail "CP_ETCD_MAINTENANCE_INTERVAL and CP_ETCD_SNAPSHOT_KEEP must be integers (got '${CP_ETCD_MAINTENANCE_INTERVAL}' / '${CP_ETCD_SNAPSHOT_KEEP}')"
  local total avail how=""
  read -r total avail < <(fs_bytes "${CP_STATE_DIR}") && [[ "${total}" =~ ^[0-9]+$ ]] \
    || fail "cannot read the size of the filesystem under ${CP_STATE_DIR} (df)"
  # Disk-full under etcd is how databases get corrupted; the quota exists so
  # etcd refuses writes first. The other half of the volume is for the WAL, a
  # defrag copy and the snapshots.
  if [ "${CP_ETCD_QUOTA_BYTES}" = "auto" ]; then
    CP_ETCD_QUOTA_BYTES=$(( total / 2 / 1048576 * 1048576 ))
    [ "${CP_ETCD_QUOTA_BYTES}" -le 2147483648 ] || CP_ETCD_QUOTA_BYTES=2147483648
    [ "${CP_ETCD_QUOTA_BYTES}" -ge "${ETCD_QUOTA_MIN}" ] \
      || fail "the filesystem under ${CP_STATE_DIR} is $(mib "${total}") MiB; half of it is under the 100 MiB minimum etcd quota. Use a larger volume"
    how=" (auto)"
  else
    [[ "${CP_ETCD_QUOTA_BYTES}" =~ ^[0-9]+$ ]] \
      && [ "${CP_ETCD_QUOTA_BYTES}" -ge "${ETCD_QUOTA_MIN}" ] && [ "${CP_ETCD_QUOTA_BYTES}" -le "${ETCD_QUOTA_MAX}" ] \
      || fail "CP_ETCD_QUOTA_BYTES must be 'auto' or an integer between ${ETCD_QUOTA_MIN} (100 MiB) and ${ETCD_QUOTA_MAX} (8 GiB), got '${CP_ETCD_QUOTA_BYTES}'"
    [ "${total}" -ge "${CP_ETCD_QUOTA_BYTES}" ] \
      || fail "the filesystem under ${CP_STATE_DIR} is $(mib "${total}") MiB, smaller than CP_ETCD_QUOTA_BYTES ($(mib "${CP_ETCD_QUOTA_BYTES}") MiB): etcd would hit disk-full before its quota. Lower the quota, set it to auto, or use a larger volume"
    [ "${total}" -ge $(( CP_ETCD_QUOTA_BYTES * 2 )) ] \
      || log "WARNING: the filesystem under ${CP_STATE_DIR} ($(mib "${total}") MiB) is under twice the quota; a defrag copy and snapshots of a database at the quota would not fit"
  fi
  [ "${avail}" -ge "${CP_ETCD_QUOTA_BYTES}" ] \
    || log "WARNING: only $(mib "${avail}") MiB free under ${CP_STATE_DIR}; etcd cannot grow to its quota ($(mib "${CP_ETCD_QUOTA_BYTES}") MiB) without filling the volume"
  log "etcd quota $(mib "${CP_ETCD_QUOTA_BYTES}") MiB${how} on a $(mib "${total}") MiB filesystem ($(mib "${avail}") MiB free); maintenance every ${CP_ETCD_MAINTENANCE_INTERVAL}s keeping ${CP_ETCD_SNAPSHOT_KEEP} snapshot(s)"
}

# Share of the container memory limit each component gets as GOMEMLIMIT, in
# percent: 85 for the five core processes plus 3 per composition function (91
# with the default two; five functions reach exactly 100 and a sixth fails the
# total check in detect_memory_limit), the rest for bash, the page cache and
# the terraform processes (which inherit the provider's value). A function
# renders templates for one request at a time and idles at about 30 MiB RSS,
# hence the small share. Membership in CP_FUNCTIONS, not a name prefix,
# decides what a function is: a function called anything gets its 3%. GOMEMLIMIT
# is a soft limit: it makes a Go runtime collect harder as it approaches, not
# die. Prints the variable name and returns 1 on a malformed
# CP_GOMEMLIMIT_PCT_<NAME> override.
GOMEMLIMIT_COMPONENTS="kube-apiserver etcd provider-upjet-railway kube-controller-manager crossplane${FUNCTION_NAMES[*]+ ${FUNCTION_NAMES[*]}}"
GOMEMLIMIT_FUNCTION_MIN_BYTES=67108864   # 64 MiB: below it a function's GC never rests
gomemlimit_share() {
  local pct var ov f
  case "$1" in
    kube-apiserver)          pct=35 ;;
    etcd)                    pct=15 ;;
    provider-upjet-railway)  pct=15 ;;
    kube-controller-manager) pct=10 ;;
    crossplane)              pct=10 ;;
    *)
      pct=0
      for f in ${FUNCTION_NAMES[@]+"${FUNCTION_NAMES[@]}"}; do
        [ "${f}" != "$1" ] || pct=3
      done ;;
  esac
  var="CP_GOMEMLIMIT_PCT_$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')"
  ov="${!var:-}"
  if [ -n "${ov}" ]; then
    [[ "${ov}" =~ ^[0-9]+$ ]] && [ "${ov}" -le 100 ] || { printf '%s' "${var}"; return 1; }
    pct="${ov}"
  fi
  printf '%s' "${pct}"
}

MEMORY_LIMIT_BYTES=""
detect_memory_limit() {
  local v="${CP_MEMORY_LIMIT_BYTES}" src="CP_MEMORY_LIMIT_BYTES" n share sum=0 shares=""
  for n in ${GOMEMLIMIT_COMPONENTS}; do
    share="$(gomemlimit_share "${n}")" || fail "${share} must be a percentage (0-100)"
    sum=$(( sum + share )); shares="${shares}${shares:+, }${n} ${share}%"
  done
  # Over 100 the shares promise more than the container has; at the default 3%
  # each, the sixth function is where that happens.
  [ "${sum}" -le 100 ] || fail "GOMEMLIMIT shares add up to ${sum}% (${shares}); keep the total at or under 100 (fewer functions in CP_FUNCTIONS, or lower CP_GOMEMLIMIT_PCT_<NAME> overrides)"
  if [ -n "${v}" ]; then
    [[ "${v}" =~ ^[0-9]+$ ]] || fail "CP_MEMORY_LIMIT_BYTES must be an integer number of bytes, got '${v}'"
  else
    if [ -r /sys/fs/cgroup/memory.max ]; then
      v="$(cat /sys/fs/cgroup/memory.max)"; src="cgroup v2 memory.max"
    elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
      v="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)"; src="cgroup v1 memory.limit_in_bytes"
    fi
    # "max" (v2) or a value near 2^63 (v1) is "unlimited".
    [[ "${v}" =~ ^[0-9]+$ ]] && [ "${v}" -lt 4611686018427387904 ] || v=""
  fi
  MEMORY_LIMIT_BYTES="${v}"
  if [ "${CP_GOMEMLIMIT_ENABLED}" != "true" ]; then
    log "GOMEMLIMIT disabled (CP_GOMEMLIMIT_ENABLED=false)"
  elif [ -z "${v}" ]; then
    log "WARNING: no container memory limit found (cgroup unlimited or not visible, CP_MEMORY_LIMIT_BYTES unset): GOMEMLIMIT not set. Pass CP_MEMORY_LIMIT_BYTES on platforms that do not expose the limit"
  else
    [ "${v}" -ge 1073741824 ] \
      || log "WARNING: memory limit is $(mib "${v}") MiB; the control plane was not tested under 1 GiB"
    # A function idles at about 30 MiB RSS; a GOMEMLIMIT under 64 MiB leaves
    # the GC running continuously against it. Warn rather than fail: the
    # function still works, only slower, and the fix is a bigger container.
    local fn fshare fbytes
    for fn in ${FUNCTION_NAMES[@]+"${FUNCTION_NAMES[@]}"}; do
      fshare="$(gomemlimit_share "${fn}")"
      [ "${fshare}" -gt 0 ] || continue   # 0 means no GOMEMLIMIT for it
      fbytes=$(( v * fshare / 100 ))
      [ "${fbytes}" -ge "${GOMEMLIMIT_FUNCTION_MIN_BYTES}" ] \
        || log "WARNING: GOMEMLIMIT for ${fn} would be $(mib "${fbytes}") MiB (${fshare}% of $(mib "${v}") MiB), under the $(mib "${GOMEMLIMIT_FUNCTION_MIN_BYTES}") MiB a function needs to idle (about 30 MiB RSS) without collecting continuously; give the container more memory or raise CP_GOMEMLIMIT_PCT_$(printf '%s' "${fn}" | tr 'a-z-' 'A-Z_')"
    done
    log "memory limit $(mib "${v}") MiB (${src}); GOMEMLIMIT shares: ${shares}"
  fi
}

ETCD_SNAPSHOT_DIR="${CP_STATE_DIR}/snapshots"
ETCD_ENDPOINT="https://127.0.0.1:${CP_ETCD_CLIENT_PORT}"
ETCD_PEER_URL="https://127.0.0.1:${CP_ETCD_PEER_PORT}"
# The supervisor's own etcd client identity (minted every boot in bootstrap_pki).
ETCDCTL_TLS=(--cacert="${CP_PKI_DIR}/etcd-ca.crt"
             --cert="${CP_PKI_DIR}/etcd-client-supervisor.crt" --key="${CP_PKI_DIR}/etcd-client-supervisor.key")
# Long timeouts for the maintenance calls (a defrag or snapshot of a database
# near the quota), short ones for the probes that gate or poll. etcdctl keeps
# retrying a refused connection until the command timeout, so a pass against
# a dead etcd takes up to that long per call; it runs in the background.
etcdctl_maint() { "${CP_BIN_DIR}/etcdctl" --endpoints "${ETCD_ENDPOINT}" "${ETCDCTL_TLS[@]}" --dial-timeout 5s --command-timeout 180s "$@"; }
etcdctl_probe() { "${CP_BIN_DIR}/etcdctl" --endpoints "${ETCD_ENDPOINT}" "${ETCDCTL_TLS[@]}" --dial-timeout 2s --command-timeout 5s "$@"; }
# etcd wants TLS1.2/TLS1.3 where kube-apiserver wants VersionTLS12/VersionTLS13.
etcd_tls_min_version() { case "${CP_TLS_MIN_VERSION}" in VersionTLS13) echo TLS1.3 ;; *) echo TLS1.2 ;; esac; }
# etcd_status_field NAME -> the integer field NAME of `endpoint status`, or
# "" when etcd does not answer. Never fails: callers run under set -e.
etcd_status_field() {
  local v
  v="$(etcdctl_probe endpoint status -w json 2>/dev/null | grep -o "\"$1\":[0-9]*" | head -1 | cut -d: -f2 || true)"
  [[ "${v}" =~ ^[0-9]+$ ]] && printf '%s' "${v}" || true
}
etcd_alarms() { etcdctl_probe alarm list 2>/dev/null || true; }
# True when the alarm list holds nothing but NOSPACE, the one alarm this
# script may clear. CORRUPT and anything else stay raised for a human.
alarms_only_nospace() {
  [ -n "$1" ] && ! printf '%s\n' "$1" | grep 'alarm:' | grep -qv 'alarm:NOSPACE'
}

# The maintenance pass. Compaction is normally the API server's job (every 5
# min); under NOSPACE its compactor cannot write its bookkeeping key, so the
# pass compacts itself when an alarm is active. Defrag is what returns space
# to the filesystem; it stalls etcd and needs a copy's worth of free space,
# so it runs only when fragmented (or alarmed) and when the space is there.
# Then: prune to KEEP-1, snapshot, so the directory never exceeds KEEP. The
# boot pass skips the snapshot when one under an hour old exists, so a crash
# loop cannot rotate every good snapshot away. Every caller invokes this as
# `etcd_maintenance ... || ...`, which also turns errexit off inside it:
# nothing in here may take the supervisor down.
etcd_maintenance() {
  local reason="$1" before inuse frag after alarms avail f rev want n newest
  before="$(etcd_status_field dbSize)"; before="${before:-0}"
  inuse="$(etcd_status_field dbSizeInUse)"; inuse="${inuse:-${before}}"
  frag=$(( before - inuse )); [ "${frag}" -ge 0 ] || frag=0
  alarms="$(etcd_alarms)"
  if [ -n "${alarms}" ]; then
    rev="$(etcd_status_field revision)"
    if [ -n "${rev}" ]; then
      # Kubernetes tolerates a third-party compaction: watchers see one "too
      # old resource version" and re-list; the apiserver's own compactor
      # handles ErrCompacted.
      if etcdctl_maint compact --physical "${rev}" >/dev/null 2>&1; then
        log "etcd alarm active (${alarms}): compacted to revision ${rev} before defrag"
      else
        log "WARNING: etcd compaction to revision ${rev} failed (${reason})"
      fi
    fi
  fi
  read -r _ avail < <(fs_bytes "${CP_STATE_DIR}") || avail=0
  if [ -n "${alarms}" ] || [ "${frag}" -ge 104857600 ] || { [ "${before}" -gt 0 ] && [ $(( frag * 4 )) -ge "${before}" ]; }; then
    if [ "${avail}" -ge "${before}" ]; then
      etcdctl_maint defrag >/dev/null 2>&1 || log "WARNING: etcd defrag failed (${reason})"
    else
      log "WARNING: skipping etcd defrag: it needs $(mib "${before}") MiB free under ${CP_STATE_DIR} and only $(mib "${avail}") MiB is"
    fi
  fi
  after="$(etcd_status_field dbSize)"; after="${after:-${before}}"
  if [ -n "${alarms}" ]; then
    if ! alarms_only_nospace "${alarms}"; then
      log "WARNING: etcd alarm that is not NOSPACE, leaving it raised: ${alarms}"
    elif [ "${after}" -lt $(( CP_ETCD_QUOTA_BYTES * 9 / 10 )) ]; then
      if etcdctl_maint alarm disarm >/dev/null 2>&1; then
        log "etcd alarm cleared after defrag ($(mib "${after}") MiB in use): ${alarms}"
      else
        log "WARNING: could not disarm etcd alarm: ${alarms}"
      fi
    else
      log "WARNING: etcd alarm active with the database at $(mib "${after}") MiB of a $(mib "${CP_ETCD_QUOTA_BYTES}") MiB quota: ${alarms}. Writes are refused until space is freed: delete objects (the alarm poll recovers within 10 minutes); if the plane cannot boot, raise CP_ETCD_QUOTA_BYTES or restore a snapshot"
    fi
  fi
  mkdir -p "${ETCD_SNAPSHOT_DIR}"; chmod 700 "${ETCD_SNAPSHOT_DIR}"   # a default ACL can beat umask
  local -a snaps=()
  mapfile -t snaps < <(printf '%s\n' "${ETCD_SNAPSHOT_DIR}"/etcd-*.db | sort -r)
  [ -e "${snaps[0]:-}" ] || snaps=()
  if [ "${CP_ETCD_SNAPSHOT_KEEP}" -eq 0 ]; then
    [ "${#snaps[@]}" -eq 0 ] || rm -f -- "${snaps[@]}"
    log "etcd maintenance (${reason}): db $(mib "${before}") -> $(mib "${after}") MiB; snapshots disabled (CP_ETCD_SNAPSHOT_KEEP=0)"
    return 0
  fi
  newest="${snaps[0]:-}"
  if [ "${reason}" = "boot" ] && [ -n "${newest}" ] \
     && [ $(( $(date +%s) - $(stat -c %Y "${newest}" 2>/dev/null || echo 0) )) -lt 3600 ]; then
    log "etcd maintenance (boot): db $(mib "${before}") -> $(mib "${after}") MiB; keeping $(basename "${newest}") (under an hour old) instead of a new snapshot"
    return 0
  fi
  n=$(( CP_ETCD_SNAPSHOT_KEEP - 1 ))
  [ "${#snaps[@]}" -le "${n}" ] || rm -f -- "${snaps[@]:${n}}"
  read -r _ avail < <(fs_bytes "${CP_STATE_DIR}") || avail=0
  # Headroom: the snapshot itself plus the database growing meanwhile.
  want=$(( after * 2 + 67108864 ))
  f="${ETCD_SNAPSHOT_DIR}/etcd-$(date -u +%Y%m%dT%H%M%SZ).db"
  if [ "${avail}" -lt "${want}" ]; then
    log "WARNING: skipping the etcd snapshot: $(mib "${avail}") MiB free under ${CP_STATE_DIR}, want $(mib "${want}") MiB"
  elif [ -e "${f}" ]; then
    log "etcd maintenance (${reason}): a snapshot was taken this same second, not taking another"
  elif etcdctl_maint snapshot save "${f}" >/dev/null 2>&1; then
    chmod 600 "${f}"
    log "etcd maintenance (${reason}): db $(mib "${before}") -> $(mib "${after}") MiB (fragmentation was $(mib "${frag}") MiB); snapshot $(basename "${f}") ($(mib "$(stat -c %s "${f}" || echo 0)") MiB), keeping ${CP_ETCD_SNAPSHOT_KEEP}; $(mib "${avail}") MiB free"
  else
    rm -f -- "${f}" "${f}.part"
    log "WARNING: etcd snapshot save failed (${reason})"
  fi
}

# --initial-* flags are read only when the data directory is created, so a
# state root from before peer TLS still records http:// as the member's peer
# URL. Harmless for a single member, but keep the record true.
etcd_update_peer_url() {
  local line id urls
  line="$(etcdctl_probe member list 2>/dev/null | grep ', control-plane, ' | head -1)" || true
  [ -n "${line}" ] || return 0
  id="$(printf '%s' "${line}" | cut -d, -f1 | tr -d ' ')"
  urls="$(printf '%s' "${line}" | cut -d, -f4 | tr -d ' ')"
  [ "${urls}" != "${ETCD_PEER_URL}" ] || return 0
  if etcdctl_maint member update "${id}" --peer-urls="${ETCD_PEER_URL}" >/dev/null 2>&1; then
    log "etcd member peer URL updated from ${urls} to ${ETCD_PEER_URL}"
  else
    log "WARNING: could not update the etcd member peer URL from ${urls} to ${ETCD_PEER_URL}"
  fi
}

# After boot the pass runs as a background job so the supervise loop keeps
# its cadence; one at a time.
MAINT_PID=""
MAINTENANCE_LAST=0
MAINTENANCE_NOW=0
ALARM_PASS_LAST=0
run_maintenance() {
  local reason="$1"
  if [ -n "${MAINT_PID}" ] && kill -0 "${MAINT_PID}" 2>/dev/null; then
    log "etcd maintenance (${reason}): the previous pass (pid ${MAINT_PID}) is still running, not starting another"
    return 0
  fi
  ( etcd_maintenance "${reason}" || log "WARNING: etcd maintenance (${reason}) did not complete" ) &
  MAINT_PID=$!
  MAINTENANCE_LAST=$(date +%s)
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
    --listen-client-urls "https://127.0.0.1:${CP_ETCD_CLIENT_PORT}" \
    --advertise-client-urls "https://127.0.0.1:${CP_ETCD_CLIENT_PORT}" \
    --cert-file "${CP_PKI_DIR}/etcd-server.crt" \
    --key-file "${CP_PKI_DIR}/etcd-server.key" \
    --trusted-ca-file "${CP_PKI_DIR}/etcd-ca.crt" \
    --client-cert-auth \
    --listen-peer-urls "${ETCD_PEER_URL}" \
    --initial-advertise-peer-urls "${ETCD_PEER_URL}" \
    --initial-cluster "control-plane=${ETCD_PEER_URL}" \
    --peer-cert-file "${CP_PKI_DIR}/etcd-server.crt" \
    --peer-key-file "${CP_PKI_DIR}/etcd-server.key" \
    --peer-trusted-ca-file "${CP_PKI_DIR}/etcd-ca.crt" \
    --peer-client-cert-auth \
    --tls-min-version "$(etcd_tls_min_version)" \
    --initial-cluster-state new \
    --auto-compaction-retention 1 \
    --quota-backend-bytes "${CP_ETCD_QUOTA_BYTES}" \
    --log-level warn

  # Two gates. "serving" is satisfied by an etcd that answers, alarm or not,
  # so the maintenance pass gets a chance to clear a NOSPACE alarm left by
  # the previous run (endpoint health reports an alarmed member unhealthy,
  # which would otherwise wedge the boot). "healthy" then demands the real thing.
  wait_ready "etcd serving" "${CP_READY_TIMEOUT}" etcdctl_probe endpoint status
  etcd_update_peer_url
  etcd_maintenance boot || log "WARNING: etcd maintenance (boot) did not complete"
  # Healthy means no alarm. Booting on through a NOSPACE alarm was tried and
  # does not work: crossplane core init needs writes and fails five attempts
  # later with a worse message. So an alarm the pass could not clear (live
  # data above 90% of the quota, or CORRUPT) stops the boot here, with the
  # ways out.
  local t alarms
  for t in $(seq 1 30); do etcdctl_probe endpoint health >/dev/null 2>&1 && break; sleep 1; done
  if etcdctl_probe endpoint health >/dev/null 2>&1; then
    log "READY: etcd healthy (no alarm)"
  else
    alarms="$(etcd_alarms)"
    if alarms_only_nospace "${alarms}"; then
      fail "etcd is still under a NOSPACE alarm after compaction and defrag: live data fills over 90% of the $(mib "${CP_ETCD_QUOTA_BYTES}") MiB quota. Raise CP_ETCD_QUOTA_BYTES (the volume permitting) and redeploy, then delete objects; or restore an older snapshot from ${ETCD_SNAPSHOT_DIR}"
    fi
    fail "etcd is not healthy after maintenance (${alarms:-no alarm reported}); see ${CP_LOG_DIR}/etcd.log"
  fi
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
    --etcd-servers "https://127.0.0.1:${CP_ETCD_CLIENT_PORT}" \
    --etcd-cafile "${CP_PKI_DIR}/etcd-ca.crt" \
    --etcd-certfile "${CP_PKI_DIR}/etcd-client-apiserver.crt" \
    --etcd-keyfile "${CP_PKI_DIR}/etcd-client-apiserver.key" \
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
  # functions/functionrevisions: register_functions writes them before
  # Crossplane starts, so they are gated here rather than assumed.
  wait_ready "crossplane core CRDs established" 120 \
    bash -c "$(declare -f kc crd_established); \
             CP_BIN_DIR='${CP_BIN_DIR}' KUBECONFIG_INTERNAL='${KUBECONFIG_INTERNAL}'; \
             crd_established locks.pkg.crossplane.io \
             && crd_established compositions.apiextensions.crossplane.io \
             && crd_established deploymentruntimeconfigs.pkg.crossplane.io \
             && crd_established functions.pkg.crossplane.io \
             && crd_established functionrevisions.pkg.crossplane.io"

  local d dirs
  IFS=':' read -ra dirs <<< "${CP_CRD_DIRS}"
  for d in "${dirs[@]}"; do apply_crd_dir "$d"; done

  # Both API groups: the legacy cluster-scoped railway.crossplane.io and the
  # namespaced railway.m.crossplane.io, whose ClusterProviderConfig
  # write_railway_credentials writes and whose Project the compositions compose.
  wait_ready "railway CRDs established" 120 \
    bash -c "$(declare -f kc crd_established); \
             CP_BIN_DIR='${CP_BIN_DIR}' KUBECONFIG_INTERNAL='${KUBECONFIG_INTERNAL}'; \
             crd_established projects.railway.crossplane.io \
             && crd_established providerconfigs.railway.crossplane.io \
             && crd_established projects.railway.m.crossplane.io \
             && crd_established clusterproviderconfigs.railway.m.crossplane.io"

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
# TLS material shared by steps 5 and 6
#
# `core init` leaves Crossplane's mTLS identities in Secrets; out of cluster
# there is no projected volume, so both Crossplane core (step 5) and the
# functions' readiness probe (step 6) read them from the ephemeral run dir.
# ------------------------------------------------------------------------------
# unpack_tls_secret SECRET DIR [KEY...]: write the named keys of a TLS Secret
# in the Crossplane namespace to DIR, mode 0600 (default keys: tls.crt tls.key
# ca.crt; the root CA Secret has no ca.crt). Base64 is decoded straight into
# the file, so no key material passes through a command line.
unpack_tls_secret() {
  local secret="$1" dir="$2"; shift 2
  local -a keys=("$@")
  [ "${#keys[@]}" -gt 0 ] || keys=(tls.crt tls.key ca.crt)
  mkdir -p "${dir}"
  chmod 700 "${dir}"   # a default ACL can beat umask
  local k
  for k in "${keys[@]}"; do
    # go-template rather than jsonpath: the keys contain dots, and quoting the
    # jsonpath escape through two layers of shell is a reliable way to get
    # silently-empty output.
    kc -n "${CP_CROSSPLANE_NAMESPACE}" get secret "${secret}" \
      -o "go-template={{index .data \"${k}\"}}" | base64 -d > "${dir}/${k}"
    [ -s "${dir}/${k}" ] || fail "secret ${secret} has no ${k}"
  done
  chmod 600 "${dir}"/*
}

# The client identity Crossplane presents to functions, unpacked to
# CP_RUN_DIR/tls/client. Loaded by `crossplane core start` (step 5) and used
# again by the functions' readiness probe (step 6); idempotent.
unpack_crossplane_client_tls() {
  wait_ready "crossplane TLS client secret" 60 \
    kc -n "${CP_CROSSPLANE_NAMESPACE}" get secret crossplane-tls-client
  unpack_tls_secret crossplane-tls-client "${CP_RUN_DIR}/tls/client"
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
start_crossplane() {
  unpack_crossplane_client_tls

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
# Step 6: composition functions
#
# Crossplane core dials each function with the mTLS client identity `core
# init` wrote to Secret crossplane-tls-client, verifying the function's serving
# certificate against the root CA in Secret crossplane-root-ca with ordinary
# hostname verification. So each function gets, every boot, a serving
# certificate signed by that root CA with an IP SAN for 127.0.0.1, plus a copy
# of the root CA certificate as the ca.crt it verifies Crossplane's client
# certificate against. All of it lives under the ephemeral run dir: the root CA
# key is Crossplane's, and it is only borrowed for the length of the signing;
# start_functions removes it from disk once the last certificate is signed.
#
# Which process answers for a function is decided by the FunctionRevision:
# Crossplane's function runner lists FunctionRevisions labelled
# pkg.crossplane.io/package=<name> with spec.desiredState Active and dials
# status.endpoint, and a Composition pipeline is only valid when every such
# revision reports the "composition" capability. Under the External package
# runtime nothing sets either field (only the Deployment runtime does), so
# register_functions writes them. Both objects carry crossplane.io/paused:
# "true" so the package manager's reconcilers never try to pull the image
# behind the placeholder spec.package/spec.image and never recompute the status
# we set; paused, they only add a ReconcilePaused condition. Both also carry
# the label below, which is how register_functions tells its own objects from
# anyone else's when it removes stale registrations.
#
# Order: AFTER crossplane core start, deliberately. function-sdk-go (v0.7.1)
# starts a Prometheus metrics server on ":8080", all interfaces, with no flag
# or variable to move or disable it, and ignores the bind error. Crossplane
# core's own metrics port is 8080 by default, and Crossplane refuses to start
# when it is taken (seen on the first Railway deploy of this step: "listen tcp
# :8080: bind: address already in use", a crash loop). Starting Crossplane
# first makes it the owner of 8080 and turns every function's metrics server
# into a silent no-op; a dial Crossplane attempts before a function is up is
# an ordinary reconcile error it retries. The functions therefore listen on
# loopback only, which the harness asserts. An SDK that made the metrics bind
# fatal would stop the function before readiness, which the wait_ready gate
# catches, so a function bump that changes this fails the boot rather than
# passing silently.
# ------------------------------------------------------------------------------
# The label on every Function and FunctionRevision this supervisor writes.
SUPERVISOR_LABEL_KEY="app.kubernetes.io/managed-by"
SUPERVISOR_LABEL_VALUE="control-plane-supervisor"

# function_port INDEX -> the port of the INDEX-th (0-based) function in
# CP_FUNCTIONS: CP_FUNCTION_PORT_BASE + INDEX (validated in the configuration
# block, which needs only the base and the count).
function_port() { printf '%s' $(( CP_FUNCTION_PORT_BASE + $1 )); }

# function_tls_ok PORT: the readiness predicate for one function, an mTLS
# handshake made the way Crossplane makes it: its client certificate, the
# root CA as trust anchor, ALPN h2 (the gRPC server refuses anything else).
# "Verify return code: 0 (ok)" alone only proves the serving certificate, since
# under TLS 1.3 a rejected client certificate arrives as an alert after the
# handshake; so a negotiated h2 and the absence of any alert are required too.
function_tls_ok() {
  local out
  out="$(openssl s_client -alpn h2 -connect "127.0.0.1:$1" \
           -CAfile "${CP_RUN_DIR}/tls/root-ca/tls.crt" \
           -cert "${CP_RUN_DIR}/tls/client/tls.crt" -key "${CP_RUN_DIR}/tls/client/tls.key" \
           </dev/null 2>&1)" || true
  printf '%s' "${out}" | grep -q 'Verify return code: 0 (ok)' \
    && printf '%s' "${out}" | grep -q 'ALPN protocol: h2' \
    && ! printf '%s' "${out}" | grep -q 'SSL alert number'
}

start_functions() {
  [ "${#FUNCTION_NAMES[@]}" -gt 0 ] || { log "composition functions disabled (CP_FUNCTIONS empty)"; return 0; }
  local i name port dir
  for name in "${FUNCTION_NAMES[@]}"; do
    [ -x "${CP_BIN_DIR}/${name}" ] || fail "CP_FUNCTIONS names ${name} but ${CP_BIN_DIR}/${name} is not an executable; build it into the image (Dockerfile, functions-build) or remove it from CP_FUNCTIONS"
  done

  wait_ready "crossplane root CA secret" 60 \
    kc -n "${CP_CROSSPLANE_NAMESPACE}" get secret crossplane-root-ca
  unpack_tls_secret crossplane-root-ca "${CP_RUN_DIR}/tls/root-ca" tls.crt tls.key
  unpack_crossplane_client_tls

  for i in "${!FUNCTION_NAMES[@]}"; do
    name="${FUNCTION_NAMES[$i]}"; port="$(function_port "$i")"
    dir="${CP_RUN_DIR}/tls/functions/${name}"
    mkdir -p "${dir}"
    chmod 700 "${dir}"
    # CN and a DNS SAN of the function's own name, for anything that dials it
    # by name; Crossplane dials 127.0.0.1, which is the SAN that matters.
    log "issuing serving certificate for ${name} (${CP_INTERNAL_CERT_DAYS} days, Crossplane root CA)"
    sign_cert "${dir}/tls" "${CP_RUN_DIR}/tls/root-ca/tls" "/CN=${name}" serverAuth \
      "DNS:localhost,DNS:${name},IP:127.0.0.1,IP:::1" "${CP_INTERNAL_CERT_DAYS}"
    cp -f "${CP_RUN_DIR}/tls/root-ca/tls.crt" "${dir}/ca.crt"
    chmod 600 "${dir}"/*
    # --tls-certs-dir is the flag's real name (kong derives it from the SDK's
    # TLSCertsDir field; the help text's "--tls-server-certs-dir" is only the
    # environment variable TLS_SERVER_CERTS_DIR). No kubeconfig: a function
    # never talks to the API server, only answers Crossplane over gRPC.
    start_bg "${name}" "${CP_BIN_DIR}/${name}" \
      --address "127.0.0.1:${port}" \
      --tls-certs-dir "${dir}"
    wait_ready "${name} mTLS on 127.0.0.1:${port}" "${CP_READY_TIMEOUT}" function_tls_ok "${port}"
  done

  # The root CA key is Crossplane's, borrowed only to sign the certificates
  # above, and every process in this container runs as one uid, so a copy left
  # on disk is readable by all of them for the container's life. Remove it (and
  # the serial file openssl keeps beside it) now that the last certificate is
  # signed. tls.crt stays: function_tls_ok and the per-function ca.crt copies
  # need it. start_functions runs once per boot (main), so nothing signs again
  # until the next boot unpacks the Secret afresh.
  rm -f "${CP_RUN_DIR}/tls/root-ca/tls.key" "${CP_RUN_DIR}/tls/root-ca/tls.srl"
  [ ! -e "${CP_RUN_DIR}/tls/root-ca/tls.key" ] || fail "could not remove the borrowed root CA key ${CP_RUN_DIR}/tls/root-ca/tls.key"
  log "root CA key removed from ${CP_RUN_DIR}/tls/root-ca after signing ${#FUNCTION_NAMES[@]} function certificate(s)"
}

# Registers each configured function (Function/<name>, FunctionRevision/
# <name>-local) and removes the registrations of functions that are no longer
# configured. status.endpoint is writable only through the status subresource
# of a cluster-scoped object, i.e. by cluster admins, and Crossplane dials it
# with CA verification against its own root CA; the registration is therefore
# exactly as trusted as the API server's admins, no more and no less.
register_functions() {
  local i name port
  for i in ${FUNCTION_NAMES[@]+"${!FUNCTION_NAMES[@]}"}; do
    name="${FUNCTION_NAMES[$i]}"; port="$(function_port "$i")"
    # Server-side apply so a reboot re-asserts the same objects without a
    # diff fight. spec.package and spec.image are required strings, and the
    # Function CRD's CEL rule demands a registry/repository:tag shape, so the
    # placeholder below looks like an image reference; nothing resolves it,
    # which is fine because the paused reconcilers never fetch it (see the
    # step comment). The same string goes in both objects.
    kc apply --server-side --force-conflicts -f - >/dev/null <<EOF || fail "could not register Function/${name}"
apiVersion: pkg.crossplane.io/v1
kind: Function
metadata:
  name: ${name}
  labels:
    ${SUPERVISOR_LABEL_KEY}: ${SUPERVISOR_LABEL_VALUE}
  annotations:
    crossplane.io/paused: "true"
spec:
  package: supervised.local/control-plane/${name}:process
---
apiVersion: pkg.crossplane.io/v1
kind: FunctionRevision
metadata:
  name: ${name}-local
  labels:
    pkg.crossplane.io/package: ${name}
    ${SUPERVISOR_LABEL_KEY}: ${SUPERVISOR_LABEL_VALUE}
  annotations:
    crossplane.io/paused: "true"
spec:
  desiredState: Active
  image: supervised.local/control-plane/${name}:process
  revision: 1
EOF
    # The status subresource is what the function runner and the pipeline
    # validator read: the endpoint to dial and the capability that makes a
    # Composition pipeline referring to this function valid.
    kc patch functionrevision "${name}-local" --subresource=status --type=merge \
        -p "{\"status\":{\"endpoint\":\"127.0.0.1:${port}\",\"capabilities\":[\"composition\"]}}" >/dev/null \
      || fail "could not set status.endpoint/status.capabilities on FunctionRevision/${name}-local; without them Crossplane cannot dial ${name} and every pipeline using it stays invalid"
    log "function ${name} registered: port ${port}, FunctionRevision/${name}-local endpoint 127.0.0.1:${port}, capabilities [composition]"
  done

  # Ports are positional, so a name removed from or reordered in CP_FUNCTIONS
  # leaves the previous boot's FunctionRevision/<old>-local pointing at a port
  # another function now owns, and Crossplane would route <old>'s pipeline
  # steps to the wrong process. Delete every object carrying this supervisor's
  # label that no configured name accounts for. Unlabelled objects were not
  # written here and are never touched. Runs with CP_FUNCTIONS empty too: that
  # is the "every name removed" case.
  local selector="${SUPERVISOR_LABEL_KEY}=${SUPERVISOR_LABEL_VALUE}" listing obj kind oname keep
  listing="$(kc get function.pkg.crossplane.io,functionrevision.pkg.crossplane.io -l "${selector}" -o name)" \
    || fail "could not list the Function/FunctionRevision objects labelled ${selector}; a stale registration from an earlier CP_FUNCTIONS could route a pipeline to the wrong port"
  while IFS= read -r obj; do
    [ -n "${obj}" ] || continue
    kind="${obj%%/*}"; oname="${obj#*/}"
    keep=0
    for name in ${FUNCTION_NAMES[@]+"${FUNCTION_NAMES[@]}"}; do
      case "${kind}" in
        function.pkg.crossplane.io)         [ "${oname}" != "${name}" ]       || keep=1 ;;
        functionrevision.pkg.crossplane.io) [ "${oname}" != "${name}-local" ] || keep=1 ;;
      esac
    done
    [ "${keep}" -eq 0 ] || continue
    if kc delete "${obj}" --ignore-not-found >/dev/null; then
      log "deleted stale ${obj} (labelled ${selector}, no longer in CP_FUNCTIONS)"
    else
      fail "could not delete stale ${obj}; its status.endpoint may point at a port another function now owns"
    fi
  done <<< "${listing}"
}

# ------------------------------------------------------------------------------
# Step 7: credentials + provider
#
# $RAILWAY_TOKEN must be a Railway *workspace or account* token. Project tokens
# fail with "Not Authorized" because the Terraform provider only ever sends an
# `Authorization: Bearer` header.
#
# B4: the token is taken out of the environment before any component starts
# (take_railway_token, called from main()), so no component inherits it. Only
# [A-Za-z0-9._-] is accepted. Two separate reasons, kept apart on purpose:
# the invariant is that the set never admits a quote, a backslash, whitespace
# or a control character, which is what keeps the hand-built JSON below safe
# (the image has no jq); the width within that invariant is a matter of what
# Railway issues, and it is a character-set check, not a format check, so do
# not narrow it to one token shape (docs/getting-started/authentication.md).
# Two copies remain and are accepted: the short-lived
# root-phase helpers (find, chown, su-exec) run before the drop with it, and
# bash's unset cannot scrub this process's own exec-time environment block, so
# /proc/<supervisor pid>/environ keeps it. Why that is acceptable, and the
# conditions under which it stops being so, are in
# docs/architecture/control-plane.md, "Secrets, audit and credential lifetimes".
# ------------------------------------------------------------------------------
# take_railway_token VAR: move $RAILWAY_TOKEN into the variable named VAR and
# unset it (same idiom as prepare_encryption). Leading and trailing whitespace
# is dropped; anything else outside the character set, interior whitespace
# included, is refused rather than silently repaired. Pure builtins, so the
# value is handed to no child process here.
take_railway_token() {
  local _tok="${RAILWAY_TOKEN:-}"
  unset RAILWAY_TOKEN
  _tok="${_tok#"${_tok%%[![:space:]]*}"}"
  _tok="${_tok%"${_tok##*[![:space:]]}"}"
  # The value itself is never logged, not even when it is refused.
  [ -z "${_tok}" ] || [[ "${_tok}" =~ ^[A-Za-z0-9._-]+$ ]] \
    || fail "RAILWAY_TOKEN contains characters outside [A-Za-z0-9._-]; expected a Railway workspace or account token"
  printf -v "$1" '%s' "${_tok}"
}

write_railway_credentials() {
  local token="$1"
  if [ -z "${token}" ]; then
    log "WARNING: RAILWAY_TOKEN is unset -- skipping Secret/ProviderConfig."
    log "         The provider will start but every reconcile will fail until"
    log "         a ProviderConfig with valid credentials exists (one written"
    log "         by an earlier boot stays in place)."
    return 0
  fi
  log "writing railway-creds Secret, ProviderConfig/default and ClusterProviderConfig/default"
  # printf is a builtin and kubectl reads the JSON from stdin, so the token is
  # on no command line and in no file. Server-side apply, because client-side
  # apply would store the data a second time in the last-applied-configuration
  # annotation. kubectl's own diagnostics can echo the object it failed on, so
  # they are captured and the token and its base64 form masked before logging.
  local ns="${CP_CROSSPLANE_NAMESPACE}" err b64
  if ! err="$( { printf '{"token":"%s"}' "${token}" \
        | kc -n "${ns}" create secret generic railway-creds \
            --from-file=credentials=/dev/stdin --dry-run=client -o yaml \
        | kc apply --server-side --force-conflicts -f - >/dev/null; } 2>&1 )"; then
    b64="$(printf '{"token":"%s"}' "${token}" | base64 | tr -d '\n')"
    err="${err//"${token}"/<redacted>}"; err="${err//"${b64}"/<redacted>}"
    log "kubectl: ${err}"
    fail "could not write the railway-creds Secret"
  fi
  # A Secret written by a boot before B4 still carries the client-side
  # annotation with the data in it; drop it. A no-op once it is gone.
  kc -n "${ns}" annotate secret railway-creds kubectl.kubernetes.io/last-applied-configuration- >/dev/null \
    || fail "could not remove the last-applied-configuration annotation from railway-creds"
  kc apply -f - >/dev/null <<EOF || fail "could not write ProviderConfig/default"
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
  # The namespaced managed resources (railway.m.crossplane.io, what a
  # Composition composes) default their providerConfigRef to
  # kind: ClusterProviderConfig, name: default, a different object from the
  # legacy ProviderConfig above. Same credentials, both kept, so legacy
  # cluster-scoped objects keep working.
  kc apply -f - >/dev/null <<EOF || fail "could not write ClusterProviderConfig/default"
apiVersion: railway.m.crossplane.io/v1beta1
kind: ClusterProviderConfig
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
  # The Railway token leaves the environment before anything is started (B4).
  local railway_token
  take_railway_token railway_token
  mkdir -p "${CP_HOME}" "${CP_LOG_DIR}" "${CP_RUN_DIR}" "${CP_HOME}/cache"
  # Separate handlers so a platform stop exits 143/130; the EXIT trap then runs
  # shutdown with that status instead of whatever command happened to be running.
  trap 'exit 143' TERM
  trap 'exit 130' INT
  trap shutdown EXIT
  trap 'MAINTENANCE_NOW=1' USR1

  apply_railway_defaults
  prepare_state_dir
  check_capacity
  detect_memory_limit
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
  # Functions after Crossplane core: see the step 6 comment (Crossplane must
  # own port 8080 before the functions' SDK tries to squat it). The reverse
  # shutdown order then stops the functions before Crossplane, which only
  # costs Crossplane a few failed dials while it is itself being stopped.
  start_functions
  register_functions
  write_railway_credentials "${railway_token}"
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
  if [ "${#FUNCTION_NAMES[@]}" -gt 0 ]; then
    local fl="" fidx
    for fidx in "${!FUNCTION_NAMES[@]}"; do fl="${fl}${fl:+, }${FUNCTION_NAMES[$fidx]}@127.0.0.1:$(function_port "${fidx}")"; done
    log "  functions:             ${fl}"
  else
    log "  functions:             none (CP_FUNCTIONS empty)"
  fi
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
  # Quantised to the 5 s tick, rounded up; 0 disables the periodic run.
  local i tick=0 maint_ticks=$(( (CP_ETCD_MAINTENANCE_INTERVAL + 4) / 5 ))
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
    if [ "${MAINTENANCE_NOW}" -eq 1 ]; then
      MAINTENANCE_NOW=0
      if [ $(( $(date +%s) - MAINTENANCE_LAST )) -lt 60 ]; then
        log "etcd maintenance (signal): ignored, the last pass started under 60 s ago"
      else
        run_maintenance signal
      fi
    elif [ $((tick % 12)) -eq 0 ] && [ -n "$(etcd_alarms)" ] \
         && [ $(( $(date +%s) - ALARM_PASS_LAST )) -ge 600 ]; then
      # Every 60 s: an alarm gets a recovery pass, at most every 10 minutes.
      ALARM_PASS_LAST=$(date +%s)
      run_maintenance alarm
    elif [ "${maint_ticks}" -gt 0 ] && [ $((tick % maint_ticks)) -eq 0 ]; then
      run_maintenance periodic
    fi
    if [ $((tick % 720)) -eq 0 ]; then
      local c
      for c in admin-internal controller-manager apiserver \
               etcd-server etcd-client-apiserver etcd-client-supervisor; do
        cert_fresh "${CP_PKI_DIR}/${c}.crt" $(( 7 * 86400 )) \
          || { log "certificate ${c} expires within 7 days -- restarting to reissue"; exit 1; }
      done
      # The functions' serving certificates are reissued at boot like the rest.
      for c in ${FUNCTION_NAMES[@]+"${FUNCTION_NAMES[@]}"}; do
        cert_fresh "${CP_RUN_DIR}/tls/functions/${c}/tls.crt" $(( 7 * 86400 )) \
          || { log "serving certificate of ${c} expires within 7 days -- restarting to reissue"; exit 1; }
      done
    fi
    sleep 5
  done
}

main "$@"
