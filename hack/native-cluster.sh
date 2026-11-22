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

MIRROR="${NATIVE_WORK}/provider-mirror"
PLUGIN_DIR="${MIRROR}/registry.terraform.io/terraform-community-providers/railway/${TERRAFORM_PROVIDER_VERSION}/linux_amd64"

say() { printf '\n=== %s\n' "$*" >&2; }

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
  if [ ! -x "$BIN/etcd" ]; then
    say "fetching etcd ${ETCD_VERSION}"
    curl -fsSL "https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-${os}-${arch}.tar.gz" \
      | tar -xz -C "$BIN" --strip-components=1 \
          "etcd-${ETCD_VERSION}-${os}-${arch}/etcd" "etcd-${ETCD_VERSION}-${os}-${arch}/etcdctl"
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
  [ -x "$BIN/provider" ] || build
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
  check "etcd healthy" env ETCDCTL_API=3 "$BIN/etcdctl" \
    --endpoints "http://127.0.0.1:${CP_ETCD_CLIENT_PORT}" endpoint health
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
  check "external kubeconfig works from a clean environment" bash -c \
    "env -i PATH=/usr/bin:/bin '$BIN/kubectl' --kubeconfig '${HOME_DIR}/kubeconfig-external' get --raw=/version"
  check "bearer-token kubeconfig works" bash -c \
    "env -i PATH=/usr/bin:/bin '$BIN/kubectl' --kubeconfig '${HOME_DIR}/kubeconfig-external-token' get --raw=/version"

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

  # Owner-reference cascading deletion is the garbage collector's job, and the
  # garbage collector lives in kube-controller-manager. Prove it actually runs.
  check "garbage collector collects orphaned children" bash -c "$(declare -f gc_probe); \
    KUBECTL='$BIN/kubectl' KC='$KC' gc_probe"

  say "cluster contents"
  "${k[@]}" get crd -o name | wc -l | xargs printf 'CRDs: %s\n'
  "${k[@]}" get providerconfig.railway.crossplane.io 2>&1 | head -3 || true

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
