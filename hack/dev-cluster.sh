#!/usr/bin/env bash
# Recreate the local dev cluster used for live reconcile tests:
#   kind -> Crossplane core -> this provider's CRDs -> ProviderConfig from $RAILWAY_TOKEN.
# The provider itself runs out-of-cluster: `hack/run-provider.sh` (or `make run`).
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="${KIND_CLUSTER_NAME:-railway-dev}"
XP_VERSION="$(grep -E '^CROSSPLANE_VERSION' Makefile | awk -F'= ' '{print $2}')"
: "${RAILWAY_TOKEN:?set RAILWAY_TOKEN to a Railway workspace/account token (project tokens do not work)}"

kind get clusters | grep -qx "$NAME" || kind create cluster --name "$NAME" --wait 120s
kubectl config use-context "kind-$NAME"

helm repo add crossplane-stable https://charts.crossplane.io/stable >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install crossplane crossplane-stable/crossplane \
  --namespace crossplane-system --create-namespace --version "$XP_VERSION" --wait --timeout 5m

kubectl apply -f package/crds >/dev/null
kubectl -n crossplane-system create secret generic railway-creds \
  --from-literal=credentials="{\"token\":\"${RAILWAY_TOKEN}\"}" \
  --dry-run=client -o yaml | kubectl apply -f -
sed 's/example-creds/railway-creds/' examples/cluster/providerconfig/providerconfig.yaml | kubectl apply -f -

echo "cluster '$NAME' ready: $(kubectl get crds -o name | grep -c railway) railway CRDs, ProviderConfig/default"
