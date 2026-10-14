#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
: "${KUBECONFIG:=/tmp/konflux-sandbox-runtime/vm-kubeconfig}"
: "${KUBE_CONTEXT:=kind-konflux-sandbox-vm-prototype}"
export KUBECONFIG KUBE_CONTEXT
DURABLE_NAMESPACE=foundation-guardian-prototype
export DURABLE_NAMESPACE
"$here/guard.sh"
results="$here/../../.prototype-results/durable-guardian"
binary="$here/../../.prototype-state/durable/bin/controller"
mkdir -p "$results"
(cd "$here" && sha256sum runtime-guardian.sh guardian-run.sh Makefile) > "$results/source-sha256.txt"
: > "$results/summary.txt"
k() { kubectl --kubeconfig "$KUBECONFIG" --context "$KUBE_CONTEXT" --request-timeout=15s -n "$DURABLE_NAMESPACE" "$@"; }
controller_pid=
current_pod=
current_uid=
current_sandbox=
current_sandbox_uid=
guest_command='printf "EXECUTION_START=guardian-a1\n"; printf "GUEST_KERNEL=%s\n" "$(uname -r)"; sleep 300'
start_controller() {
  "$binary" --kubeconfig "$KUBECONFIG" --context "$KUBE_CONTEXT" --namespace "$DURABLE_NAMESPACE" --guard "$here/guard.sh" > "$1" 2>&1 &
  controller_pid=$!
}
stop_controller() {
  if [[ -n "$controller_pid" ]]; then
    kill -TERM "$controller_pid" 2>/dev/null || true
    wait "$controller_pid" 2>/dev/null || true
    controller_pid=
  fi
}
finish() {
  local code=$?
  stop_controller
  if ((code!=0)); then
    if [[ -n "$current_sandbox" && -n "$current_sandbox_uid" ]]; then
      patch=$(jq -n --arg uid "$current_sandbox_uid" '[{op:"test",path:"/metadata/uid",value:$uid},{op:"replace",path:"/spec/operatingMode",value:"Suspended"}]')
      k patch sandbox "$current_sandbox" --type=json -p "$patch" > "$results/failure-suspend.log" 2>&1 || true
    fi
    if [[ -n "$current_uid" && -n "$current_pod" ]]; then
      jq -n --arg uid "$current_uid" '{apiVersion:"v1",kind:"DeleteOptions",gracePeriodSeconds:1,preconditions:{uid:$uid}}' > "$results/failure-delete-options.json"
      k delete --raw "/api/v1/namespaces/$DURABLE_NAMESPACE/pods/$current_pod" -f "$results/failure-delete-options.json" > "$results/failure-delete.log" 2>&1 || true
    fi
    printf '%s\n' 'Failure recovery: inspect foundation-guardian-prototype. Suspend exec-restartable-session if present. Patch remaining Execution spec.cancel=true; run the durable controller for this namespace. Retain finalizers until runtime disposal completes.' > "$results/failure-recovery.txt"
  fi
}
trap finish EXIT
wait_execution() {
  local name=$1 expression=$2 file=$3
  for _ in {1..120}; do
    if k get fexec "$name" -o json > "$file" && jq -e "$expression" "$file" >/dev/null; then return; fi
    sleep 1
  done
  return 1
}
observe() {
  "$binary" --kubeconfig "$KUBECONFIG" --context "$KUBE_CONTEXT" --namespace "$DURABLE_NAMESPACE" --guard "$here/guard.sh" --observe-child "$current_pod" --observe-uid "$1" --observe-runtime-id "$2"
}
observe_cleanup() {
  local folder=$1 allocation uid
  while IFS=$'\t' read -r allocation uid; do
    observe "$uid" "$allocation" > "$folder/$allocation.runtime-after-cleanup.json"
    jq -e '.ready==false and (.vmPIDs|length)==0' "$folder/$allocation.runtime-after-cleanup.json" >/dev/null
  done < <(jq -r '.[]|[.id,.metadata.uid]|@tsv' "$folder/observed-sandboxes.json")
  [[ $(k get pods -o json | jq '.items|length') == 0 ]]
}
run_guardian() {
  env -u KUBECONFIG -u KUBE_CONTEXT "$here/runtime-guardian.sh" "$1/binding.json" "$1" > "$1/guardian.stdout.log" 2> "$1/guardian.stderr.log"
  jq -e '.initialVMGone==true and .disposalProven==false and .replayPrevented==false and .observationDurationNanoseconds>=30000000000' "$1/summary.json" >/dev/null
}
if existing=$(k get namespace "$DURABLE_NAMESPACE" -o json 2>/dev/null); then
  jq -e '.metadata.labels["foundation.sandbox.p5.dev/owner"]=="durable"' <<< "$existing" >/dev/null
