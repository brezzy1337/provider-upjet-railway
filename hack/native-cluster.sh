#!/usr/bin/env bash
# ==============================================================================
# Run the control plane as bare processes, with no container runtime.
#
# This is the Docker-less proof of cluster/images/control-plane: it fetches or
# builds exactly the pinned binaries the image ships, then hands them to the
# *same* supervisor (cluster/images/control-plane/control-plane.sh), so the
# flags proven here are the flags that ship.
#
# Nothing here needs privileges: there is no kubelet and no scheduler, so
# nothing ever tries to run a Pod. That is the whole reason a nodeless control
# plane works where kind or Docker cannot.
#
#   hack/native-cluster.sh build   # fetch/build every pinned binary
#   hack/native-cluster.sh up      # build if needed, then boot (foreground)
#   hack/native-cluster.sh verify  # one-shot assertions against a running plane
#   hack/native-cluster.sh down    # stop everything still holding .work/native
#   hack/native-cluster.sh clean   # down, then remove state (keeps binaries)
#
# Root path (what the image does on Railway): chown .work/native/state to root
# to imitate a platform mount, then
#   sudo -E env PATH="$PATH" hack/native-cluster.sh up
# The supervisor chowns the state root back to the checkout owner (CP_RUN_UID
# defaults to that uid here) and re-execs itself unprivileged; `verify` then
# asserts that no component runs as uid 0.
#
# RAILWAY_TOKEN: pass it to `up` as the image would receive it; a fake value
# (RAILWAY_TOKEN=fake_token-for-b4-test) exercises the handling, the provider
# just fails its reconciles. Pass the same value to `verify` to turn on the
# checks that need it (Secret contents, no trace in ps or logs).
#
# Memory: this host has no cgroup limit, so the harness passes a 4 GiB
# CP_MEMORY_LIMIT_BYTES by default to exercise the GOMEMLIMIT path; set it
# empty (CP_MEMORY_LIMIT_BYTES=) to test cgroup detection itself.
#
# Railway: set RAILWAY_SERVICE_ID=x RAILWAY_TCP_PROXY_DOMAIN=<host>
# RAILWAY_TCP_PROXY_PORT=<port>, all three, for `up` and again for `verify`, to
# exercise the platform defaults (proxy hostname in the serving cert, kubeconfig
# URL). verify then skips the two kubeconfig round trips, since the host does
# not resolve here.
#
# Composition functions (Phase 3): function-go-templating and function-auto-ready
# are built from source into $BIN like crossplane core and supervised as two
# more processes, listening with mTLS on 127.0.0.1:19450 and 127.0.0.1:19451
# (CP_FUNCTION_PORT_BASE, one port per name in CP_FUNCTIONS order). `verify`
# checks the processes, their certificate chains, the FunctionRevision
# registrations, and runs a round trip through hack/fixtures/functions-spike
# (XRD + Composition + XR rendering one Railway Project). The Project itself
# only reaches Ready with a real RAILWAY_TOKEN; with a fake one that step is a
# SKIP, the rendering and the deletion are still asserted.
#
# State lives in .work/native (gitignored). Set NATIVE_WORK to relocate.
# ==============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"

NATIVE_WORK="${NATIVE_WORK:-${REPO}/.work/native}"
BIN="${NATIVE_WORK}/bin"
SRC="${NATIVE_WORK}/src"
HOME_DIR="${NATIVE_WORK}/home"

# Pins. Keep in sync with cluster/images/control-plane/Dockerfile.
KUBERNETES_VERSION="${KUBERNETES_VERSION:-v1.35.8}"
ETCD_VERSION="${ETCD_VERSION:-v3.6.14}"
CROSSPLANE_VERSION="${CROSSPLANE_VERSION:-$(awk -F'= ' '/^CROSSPLANE_VERSION/{print $2}' Makefile)}"
FUNCTION_GO_TEMPLATING_VERSION="${FUNCTION_GO_TEMPLATING_VERSION:-$(awk -F'= ' '/^FUNCTION_GO_TEMPLATING_VERSION/{print $2}' Makefile)}"
FUNCTION_AUTO_READY_VERSION="${FUNCTION_AUTO_READY_VERSION:-$(awk -F'= ' '/^FUNCTION_AUTO_READY_VERSION/{print $2}' Makefile)}"
TERRAFORM_VERSION="${TERRAFORM_VERSION:-$(awk -F'= ' '/^export TERRAFORM_VERSION/{print $2}' Makefile)}"
TERRAFORM_PROVIDER_VERSION="${TERRAFORM_PROVIDER_VERSION:-$(awk -F'= ' '/^export TERRAFORM_PROVIDER_VERSION/{print $2}' Makefile)}"
TERRAFORM_PROVIDER_REPO="${TERRAFORM_PROVIDER_REPO:-https://github.com/terraform-community-providers/terraform-provider-railway}"

# Ports are shifted off the defaults so this can coexist with anything else.
export CP_APISERVER_PORT="${CP_APISERVER_PORT:-16443}"
export CP_ETCD_CLIENT_PORT="${CP_ETCD_CLIENT_PORT:-12379}"
export CP_ETCD_PEER_PORT="${CP_ETCD_PEER_PORT:-12380}"
export CP_CROSSPLANE_METRICS_PORT="${CP_CROSSPLANE_METRICS_PORT:-18080}"
export CP_CROSSPLANE_HEALTH_PORT="${CP_CROSSPLANE_HEALTH_PORT:-18081}"
export CP_PROVIDER_METRICS_PORT="${CP_PROVIDER_METRICS_PORT:-18090}"
# Composition functions: the supervisor gives the i-th name in CP_FUNCTIONS the
# port base+i on 127.0.0.1. CP_FUNCTIONS is exported only when the caller set
# it (set-and-empty disables the functions in the supervisor, which reads
# ${CP_FUNCTIONS-default}), so the supervisor's own default list is what is
# under test unless the caller says otherwise.
export CP_FUNCTION_PORT_BASE="${CP_FUNCTION_PORT_BASE:-19450}"
[ -z "${CP_FUNCTIONS+set}" ] || export CP_FUNCTIONS
# Mirror of the supervisor's defaults, for verify: the function list, and the
# port of the function at index i (0-based) in that list.
functions_list() { printf '%s' "${CP_FUNCTIONS-function-go-templating function-auto-ready}"; }
function_port() { printf '%s' "$(( CP_FUNCTION_PORT_BASE + $1 ))"; }

MIRROR="${NATIVE_WORK}/provider-mirror"
PLUGIN_DIR="${MIRROR}/registry.terraform.io/terraform-community-providers/railway/${TERRAFORM_PROVIDER_VERSION}/linux_amd64"

say() { printf '\n=== %s\n' "$*" >&2; }
# The supervisor's pid: bash running the script with no arguments, which is
# how both `up` and the image's re-exec leave it. Anchored, so a shell whose
# command line merely mentions the path (such as this probe) does not match.
sup_pid() { pgrep -f '^bash [^ ]*cluster/images/control-plane/control-plane\.sh$' | head -1; }
# etcd requires a client certificate from its own CA; verify borrows the
# supervisor's identity from the state root's PKI.
ectl() {
  "$BIN/etcdctl" --endpoints "https://127.0.0.1:${CP_ETCD_CLIENT_PORT}" \
    --cacert "${CP_STATE_DIR}/pki/etcd-ca.crt" \
    --cert "${CP_STATE_DIR}/pki/etcd-client-supervisor.crt" --key "${CP_STATE_DIR}/pki/etcd-client-supervisor.key" "$@"
}

