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
# unprivileged. The chown is recursive only when the state root is not already
# owned by the target uid (an interim root-run deployment leaves root-owned
# pki/ and etcd/ behind; a healthy one costs a single stat).
# ------------------------------------------------------------------------------
drop_privileges_if_root() {
  [ "$(id -u)" = "0" ] || return 0
  if [ "${CP_STAY_ROOT}" = "true" ]; then
    log "WARNING: running the control plane as root because CP_STAY_ROOT=true"
    return 0
  fi
  command -v su-exec >/dev/null 2>&1 \
    || fail "running as root but su-exec is not installed (apk add su-exec); set CP_STAY_ROOT=true only if you accept running everything as root"
  log "started as root: taking ownership of ${CP_STATE_DIR} and ${CP_HOME} for ${CP_RUN_UID}:${CP_RUN_GID}, then dropping privileges"
  mkdir -p "${CP_STATE_DIR}" "${CP_HOME}" "${CP_LOG_DIR}" "${CP_RUN_DIR}" "${CP_HOME}/cache" "${CP_HOME}/tf"
  local d
  for d in "${CP_STATE_DIR}" "${CP_HOME}" /terraform; do
    [ -d "$d" ] || continue
    if [ "$(stat -c %u "$d")" != "${CP_RUN_UID}" ] || [ "${CP_FORCE_CHOWN:-false}" = "true" ]; then
      log "chown -R ${CP_RUN_UID}:${CP_RUN_GID} $d"
      chown -R "${CP_RUN_UID}:${CP_RUN_GID}" "$d"
    fi
  done
  chmod 700 "${CP_STATE_DIR}"
  exec su-exec "${CP_RUN_UID}:${CP_RUN_GID}" env HOME="${CP_HOME}" "$0" "$@"
}

