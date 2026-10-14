#!/usr/bin/env bash
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../.." && pwd)
results="$root/.prototype-results/konflux"
mkdir -p "$results"
: "${KUBECONFIG:=/tmp/konflux-sandbox-prototype-qw2Tu2/kubeconfig}"
: "${KUBE_CONTEXT:=kind-konflux-sandbox-prototype}"
"$here/guard.sh"
k() { kubectl --kubeconfig "$KUBECONFIG" --context "$KUBE_CONTEXT" --request-timeout=20s "$@"; }

prototype_pid=""
cleanup() {
  if [[ -n "$prototype_pid" ]]; then
    kill -TERM "$prototype_pid" 2>/dev/null || true
    wait "$prototype_pid" || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if original=$(k -n release-service get releaseserviceconfig release-service-config -o json 2>/dev/null); then
  jq -e '.spec.debug==false' <<< "$original" >/dev/null
fi
(cd "$here" && exec ./run.sh release) > "$results/release-interrupt-run.log" 2>&1 &
prototype_pid=$!
deadline=$((SECONDS+120))
until k -n release-service get releaseserviceconfig release-service-config -o json 2>/dev/null | jq -e '.spec.debug==true' >/dev/null; do
  kill -0 "$prototype_pid" 2>/dev/null
  ((SECONDS<deadline))
  sleep 1
done
kill -TERM "$prototype_pid"
prototype_exit=0
wait "$prototype_pid" || prototype_exit=$?
prototype_pid=""
[[ "$prototype_exit" == 143 ]]
k -n release-service get releaseserviceconfig release-service-config -o json | jq -e '.spec.debug==false' >/dev/null
jq -n --argjson code "$prototype_exit" '{signal:"TERM",exitCode:$code,debugBefore:false,debugAtSignal:true,debugAfter:false,restored:true,scope:"Configuration restoration; no claim that CLI termination cancels already-created release workflows"}' > "$results/release-interrupt-restoration.json"
cat "$results/release-interrupt-restoration.json"