# The supervisor shells out to these at boot; fail early instead of dying
# mid-PKI with a bare "shutting down".
need_tools() {
  local missing=() t
  for t in openssl curl ip hostname base64 stat git tar unzip; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  [ ${#missing[@]} -eq 0 ] || {
    echo "missing on PATH: ${missing[*]} (alpine: apk add openssl curl iproute2 coreutils git tar unzip)" >&2
    exit 1
  }
}

need_go() {
  command -v go >/dev/null 2>&1 || {
    echo "go is not on PATH (need $(awk -F'?= ' '/^GO_REQUIRED_VERSION/{print $2}' Makefile) or newer)" >&2
    exit 1
  }
}

build() {
  mkdir -p "$BIN" "$SRC" "$PLUGIN_DIR"
  local os=linux arch=amd64

  if [ ! -x "$BIN/kube-apiserver" ]; then
    say "fetching kube-apiserver ${KUBERNETES_VERSION}"
    curl -fsSLo "$BIN/kube-apiserver" \
      "https://dl.k8s.io/release/${KUBERNETES_VERSION}/bin/${os}/${arch}/kube-apiserver"
    chmod +x "$BIN/kube-apiserver"
  fi
  if [ ! -x "$BIN/kube-controller-manager" ]; then
    say "fetching kube-controller-manager ${KUBERNETES_VERSION}"
    curl -fsSLo "$BIN/kube-controller-manager" \
      "https://dl.k8s.io/release/${KUBERNETES_VERSION}/bin/${os}/${arch}/kube-controller-manager"
    chmod +x "$BIN/kube-controller-manager"
  fi
  if [ ! -x "$BIN/kubectl" ]; then
    say "fetching kubectl ${KUBERNETES_VERSION}"
    curl -fsSLo "$BIN/kubectl" \
      "https://dl.k8s.io/release/${KUBERNETES_VERSION}/bin/${os}/${arch}/kubectl"
    chmod +x "$BIN/kubectl"
  fi
  if [ ! -x "$BIN/etcd" ] || [ ! -x "$BIN/etcdutl" ]; then
    say "fetching etcd ${ETCD_VERSION}"
    curl -fsSL "https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-${os}-${arch}.tar.gz" \
      | tar -xz -C "$BIN" --strip-components=1 \
          "etcd-${ETCD_VERSION}-${os}-${arch}/etcd" "etcd-${ETCD_VERSION}-${os}-${arch}/etcdctl" \
          "etcd-${ETCD_VERSION}-${os}-${arch}/etcdutl"
  fi
  if [ ! -x "$BIN/terraform" ]; then
    say "fetching terraform ${TERRAFORM_VERSION}"
    curl -fsSLo "${NATIVE_WORK}/terraform.zip" \
      "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_${os}_${arch}.zip"
    unzip -oq "${NATIVE_WORK}/terraform.zip" -d "$BIN"
    rm -f "${NATIVE_WORK}/terraform.zip"
    chmod +x "$BIN/terraform"
  fi

  need_go

  if [ ! -x "$BIN/crossplane" ]; then
    say "building crossplane core v${CROSSPLANE_VERSION} from source"
    [ -d "$SRC/crossplane" ] || git clone --quiet --depth 1 \
      --branch "v${CROSSPLANE_VERSION}" https://github.com/crossplane/crossplane.git "$SRC/crossplane"
    ( cd "$SRC/crossplane" && CGO_ENABLED=0 go build -o "$BIN/crossplane" ./cmd/crossplane )
  fi

  # Composition functions ship as xpkg images, which a nodeless plane cannot
  # run, so they are built from their tags like crossplane core and supervised
  # as processes. Both build with a plain `go build .` at the tag root.
  local fn ver
  for fn in function-go-templating function-auto-ready; do
    case "$fn" in
      function-go-templating) ver="${FUNCTION_GO_TEMPLATING_VERSION}" ;;
      function-auto-ready)    ver="${FUNCTION_AUTO_READY_VERSION}" ;;
    esac
    if [ ! -x "$BIN/$fn" ]; then
      say "building ${fn} v${ver} from source"
      [ -d "$SRC/$fn" ] || git clone --quiet --depth 1 \
        --branch "v${ver}" "https://github.com/crossplane-contrib/${fn}.git" "$SRC/$fn"
      ( cd "$SRC/$fn" && CGO_ENABLED=0 go build -o "$BIN/$fn" . )
    fi
  done

  if [ ! -x "${PLUGIN_DIR}/terraform-provider-railway_v${TERRAFORM_PROVIDER_VERSION}" ]; then
    say "building patched terraform-provider-railway v${TERRAFORM_PROVIDER_VERSION}"
    # Upstream PR #93 is still open and no release (0.6.3 included) carries it,
    # so the released binary lacks the not-found fix Upjet's observe depends on.
    rm -rf "$SRC/terraform-provider-railway"
    git clone --quiet --branch "v${TERRAFORM_PROVIDER_VERSION}" \
      "${TERRAFORM_PROVIDER_REPO}" "$SRC/terraform-provider-railway"
    ( cd "$SRC/terraform-provider-railway" \
        && git -c user.email=build@local -c user.name=build am "${REPO}"/hack/upstream/*.patch \
        && CGO_ENABLED=0 go build \
             -o "${PLUGIN_DIR}/terraform-provider-railway_v${TERRAFORM_PROVIDER_VERSION}" . )
  fi

  say "building provider-upjet-railway"
  CGO_ENABLED=0 go build -o "$BIN/provider" ./cmd/provider

  cat > "${NATIVE_WORK}/terraformrc.hcl" <<EOF
provider_installation {
  filesystem_mirror {
    path    = "${MIRROR}"
    include = ["*/*"]
  }
  direct {
    exclude = ["*/*"]
  }
}
EOF

  stage_crds

  say "binaries ready in ${BIN}"
  "$BIN/etcd" --version | head -1
  "$BIN/kube-apiserver" --version
  "$BIN/kubectl" version --client 2>/dev/null | head -1
  "$BIN/terraform" version | head -1
  ls -l "$BIN/function-go-templating" "$BIN/function-auto-ready"
  ls -l "${PLUGIN_DIR}"
}

