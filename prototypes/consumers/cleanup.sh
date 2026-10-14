#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ../runtime/context.sh
require_runtime_context /tmp/konflux-sandbox-runtime/vm-kubeconfig kind-konflux-sandbox-vm-prototype
shopt -s nullglob
for state in .state/run.*;do
  namespace=foundation-consumers-prototype
  if [[ -f $state/namespace-uid && $(runtime_k get namespace "$namespace" -o jsonpath='{.metadata.uid}' 2>/dev/null) == "$(cat "$state/namespace-uid")" ]];then
    for request in finite session;do
      if [[ -f $state/$request/backend.json ]];then bash backend.sh stop "$PWD/$state" "$request" "$request";fi
    done
    runtime_k delete namespace "$namespace" --wait=true --timeout=90s
  fi
  namespace=foundation-consumers-clients-prototype
  if [[ -f $state/client-namespace-uid && $(runtime_k get namespace "$namespace" -o jsonpath='{.metadata.uid}' 2>/dev/null) == "$(cat "$state/client-namespace-uid")" ]];then
    runtime_k delete namespace "$namespace" --wait=true --timeout=90s
  fi
  for record in "$state"/finite/fence.json "$state"/session/fence.json;do
    bash ../firewall/fence.sh remove /tmp/konflux-sandbox-runtime/vm-kubeconfig "$record"
  done
 done
