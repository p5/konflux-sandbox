#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ../runtime/context.sh
: "${KUBECONFIG:=/tmp/konflux-sandbox-runtime/vm-kubeconfig}"
require_runtime_context "$KUBECONFIG" kind-konflux-sandbox-vm-prototype
root=$(cd ../.. && pwd)
results="$root/.prototype-results/firewall"
state="$root/.prototype-state/firewall"
namespace=foundation-firewall-prototype
node=konflux-sandbox-vm-prototype-control-plane
k() { runtime_k "$@"; }
[[ -z $(k get namespace "$namespace" --ignore-not-found -o name) ]]
k create namespace "$namespace" -o json > "$state/rejection-namespace.json"
uid=$(jq -r .metadata.uid "$state/rejection-namespace.json")
owned=true
cleanup() {
  if [[ "$owned" == true && $(k get namespace "$namespace" -o jsonpath='{.metadata.uid}' 2>/dev/null) == "$uid" ]]; then
    k delete namespace "$namespace" --wait=true --timeout=60s >/dev/null
  fi
}
trap cleanup EXIT
k -n "$namespace" create configmap ownership-sentinel --from-literal=fixture=keep
if FIREWALL_RESULTS_DIR="$results/failure-ownership" bash ./run.sh > "$results/failure-ownership-driver.log" 2>&1; then
  echo 'FAIL unowned namespace accepted'; exit 1
fi
[[ $(k get namespace "$namespace" -o jsonpath='{.metadata.uid}') == "$uid" ]]
k -n "$namespace" get configmap ownership-sentinel >/dev/null
k delete namespace "$namespace" --wait=true --timeout=60s
owned=false
code=0
FIREWALL_FAULT_AFTER_IPV4=1 FIREWALL_RESULTS_DIR="$results/failure-partial" bash ./run.sh > "$results/failure-partial-driver.log" 2>&1 || code=$?
[[ "$code" == 91 ]]
[[ -z $(k get namespace "$namespace" --ignore-not-found -o name) ]]
jq -e '.removed==true and .ready==false' "$state/ordinary-fence.json" >/dev/null
for family in iptables ip6tables; do
  for field in chain incomingChain; do
    chain=$(jq -r ".$field" "$state/ordinary-fence.json")
    if docker exec "$node" "$family" -S "$chain" >/dev/null 2>&1; then echo 'FAIL partial fence retained'; exit 1; fi
  done
done
jq -n '{unownedNamespacePreserved:true,partialInstallExitCode:91,partialRulesRemoved:true,ownedNamespaceRemoved:true}' | tee "$results/failure-summary.json"
echo 'PASS namespace rejection and partial fence cleanup'
