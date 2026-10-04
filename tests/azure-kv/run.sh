#!/usr/bin/env bash
# SPIRE -> Entra ID -> Azure Key Vault tests.
#
#   ./run.sh              run every case
#   ./run.sh <case>...    run selected cases: allowed denied-secret wrong-sa sdk
#   ./run.sh shell        start the interactive kv-shell pod and print how to use it
#   ./run.sh cleanup      delete the kv-shell pod and the test service accounts
#
# Reads the managed identity, tenant, vault URI and secret names from azure/terraform outputs
# (enable_spire_keyvault = true). Pods are deleted after each case.
set -euo pipefail
cd "$(dirname "$0")"

TF_DIR=../../azure/terraform
NS=spire-demo
CURL_IMAGE=curlimages/curl:8.16.0
PYTHON_IMAGE=python:3.13-slim

tf() { terraform -chdir="$TF_DIR" output -raw "$1"; }
tfjson() { terraform -chdir="$TF_DIR" output -json "$1"; }

# case -> service-account secret mode expectation
#   allowed          rest: token exchange ok, KV_GET=200 with the expected value
#   denied-secret    rest: token exchange ok, KV_GET=403 ForbiddenByRbac (RBAC is on one secret only)
#   AADSTS<code>     token exchange refused with exactly this Entra error
#   sdk              sdk:  DefaultAzureCredential reads the secret, KV_GET=200 with the expected value
case_def() {
  case $1 in
    allowed)       echo "kv-reader    $ALLOWED rest allowed" ;;
    denied-secret) echo "kv-reader    $DENIED  rest denied" ;;
    wrong-sa)      echo "azure-client $ALLOWED rest AADSTS700213" ;;
    sdk)           echo "kv-reader    $ALLOWED sdk  allowed" ;;
    *) echo "unknown case: $1" >&2; exit 2 ;;
  esac
}
ORDER=(allowed denied-secret wrong-sa sdk)

ensure_ns_sa() {
  kubectl get namespace "$NS" >/dev/null 2>&1 || {
    kubectl create namespace "$NS" >/dev/null
    kubectl label namespace "$NS" pod-security.kubernetes.io/enforce=restricted >/dev/null
  }
  kubectl -n "$NS" get serviceaccount "$1" >/dev/null 2>&1 || kubectl -n "$NS" create serviceaccount "$1" >/dev/null
}

if [[ "${1:-}" == "cleanup" ]]; then
  kubectl -n "$NS" delete pod/kv-shell configmap/kv-shell serviceaccount/kv-reader --ignore-not-found
  exit 0
fi

export TENANT_ID CLIENT_ID VAULT_URI NS
TENANT_ID=$(tf tenant_id)
CLIENT_ID=$(tf spire_kv_client_id)
VAULT_URI=$(tf spire_kv_vault_uri)
[[ -n "$CLIENT_ID" && "$CLIENT_ID" != "null" ]] || { echo "spire_kv_client_id is empty: enable_spire_keyvault and apply first"; exit 1; }
VAULT_URI=${VAULT_URI%/}
ALLOWED=$(tfjson spire_kv_secret_names | jq -r .allowed)
DENIED=$(tfjson spire_kv_secret_names | jq -r .denied)
KV_SPIFFE_ID=$(tfjson spire_kv_federated_credential | jq -r .subject)
EXPECTED_VALUE=demo-db-password-read-with-a-spire-svid

if [[ "${1:-}" == "shell" ]]; then
  ensure_ns_sa kv-reader
  export SYNC_SECRETS="$ALLOWED"
  envsubst '${NS} ${TENANT_ID} ${CLIENT_ID} ${VAULT_URI} ${SYNC_SECRETS}' <shell.yaml.tmpl | kubectl apply -f - >/dev/null
  kubectl -n "$NS" wait pod/kv-shell --for=condition=Ready --timeout=180s >/dev/null
  cat <<EOF
kv-shell is ready (runs as $KV_SPIFFE_ID). Try:

  kubectl -n $NS logs kv-shell -c secret-sync          # every sync: "$ALLOWED: synced to /secrets/$ALLOWED"
  kubectl -n $NS exec -it kv-shell -c shell -- sh
    ls -la /secrets                       # tmpfs, written by the secret-sync sidecar
    cat /secrets/$ALLOWED
    svid                                  # the JWT-SVID that's swapped for the Key Vault token
    kv-get $ALLOWED                       # allowed
    kv-get $DENIED                        # HTTP 403 ForbiddenByRbac
    mount | grep -E '/secrets|/svid'      # both tmpfs: nothing on disk, nothing in etcd

Remove it with: ./run.sh cleanup
EOF
  exit 0
fi

[[ $# -gt 0 ]] && ORDER=("$@")

fail=0
for c in "${ORDER[@]}"; do
  def=$(case_def "$c")
  read -r SA SECRET_NAME MODE EXPECT <<<"$def"
  IMAGE=$CURL_IMAGE; [[ $MODE == sdk ]] && IMAGE=$PYTHON_IMAGE
  export SA SECRET_NAME MODE IMAGE NAME="kv-$c"
  echo "=== $c: spiffe://.../ns/$NS/sa/$SA reads '$SECRET_NAME' via $MODE (expect $EXPECT)"
  ensure_ns_sa "$SA"
  envsubst '${NS} ${SA} ${SECRET_NAME} ${MODE} ${IMAGE} ${NAME} ${TENANT_ID} ${CLIENT_ID} ${VAULT_URI}' <pod.yaml.tmpl \
    | kubectl apply -f - >/dev/null
  kubectl -n "$NS" wait "pod/$NAME" --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s >/dev/null
  out=$(kubectl -n "$NS" logs "$NAME" -c kv)
  echo "$out" | sed 's/^/    /'
  kubectl -n "$NS" delete pod "$NAME" --wait=false >/dev/null
  kubectl -n "$NS" delete configmap "$NAME-helper" >/dev/null

  # Only meaningful if the pod presented a real SVID for the expected identity.
  if ! grep -q "^SVID=.*\"sub\":\"spiffe://[^\"]*/ns/$NS/sa/$SA\"" <<<"$out"; then
    echo "    FAIL (no SVID for ns/$NS/sa/$SA was presented)"; fail=1; continue
  fi
  case $EXPECT in
    allowed) grep -q '^TOKEN_EXCHANGE=ok' <<<"$out" && grep -qx "KV_GET=200 $EXPECTED_VALUE" <<<"$out" ;;
    denied)  grep -q '^TOKEN_EXCHANGE=ok' <<<"$out" && grep -q '^KV_GET=403 ForbiddenByRbac' <<<"$out" ;;
    *)       grep -q "^TOKEN_EXCHANGE=failed $EXPECT\$" <<<"$out" ;;
  esac && echo "    PASS" || { echo "    FAIL (expected $EXPECT)"; fail=1; }
done
exit $fail
