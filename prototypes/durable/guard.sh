#!/usr/bin/env bash
set -euo pipefail
: "${KUBECONFIG:=/tmp/konflux-sandbox-runtime/vm-kubeconfig}"
: "${KUBE_CONTEXT:=kind-konflux-sandbox-vm-prototype}"
[[ "$KUBE_CONTEXT" == kind-konflux-sandbox-vm-prototype ]]
node=konflux-sandbox-vm-prototype-control-plane
k() { kubectl --kubeconfig "$KUBECONFIG" --context "$KUBE_CONTEXT" --request-timeout=15s "$@"; }
server=$(k config view --minify -o jsonpath='{.clusters[0].cluster.server}')
[[ "$server" =~ ^https://127\.0\.0\.1:[0-9]+$ ]]
[[ $(docker inspect "$node" --format '{{index .Config.Labels "io.x-k8s.kind.cluster"}}') == konflux-sandbox-vm-prototype ]]
port=$(docker inspect "$node" --format '{{(index (index .NetworkSettings.Ports "6443/tcp") 0).HostPort}}')
[[ "${server##*:}" == "$port" ]]
k get nodes -o json | jq -e --arg node "$node" '(.items|length)==1 and any(.items[];.metadata.name==$node) and all(.items[];(.spec.providerID//"")|startswith("kind://docker/konflux-sandbox-vm-prototype/"))' >/dev/null
k get runtimeclass kata-prototype -o json | jq -e '.handler=="kata-prototype"' >/dev/null
