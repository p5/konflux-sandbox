#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
: "${KUBECONFIG:=/tmp/konflux-sandbox-runtime/vm-kubeconfig}"
: "${KUBE_CONTEXT:=kind-konflux-sandbox-vm-prototype}"
: "${DURABLE_NAMESPACE:=foundation-durable-prototype}"
export KUBECONFIG KUBE_CONTEXT DURABLE_NAMESPACE
"$here/guard.sh"
results="$here/../../.prototype-results/durable"
binary="$here/../../.prototype-state/durable/bin/controller"
mkdir -p "$results"
: > "$results/summary.txt"
(cd "$here" && sha256sum ./*.go go.mod go.sum crd.yaml guard.sh install.sh run.sh Makefile) > "$results/source-sha256.txt"
sha256sum "$binary" > "$results/binary-sha256.txt"
controller_pid=
watchdog_pid=
k() { kubectl --kubeconfig "$KUBECONFIG" --context "$KUBE_CONTEXT" --request-timeout=15s -n "$DURABLE_NAMESPACE" "$@"; }
stop_controller() {
  if [[ -n "$controller_pid" ]]; then
    kill -CONT "$controller_pid" 2>/dev/null || true
    kill -TERM "$controller_pid" 2>/dev/null || true
    wait "$controller_pid" 2>/dev/null || true
    controller_pid=
  fi
}
stop_watchdog() {
  if [[ -n "$watchdog_pid" ]]; then
    kill -TERM "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    watchdog_pid=
  fi
}
trap 'stop_controller; stop_watchdog' EXIT
start_watchdog() {
  "$binary" --kubeconfig "$KUBECONFIG" --context "$KUBE_CONTEXT" --namespace "$DURABLE_NAMESPACE" --guard "$here/guard.sh" --watchdog > "$results/$1.watchdog.log" 2> "$results/$1.watchdog.stderr.log" &
  watchdog_pid=$!
}
wait_absent() {
  local resource=$1
  for _ in {1..120}; do
    if k get "$resource" --ignore-not-found -o name > "$results/absence-check.txt" 2> "$results/absence-check.stderr.log" && [[ ! -s "$results/absence-check.txt" ]]; then return; fi
    sleep 1
  done
  echo "resource remains: $resource" >&2
  return 1
}
start_controller() {
  local log=$1; shift
  "$binary" --kubeconfig "$KUBECONFIG" --context "$KUBE_CONTEXT" --namespace "$DURABLE_NAMESPACE" --guard "$here/guard.sh" "$@" > "$results/$log.controller.log" 2>&1 &
  controller_pid=$!
}
wait_execution() {
  local name=$1 expression=$2
  for _ in {1..180}; do
    if k get fexec "$name" -o json > "$results/$name.json" 2>/dev/null && jq -e "$expression" "$results/$name.json" >/dev/null; then return; fi
    sleep 1
  done
  cat "$results/$name.json" >&2
  cat "$results"/*.controller.log >&2
  return 1
}
wait_crash() {
  local code=0
  wait "$controller_pid" || code=$?
  controller_pid=
  [[ $code == 70 ]]
}
create_execution() {
  local name=$1 duration=$2 ttl=$3 mode=${4:-finite} attempt=${5:-a1}
  local deadline
  deadline=$(date -u -d "+$ttl seconds" +%Y-%m-%dT%H:%M:%SZ)
  jq -n --arg name "$name" --arg namespace "$DURABLE_NAMESPACE" --arg deadline "$deadline" --arg mode "$mode" --arg attempt "$attempt" --arg command "printf 'GUEST_KERNEL=%s\\n' \"\$(uname -r)\"; printf 'ATTEMPT=%s\\n' \"\$ATTEMPT_ID\"; sleep $duration" '{apiVersion:"foundation.sandbox.p5.dev/v1alpha1",kind:"Execution",metadata:{name:$name,namespace:$namespace},spec:{ownerID:"prototype-owner",attemptID:$attempt,sourceDigest:("sha256:"+("1"*64)),profileDigest:("sha256:"+("2"*64)),image:"konflux-sandbox-runtime:prototype",command:["/bin/sh","-c",$command],env:{ATTEMPT_ID:$attempt},deadline:$deadline,mode:$mode}}' > "$results/$name.input.json"
  k create -f "$results/$name.input.json" >/dev/null
}
child_name() { k get fexec "$1" -o jsonpath='{.status.childName}'; }
record_running() {
  local name=$1 child uid
  wait_execution "$name" '.status.phase=="Running" and .status.vmObserved==true'
  child=$(child_name "$name")
  uid=$(k get pod "$child" -o jsonpath='{.metadata.uid}')
  k get pod "$child" -o json > "$results/$name.pod.json"
  k logs "$child" > "$results/$name.guest.log"
  "$binary" --kubeconfig "$KUBECONFIG" --context "$KUBE_CONTEXT" --namespace "$DURABLE_NAMESPACE" --guard "$here/guard.sh" --observe-child "$child" --observe-uid "$uid" > "$results/$name.runtime-before.json"
  jq -e '.ready==true and (.vmPIDs|length)==1' "$results/$name.runtime-before.json" >/dev/null
  jq -e '.spec.runtimeClassName=="kata-prototype" and .spec.automountServiceAccountToken==false and .spec.restartPolicy=="Never" and (.spec.containers|length)==1 and (.spec.volumes//[]|length)==0' "$results/$name.pod.json" >/dev/null
  rg '^GUEST_KERNEL=' "$results/$name.guest.log" >/dev/null
}
record_cleaned() {
  local name=$1 phase=$2 child uid sid
  wait_execution "$name" ".status.phase==\"$phase\" and .status.cleanupComplete==true and (.metadata.finalizers//[]|length)==0"
  child=$(jq -r '.status.childName' "$results/$name.json")
  uid=$(jq -r '.status.childUID//""' "$results/$name.json")
  sid=$(jq -r '.status.runtimeSandboxID//""' "$results/$name.json")
  [[ -z $(k get pod "$child" --ignore-not-found -o name) ]]
  "$binary" --kubeconfig "$KUBECONFIG" --context "$KUBE_CONTEXT" --namespace "$DURABLE_NAMESPACE" --guard "$here/guard.sh" --observe-child "$child" --observe-uid "$uid" --observe-runtime-id "$sid" > "$results/$name.runtime-after.json"
  jq -e '.ready==false and (.vmPIDs|length)==0' "$results/$name.runtime-after.json" >/dev/null
}
start_controller reset
k get fexec -o json | jq -r '.items[]|select(.status.cleanupComplete==true)|.metadata.name' | while read -r old; do k delete fexec "$old" --wait=false >/dev/null; done
for _ in {1..120}; do [[ $(k get fexec -o json | jq '[.items[]|select(.status.cleanupComplete==true)]|length') == 0 ]] && break; sleep 1; done
[[ $(k get fexec -o json | jq '[.items[]|select(.status.cleanupUnverified!=true)]|length') == 0 ]]
[[ $(k get pods -o json | jq '.items|length') == 0 ]]
stop_controller

# A crash before dispatch intent permits the first dispatch.
create_execution allocation 10 120
start_controller allocation-crash --fault-execution allocation --crash-at before-intent
wait_crash
wait_execution allocation '.status.phase=="Allocating" and .status.dispatchCommittedAt==null'
[[ -z $(k get pod "$(child_name allocation)" --ignore-not-found -o name) ]]
start_controller allocation-restart
record_running allocation
record_cleaned allocation Succeeded
jq -e '.status.exitCode==0 and .status.vmObserved==true and (.status.guestKernel|length)>0' "$results/allocation.json" >/dev/null
stop_controller

# A committed dispatch with no observable child stays unknown. It never repeats.
intent_case="intent-only-$(date +%s)"
create_execution "$intent_case" 30 120
start_controller intent-crash --fault-execution "$intent_case" --crash-at after-intent
wait_crash
wait_execution "$intent_case" '.status.phase=="DispatchCommitted" and .status.dispatchCommittedAt!=null'
start_controller intent-restart
wait_execution "$intent_case" '.status.phase=="UnknownOutcome" and .status.cleanupUnverified==true and .status.cleanupComplete!=true'
k delete fexec "$intent_case" --wait=false >/dev/null
wait_execution "$intent_case" '.metadata.deletionTimestamp!=null and (.metadata.finalizers|index("foundation.sandbox.p5.dev/cleanup"))!=null and .status.cleanupUnverified==true'
cp "$results/$intent_case.json" "$results/intent-only.unverified-deletion.json"
sleep 2
[[ -z $(k get pod "$(child_name "$intent_case")" --ignore-not-found -o name) ]]
stop_controller

# A successful POST followed by a crash adopts the exact child UID.
create_execution adoption 180 180 session
start_controller adoption-crash --fault-execution adoption --crash-at after-create
wait_crash
wait_execution adoption '.status.phase=="DispatchCommitted" and .status.childUID==null'
adopt_child=$(child_name adoption)
k wait "pod/$adopt_child" --for=condition=Ready --timeout=90s >/dev/null
adopt_uid=$(k get pod "$adopt_child" -o jsonpath='{.metadata.uid}')
start_controller adoption-restart
record_running adoption
jq -e --arg uid "$adopt_uid" '.status.adopted==true and .status.childUID==$uid' "$results/adoption.json" >/dev/null
k patch fexec adoption --type=merge -p '{"spec":{"cancel":true}}' >/dev/null
record_cleaned adoption Cancelled
if k patch fexec adoption --type=merge -p '{"spec":{"cancel":false}}' > "$results/cancel-withdrawal.log" 2>&1; then
  echo 'unexpected cancellation withdrawal' >&2; exit 1
fi
rg 'cancellation cannot be withdrawn' "$results/cancel-withdrawal.log" >/dev/null
stop_controller

# A dispatched child that disappears before status recovery must not replay.
create_execution lost-child 180 180 session
start_controller lost-crash --fault-execution lost-child --crash-at after-create
wait_crash
lost_child=$(child_name lost-child)
k wait "pod/$lost_child" --for=condition=Ready --timeout=90s >/dev/null
lost_uid=$(k get pod "$lost_child" -o jsonpath='{.metadata.uid}')
k get pod "$lost_child" -o json > "$results/lost-child.pod.json"
k logs "$lost_child" > "$results/lost-child.guest.log"
"$binary" --kubeconfig "$KUBECONFIG" --context "$KUBE_CONTEXT" --namespace "$DURABLE_NAMESPACE" --guard "$here/guard.sh" --observe-child "$lost_child" --observe-uid "$lost_uid" > "$results/lost-child.runtime-before.json"
jq -e '.ready and (.vmPIDs|length)==1' "$results/lost-child.runtime-before.json" >/dev/null
k delete pod "$lost_child" --grace-period=1 --wait=false >/dev/null
wait_absent "pod/$lost_child"
lost_sid=$(jq -r .sandboxID "$results/lost-child.runtime-before.json")
docker exec konflux-sandbox-vm-prototype-control-plane crictl inspectp "$lost_sid" > "$results/lost-child.stopped-cri.json"
jq -e --arg uid "$lost_uid" '.status.metadata.uid==$uid and .status.state=="SANDBOX_NOTREADY"' "$results/lost-child.stopped-cri.json" >/dev/null
# Remove only this stopped guest's CRI metadata to exercise deletion-before-observation.
docker exec konflux-sandbox-vm-prototype-control-plane crictl rmp "$lost_sid" > "$results/lost-child.metadata-removal.log"
start_controller lost-restart
wait_execution lost-child '.status.phase=="UnknownOutcome" and .status.cleanupUnverified==true and .status.cleanupComplete!=true'
cp "$results/lost-child.json" "$results/lost-child.unverified.json"
"$binary" --kubeconfig "$KUBECONFIG" --context "$KUBE_CONTEXT" --namespace "$DURABLE_NAMESPACE" --guard "$here/guard.sh" --observe-child "$lost_child" --observe-uid "$lost_uid" --observe-runtime-id "$lost_sid" > "$results/lost-child.explicit-runtime-after.json"
jq -e '.ready==false and (.vmPIDs|length)==0' "$results/lost-child.explicit-runtime-after.json" >/dev/null
"$binary" --kubeconfig "$KUBECONFIG" --context "$KUBE_CONTEXT" --namespace "$DURABLE_NAMESPACE" --guard "$here/guard.sh" --recover-execution lost-child --observe-uid "$lost_uid" --observe-runtime-id "$lost_sid" > "$results/lost-child.trusted-recovery.log" 2>&1
record_cleaned lost-child UnknownOutcome
stop_controller

# Kubelet enforces a finite deadline while the submitting controller is down.
create_execution deadline 180 40 session
start_controller deadline-start
record_running deadline
deadline_child=$(child_name deadline)
stop_controller
for _ in {1..90}; do
  k get pod "$deadline_child" -o json > "$results/deadline.expired-pod.json"
  jq -e '.status.phase=="Failed" and .status.reason=="DeadlineExceeded"' "$results/deadline.expired-pod.json" >/dev/null && break
  sleep 1
done
jq -e '.status.phase=="Failed" and .status.reason=="DeadlineExceeded"' "$results/deadline.expired-pod.json" >/dev/null
start_controller deadline-restart
record_cleaned deadline DeadlineExceeded
stop_controller

# An independent watchdog stops cancellation while the lifecycle controller is down.
create_execution watchdog-cancel 180 180 session
start_controller watchdog-cancel-start
record_running watchdog-cancel
cancel_child=$(child_name watchdog-cancel)
stop_controller
start_watchdog cancellation
cancel_at=$(date -u +%s)
k patch fexec watchdog-cancel --type=merge -p '{"spec":{"cancel":true}}' >/dev/null
wait_absent "pod/$cancel_child"
jq -e '.execution=="watchdog-cancel" and .reason=="Cancellation"' "$results/cancellation.watchdog.log" >/dev/null
cancel_deleted=$(jq -r .at "$results/cancellation.watchdog.log")
[[ $(( $(date -u -d "$cancel_deleted" +%s) - cancel_at )) -le 5 ]]
stop_watchdog
start_controller watchdog-cancel-restart
record_cleaned watchdog-cancel Cancelled
stop_controller

# A scheduling delay separates the absolute deadline from native Pod ADS.
create_execution watchdog-deadline 180 45 session
start_controller watchdog-delay --scheduling-gate
wait_execution watchdog-deadline '.status.phase=="Starting" and .status.childUID!=null'
watch_child=$(child_name watchdog-deadline)
stop_controller
sleep 10
k patch pod "$watch_child" --type=json -p '[{"op":"remove","path":"/spec/schedulingGates"}]' >/dev/null
start_controller watchdog-running
record_running watchdog-deadline
stop_controller
absolute=$(jq -r .spec.deadline "$results/watchdog-deadline.json")
pod_start=$(jq -r .status.startTime "$results/watchdog-deadline.pod.json")
pod_ads=$(jq -r .spec.activeDeadlineSeconds "$results/watchdog-deadline.pod.json")
native_expiry=$(( $(date -u -d "$pod_start" +%s) + pod_ads ))
absolute_epoch=$(date -u -d "$absolute" +%s)
[[ $((native_expiry-absolute_epoch)) -ge 8 ]]
start_watchdog deadline
wait_absent "pod/$watch_child"
jq -e '.execution=="watchdog-deadline" and .reason=="AbsoluteDeadline"' "$results/deadline.watchdog.log" >/dev/null
watch_deleted=$(jq -r .at "$results/deadline.watchdog.log")
watch_epoch=$(date -u -d "$watch_deleted" +%s)
[[ $((watch_epoch-absolute_epoch)) -ge 0 && $((watch_epoch-absolute_epoch)) -le 5 ]]
[[ $((native_expiry-watch_epoch)) -ge 7 ]]
jq -n --arg requested "$absolute" --arg start "$pod_start" --arg deleted "$watch_deleted" --argjson nativeExpiry "$native_expiry" --argjson elapsed "$((watch_epoch-absolute_epoch))" '{requestedDeadline:$requested,podStart:$start,nativeExpiryEpoch:$nativeExpiry,watchdogDelete:$deleted,secondsAfterAbsoluteDeadline:$elapsed}' > "$results/watchdog-deadline.timing.json"
stop_watchdog
start_controller watchdog-deadline-restart
record_cleaned watchdog-deadline DeadlineExceeded
stop_controller

# Finalization holds the owner until the owned child and VM disappear.
create_execution finalizer 180 180 session
start_controller finalizer-start
record_running finalizer
final_child=$(child_name finalizer)
final_uid=$(k get pod "$final_child" -o jsonpath='{.metadata.uid}')
final_sid=$(jq -r .sandboxID "$results/finalizer.runtime-before.json")
kill -STOP "$controller_pid"
k delete fexec finalizer --wait=false >/dev/null
k get fexec finalizer -o json > "$results/finalizer.deleting.json"
jq -e '.metadata.deletionTimestamp!=null and (.metadata.finalizers|index("foundation.sandbox.p5.dev/cleanup"))!=null' "$results/finalizer.deleting.json" >/dev/null
[[ $(k get pod "$final_child" -o jsonpath='{.metadata.uid}') == "$final_uid" ]]
kill -CONT "$controller_pid"
wait_absent fexec/finalizer
[[ -z $(k get pod "$final_child" --ignore-not-found -o name) ]]
"$binary" --kubeconfig "$KUBECONFIG" --context "$KUBE_CONTEXT" --namespace "$DURABLE_NAMESPACE" --guard "$here/guard.sh" --observe-child "$final_child" --observe-uid "$final_uid" --observe-runtime-id "$final_sid" > "$results/finalizer.runtime-after.json"
jq -e '.ready==false and (.vmPIDs|length)==0' "$results/finalizer.runtime-after.json" >/dev/null
stop_controller

# Name collisions do not grant ownership of an unrelated child.
create_execution collision 180 180
collision_uid=$(k get fexec collision -o jsonpath='{.metadata.uid}')
collision_child="exec-$collision_uid-a1"
jq -n --arg name "$collision_child" --arg ns "$DURABLE_NAMESPACE" '{apiVersion:"v1",kind:"Pod",metadata:{name:$name,namespace:$ns},spec:{automountServiceAccountToken:false,restartPolicy:"Never",containers:[{name:"foreign",image:"konflux-sandbox-runtime:prototype",imagePullPolicy:"Never",command:["/bin/sh","-c","sleep 180"]}]}}' > "$results/collision.foreign-input.json"
k create -f "$results/collision.foreign-input.json" >/dev/null
foreign_uid=$(k get pod "$collision_child" -o jsonpath='{.metadata.uid}')
start_controller collision-start
wait_execution collision '.status.phase=="Rejected" and .status.reason=="ChildOwnershipConflict" and .status.cleanupComplete==true'
[[ $(k get pod "$collision_child" -o jsonpath='{.metadata.uid}') == "$foreign_uid" ]]
k get pod "$collision_child" -o json > "$results/collision.foreign-retained.json"
k delete pod "$collision_child" --grace-period=1 --wait=false >/dev/null
wait_absent "pod/$collision_child"

# Admission fixes request identity and command for this Kubernetes object.
for field in ownerID attemptID sourceDigest profileDigest image command env deadline mode; do
  case $field in
    ownerID) value='"other-owner"';;
    attemptID) value='"a2"';;
    sourceDigest|profileDigest) value='"sha256:3333333333333333333333333333333333333333333333333333333333333333"';;
    image) value='"other-image"';;
    command) value='["/bin/false"]';;
    env) value='{"ATTEMPT_ID":"other"}';;
    deadline) value='"2099-01-01T00:00:00Z"';;
    mode) value='"session"';;
  esac
  if k patch fexec collision --type=merge -p "{\"spec\":{\"$field\":$value}}" > "$results/immutable-$field.log" 2>&1; then
    echo "unexpected mutable field: $field" >&2; exit 1
  fi
  rg 'immutable' "$results/immutable-$field.log" >/dev/null
done
old_uid=$(k get fexec collision -o jsonpath='{.metadata.uid}')
k delete fexec collision --wait=true --timeout=30s >/dev/null
create_execution collision 10 120 finite a2
record_running collision
new_uid=$(k get fexec collision -o jsonpath='{.metadata.uid}')
[[ "$old_uid" != "$new_uid" ]]
[[ $(child_name collision) == "exec-$new_uid-a2" ]]
record_cleaned collision Succeeded
stop_controller
k get fexec -o json > "$results/final-executions.json"
k get pods -o json > "$results/final-pods.json"
jq -e '.items|length==0' "$results/final-pods.json" >/dev/null
printf '%s\n' 'PASS: allocation, fail-closed unknown disposal, adoption, trusted recovery, independent cancellation/deadline watchdog, native deadline, finalizer, ownership, immutable attempt identity' | tee "$results/summary.txt"