# Copy the CRDs the supervisor applies at boot into $HOME_DIR. Separate from
# build() because `clean` removes $HOME_DIR while keeping the binaries, so `up`
# must be able to restage without a rebuild.
stage_crds() {
  [ -d "$SRC/crossplane/cluster/crds" ] || {
    echo "crossplane source missing at $SRC/crossplane; run: $0 build" >&2; exit 1; }
  mkdir -p "${HOME_DIR}/crds"
  # Crossplane's own CRDs live in its source tree, not in a release artifact.
  rm -rf "${HOME_DIR}/crds/crossplane.new"
  cp -r "$SRC/crossplane/cluster/crds" "${HOME_DIR}/crds/crossplane.new"
  rm -rf "${HOME_DIR}/crds/crossplane"; mv "${HOME_DIR}/crds/crossplane.new" "${HOME_DIR}/crds/crossplane"
  rm -rf "${HOME_DIR}/crds/webhookconfigurations"
  cp -r "$SRC/crossplane/cluster/webhookconfigurations" "${HOME_DIR}/crds/webhookconfigurations"
  # This provider's CRDs, straight from the repo.
  rm -rf "${HOME_DIR}/crds/railway"
  mkdir -p "${HOME_DIR}/crds/railway"
  cp package/crds/*.yaml "${HOME_DIR}/crds/railway/"
  # Under a root run (see header) these files were just written by root; hand
  # them to the uid the supervisor will drop to, so a healthy boot needs no chown.
  if [ "$(id -u)" = "0" ] && [ -n "${CP_RUN_UID:-}" ]; then
    chown -R "${CP_RUN_UID}:${CP_RUN_GID:-${CP_RUN_UID}}" "${HOME_DIR}"
  fi
}

export_env() {
  export CP_HOME="${HOME_DIR}"
  export CP_BIN_DIR="${BIN}"
  # etcd + pki + VERSION under one root, like the image
  export CP_STATE_DIR="${CP_STATE_DIR:-${NATIVE_WORK}/state}"
  # When started as root, drop to the checkout's owner (not 65532, which could
  # not traverse the repository) unless the caller chose otherwise.
  # The gid comes from that user's primary group, not from the directory: a
  # codespace checkout is often user:root, and the supervisor refuses gid 0.
  # Mirror the supervisor's defaults so verify reads the same values it did.
  export CP_LOG_DIR="${CP_LOG_DIR:-${HOME_DIR}/log}"
  export CP_AUDIT_LOG_PATH="${CP_AUDIT_LOG_PATH:-${CP_LOG_DIR}/audit.log}"
  export CP_CLIENT_CERT_DAYS="${CP_CLIENT_CERT_DAYS:-90}"
  export CP_ETCD_QUOTA_BYTES="${CP_ETCD_QUOTA_BYTES:-2147483648}"
  export CP_ETCD_SNAPSHOT_KEEP="${CP_ETCD_SNAPSHOT_KEEP:-2}"
  # Unset: 4 GiB. Empty: let the supervisor read the (absent) cgroup limit.
  export CP_MEMORY_LIMIT_BYTES="${CP_MEMORY_LIMIT_BYTES-4294967296}"
  export CP_RUN_UID="${CP_RUN_UID:-$(stat -c %u "${REPO}")}"
  export CP_RUN_GID="${CP_RUN_GID:-$(id -g "${CP_RUN_UID}" 2>/dev/null || printf '%s' "${CP_RUN_UID}")}"
  export CP_CRD_DIRS="${HOME_DIR}/crds/railway"
  export CP_CROSSPLANE_CRDS_DIR="${HOME_DIR}/crds/crossplane"
  export CP_WEBHOOK_CONFIGS_DIR="${HOME_DIR}/crds/webhookconfigurations"
  export TF_CLI_CONFIG_FILE="${NATIVE_WORK}/terraformrc.hcl"
  export TERRAFORM_VERSION TERRAFORM_PROVIDER_VERSION
  export TERRAFORM_PROVIDER_SOURCE="${TERRAFORM_PROVIDER_SOURCE:-terraform-community-providers/railway}"
  export PATH="${BIN}:${PATH}"
}

up() {
  need_tools
  { [ -x "$BIN/provider" ] && [ -x "$BIN/etcdutl" ]; } || build
  export_env
  stage_crds
  say "booting control plane (Ctrl-C to stop)"
  exec cluster/images/control-plane/control-plane.sh
}

# Create a ConfigMap owned by another ConfigMap, delete the owner, and see
# whether the child is collected. Nothing here needs a node.
gc_probe() {
  local k=("$KUBECTL" --kubeconfig "$KC")
  "${k[@]}" create ns gc-probe --dry-run=client -o yaml | "${k[@]}" apply -f - >/dev/null
  "${k[@]}" -n gc-probe delete configmap gc-owner gc-owned --ignore-not-found >/dev/null 2>&1
  # Setup failures must be failures: without these guards a dead API server
  # made this probe PASS, because "gc-owned not found" was taken as collected.
  "${k[@]}" -n gc-probe create configmap gc-owner --from-literal=a=b >/dev/null || return 1
  local uid; uid="$("${k[@]}" -n gc-probe get configmap gc-owner -o jsonpath='{.metadata.uid}')"
  [ -n "$uid" ] || return 1
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: gc-owned\n  namespace: gc-probe\n  ownerReferences:\n  - apiVersion: v1\n    kind: ConfigMap\n    name: gc-owner\n    uid: %s\ndata:\n  a: b\n' "$uid" \
    | "${k[@]}" apply -f - >/dev/null || return 1
  "${k[@]}" -n gc-probe get configmap gc-owned >/dev/null 2>&1 || return 1
  "${k[@]}" -n gc-probe delete configmap gc-owner >/dev/null || return 1
  local i
  for i in $(seq 1 30); do
    "${k[@]}" -n gc-probe get configmap gc-owned >/dev/null 2>&1 || {
      "${k[@]}" delete ns gc-probe --wait=false >/dev/null 2>&1
      return 0
    }
    sleep 1
  done
  "${k[@]}" delete ns gc-probe --wait=false >/dev/null 2>&1
  return 1
}

# wait_until SECONDS cmd...: poll once a second, true as soon as cmd succeeds.
wait_until() {
  local n="$1" t; shift
  for t in $(seq 1 "$n"); do "$@" >/dev/null 2>&1 && return 0; sleep 1; done
  return 1
}

# Round trip through hack/fixtures/functions-spike: a Composition whose
# pipeline runs through both supervised functions must render a namespaced
# Railway Project from an XR, and deleting the XR must remove it again. Runs
# inside verify (it uses `check` and `fails`). Setup failures are failures, as
# in gc_probe: each step that a dead API server could fake is asserted on its
# own, and a failed setup step ends the probe instead of cascading.
functions_probe() {
  local k=("$BIN/kubectl" --kubeconfig "$KC") fx="${REPO}/hack/fixtures/functions-spike"
  local ns=functions-spike xr=spike comp=xrailwayproject.harness.railway.crossplane.io
  # Fully qualified resource names: the XRD's CRD may be seconds old when the
  # probe runs and short names depend on a discovery cache.
  local xrd=xrailwayprojects.harness.railway.crossplane.io xrk=xrailwayprojects.harness.railway.crossplane.io
  local want msg
  check "functions-spike XRD and Composition apply" "${k[@]}" apply -f "$fx/xrd.yaml" -f "$fx/composition.yaml" || return 0
  check "XRD ${xrd} is Established" \
    "${k[@]}" wait --for=condition=Established "compositeresourcedefinition.apiextensions.crossplane.io/${xrd}" --timeout=60s || return 0
  # ValidPipeline is set by the revision controller only after every function
  # in the pipeline has an active FunctionRevision advertising the composition
  # capability; it is the proof that the hand-written registrations are read.
  check "CompositionRevision of ${comp} reports ValidPipeline=True (functions advertise the composition capability)" \
    wait_until 60 bash -c '"$1" --kubeconfig "$2" get compositionrevision -l "crossplane.io/composition-name=$3" \
      -o jsonpath="{range .items[*]}{range .status.conditions[?(@.type==\"ValidPipeline\")]}{.status}{\"\n\"}{end}{end}" | grep -qx True' \
    _ "$BIN/kubectl" "$KC" "$comp" || return 0
  "${k[@]}" create ns "$ns" --dry-run=client -o yaml | "${k[@]}" apply -f - >/dev/null 2>&1
  # A leftover XR from an interrupted run would make "rendered" trivially true.
  "${k[@]}" -n "$ns" delete "$xrk" "$xr" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  wait_until 90 bash -c '! "$1" --kubeconfig "$2" -n "$3" get "$5" "$4" >/dev/null 2>&1' _ "$BIN/kubectl" "$KC" "$ns" "$xr" "$xrk" \
    || { printf 'FAIL  a previous functions-spike XR could not be removed before the round trip\n'; fails=$((fails+1)); return 0; }
  check "functions-spike XR applies" "${k[@]}" apply -f "$fx/xr.yaml" || return 0
  want="$("${k[@]}" -n "$ns" get "$xrk" "$xr" -o jsonpath='{.spec.name}' 2>/dev/null)"
  [ -n "$want" ] || { printf 'FAIL  XR %s has no spec.name to compare against\n' "$xr"; fails=$((fails+1)); return 0; }
  check "composition pipeline rendered the Project through function-go-templating" \
    wait_until 90 bash -c '"$1" --kubeconfig "$2" -n "$3" get project.railway.m.crossplane.io -l "crossplane.io/composite=$4" \
      -o jsonpath="{range .items[*]}{.spec.forProvider.name}{\"\n\"}{end}" | grep -qxF "$5"' _ "$BIN/kubectl" "$KC" "$ns" "$xr" "$want"
  if wait_until 60 bash -c '"$1" --kubeconfig "$2" -n "$3" get "$5" "$4" \
      -o jsonpath="{.status.conditions[?(@.type==\"Ready\")].status}" | grep -qx True' _ "$BIN/kubectl" "$KC" "$ns" "$xr" "$xrk"; then
    printf 'PASS  XR Ready (Project reconciled against Railway)\n'
  else
    msg="$("${k[@]}" -n "$ns" get project.railway.m.crossplane.io -l "crossplane.io/composite=$xr" \
      -o jsonpath='{.items[0].status.conditions[?(@.type=="Synced")].message}' 2>/dev/null)"
    if printf '%s' "$msg" | grep -qiE 'not authorized|401|authoriz|token'; then
      printf 'SKIP  XR Ready (the provider cannot create the Project with this RAILWAY_TOKEN; expected with the fake token)\n'
    else
      printf 'FAIL  XR Ready (Project reconciled against Railway)\n'; fails=$((fails+1))
      printf 'Project Synced condition: %s\n' "${msg:-<none yet>}" >&2
    fi
  fi
  "${k[@]}" -n "$ns" delete "$xrk" "$xr" --wait=false >/dev/null 2>&1 || true
  check "deleting the XR removes the composed Project" \
    wait_until 90 bash -c '[ -z "$("$1" --kubeconfig "$2" -n "$3" get project.railway.m.crossplane.io -l "crossplane.io/composite=$4" -o name 2>/dev/null)" ] \
      && ! "$1" --kubeconfig "$2" -n "$3" get "$5" "$4" >/dev/null 2>&1' _ "$BIN/kubectl" "$KC" "$ns" "$xr" "$xrk"
  "${k[@]}" delete ns "$ns" --wait=false >/dev/null 2>&1 || true
}

verify() {
  export_env
  local KC="${HOME_DIR}/kubeconfig"
  local k=("$BIN/kubectl" --kubeconfig "$KC")
  local fails=0
  check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then printf 'PASS  %s\n' "$desc"
    else printf 'FAIL  %s\n' "$desc"; fails=$((fails+1)); fi
  }

  say "verifying"
  # B1: the PKI and etcd must share the persistent state root, and the root
  # must carry the VERSION stamp that guards against image rollback.
  check "state root holds pki, etcd and VERSION" bash -c \
    "test -f '${CP_STATE_DIR}/pki/ca.crt' && test -d '${CP_STATE_DIR}/etcd/member' && grep -q '^kubernetes=v' '${CP_STATE_DIR}/VERSION'"
  check "state root is private (0700)" bash -c "test \"\$(stat -c %a '${CP_STATE_DIR}')\" = 700"
  check "VERSION stamp has non-empty etcd= and kubernetes= values" bash -c \
    "grep -qE '^etcd=[0-9]' '${CP_STATE_DIR}/VERSION' && grep -qE '^kubernetes=v[0-9]' '${CP_STATE_DIR}/VERSION'"
  # The property B1 exists for: cluster identity survives down/up. The first
  # verify records it; every later verify against the same state compares.
  local ident_file="${HOME_DIR}/identity.sha256" ident_now
  ident_now="$(cat "${CP_STATE_DIR}/pki/ca.crt" "${CP_STATE_DIR}/pki/tokens.csv" | sha256sum | cut -c1-64)"
  if [ -f "${ident_file}" ]; then
    check "cluster identity (CA + admin token) unchanged since first verify" test "$(cat "${ident_file}")" = "${ident_now}"
  else
    printf '%s\n' "${ident_now}" > "${ident_file}"
    check "cluster identity recorded for later restart comparison" test -s "${ident_file}"
  fi
  # B2: nothing in the control plane may run as root, however it was started.
  check "no control-plane process runs as uid 0" bash -c \
    "pids=\$(pgrep -f '${NATIVE_WORK}/bin/'); [ -n \"\$pids\" ] && ! ps -o uid= -p \$pids | grep -qx ' *0'"
  check "etcd healthy" ectl endpoint health
  check "apiserver /readyz" "${k[@]}" get --raw=/readyz
  check "apiserver rejects anonymous" bash -c \
    "curl -sk https://127.0.0.1:${CP_APISERVER_PORT}/api | grep -q Unauthorized"
  # Every CRD shipped under package/crds must be present, for both the
  # cluster-scoped group and the namespaced (.m.) group; compare against the
  # repo instead of a hard-coded count.
  local want_crds want_mcrds
  want_crds="$(ls package/crds/railway.crossplane.io_*.yaml | wc -l | tr -d ' ')"
  want_mcrds="$(ls package/crds/railway.m.crossplane.io_*.yaml | wc -l | tr -d ' ')"
  check "all ${want_crds} railway.crossplane.io CRDs present" bash -c \
    "'$BIN/kubectl' --kubeconfig '$KC' get crd -o name | grep -c '^customresourcedefinition.apiextensions.k8s.io/[a-z]*\\.railway\\.crossplane\\.io$' | grep -qx ${want_crds}"
  check "all ${want_mcrds} railway.m.crossplane.io CRDs present" bash -c \
    "'$BIN/kubectl' --kubeconfig '$KC' get crd -o name | grep -c '^customresourcedefinition.apiextensions.k8s.io/[a-z]*\\.railway\\.m\\.crossplane\\.io$' | grep -qx ${want_mcrds}"
  check "crossplane apiextensions CRDs present" "${k[@]}" get crd \
    compositeresourcedefinitions.apiextensions.crossplane.io \
    compositions.apiextensions.crossplane.io \
    compositionrevisions.apiextensions.crossplane.io
  check "crossplane core /readyz" curl -fsS "http://127.0.0.1:${CP_CROSSPLANE_HEALTH_PORT}/readyz"
  check "crossplane core /healthz" curl -fsS "http://127.0.0.1:${CP_CROSSPLANE_HEALTH_PORT}/healthz"
  check "provider metrics" curl -fsS "http://127.0.0.1:${CP_PROVIDER_METRICS_PORT}/metrics"
  check "provider controllers running" bash -c \
    "curl -fsS http://127.0.0.1:${CP_PROVIDER_METRICS_PORT}/metrics | grep -q 'controller_runtime_active_workers.*project'"
  local railway_sim=""
  [ -n "${RAILWAY_SERVICE_ID:-}" ] && [ -n "${RAILWAY_TCP_PROXY_DOMAIN:-}" ] && [ -n "${RAILWAY_TCP_PROXY_PORT:-}" ] && railway_sim=1
  if [ -z "${railway_sim}" ]; then
    check "external kubeconfig works from a clean environment" bash -c \
      "env -i PATH=/usr/bin:/bin '$BIN/kubectl' --kubeconfig '${HOME_DIR}/kubeconfig-external' get --raw=/version"
    check "bearer-token kubeconfig works" bash -c \
      "env -i PATH=/usr/bin:/bin '$BIN/kubectl' --kubeconfig '${HOME_DIR}/kubeconfig-external-token' get --raw=/version"
  else
    # The exported kubeconfigs point at the simulated proxy, which does not
    # resolve here; the Railway check further down asserts their contents.
    printf 'SKIP  external and bearer-token kubeconfig round trips (they point at the simulated Railway proxy)\n'
  fi

  # The mirror must hold the PATCHED build, not the v0.6.2 release. Two
  # fingerprints only the patched tree produces: a pseudo-version past the tag,
  # and gqlparser, which the patch's not_found.go is the sole reason to depend
  # on.
  local tfp="${PLUGIN_DIR}/terraform-provider-railway_v${TERRAFORM_PROVIDER_VERSION}"
  check "terraform mirror binary present" test -x "$tfp"
  if command -v go >/dev/null 2>&1; then
    check "terraform mirror is the PATCHED build (gqlparser dep)" bash -c \
      "go version -m '$tfp' | grep -q 'dep.*github.com/vektah/gqlparser'"
    # A tree with the patch committed on top of the tag reports either a
    # pseudo-version (vX.Y.Z-0.<timestamp>-<sha>) or "(devel)", never the bare
    # release version. Assert positively so an empty `go version -m` cannot pass.
    check "terraform mirror module version is (devel) or a pseudo-version, not the bare tag" bash -c \
      "go version -m '$tfp' | grep -qE 'mod\\s+github.com/terraform-community-providers/terraform-provider-railway\\s+(\\(devel\\)|v[0-9.]+-0\\.[0-9]{14}-[0-9a-f]+)'"
  fi
  check "terraform resolves the mirror (offline install)" bash -c \
    "d=\$(mktemp -d); printf 'terraform {\n required_providers {\n railway = {\n source = \"terraform-community-providers/railway\"\n version = \"${TERRAFORM_PROVIDER_VERSION}\"\n }\n }\n}\n' > \$d/main.tf; \
     cd \$d && TF_CLI_CONFIG_FILE='${NATIVE_WORK}/terraformrc.hcl' '$BIN/terraform' init -no-color -input=false >/dev/null; rc=\$?; rm -rf \$d; exit \$rc"

  # B3: Secrets are encrypted at rest, audited, and admin credentials are short.
  local probe=b3-probe
  kp() { "$BIN/kubectl" --kubeconfig "$KC" -n default "$@"; }
  kp delete secret "$probe" --ignore-not-found >/dev/null 2>&1 || true
  check "secrets are encrypted at rest (secretbox) in etcd" bash -c "$(declare -f kp ectl); BIN='$BIN' KC='$KC'
    kp create secret generic '$probe' --from-literal=k=v >/dev/null 2>&1 || exit 1
    v=\$(ectl get /registry/secrets/default/$probe --print-value-only | head -c 24)
    case \"\$v\" in k8s:enc:secretbox:v1:*) exit 0;; *) echo \"stored as: \$v\" >&2; exit 1;; esac"
  check "encryption key fingerprint stamped in the state root" bash -c "grep -qE '^[0-9a-f]{16}\$' '${CP_STATE_DIR}/ENCRYPTION'"
  check "audit log records the secret write at Metadata level without a body" bash -c "
    f='${CP_AUDIT_LOG_PATH}'; test -s \"\$f\" || exit 1
    l=\$(grep '\"name\":\"$probe\"' \"\$f\" | grep '\"verb\":\"create\"'); [ -n \"\$l\" ] || exit 1
    printf '%s' \"\$l\" | grep -q '\"level\":\"Metadata\"' && ! printf '%s' \"\$l\" | grep -q requestObject"
  # The exported admin cert must not outlive the policy (same predicate the supervisor uses).
  check "exported admin certificate does not outlive CP_CLIENT_CERT_DAYS (${CP_CLIENT_CERT_DAYS})" bash -c \
    "! openssl x509 -checkend $(( CP_CLIENT_CERT_DAYS * 86400 + 60 )) -noout -in '${CP_STATE_DIR}/pki/admin.crt'"
  check "in-container identity (control-plane-internal) is separate from the exported admin cert" bash -c \
    "openssl x509 -subject -noout -in '${CP_STATE_DIR}/pki/admin-internal.crt' | grep -q control-plane-internal && openssl x509 -subject -noout -in '${CP_STATE_DIR}/pki/admin.crt' | grep -q control-plane-admin"
  # TLS floor: positive control first (1.2 works), then the refusal.
  check "TLS 1.2 accepted and TLS 1.1 refused by the API server" bash -c \
    "curl -sk --tlsv1.2 --tls-max 1.2 -o /dev/null https://127.0.0.1:${CP_APISERVER_PORT}/ && ! curl -sk --tls-max 1.1 -o /dev/null https://127.0.0.1:${CP_APISERVER_PORT}/"
  kp delete secret "$probe" --ignore-not-found >/dev/null 2>&1 || true

  # B4: the Railway token must be in no component's environment, on no command
  # line and in no log, and the Secret made from it must hold exactly the JSON
  # the provider expects. The value-dependent checks run when verify itself has
  # RAILWAY_TOKEN set (to the value `up` was given); they read it from the
  # environment inside single-quoted bash -c scripts, so the probes never put
  # it on a command line either.
  local ns="${CP_CROSSPLANE_NAMESPACE:-crossplane-system}"
  # Same trim as the supervisor, so a padded value compares equal; exported so
  # the probes below see it (a plain shell variable would not reach them).
  if [ -n "${RAILWAY_TOKEN:-}" ]; then
    RAILWAY_TOKEN="${RAILWAY_TOKEN#"${RAILWAY_TOKEN%%[![:space:]]*}"}"
    RAILWAY_TOKEN="${RAILWAY_TOKEN%"${RAILWAY_TOKEN##*[![:space:]]}"}"
    export RAILWAY_TOKEN
  fi
  # Every process under the supervisor (components and, when present, the
  # terraform processes the provider forks; Go keeps argv[0] as "terraform",
  # so a path match would miss them) must lack RAILWAY_TOKEN. Fail closed: no
  # supervisor, no descendants or an unreadable environ is a FAIL, not a pass.
  check "RAILWAY_TOKEN is in no process under the supervisor (components and their children)" bash -c "$(declare -f sup_pid)"'
    descend() { local c; for c in $(pgrep -P "$1" || true); do echo "$c"; descend "$c"; done; }
    sup=$(sup_pid); [ -n "$sup" ] || { echo "no supervisor" >&2; exit 1; }
    pids=$(descend "$sup"); [ -n "$pids" ] || { echo "no processes under supervisor $sup" >&2; exit 1; }
    for p in $pids; do
      e=$(tr "\0" "\n" < "/proc/$p/environ") || { echo "cannot read environ of pid $p" >&2; exit 1; }
      if printf "%s\n" "$e" | grep -q "^RAILWAY_TOKEN="; then
        echo "pid $p: $(tr "\0" " " < "/proc/$p/cmdline" | cut -c1-80)" >&2; exit 1
      fi
    done'
  if [ -n "${RAILWAY_TOKEN:-}" ]; then
    # Positive control for the documented residual: the supervisor'"'"'s own
    # exec-time environment still holds the token (bash cannot scrub it). If
    # this ever fails, the residual was closed and the architecture page is stale.
    check "supervisor's own environ still holds RAILWAY_TOKEN (documented residual, pinned)" bash -c "$(declare -f sup_pid)"'
      sup=$(sup_pid); [ -n "$sup" ] || exit 1
      tr "\0" "\n" < "/proc/$sup/environ" | grep -qxF -- "RAILWAY_TOKEN=${RAILWAY_TOKEN}"'

    check "railway-creds Secret holds exactly {\"token\":\"<RAILWAY_TOKEN>\"} (verify needs the same RAILWAY_TOKEN as up)" bash -c '
      got=$("$1" --kubeconfig "$2" -n "$3" get secret railway-creds -o "go-template={{index .data \"credentials\"}}" | base64 -d)
      [ "$got" = "{\"token\":\"${RAILWAY_TOKEN}\"}" ]' _ "$BIN/kubectl" "$KC" "$ns"
    check "railway-creds carries no last-applied-configuration annotation (server-side apply)" bash -c \
      "! '$BIN/kubectl' --kubeconfig '$KC' -n '$ns' get secret railway-creds -o jsonpath='{.metadata.annotations}' | grep -q last-applied-configuration"
    check "ProviderConfig/default points at railway-creds" bash -c \
      "'$BIN/kubectl' --kubeconfig '$KC' get providerconfig.railway.crossplane.io default -o jsonpath='{.spec.credentials.secretRef.name}' | grep -qx railway-creds"
    # Namespaced managed resources (the ones a Composition renders) default to
    # ClusterProviderConfig/default in the .m. group; it must exist as well.
    check "ClusterProviderConfig/default (railway.m.crossplane.io) points at railway-creds" bash -c \
      "'$BIN/kubectl' --kubeconfig '$KC' get clusterproviderconfig.railway.m.crossplane.io default -o jsonpath='{.spec.credentials.secretRef.name}' | grep -qx railway-creds"
    check "RAILWAY_TOKEN value is on no process command line" bash -c '
      for f in /proc/[0-9]*/cmdline; do
        p=${f#/proc/}; p=${p%/cmdline}; [ "$p" = "$$" ] && continue
        c=$(tr "\0" " " < "$f" 2>/dev/null) || continue
        case "$c" in *"${RAILWAY_TOKEN}"*) echo "pid $p: ${c:0:80}" >&2; exit 1;; esac
      done'
    check "RAILWAY_TOKEN value appears in no log under CP_LOG_DIR (audit log included)" bash -c '
      ! grep -rqF -f <(printf "%s\n" "${RAILWAY_TOKEN}") "$1"' _ "${CP_LOG_DIR}"
  else
    printf 'SKIP  railway-creds Secret, annotation, ProviderConfig, ClusterProviderConfig, command-line, log and residual checks (RAILWAY_TOKEN unset for verify)\n'
  fi

  # B5: quota on etcd, snapshots on the volume, GOMEMLIMIT on every Go process.
  check "etcd runs with --quota-backend-bytes ${CP_ETCD_QUOTA_BYTES}" bash -c '
    p=$(pgrep -f "^$1/bin/etcd " | head -1); [ -n "$p" ] || exit 1
    tr "\0" "\n" < "/proc/$p/cmdline" | grep -A1 -x -- --quota-backend-bytes | grep -qx "$2"' _ "${NATIVE_WORK}" "${CP_ETCD_QUOTA_BYTES}"
  check "etcd has no alarm raised" bash -c "$(declare -f ectl); BIN='$BIN'"'
    out=$(ectl alarm list) || exit 1; [ -z "$out" ]'
  if [ -n "${CP_MEMORY_LIMIT_BYTES:-}" ]; then
    # Same table as gomemlimit_share in the supervisor (each enabled composition
    # function gets 3); the sum must stay under the limit.
    check "GOMEMLIMIT on every Go component is its share of CP_MEMORY_LIMIT_BYTES (sum under the limit)" bash -c '
      limit=$2; sum=0; fns=""
      for n in $3; do fns="$fns $n=3"; done
      for spec in kube-apiserver=35 etcd=15 provider=15 kube-controller-manager=10 crossplane=10 $fns; do
        n=${spec%=*}; pct=${spec#*=}
        p=$(pgrep -f "^$1/bin/$n " | head -1); [ -n "$p" ] || { echo "no $n" >&2; exit 1; }
        want="GOMEMLIMIT=$(( limit * pct / 100 / 1048576 ))MiB"
        tr "\0" "\n" < "/proc/$p/environ" | grep -qx "$want" || { echo "$n lacks $want" >&2; exit 1; }
        sum=$(( sum + limit * pct / 100 ))
      done
      [ "$sum" -lt "$limit" ]' _ "${NATIVE_WORK}" "${CP_MEMORY_LIMIT_BYTES}" "$(functions_list)"
  else
    printf 'SKIP  GOMEMLIMIT check (CP_MEMORY_LIMIT_BYTES empty: cgroup detection mode)\n'
  fi
  local snapdir="${CP_STATE_DIR}/snapshots"
  check "a snapshot exists under state/snapshots in a 0700 directory, mode 0600" bash -c '
    f=$(ls -1 "$1"/etcd-*.db 2>/dev/null | sort | tail -1); [ -n "$f" ] || exit 1
    [ "$(stat -c %a "$1")" = 700 ] && [ "$(stat -c %a "$f")" = 600 ]' _ "${snapdir}"
  # The pass runs in the background and SIGUSR1 is rate-limited to one a
  # minute, so a verify run straight after a boot or another verify waits.
  check "SIGUSR1 to the supervisor produces a new snapshot that etcdutl can read" bash -c "$(declare -f sup_pid)"'
    sup=$(sup_pid); [ -n "$sup" ] || exit 1
    last=$(ls -1 "$1"/etcd-*.db 2>/dev/null | sort | tail -1)
    for i in $(seq 1 90); do
      kill -USR1 "$sup" || exit 1
      sleep 2
      new=$(ls -1 "$1"/etcd-*.db 2>/dev/null | sort | tail -1)
      [ -n "$new" ] && [ "$new" != "$last" ] && [ ! -e "$new.part" ] && break
    done
    [ -n "$new" ] && [ "$new" != "$last" ] || { echo "no new snapshot" >&2; exit 1; }
    "$2" snapshot status "$new" -w table | grep -q -i revision' _ "${snapdir}" "$BIN/etcdutl"
  check "snapshots are pruned to CP_ETCD_SNAPSHOT_KEEP (${CP_ETCD_SNAPSHOT_KEEP})" bash -c '
    [ "$(ls -1 "$1"/etcd-*.db | wc -l)" -le "$2" ]' _ "${snapdir}" "${CP_ETCD_SNAPSHOT_KEEP}"

  # etcd client authentication (the B3 leftover): both loopback listeners take
  # TLS only, demand a client certificate, and trust only the etcd CA. The
  # refusals are asserted by cause (curl's TLS alert text), never by a timeout,
  # and each port gets a positive control with the supervisor's identity first.
  local pki="${CP_STATE_DIR}/pki"
  tls_refused() {   # tls_refused URL [curl identity flags...]: a TLS-level refusal, not a timeout
    local url="$1"; shift
    local err; err="$(curl -sS --http1.1 --max-time 5 --cacert "${pki}/etcd-ca.crt" "$@" "$url" 2>&1 >/dev/null)" && return 1
    printf '%s' "$err" | grep -qiE 'alert|handshake|certificate' && ! printf '%s' "$err" | grep -qi 'timed out'
  }
  plaintext_dropped() {   # a TLS-only listener closes a plaintext request without any HTTP reply (curl 52/56), never a timeout (28)
    local code rc; code="$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "$1")"; rc=$?
    [ "$code" = "000" ] && { [ "$rc" -eq 52 ] || [ "$rc" -eq 56 ]; }
  }
  check "etcd client port serves /health to the supervisor's certificate" bash -c "$(declare -f ectl)"'
    curl -fsS --max-time 5 --cacert "$1/etcd-ca.crt" --cert "$1/etcd-client-supervisor.crt" --key "$1/etcd-client-supervisor.key" \
      "https://127.0.0.1:$2/health" | grep -q "\"health\":\"true\""' _ "$pki" "${CP_ETCD_CLIENT_PORT}"
  check "etcd client port drops a plaintext request without an HTTP reply" bash -c "$(declare -f plaintext_dropped)"'
    plaintext_dropped "http://127.0.0.1:$1/health"' _ "${CP_ETCD_CLIENT_PORT}"
  check "etcd client port refuses a TLS client without a certificate (TLS alert)" bash -c "pki='$pki'; $(declare -f tls_refused)"'
    tls_refused "https://127.0.0.1:$1/health"' _ "${CP_ETCD_CLIENT_PORT}"
  check "etcd client port refuses a certificate from the cluster CA, admin-internal (TLS alert)" bash -c "pki='$pki'; $(declare -f tls_refused)"'
    [ -r "$pki/admin-internal.key" ] && tls_refused "https://127.0.0.1:$1/health" --cert "$pki/admin-internal.crt" --key "$pki/admin-internal.key"' _ "${CP_ETCD_CLIENT_PORT}"
  check "etcd peer port serves /members to the etcd-CA identity and refuses plaintext and certificate-less clients" bash -c "pki='$pki'; $(declare -f tls_refused plaintext_dropped)"'
    curl -fsS --http1.1 --max-time 5 --cacert "$pki/etcd-ca.crt" --cert "$pki/etcd-client-supervisor.crt" --key "$pki/etcd-client-supervisor.key" \
      "https://127.0.0.1:$1/members" | grep -q control-plane || { echo "positive control failed" >&2; exit 1; }
    plaintext_dropped "http://127.0.0.1:$1/members" || { echo "plaintext not dropped" >&2; exit 1; }
    tls_refused "https://127.0.0.1:$1/members"' _ "${CP_ETCD_PEER_PORT}"
  check "etcd member record carries the https peer URL" bash -c "$(declare -f ectl); BIN='$BIN'"'
    ectl member list | grep ", control-plane, " | grep -q ", https://127.0.0.1:$1, "' _ "${CP_ETCD_PEER_PORT}"
  check "etcd server certificate is signed by the etcd CA and not by the cluster CA" bash -c \
    'openssl verify -CAfile "$1/etcd-ca.crt" "$1/etcd-server.crt" >/dev/null 2>&1 && ! openssl verify -CAfile "$1/ca.crt" "$1/etcd-server.crt" >/dev/null 2>&1' _ "$pki"
  check "kube-apiserver reaches etcd over https with its own client certificate" bash -c '
    p=$(pgrep -f "^$1/bin/kube-apiserver " | head -1); [ -n "$p" ] || exit 1
    c=$(tr "\0" "\n" < "/proc/$p/cmdline")
    printf "%s\n" "$c" | grep -A1 -x -- --etcd-servers | grep -q "^https://127.0.0.1:" \
      && printf "%s\n" "$c" | grep -A1 -x -- --etcd-certfile | grep -q etcd-client-apiserver.crt' _ "${NATIVE_WORK}"

  # Railway platform defaults: with the proxy variables set for both up and
  # verify, the proxy hostname must be a SAN of the serving certificate and the
  # exported kubeconfig must point at https://domain:port.
  if [ -n "${railway_sim}" ]; then
    check "serving certificate carries the Railway TCP proxy hostname and the exported kubeconfig points at it" bash -c '
      openssl x509 -noout -ext subjectAltName -in "$1/pki/apiserver.crt" | tr "," "\n" | grep -qxF " DNS:$2" \
        && grep -qxF "    server: https://$2:$3" "$4/kubeconfig-external"' _ "${CP_STATE_DIR}" "${RAILWAY_TCP_PROXY_DOMAIN}" "${RAILWAY_TCP_PROXY_PORT:-}" "${HOME_DIR}"
  fi

  # Owner-reference cascading deletion is the garbage collector's job, and the
  # garbage collector lives in kube-controller-manager. Prove it actually runs.
  check "garbage collector collects orphaned children" bash -c "$(declare -f gc_probe); \
    KUBECTL='$BIN/kubectl' KC='$KC' gc_probe"

  # Phase 3: composition functions as supervised processes. Each function is a
  # gRPC server on loopback behind mTLS: its serving certificate is issued by
  # the supervisor under Crossplane's root CA (never the cluster CA), Crossplane
  # dials it with the client identity from crossplane-tls-client, and a paused
  # FunctionRevision with a hand-written status points the pipeline at the
  # loopback endpoint. Function servers enforce ALPN h2, so every TLS probe
  # offers it; refusals are asserted by the alert text, never by a timeout.
  local run_dir="${CP_RUN_DIR:-${HOME_DIR}/run}" root_ca="${CP_RUN_DIR:-${HOME_DIR}/run}/tls/root-ca/tls.crt"
  mtls_refused() {   # mtls_refused HOST:PORT [openssl identity flags...]: refused by a TLS alert (never a timeout, exit 124)
    local target="$1"; shift
    local out rc
    out="$(timeout 10 openssl s_client -alpn h2 -connect "$target" -CAfile "${root_ca}" -ign_eof "$@" 2>&1 </dev/null)"; rc=$?
    [ "$rc" -ne 124 ] && printf '%s' "$out" | grep -q 'SSL alert number'
  }
  local fn port idx=0
  [ -n "$(functions_list)" ] || printf 'SKIP  composition function checks and the functions-spike round trip (CP_FUNCTIONS set empty: functions disabled)\n'
  for fn in $(functions_list); do
    port="$(function_port "$idx")"; idx=$((idx+1))
    check "${fn} runs from \$BIN with --address 127.0.0.1:${port}" bash -c '
      p=$(pgrep -f "^$1/bin/$2 " | head -1); [ -n "$p" ] || exit 1
      c=$(tr "\0" "\n" < "/proc/$p/cmdline")
      printf "%s\n" "$c" | grep -qx -- "--address=127.0.0.1:$3" \
        || printf "%s\n" "$c" | grep -A1 -x -- --address | grep -qx "127.0.0.1:$3"' _ "${NATIVE_WORK}" "$fn" "$port"
    check "${fn} serving certificate verifies against Crossplane's root CA, not the cluster CA, and names IP 127.0.0.1" bash -c '
      c="$1/tls/functions/$2/tls.crt"; test -s "$c" || exit 1
      openssl verify -CAfile "$3" "$c" >/dev/null 2>&1 \
        && ! openssl verify -CAfile "$4/ca.crt" "$c" >/dev/null 2>&1 \
        && openssl x509 -noout -ext subjectAltName -in "$c" | grep -q "IP Address:127.0.0.1"' _ "$run_dir" "$fn" "$root_ca" "$pki"
    # TLS 1.3 reports "Verify return code: 0 (ok)" before the server has seen
    # the client certificate, so the chain check alone would pass without one;
    # with -ign_eof the refusal then shows as a post-handshake alert. Required:
    # the chain verifies, ALPN settled on h2, no alert arrived, and the server
    # sent its HTTP/2 SETTINGS frame (type 0x04 on stream 0), which only
    # happens once mTLS completed.
    check "${fn} completes an mTLS handshake (ALPN h2, no alert) with Crossplane's own client identity and answers with an HTTP/2 SETTINGS frame" bash -c '
      f=$(mktemp); timeout 5 openssl s_client -alpn h2 -connect "127.0.0.1:$3" -CAfile "$2" -cert "$1/tls/client/tls.crt" -key "$1/tls/client/tls.key" -ign_eof </dev/null >"$f" 2>&1
      grep -aq "Verify return code: 0 (ok)" "$f" && grep -aq "ALPN protocol: h2" "$f" && ! grep -aq "SSL alert number" "$f" \
        && od -An -tx1 "$f" | tr -d " \n" | grep -qE "0000[0-9a-f]{2}0400000000"; rc=$?
      rm -f "$f"; exit $rc' _ "$run_dir" "$root_ca" "$port"
    check "${fn} refuses a TLS client without a certificate (TLS alert)" bash -c "root_ca='$root_ca'; $(declare -f mtls_refused)"'
      mtls_refused "127.0.0.1:$1"' _ "$port"
    check "${fn} refuses a client certificate from the cluster CA, admin-internal (TLS alert)" bash -c "root_ca='$root_ca'; $(declare -f mtls_refused)"'
      [ -r "$2/admin-internal.key" ] && mtls_refused "127.0.0.1:$1" -cert "$2/admin-internal.crt" -key "$2/admin-internal.key"' _ "$port" "$pki"
    check "Function/${fn} exists" "${k[@]}" get function.pkg.crossplane.io "$fn"
    check "FunctionRevision/${fn}-local is Active, paused, endpoint 127.0.0.1:${port}, capability composition" bash -c '
      set -- $("$1" --kubeconfig "$2" get functionrevision.pkg.crossplane.io "$3-local" \
        -o go-template="{{.spec.desiredState}} {{index .metadata.annotations \"crossplane.io/paused\"}} {{.status.endpoint}} {{range .status.capabilities}}{{.}},{{end}}") "$4" || exit 1
      [ "$1" = Active ] && [ "$2" = true ] && [ "$3" = "127.0.0.1:$5" ] && case ",$4" in *,composition,*) exit 0;; esac; exit 1' \
      _ "$BIN/kubectl" "$KC" "$fn" "$port"
  done
  [ -z "$(functions_list)" ] || functions_probe

  say "cluster contents"
  "${k[@]}" get crd -o name | wc -l | xargs printf 'CRDs: %s\n'
  "${k[@]}" get providerconfig.railway.crossplane.io 2>&1 | head -3 || true
  "${k[@]}" get functionrevision.pkg.crossplane.io 2>&1 | head -4 || true

  [ "$fails" -eq 0 ] || { echo "$fails check(s) failed" >&2; return 1; }
  say "all checks passed"
}