else
  k create namespace "$DURABLE_NAMESPACE" >/dev/null
  k label namespace "$DURABLE_NAMESPACE" foundation.sandbox.p5.dev/owner=durable >/dev/null
fi
k get crd executions.foundation.sandbox.p5.dev >/dev/null
jq -n --arg ns "$DURABLE_NAMESPACE" '{apiVersion:"v1",kind:"ServiceAccount",metadata:{name:"durable-guest",namespace:$ns},automountServiceAccountToken:false}' | k apply -f - >/dev/null
[[ $(k get pods -o json | jq '.items|length') == 0 ]]
for scenario in absolute-deadline allocation-lease; do
  case_results="$results/$scenario"
  mkdir -p "$case_results"
  if k get fexec "$scenario" -o json > "$case_results/previous.json" 2>/dev/null; then
    if ! jq -e '.status.cleanupComplete==true' "$case_results/previous.json" >/dev/null; then
      k patch fexec "$scenario" --type=merge -p '{"spec":{"cancel":true}}' >/dev/null
      start_controller "$case_results/interrupted-run-recovery.log"
      wait_execution "$scenario" '.status.cleanupComplete==true' "$case_results/interrupted-run-recovered.json"
      stop_controller
    fi
    k delete fexec "$scenario" --wait=true --timeout=30s >/dev/null
  fi
  ttl=45
  [[ "$scenario" == allocation-lease ]] && ttl=120
  deadline=$(date -u -d "+$ttl seconds" +%Y-%m-%dT%H:%M:%SZ)
  jq -n --arg name "$scenario" --arg ns "$DURABLE_NAMESPACE" --arg deadline "$deadline" --arg command "$guest_command" '{apiVersion:"foundation.sandbox.p5.dev/v1alpha1",kind:"Execution",metadata:{name:$name,namespace:$ns},spec:{ownerID:"guardian-prototype",attemptID:"a1",sourceDigest:("sha256:"+("1"*64)),profileDigest:("sha256:"+("2"*64)),image:"konflux-sandbox-runtime:prototype",mode:"session",command:["/bin/sh","-c",$command],deadline:$deadline}}' > "$case_results/execution.input.json"
  k create -f "$case_results/execution.input.json" >/dev/null
  start_controller "$case_results/controller.log"
  wait_execution "$scenario" '.status.phase=="Running" and .status.vmObserved==true' "$case_results/running-execution.json"
  current_pod=$(jq -r .status.childName "$case_results/running-execution.json")
  current_uid=$(jq -r .status.childUID "$case_results/running-execution.json")
  k get pod "$current_pod" -o json > "$case_results/running-pod.json"
  k logs "$current_pod" > "$case_results/initial-guest.log"
  rg '^EXECUTION_START=guardian-a1$' "$case_results/initial-guest.log" >/dev/null
  lease_expires=
  [[ "$scenario" == allocation-lease ]] && lease_expires=$(date -u -d '+12 seconds' +%Y-%m-%dT%H:%M:%SZ)
  jq --arg lease "$lease_expires" '{namespace:.metadata.namespace,executionUID:.metadata.uid,podName:.status.childName,podUID:.status.childUID,sandboxID:.status.runtimeSandboxID,deadline:.spec.deadline,leaseExpires:$lease}' "$case_results/running-execution.json" > "$case_results/binding.json"
  stop_controller
  run_guardian "$case_results"
  k get pod "$current_pod" -o json > "$case_results/pod-after-outage.json"
  k get fexec "$scenario" -o json > "$case_results/execution-after-outage.json"
  k patch fexec "$scenario" --type=merge -p '{"spec":{"cancel":true}}' >/dev/null
  start_controller "$case_results/recovery-controller.log"
  wait_execution "$scenario" '.status.cleanupComplete==true' "$case_results/completed-execution.json"
  stop_controller
  observe_cleanup "$case_results"
  current_pod=
  current_uid=
done

# The actual Agent Sandbox controller owns this restartable session allocation.
case_results="$results/restartable-session"
mkdir -p "$case_results"
current_sandbox=exec-restartable-session
if existing=$(k get sandbox "$current_sandbox" -o json 2>/dev/null); then
  jq -e '.spec.operatingMode=="Suspended"' <<< "$existing" >/dev/null
  k delete sandbox "$current_sandbox" --wait=true --timeout=30s >/dev/null