# ------------------------------------------------------------------------------
# Step -1: the state root
#
# Create or adopt $CP_STATE_DIR, refuse to run if it is not writable, warn if
# the PKI or etcd directories were pointed somewhere else, and keep a VERSION
# stamp so an accidental rollback of the image onto newer stored state fails
# before etcd or the API server get a chance to corrupt it.
# ------------------------------------------------------------------------------
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
  # Guard the layout itself before touching anything.
  case "${CP_STATE_DIR%/}" in
    "${CP_HOME%/}") fail "CP_STATE_DIR must not equal CP_HOME (${CP_HOME}); mount the volume at a subdirectory such as ${CP_HOME}/state" ;;
  esac
  local d
  for d in "${CP_LOG_DIR}" "${CP_RUN_DIR}" "${CP_HOME}/cache"; do
    case "${d%/}/" in "${CP_STATE_DIR%/}/"*) fail "CP_STATE_DIR (${CP_STATE_DIR}) must not contain ephemeral dir ${d}" ;; esac
  done

  mkdir -p "${CP_STATE_DIR}" 2>/dev/null || true
  [ -d "${CP_STATE_DIR}" ] || fail "state dir ${CP_STATE_DIR} does not exist and cannot be created"
  [ -w "${CP_STATE_DIR}" ] || fail "state dir ${CP_STATE_DIR} is not writable by uid $(id -u). Start the container as root (the image default) so the supervisor can chown the mount and drop to CP_RUN_UID, or chown it to $(id -u) yourself"
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
  stored=""; [ -f "${stamp}" ] && stored="$(cat "${stamp}")"
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
  printf '%s' "${keep}" > "${stamp}.tmp" && mv -f "${stamp}.tmp" "${stamp}"
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
     [ "$(cat "${CP_PKI_DIR}/apiserver.sans")" != "${sans}" ]; then
    log "issuing apiserver serving certificate for ${sans}"
    openssl genrsa -out "${CP_PKI_DIR}/apiserver.key" 2048 2>/dev/null
    openssl req -new -key "${CP_PKI_DIR}/apiserver.key" \
      -subj "/CN=kube-apiserver" -out "${CP_PKI_DIR}/apiserver.csr" 2>/dev/null
    openssl x509 -req -in "${CP_PKI_DIR}/apiserver.csr" \
      -CA "${CP_PKI_DIR}/ca.crt" -CAkey "${CP_PKI_DIR}/ca.key" -CAcreateserial \
      -out "${CP_PKI_DIR}/apiserver.crt" -days 3650 -sha256 \
      -extfile <(printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\n' "${sans}") 2>/dev/null
    rm -f "${CP_PKI_DIR}/apiserver.csr"
    printf '%s' "${sans}" > "${CP_PKI_DIR}/apiserver.sans"
  fi

  # ---- client certificates --------------------------------------------------
  # admin: O=system:masters, which RBAC treats as superuser.
  # controller-manager: a distinct identity, also system:masters for simplicity
  #   in a single-tenant control plane.
  issue_client_cert admin            "control-plane-admin"          "system:masters"
  issue_client_cert controller-manager "system:kube-controller-manager" "system:masters"

  # ---- static bearer token --------------------------------------------------
  # Convenient for clients that cannot carry a client certificate. NEVER
  # anonymous: --anonymous-auth=false is passed to the apiserver.
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

issue_client_cert() {
  local name="$1" cn="$2" org="$3"
  [ -f "${CP_PKI_DIR}/${name}.crt" ] && return 0
  log "issuing client certificate ${name} (CN=${cn}, O=${org})"
  openssl genrsa -out "${CP_PKI_DIR}/${name}.key" 2048 2>/dev/null
  openssl req -new -key "${CP_PKI_DIR}/${name}.key" \
    -subj "/O=${org}/CN=${cn}" -out "${CP_PKI_DIR}/${name}.csr" 2>/dev/null
  openssl x509 -req -in "${CP_PKI_DIR}/${name}.csr" \
    -CA "${CP_PKI_DIR}/ca.crt" -CAkey "${CP_PKI_DIR}/ca.key" -CAcreateserial \
    -out "${CP_PKI_DIR}/${name}.crt" -days 3650 -sha256 \
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
# Step 2: kube-apiserver
#
# Nodeless notes:
#   * --anonymous-auth=false, RBAC + Node authorizers, client-cert and static
#     token authn. Nothing is reachable unauthenticated.
#   * ServiceAccount admission needs the SA key pair even though nothing here
#     mounts a token into a Pod.
#   * No --enable-aggregator-routing: there is no kube-proxy to route to.
# ------------------------------------------------------------------------------
start_apiserver() {
  start_bg kube-apiserver "${CP_BIN_DIR}/kube-apiserver" \
    --etcd-servers "http://127.0.0.1:${CP_ETCD_CLIENT_PORT}" \
    --bind-address "${CP_APISERVER_BIND_ADDRESS}" \
    --secure-port "${CP_APISERVER_PORT}" \
    --advertise-address "${CP_APISERVER_ADVERTISE_ADDRESS}" \
    --tls-cert-file "${CP_PKI_DIR}/apiserver.crt" \
    --tls-private-key-file "${CP_PKI_DIR}/apiserver.key" \
    --client-ca-file "${CP_PKI_DIR}/ca.crt" \
    --token-auth-file "${CP_PKI_DIR}/tokens.csv" \
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
    --v=1

  wait_ready "kube-apiserver /readyz" "${CP_READY_TIMEOUT}" \
    kc get --raw=/readyz
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

  write_kubeconfig "${KUBECONFIG_INTERNAL}" "https://127.0.0.1:${CP_APISERVER_PORT}" admin
  write_kubeconfig "${KUBECONFIG_EXTERNAL}" "${external}" admin
  write_kubeconfig_token "${KUBECONFIG_EXTERNAL_TOKEN}" "${external}"

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
  log "  kubeconfig (external): ${KUBECONFIG_EXTERNAL_TOKEN} (bearer token)"
  # The token is a cluster-admin credential and this log stream is usually the
  # platform's deploy log, so print it only when explicitly asked. It is always
  # in the token kubeconfig above and in ${CP_PKI_DIR}/tokens.csv.
  if [ "${CP_LOG_ADMIN_TOKEN:-false}" = "true" ]; then
    log "  bearer token:          ${CP_ADMIN_TOKEN}"
  else
    log "  bearer token:          <hidden; set CP_LOG_ADMIN_TOKEN=true to print>"
  fi
  log "  logs:                  ${CP_LOG_DIR}"
  log "=============================================================="

  # Supervise: if any component dies, take the whole container down so the
  # platform restarts it. Partial control planes are worse than dead ones.
  local i
  while true; do
    for i in "${!PIDS[@]}"; do
      if ! kill -0 "${PIDS[$i]}" 2>/dev/null; then
        log "component ${NAMES[$i]} (pid ${PIDS[$i]}) exited -- tearing down"
        tail -n 40 "${CP_LOG_DIR}/${NAMES[$i]}.log" >&2 2>/dev/null || true
        exit 1
      fi
    done
    sleep 5
  done
}

main "$@"
