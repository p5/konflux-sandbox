#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ../runtime/context.sh
require_runtime_context /tmp/konflux-sandbox-runtime/vm-kubeconfig kind-konflux-sandbox-vm-prototype
namespace=foundation-storage-prototype
node=konflux-sandbox-vm-prototype-control-plane
results=../../.prototype-results/storage
mkdir -p "$results"
: >"$results/runtime-bindings.txt"
namespace_uid=
k() { runtime_k -n "$namespace" "$@"; }
cleanup() {
  local code=$?
  trap - EXIT
  if [[ -n "$namespace_uid" ]]; then
    if current=$(k get namespace "$namespace" --ignore-not-found -o json); then
      if [[ -n "$current" && $(jq -r .metadata.uid <<<"$current") == "$namespace_uid" ]]; then
        k delete namespace "$namespace" --wait=true --timeout=90s >"$results/cleanup.log" 2>&1 || code=1
      fi
    else
      code=1
    fi
  fi
  while read -r allocation; do
    local ready=true vm=unknown
    for _ in {1..60}; do
      ready=$(docker exec "$node" crictl pods -o json | jq --arg sid "$allocation" 'any(.items[];.id==$sid and .state=="SANDBOX_READY")')
      vm=$(docker exec "$node" ps -eo pid,comm,args | awk -v sid="$allocation" '$2 ~ /^qemu-system/ && index($0,sid)>0')
      [[ "$ready" == false && -z "$vm" ]] && break
      sleep 1
    done
    [[ "$ready" == false && -z "$vm" ]] || code=1
  done <"$results/runtime-bindings.txt"
  exit "$code"
}
trap cleanup EXIT
existing=$(k get namespace "$namespace" --ignore-not-found -o json)
[[ -z "$existing" ]] || { echo 'Storage fixture namespace already exists' >&2; exit 1; }
k create namespace "$namespace" -o json >"$results/namespace.json"
namespace_uid=$(jq -r .metadata.uid "$results/namespace.json")
k label namespace "$namespace" foundation.sandbox.p5.dev/owner=storage >/dev/null
cat <<EOF | k apply -f - >/dev/null
apiVersion: v1
kind: ServiceAccount
metadata: {name: storage-runner, namespace: $namespace}
automountServiceAccountToken: false
EOF
k create configmap storage-probe --from-file=probe.sh --from-file=bootstrap.sh >/dev/null
for medium in memory disk guest-tmpfs guest-filtered; do
  volume_medium=''
  [[ "$medium" == memory ]] && volume_medium=Memory
  jq -n --arg ns "$namespace" --arg name "$medium" --arg medium "$volume_medium" '{apiVersion:"v1",kind:"Pod",metadata:{name:$name,namespace:$ns},spec:{runtimeClassName:"kata-prototype",serviceAccountName:"storage-runner",automountServiceAccountToken:false,restartPolicy:"Never",activeDeadlineSeconds:90,terminationGracePeriodSeconds:1,securityContext:{runAsUser:1000,runAsGroup:1000,fsGroup:1000},containers:[{name:"probe",image:"konflux-sandbox-storage:prototype",imagePullPolicy:"Never",securityContext:{readOnlyRootFilesystem:true,allowPrivilegeEscalation:false,capabilities:{drop:["ALL"]}},resources:{requests:{cpu:"100m",memory:"128Mi"},limits:{cpu:"1",memory:"384Mi","ephemeral-storage":"32Mi"}},volumeMounts:[{name:"bounded",mountPath:"/bounded"},{name:"probe",mountPath:"/probe",readOnly:true}],command:["/bin/sh","/probe/probe.sh"]}],volumes:[{name:"bounded",emptyDir:{medium:$medium,sizeLimit:"8Mi"}},{name:"probe",configMap:{name:"storage-probe"}}]}} | if ($name=="guest-tmpfs" or $name=="guest-filtered") then .spec.securityContext.runAsUser=0 | .spec.securityContext.runAsGroup=0 | .spec.containers[0].securityContext.capabilities.add=["SYS_ADMIN","SETUID","SETGID","SETPCAP"] | .spec.containers[0].command=(["/bin/sh","/probe/bootstrap.sh"] + if $name=="guest-filtered" then ["filtered"] else [] end) else . end' >"$results/$medium.input.json"
  k create -f "$results/$medium.input.json" >/dev/null
  k wait pod/"$medium" --for=condition=Ready --timeout=120s >/dev/null
  k get pod "$medium" -o json >"$results/$medium.pod.json"
  uid=$(jq -r .metadata.uid "$results/$medium.pod.json")
  sid=$(docker exec "$node" crictl pods -o json | jq -r --arg uid "$uid" '.items[]|select(.metadata.uid==$uid and .state=="SANDBOX_READY")|.id')
  [[ "$sid" =~ ^[a-f0-9]{64}$ ]]
  printf '%s\n' "$sid" >>"$results/runtime-bindings.txt"
  docker exec "$node" ps -eo pid,comm,args | awk -v sid="$sid" '$2 ~ /^qemu-system/ && index($0,sid)>0' >"$results/$medium.vm-before.txt"
  [[ -s "$results/$medium.vm-before.txt" ]]
  for _ in {1..50}; do
    k logs "$medium" >"$results/$medium.log"
    if rg '^PROBE_COMPLETE$' "$results/$medium.log" >/dev/null; then break; fi
    sleep 0.2
  done
  rg '^PROBE_COMPLETE$' "$results/$medium.log" >/dev/null
  ! rg '^ROOT_WRITE_EXIT=0$' "$results/$medium.log" >/dev/null
  rg -i 'read-only file system' "$results/$medium.log" >/dev/null
  rg '^WORKLOAD_UID=1000$' "$results/$medium.log" >/dev/null
  rg '^CapEff:[[:space:]]+0000000000000000$' "$results/$medium.log" >/dev/null
  rg '^CapBnd:[[:space:]]+0000000000000000$' "$results/$medium.log" >/dev/null
  kernel=$(sed -n 's/^GUEST_KERNEL=//p' "$results/$medium.log")
  [[ "$kernel" != "$(docker exec "$node" uname -r)" ]]
  bytes=$(sed -n 's/^FILE_BYTES=//p' "$results/$medium.log")
  remount_exit=$(sed -n 's/^REMOUNT_EXIT=//p' "$results/$medium.log")
  userns_exit=$(sed -n 's/^USER_NAMESPACE_MOUNT_EXIT=//p' "$results/$medium.log")
  write_exit=$(sed -n 's/^WRITE_EXIT=//p' "$results/$medium.log")
  jq -n --arg medium "$medium" --arg uid "$uid" --arg sid "$sid" --arg kernel "$kernel" --argjson bytes "$bytes" --argjson code "$write_exit" --argjson remount "$remount_exit" --argjson userns "$userns_exit" '{medium:$medium,podUID:$uid,runtimeSandboxID:$sid,guestKernel:$kernel,requestedBytes:8388608,attemptedBytes:16777216,storedBytes:$bytes,writeExit:$code,immediateLimit:($code!=0 and $bytes<=8388608),rootWriteDenied:true,workloadUID:1000,capabilitiesDropped:true,remountDenied:($remount!=0),userNamespaceMountDenied:($userns!=0)}' >"$results/$medium.json"
  if [[ "$medium" == guest-filtered ]]; then jq -e ' .immediateLimit==true and .remountDenied==true and .userNamespaceMountDenied==true' "$results/$medium.json" >/dev/null; fi
  k delete pod "$medium" --wait=true --timeout=90s >/dev/null
  for _ in {1..60}; do
    ready=$(docker exec "$node" crictl pods -o json | jq --arg sid "$sid" 'any(.items[];.id==$sid and .state=="SANDBOX_READY")')
    vm=$(docker exec "$node" ps -eo pid,comm,args | awk -v sid="$sid" '$2 ~ /^qemu-system/ && index($0,sid)>0')
    [[ "$ready" == false && -z "$vm" ]] && break
    sleep 1
  done
  [[ "$ready" == false && -z "$vm" ]]
  jq '.runtimeRemovalVerified=true' "$results/$medium.json" >"$results/$medium.tmp"
  mv "$results/$medium.tmp" "$results/$medium.json"
done
jq -s '{cases:.,status:"observed",production:false}' "$results/memory.json" "$results/disk.json" "$results/guest-tmpfs.json" "$results/guest-filtered.json" | tee "$results/summary.json"
