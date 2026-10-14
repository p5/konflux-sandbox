#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
source "$here/../runtime/context.sh"
action=${1:?install or remove}
config=${2:?dedicated kubeconfig}
record=${3:?private record path}
require_runtime_context "$config" kind-konflux-sandbox-vm-prototype
node=konflux-sandbox-vm-prototype-control-plane
case "$action" in
  install)
    namespace=${4:?namespace}
    pod=${5:?pod}
    gateway=${6:?gateway IPv4 address}
    control=${7:-}
    case "$namespace" in foundation-firewall-prototype|foundation-consumers-prototype|foundation-broker-network-prototype) ;; *) echo 'Refusing namespace outside foundation firewall fixtures' >&2; exit 1;; esac
    [[ "$gateway" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
    [[ -z "$control" || "$control" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
    description=$(runtime_k -n "$namespace" get pod "$pod" -o json)
    [[ $(jq -r .spec.nodeName <<<"$description") == "$node" ]]
    uid=$(jq -r .metadata.uid <<<"$description")
    address=$(jq -r .status.podIP <<<"$description")
    interface=$(docker exec "$node" ip -j route get "$address" | jq -r '.[0].dev')
    [[ "$interface" =~ ^veth[a-z0-9]+$ ]]
    chain="KSBP7${uid//-/}"
    chain=${chain:0:17}
    incoming="KSBI7${uid//-/}"
    incoming=${incoming:0:17}
    runtime_id=$(docker exec "$node" crictl pods -o json | jq -r --arg uid "$uid" '.items[]|select(.metadata.uid==$uid and .state=="SANDBOX_READY")|.id')
    [[ "$runtime_id" =~ ^[a-f0-9]{64}$ ]]
    runtime_class=$(jq -r '.spec.runtimeClassName//""' <<<"$description")
    qemu_pid=''
    if [[ "$runtime_class" == kata-prototype ]]; then
      qemu_pid=$(docker exec "$node" ps -eo pid,comm,args | awk -v sid="$runtime_id" '$2 ~ /^qemu-system/ && index($0,sid)>0 {print $1}')
      [[ "$qemu_pid" =~ ^[0-9]+$ ]]
    fi
    mkdir -p "$(dirname "$record")"
    jq -n --arg uid "$uid" --arg pod "$pod" --arg namespace "$namespace" --arg ip "$address" --arg interface "$interface" --arg chain "$chain" --arg incoming "$incoming" --arg gateway "$gateway" --arg control "$control" --arg runtime "$runtime_id" --arg class "$runtime_class" --arg qemu "$qemu_pid" '{podUID:$uid,pod:$pod,namespace:$namespace,podIP:$ip,interface:$interface,chain:$chain,incomingChain:$incoming,gatewayIP:$gateway,controlRelayIP:$control,controlPort:8443,runtimeSandboxID:$runtime,runtimeClass:$class,qemuPID:$qemu,ready:false,ipv6:"deny-all",sourceBinding:"node-side ingress veth"}' > "$record"
    for family in iptables ip6tables; do
      docker exec "$node" "$family" -N "$chain"
      docker exec "$node" "$family" -N "$incoming"
      if [[ "$family" == iptables ]]; then
        docker exec "$node" "$family" -A "$chain" -p tcp -d "$gateway" --dport 8080 -j ACCEPT
        docker exec "$node" "$family" -A "$incoming" -p tcp -s "$gateway" --sport 8080 -m conntrack --ctstate ESTABLISHED --ctdir REPLY -j ACCEPT
        if [[ -n "$control" ]]; then
          docker exec "$node" "$family" -A "$chain" -p tcp -d "$control" --sport 8443 -m conntrack --ctstate ESTABLISHED --ctdir REPLY -j ACCEPT
          docker exec "$node" "$family" -A "$incoming" -p tcp -s "$control" --dport 8443 -j ACCEPT
        fi
      fi
      docker exec "$node" "$family" -A "$chain" -j REJECT
      docker exec "$node" "$family" -A "$incoming" -j REJECT
      for hook in INPUT FORWARD; do
        docker exec "$node" "$family" -I "$hook" 1 -i "$interface" -j "$chain"
        docker exec "$node" "$family" -C "$hook" -i "$interface" -j "$chain"
      done
      for hook in OUTPUT FORWARD; do
        docker exec "$node" "$family" -I "$hook" 1 -o "$interface" -j "$incoming"
        docker exec "$node" "$family" -C "$hook" -o "$interface" -j "$incoming"
      done
      if [[ "${FIREWALL_FAULT_AFTER_IPV4:-}" == 1 && "$family" == iptables ]]; then
        echo 'Injected partial IPv4 fence installation failure' >&2
        exit 91
      fi
    done
    jq '.ready=true' "$record" > "$record.tmp"
    mv "$record.tmp" "$record"
    cat "$record"
    ;;
  remove)
    [[ -f "$record" ]] || exit 0
    interface=$(jq -r .interface "$record")
    chain=$(jq -r .chain "$record")
    incoming=$(jq -r .incomingChain "$record")
    uid=$(jq -r .podUID "$record")
    runtime_id=$(jq -r .runtimeSandboxID "$record")
    [[ "$interface" =~ ^veth[a-z0-9]+$ && "$chain" =~ ^KSBP7[a-f0-9]{12}$ && "$incoming" =~ ^KSBI7[a-f0-9]{12}$ ]]
    [[ "$runtime_id" =~ ^[a-f0-9]{64}$ ]]
    deadline=$((SECONDS+60))
    while true; do
      pod_present=$(runtime_k get pods -A -o json | jq --arg uid "$uid" 'any(.items[];.metadata.uid==$uid)')
      runtime_present=$(docker exec "$node" crictl pods -o json | jq --arg sid "$runtime_id" 'any(.items[];.id==$sid and .state=="SANDBOX_READY")')
      qemu=$(docker exec "$node" ps -eo pid,comm,args | awk -v sid="$runtime_id" '$2 ~ /^qemu-system/ && index($0,sid)>0 {print $1}')
      if [[ "$pod_present" == false && "$runtime_present" == false && -z "$qemu" ]]; then break; fi
      if ((SECONDS>=deadline)); then echo 'Guest disposal unverified; retaining packet fence' >&2; exit 1; fi
      sleep 1
    done
    for family in iptables ip6tables; do
      for hook in INPUT FORWARD; do
        if docker exec "$node" "$family" -C "$hook" -i "$interface" -j "$chain" 2>/dev/null; then
          docker exec "$node" "$family" -D "$hook" -i "$interface" -j "$chain"
        fi
      done
      for hook in OUTPUT FORWARD; do
        if docker exec "$node" "$family" -C "$hook" -o "$interface" -j "$incoming" 2>/dev/null; then
          docker exec "$node" "$family" -D "$hook" -o "$interface" -j "$incoming"
        fi
      done
      if docker exec "$node" "$family" -S "$chain" >/dev/null 2>&1; then
        docker exec "$node" "$family" -F "$chain"
        docker exec "$node" "$family" -X "$chain"
      fi
      if docker exec "$node" "$family" -S "$incoming" >/dev/null 2>&1; then
        docker exec "$node" "$family" -F "$incoming"
        docker exec "$node" "$family" -X "$incoming"
      fi
    done
    jq '.ready=false | .removed=true | .runtimeRemovalVerified=true' "$record" > "$record.tmp"
    mv "$record.tmp" "$record"
    ;;
  *) echo 'Unsupported fence action' >&2; exit 1 ;;
esac
