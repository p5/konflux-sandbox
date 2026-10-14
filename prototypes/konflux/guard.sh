#!/usr/bin/env bash
set -euo pipefail
: "${KUBECONFIG:=/tmp/konflux-sandbox-prototype-qw2Tu2/kubeconfig}"
: "${KUBE_CONTEXT:=kind-konflux-sandbox-prototype}"
[[ "$KUBE_CONTEXT" == kind-konflux-sandbox-prototype ]]
node=konflux-sandbox-prototype-control-plane
k() { kubectl --kubeconfig "$KUBECONFIG" --context "$KUBE_CONTEXT" --request-timeout=20s "$@"; }
server=$(k config view --minify -o jsonpath='{.clusters[0].cluster.server}')
[[ "$server" =~ ^https://127\.0\.0\.1:[0-9]+$ ]]
[[ $(docker inspect "$node" --format '{{index .Config.Labels "io.x-k8s.kind.cluster"}}') == konflux-sandbox-prototype ]]
port=$(docker inspect "$node" --format '{{(index (index .NetworkSettings.Ports "6443/tcp") 0).HostPort}}')
[[ "${server##*:}" == "$port" ]]
k get nodes -o json | jq -e --arg node "$node" '
  any(.items[]; .metadata.name==$node) and
  all(.items[]; (.spec.providerID//"")|startswith("kind://docker/konflux-sandbox-prototype/"))' >/dev/null
