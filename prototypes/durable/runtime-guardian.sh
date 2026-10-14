#!/usr/bin/env bash
set -euo pipefail
binding=$1
results=$2
node=konflux-sandbox-vm-prototype-control-plane
mkdir -p "$results"
[[ $(docker inspect "$node" --format '{{index .Config.Labels "io.x-k8s.kind.cluster"}}') == konflux-sandbox-vm-prototype ]]
jq -e '.namespace=="foundation-guardian-prototype" and (.podUID|test("^[a-f0-9-]{36}$")) and (.sandboxID|test("^[a-f0-9]{64}$")) and (.podName|startswith("exec-"))' "$binding" >/dev/null
namespace=$(jq -r .namespace "$binding")
pod_name=$(jq -r .podName "$binding")
pod_uid=$(jq -r .podUID "$binding")
sid=$(jq -r .sandboxID "$binding")
deadline=$(date -u -d "$(jq -r .deadline "$binding")" +%s)
expiry=$deadline
reason=AbsoluteDeadline
if [[ $(jq -r '.leaseExpires//""' "$binding") != "" ]]; then
  lease=$(date -u -d "$(jq -r .leaseExpires "$binding")" +%s)
  if (( lease < expiry )); then expiry=$lease; reason=AllocationLeaseExpired; fi
fi
cri() { docker exec "$node" crictl "$@"; }
vm_pids() {
  docker exec "$node" ps -eo pid,args | awk -v id="$1" '/qemu-system/ && index($0,id)>0 {print $1}' | jq -Rn '[inputs|tonumber]'
}
cri inspectp "$sid" | jq '{status:.status}' > "$results/initial-sandbox.json"
jq -e --arg sid "$sid" --arg uid "$pod_uid" --arg ns "$namespace" --arg name "$pod_name" '.status.id==$sid and .status.metadata.uid==$uid and .status.metadata.namespace==$ns and .status.metadata.name==$name and .status.state=="SANDBOX_READY"' "$results/initial-sandbox.json" >/dev/null
vm_pids "$sid" > "$results/initial-vm-pids.json"
jq -e 'length==1' "$results/initial-vm-pids.json" >/dev/null
cri ps -a -o json | jq --arg uid "$pod_uid" '[.containers[]|select(.labels["io.kubernetes.pod.uid"]==$uid)]' > "$results/initial-containers.json"
jq -e 'length>=1 and any(.[];.state=="CONTAINER_RUNNING")' "$results/initial-containers.json" >/dev/null
: > "$results/initial-container-statuses.jsonl"
: > "$results/initial-command-markers.jsonl"
while read -r id; do
  cri inspect "$id" | jq '{id:.status.id,state:.status.state,createdAt:.status.createdAt,startedAt:.status.startedAt,finishedAt:.status.finishedAt}' >> "$results/initial-container-statuses.jsonl"
  cri logs "$id" > "$results/$id.initial.log"
  while IFS= read -r marker; do
    jq -n --arg id "$id" --arg marker "$marker" '{containerID:$id,marker:$marker}' >> "$results/initial-command-markers.jsonl"
  done < <(rg '^EXECUTION_START=' "$results/$id.initial.log" || true)
