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

# ------------------------------------------------------------------------------
# Configuration (every value overridable from the environment)
# ------------------------------------------------------------------------------
CP_HOME="${CP_HOME:-/var/lib/control-plane}"
CP_BIN_DIR="${CP_BIN_DIR:-/usr/local/bin}"
CP_LOG_DIR="${CP_LOG_DIR:-${CP_HOME}/log}"
CP_PKI_DIR="${CP_PKI_DIR:-${CP_HOME}/pki}"
CP_RUN_DIR="${CP_RUN_DIR:-${CP_HOME}/run}"

# etcd data lives on a mounted volume; keep it out of $CP_HOME by default.
CP_ETCD_DATA_DIR="${CP_ETCD_DATA_DIR:-/var/lib/etcd}"
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
  "$@" >>"${CP_LOG_DIR}/${name}.log" 2>&1 &
  local pid=$!
  PIDS+=("$pid")
  NAMES+=("$name")
  log "${name} pid=${pid} log=${CP_LOG_DIR}/${name}.log"
}

shutdown() {
  local rc=$?
  trap - EXIT TERM INT
  log "shutting down"
  local i
  for (( i=${#PIDS[@]}-1; i>=0; i-- )); do
    kill -TERM "${PIDS[$i]}" 2>/dev/null || true
  done
  for (( i=${#PIDS[@]}-1; i>=0; i-- )); do
    wait "${PIDS[$i]}" 2>/dev/null || true
  done
  exit "$rc"
}

kc() { "${CP_BIN_DIR}/kubectl" --kubeconfig "${KUBECONFIG_INTERNAL}" "$@"; }

# ------------------------------------------------------------------------------
# Step 0: PKI + auth material
#
# Persisted under $CP_PKI_DIR so that restarts keep the same CA and the
# kubeconfig handed out to clients stays valid. The serving certificate is
# regenerated whenever the requested SAN set changes (e.g. once the Railway TCP
# proxy hostname is known).
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
  if [ ! -f "${CP_PKI_DIR}/tokens.csv" ]; then
    local tok="${CP_ADMIN_TOKEN:-}"
    [ -n "${tok}" ] || tok="$(openssl rand -hex 32)"
    printf '%s,control-plane-admin,control-plane-admin,"system:masters"\n' "${tok}" \
      > "${CP_PKI_DIR}/tokens.csv"
    chmod 600 "${CP_PKI_DIR}/tokens.csv"
  fi
  CP_ADMIN_TOKEN="$(cut -d, -f1 "${CP_PKI_DIR}/tokens.csv")"
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
  # On a platform-mounted volume the directory may exist already and be owned by
  # root while this container runs as 65532. Fail here with something readable
  # rather than deep inside etcd.
  mkdir -p "${CP_ETCD_DATA_DIR}" 2>/dev/null || true
  [ -d "${CP_ETCD_DATA_DIR}" ] || fail "etcd data dir ${CP_ETCD_DATA_DIR} does not exist and cannot be created"
  [ -w "${CP_ETCD_DATA_DIR}" ] || fail "etcd data dir ${CP_ETCD_DATA_DIR} is not writable by uid $(id -u) -- chown the volume or run this image as root"
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
    --secure-port 10257 \
    --profiling=false \
    --v=1

  wait_ready "kube-controller-manager" "${CP_READY_TIMEOUT}" \
    kc get --raw=/readyz
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
  [ -d "$d" ] || { log "skipping missing CRD dir $d"; return 0; }
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
  mkdir -p "${CP_HOME}" "${CP_LOG_DIR}" "${CP_RUN_DIR}" "${CP_HOME}/cache"
  trap shutdown EXIT TERM INT

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
