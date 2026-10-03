#!/usr/bin/env bash
# SPIRE -> Entra ID workload identity tests.
#
#   ./run.sh              run every case
#   ./run.sh <case>...    run selected cases: allowed wrong-sa wrong-ns wrong-audience kube-viewer
#   ./run.sh shell        start an interactive pod (svid, kube-token, ekubectl) and print the exec command
#   ./run.sh cleanup      delete the test namespaces
#
# Reads the managed identity, tenant, blob URL and kube-apiserver app ID from azure/terraform
# outputs (enable_spire_workload_identity = true). Pods are deleted after each case; the
# namespaces and service accounts are left for re-runs.
set -euo pipefail
cd "$(dirname "$0")"

TF_DIR=../../azure/terraform
AZURE_AUDIENCE="api://AzureADTokenExchange"
KUBECTL_VERSION=v1.36.5

tf() { terraform -chdir="$TF_DIR" output -raw "$1"; }

cleanup() {
  kubectl delete namespace spire-demo spire-demo-other --ignore-not-found --wait=false
}

# case -> namespace service-account audience mode expectation
#   allowed          storage: token exchange ok, blob read 200, blob write 403
#   kube-viewer      kube: token exchange ok, whoami entra:role:Cluster.Viewer, list pods 200, create configmap 403
#   AADSTS<code>     token exchange refused with exactly this Entra error
#     700213  no federated credential matches the assertion's subject
#     700212  no federated credential matches the assertion's audience
case_def() {
  case $1 in
    allowed)        echo "spire-demo azure-client $AZURE_AUDIENCE storage allowed" ;;
    wrong-sa)       echo "spire-demo other-client $AZURE_AUDIENCE storage AADSTS700213" ;;
    wrong-ns)       echo "spire-demo-other azure-client $AZURE_AUDIENCE storage AADSTS700213" ;;
    wrong-audience) echo "spire-demo azure-client api://not-azure storage AADSTS700212" ;;
    kube-viewer)    echo "spire-demo azure-client $AZURE_AUDIENCE kube viewer" ;;
    *) echo "unknown case: $1" >&2; exit 2 ;;
  esac
}
ORDER=(allowed wrong-sa wrong-ns wrong-audience kube-viewer)

ensure_ns_sa() {
  local ns=$1 sa=$2
  kubectl get namespace "$ns" >/dev/null 2>&1 || {
    kubectl create namespace "$ns" >/dev/null
    kubectl label namespace "$ns" pod-security.kubernetes.io/enforce=restricted >/dev/null
  }
  kubectl -n "$ns" get serviceaccount "$sa" >/dev/null 2>&1 || kubectl -n "$ns" create serviceaccount "$sa" >/dev/null
}

if [[ "${1:-}" == "cleanup" ]]; then cleanup; exit 0; fi

export TENANT_ID CLIENT_ID BLOB_URL KUBE_APP_ID KUBECTL_VERSION
TENANT_ID=$(tf tenant_id)
CLIENT_ID=$(tf spire_client_id)
BLOB_URL=$(tf spire_test_blob_url)
KUBE_APP_ID=$(tf kube_apiserver_client_id)
[[ -n "$CLIENT_ID" && "$CLIENT_ID" != "null" ]] || { echo "spire_client_id is empty: enable_spire_workload_identity and apply first"; exit 1; }

if [[ "${1:-}" == "shell" ]]; then
  export NS=spire-demo
  ensure_ns_sa "$NS" azure-client
  # shellcheck disable=SC2016 # literal ${VAR} list: tells envsubst which variables to replace
  envsubst '${NS} ${TENANT_ID} ${CLIENT_ID} ${KUBE_APP_ID} ${KUBECTL_VERSION}' <shell.yaml.tmpl | kubectl apply -f - >/dev/null
  kubectl -n "$NS" wait pod/fic-shell --for=condition=Ready --timeout=180s >/dev/null
  cat <<EOF
fic-shell is ready. Try:

  kubectl -n $NS exec -it fic-shell -c shell -- sh
    svid                      # JWT-SVID claims (iss, sub, aud)
    kube-token | cut -c1-40   # SVID exchanged for an Entra token for homelab-kube-apiserver
    ekubectl auth whoami      # entra:<managed-identity-oid>, entra:role:Cluster.Viewer
    ekubectl get pods -n $NS  # allowed (view)
    ekubectl create configmap x -n $NS   # forbidden (view is read-only)

Remove it with: kubectl -n $NS delete pod/fic-shell configmap/fic-shell
EOF
  exit 0
fi

[[ $# -gt 0 ]] && ORDER=("$@")

fail=0
for c in "${ORDER[@]}"; do
  def=$(case_def "$c")
  read -r NS SA AUDIENCE MODE EXPECT <<<"$def"
  export NS SA AUDIENCE MODE NAME="fic-$c"
  echo "=== $c: spiffe://.../ns/$NS/sa/$SA, aud=$AUDIENCE, $MODE (expect $EXPECT)"
  ensure_ns_sa "$NS" "$SA"
  # shellcheck disable=SC2016 # literal ${VAR} list: tells envsubst which variables to replace
  envsubst '${NS} ${SA} ${AUDIENCE} ${MODE} ${NAME} ${TENANT_ID} ${CLIENT_ID} ${BLOB_URL} ${KUBE_APP_ID}' <pod.yaml.tmpl | kubectl apply -f - >/dev/null
  kubectl -n "$NS" wait "pod/$NAME" --for=jsonpath='{.status.phase}'=Succeeded --timeout=180s >/dev/null
  out=$(kubectl -n "$NS" logs "$NAME" -c azure)
  # shellcheck disable=SC2001 # indents every line of multi-line output
  echo "$out" | sed 's/^/    /'
  kubectl -n "$NS" delete pod "$NAME" --wait=false >/dev/null
  kubectl -n "$NS" delete configmap "$NAME-helper" >/dev/null

  # Every case must have presented a real SVID for the expected identity and audience,
  # otherwise a "denied" result proves nothing.
  svid_ok=0
  grep -q "^SVID=.*\"sub\":\"spiffe://[^\"]*/ns/$NS/sa/$SA\"" <<<"$out" && grep -q "\"aud\":\[\"$AUDIENCE\"\]" <<<"$out" && svid_ok=1

  if [[ $svid_ok -ne 1 ]]; then
    echo "    FAIL (no SVID for ns/$NS/sa/$SA with aud $AUDIENCE was presented)"; fail=1
  elif [[ $EXPECT == allowed ]]; then
    if grep -q '^TOKEN_EXCHANGE=ok' <<<"$out" && grep -q '^BLOB_READ=200' <<<"$out" && grep -q '^BLOB_WRITE=403' <<<"$out"; then
      echo "    PASS"
    else
      echo "    FAIL"; fail=1
    fi
  elif [[ $EXPECT == viewer ]]; then
    if grep -q '^TOKEN_EXCHANGE=ok' <<<"$out" \
      && grep -q '^KUBE_WHOAMI=201 .*"entra:role:Cluster.Viewer"' <<<"$out" \
      && grep -q '^KUBE_LIST_PODS=200' <<<"$out" \
      && grep -q '^KUBE_CREATE_CONFIGMAP=403' <<<"$out"; then
      echo "    PASS"
    else
      echo "    FAIL"; fail=1
    fi
  elif grep -q "^TOKEN_EXCHANGE=failed $EXPECT\$" <<<"$out"; then
    echo "    PASS"
  else
    echo "    FAIL (expected $EXPECT)"; fail=1
  fi
done
exit $fail