fi
deadline=$(date -u -d '+120 seconds' +%Y-%m-%dT%H:%M:%SZ)
jq -n --arg name "$current_sandbox" --arg ns "$DURABLE_NAMESPACE" --arg deadline "$deadline" --arg command "$guest_command" '{
 apiVersion:"agents.x-k8s.io/v1beta1",kind:"Sandbox",metadata:{name:$name,namespace:$ns},
 spec:{operatingMode:"Running",shutdownTime:$deadline,shutdownPolicy:"Retain",service:false,podTemplate:{spec:{
  runtimeClassName:"kata-prototype",serviceAccountName:"durable-guest",automountServiceAccountToken:false,
  restartPolicy:"Always",activeDeadlineSeconds:120,terminationGracePeriodSeconds:1,
  securityContext:{runAsUser:1000,runAsGroup:1000,fsGroup:1000},containers:[{
   name:"guest",image:"konflux-sandbox-runtime:prototype",imagePullPolicy:"Never",command:["/bin/sh","-c",$command],
   resources:{requests:{cpu:"100m",memory:"128Mi"},limits:{cpu:"1",memory:"512Mi"}},
   securityContext:{allowPrivilegeEscalation:false,capabilities:{drop:["ALL"]}}
  }]
 }}}}' > "$case_results/sandbox.input.json"
k create -f "$case_results/sandbox.input.json" >/dev/null
current_sandbox_uid=$(k get sandbox "$current_sandbox" -o jsonpath='{.metadata.uid}')
for _ in {1..90}; do
  if k get pod "$current_sandbox" -o json > "$case_results/running-pod.json" 2>/dev/null && jq -e '.status.phase=="Running" and any(.status.conditions[]?;.type=="Ready" and .status=="True")' "$case_results/running-pod.json" >/dev/null; then break; fi
  sleep 1
done
jq -e --arg uid "$current_sandbox_uid" '.spec.restartPolicy=="Always" and any(.metadata.ownerReferences[]?;.uid==$uid and .kind=="Sandbox") and .status.phase=="Running"' "$case_results/running-pod.json" >/dev/null
current_pod=$current_sandbox
current_uid=$(jq -r .metadata.uid "$case_results/running-pod.json")
observe "$current_uid" "" > "$case_results/initial-runtime.json"
jq -e '.ready and (.vmPIDs|length)==1' "$case_results/initial-runtime.json" >/dev/null
k logs "$current_pod" > "$case_results/initial-guest.log"
rg '^EXECUTION_START=guardian-a1$' "$case_results/initial-guest.log" >/dev/null
lease_expires=$(date -u -d '+12 seconds' +%Y-%m-%dT%H:%M:%SZ)
jq -n --arg ns "$DURABLE_NAMESPACE" --arg name "$current_pod" --arg uid "$current_uid" --arg ownerUID "$current_sandbox_uid" --arg sid "$(jq -r .sandboxID "$case_results/initial-runtime.json")" --arg deadline "$deadline" --arg lease "$lease_expires" '{namespace:$ns,podName:$name,podUID:$uid,ownerKind:"Sandbox",ownerUID:$ownerUID,sandboxID:$sid,deadline:$deadline,leaseExpires:$lease}' > "$case_results/binding.json"
run_guardian "$case_results"
k get pod "$current_pod" -o json > "$case_results/pod-after-outage.json"
k get sandbox "$current_sandbox" -o json > "$case_results/sandbox-after-outage.json"
jq -e --arg uid "$current_sandbox_uid" 'any(.metadata.ownerReferences[]?;.kind=="Sandbox" and .uid==$uid)' "$case_results/pod-after-outage.json" >/dev/null
patch=$(jq -n --arg uid "$current_sandbox_uid" '[{op:"test",path:"/metadata/uid",value:$uid},{op:"replace",path:"/spec/operatingMode",value:"Suspended"}]')
k patch sandbox "$current_sandbox" --type=json -p "$patch" >/dev/null
for _ in {1..120}; do
  if absent=$(k get pod "$current_pod" --ignore-not-found -o name) && [[ -z "$absent" ]]; then break; fi
  sleep 1
done
observe_cleanup "$case_results"
current_pod=
current_uid=
current_sandbox=
current_sandbox_uid=
printf '%s\n' 'PASS: runtime-local absolute deadline and lease stop; restartable Agent Sandbox replay observations; no prevention claim' | tee "$results/summary.txt"