done < <(jq -r '.[].id' "$results/initial-containers.json")
printf '[]\n' > "$results/observed-containers.json"
printf '[]\n' > "$results/observed-sandboxes.json"
: > "$results/observations.jsonl"
: > "$results/owned-runtime-pids.jsonl"
while (( $(date -u +%s) < expiry )); do sleep 0.2; done
# Recheck the immutable runtime binding immediately before the stop.
cri inspectp "$sid" | jq -e --arg sid "$sid" --arg uid "$pod_uid" --arg ns "$namespace" '.status.id==$sid and .status.metadata.uid==$uid and .status.metadata.namespace==$ns' >/dev/null
stop_started=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
cri stopp "$sid" > "$results/stop.log"
stop_completed=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
capture() {
  cri pods -o json | jq --arg name "$pod_name" --arg ns "$namespace" '[.items[]|select(.metadata.name==$name and .metadata.namespace==$ns)]' > "$results/current-sandboxes.json"
  cri ps -a -o json | jq --arg name "$pod_name" --arg ns "$namespace" '[.containers[]|select(.labels["io.kubernetes.pod.name"]==$name and .labels["io.kubernetes.pod.namespace"]==$ns)]' > "$results/current-containers.json"
  jq -s 'add|unique_by(.id)' "$results/observed-sandboxes.json" "$results/current-sandboxes.json" > "$results/merge.json"
  mv "$results/merge.json" "$results/observed-sandboxes.json"
  jq -s 'add|unique_by(.id)' "$results/observed-containers.json" "$results/current-containers.json" > "$results/merge.json"
  mv "$results/merge.json" "$results/observed-containers.json"
  vm_pids "$sid" > "$results/initial-vm-pids-after.json"
  jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" --slurpfile sandboxes "$results/current-sandboxes.json" --slurpfile containers "$results/current-containers.json" --slurpfile pids "$results/initial-vm-pids-after.json" '{at:$at,sandboxes:$sandboxes[0],containers:$containers[0],initialVMPIDs:$pids[0]}' >> "$results/observations.jsonl"
  while read -r allocation; do
    pids=$(vm_pids "$allocation")
    jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" --arg sid "$allocation" --argjson pids "$pids" '{at:$at,sandboxID:$sid,vmPIDs:$pids}' >> "$results/owned-runtime-pids.jsonl"
  done < <(jq -r '.[].id' "$results/current-sandboxes.json")
}
observation_started_ns=$(date -u +%s%N)
end=$(( observation_started_ns + 30000000000 ))
while (( $(date -u +%s%N) < end )); do
  capture
  sleep 0.5
done
capture
observation_ended_ns=$(date -u +%s%N)
observation_duration_ns=$(( observation_ended_ns - observation_started_ns ))
(( observation_duration_ns >= 30000000000 ))
vm_pids "$sid" > "$results/initial-vm-pids-after.json"
old_vm_gone=$(jq 'length==0' "$results/initial-vm-pids-after.json")
cp "$results/initial-command-markers.jsonl" "$results/command-markers.jsonl"
: > "$results/container-statuses.jsonl"
while read -r id; do
  if status=$(cri inspect "$id" 2> "$results/$id.inspect.stderr.log"); then
    jq '{id:.status.id,state:.status.state,createdAt:.status.createdAt,startedAt:.status.startedAt,finishedAt:.status.finishedAt,exitCode:.status.exitCode,reason:.status.reason}' <<< "$status" >> "$results/container-statuses.jsonl"
  fi
  if cri logs "$id" > "$results/$id.log" 2> "$results/$id.stderr.log"; then
    while IFS= read -r marker; do
      jq -n --arg id "$id" --arg marker "$marker" '{containerID:$id,marker:$marker}' >> "$results/command-markers.jsonl"
    done < <(rg '^EXECUTION_START=' "$results/$id.log" || true)
  fi
done < <(jq -r '.[].id' "$results/observed-containers.json")
jq -n --arg reason "$reason" --arg initialSID "$sid" --arg stopStarted "$stop_started" --arg stopCompleted "$stop_completed" --argjson expiry "$expiry" --argjson initialVMGone "$old_vm_gone" --slurpfile initial "$results/initial-containers.json" --slurpfile sandboxes "$results/observed-sandboxes.json" --slurpfile containers "$results/observed-containers.json" --slurpfile markers "$results/command-markers.jsonl" '{reason:$reason,enforcedExpiryEpoch:$expiry,initialSandboxID:$initialSID,stopStarted:$stopStarted,stopCompleted:$stopCompleted,initialVMGone:$initialVMGone,replacementSandboxIDs:[$sandboxes[0][]|select(.id!=$initialSID)|.id],newContainerIDs:[$containers[0][]|select(.id as $id|all($initial[0][];.id!=$id))|.id],commandStarts:$markers,replayObserved:any($markers[];.containerID as $id|all($initial[0][];.id!=$id)),outcome:"UnknownRuntimeOutcome",disposalProven:false,replayPrevented:false}' > "$results/summary.json"
jq -e '.initialVMGone==true' "$results/summary.json" >/dev/null
jq --arg uid "$pod_uid" --arg started "$observation_started_ns" --arg ended "$observation_ended_ns" --argjson duration "$observation_duration_ns" '. + {initialPodUID:$uid,observationStartedEpochNanoseconds:$started,observationEndedEpochNanoseconds:$ended,observationDurationNanoseconds:$duration} | .commandStarts |= unique_by(.containerID,.marker)' "$results/summary.json" > "$results/final-summary.json"
mv "$results/final-summary.json" "$results/summary.json"
[[ $(( $(date -u -d "$stop_started" +%s) - expiry )) -le 5 ]]
