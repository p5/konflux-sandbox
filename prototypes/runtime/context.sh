#!/usr/bin/env bash

require_runtime_context() {
  RUNTIME_KUBECONFIG=$1
  RUNTIME_CONTEXT=$(kubectl --kubeconfig "$RUNTIME_KUBECONFIG" config current-context)
  case "$RUNTIME_CONTEXT" in
    kind-konflux-sandbox-prototype|kind-konflux-sandbox-vm-prototype) ;;
    *) echo "Refusing non-prototype context: $RUNTIME_CONTEXT" >&2; return 1 ;;
  esac
  if [[ -n ${2:-} && $RUNTIME_CONTEXT != "$2" ]]; then
    echo "Expected context $2; got $RUNTIME_CONTEXT" >&2
    return 1
  fi
  local cluster=${RUNTIME_CONTEXT#kind-}
  local expected_server actual_server
  expected_server=$(kind get kubeconfig --name "$cluster" | kubectl --kubeconfig /dev/stdin config view --minify -o jsonpath='{.clusters[0].cluster.server}')
  actual_server=$(kubectl --kubeconfig "$RUNTIME_KUBECONFIG" --context "$RUNTIME_CONTEXT" config view --minify -o jsonpath='{.clusters[0].cluster.server}')
  if [[ -z $expected_server || $actual_server != "$expected_server" ]]; then
    echo "Refusing API endpoint outside dedicated Kind cluster: $actual_server" >&2
    return 1
  fi
  kubectl --kubeconfig "$RUNTIME_KUBECONFIG" --context "$RUNTIME_CONTEXT" get node "$cluster-control-plane" >/dev/null
}

runtime_k() {
  kubectl --kubeconfig "$RUNTIME_KUBECONFIG" --context "$RUNTIME_CONTEXT" "$@"
}