down() {
  # Kill anything still holding this work directory. A half-dead control plane
  # keeps port 6443/etcd bound and the next `up` fails with "address in use".
  local pids
  pids="$(pgrep -f "${NATIVE_WORK}/bin/" 2>/dev/null | tr '\n' ' ' || true)"
  [ -n "${pids// /}" ] || { say "nothing running"; return 0; }
  say "stopping: ${pids}"
  # shellcheck disable=SC2086
  kill -TERM $pids 2>/dev/null || true
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f "${NATIVE_WORK}/bin/" >/dev/null 2>&1 || break
    sleep 1
  done
  pids="$(pgrep -f "${NATIVE_WORK}/bin/" 2>/dev/null | tr '\n' ' ' || true)"
  # shellcheck disable=SC2086
  [ -z "${pids// /}" ] || kill -KILL $pids 2>/dev/null || true
  say "stopped"
}

clean() {
  down
  rm -rf "${HOME_DIR}" "${NATIVE_WORK}/state" "${NATIVE_WORK}/etcd"
  say "removed ${HOME_DIR} and ${NATIVE_WORK}/state (binaries in ${BIN} kept)"
}

case "${1:-up}" in
  build)  build ;;
  up)     up ;;
  verify) verify ;;
  down)   down ;;
  clean)  clean ;;
  *) echo "usage: $0 {build|up|verify|down|clean}" >&2; exit 1 ;;
esac
