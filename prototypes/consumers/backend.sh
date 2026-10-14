#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ../runtime/context.sh
require_runtime_context /tmp/konflux-sandbox-runtime/vm-kubeconfig kind-konflux-sandbox-vm-prototype
k(){ runtime_k "$@"; }
action=$1;state=$2;request=$3;kind=$4
[[ $request == finite || $request == session ]]
[[ $kind == finite || $kind == session ]]
namespace=foundation-consumers-prototype
child=$state/$request
mkdir -p "$child"
test -f "$state/namespace-uid"
test "$(k get namespace "$namespace" -o jsonpath='{.metadata.uid}')" = "$(cat "$state/namespace-uid")"
config=/tmp/konflux-sandbox-runtime/vm-kubeconfig
issuer=$state/issuer
issue(){ .build/identity issue "$issuer" alice "$request" 1 "$uid" "$1" 300; }
bundle(){ local record=$1 destination=$2;mkdir -p "$destination";cp "$(jq -r .ca <<<"$record")" "$destination/ca.crt";cp "$(jq -r .cert <<<"$record")" "$destination/tls.crt";cp "$(jq -r .key <<<"$record")" "$destination/tls.key"; }
load(){ pod=$(jq -r .pod "$child/backend.json");uid=$(jq -r .guestUID "$child/backend.json");gateway_address=$(cat "$state/gateway/address");host_ip=$(jq -r .hostIP "$state/platform.json"); }
request_tls(){ local method=$1 path=$2;shift 2;curl -sS --max-time 10 --noproxy '*' --cacert "$child/control/ca.crt" --cert "$child/control/tls.crt" --key "$child/control/tls.key" --resolve "gateway.prototype:${gateway_address##*:}:$host_ip" -H "X-Guest-UID: $uid" -X "$method" "https://gateway.prototype:${gateway_address##*:}$path" "$@"; }
rpc(){ grpcurl -max-time 30 -cacert "$child/control/ca.crt" -cert "$child/control/tls.crt" -key "$child/control/tls.key" -servername gateway.prototype -H "X-Guest-UID: $uid" -import-path ../../../agent-sandbox/packages/sandboxd/spec -proto process/v1/process.proto -d "$2" "$gateway_address" "process.v1.ProcessService/$1"; }
case "$action" in
 start)
  image=$(cat "$state/image-reference")
  marker_start=:
  if [[ -f $state/recovery-enabled ]];then marker_start="marker notify http://marker.test:8080/startup/$request $(jq -r .proxy "$state/platform.json")";fi
  if [[ $kind == finite ]];then
   cat <<EOF | k apply -f -
apiVersion: tekton.dev/v1
kind: TaskRun
metadata: {name: consumer-finite, namespace: $namespace}
spec:
  serviceAccountName: consumer-runner
  podTemplate: {runtimeClassName: kata-prototype, automountServiceAccountToken: false}
  taskSpec:
    results: [{name: kernel}, {name: outcome}]
    steps:
    - name: check
      image: $image
      imagePullPolicy: Never
      computeResources: {requests: {cpu: 100m, memory: 128Mi}, limits: {cpu: '1', memory: 512Mi}}
      script: |
        #!/bin/bash
        set -euo pipefail
        $marker_start
        while [[ ! -f /workspace/run-approved ]];do sleep 0.1;done
        bash /workspace/approved.sh > /workspace/output.log 2>&1
        cat /workspace/output.log
        uname -r > \$(results.kernel.path)
        printf passed > \$(results.outcome.path)
EOF
   for _ in {1..120};do pod=$(k get taskrun consumer-finite -n "$namespace" -o jsonpath='{.status.podName}');[[ -n $pod ]]&&break;sleep 0.5;done
   backend=kata-taskrun
  else
   cat <<EOF | k apply -f -
apiVersion: agents.x-k8s.io/v1beta1
kind: Sandbox
metadata: {name: consumer-session, namespace: $namespace}
spec:
  podTemplate:
    spec:
      runtimeClassName: kata-prototype
      serviceAccountName: consumer-runner
      automountServiceAccountToken: false
      terminationGracePeriodSeconds: 2
      containers:
      - name: session
        image: $image
        imagePullPolicy: Never
        command: [sh, -ec, '$marker_start; exec sleep 3600']
        resources: {requests: {cpu: 100m, memory: 128Mi}, limits: {cpu: '1', memory: 512Mi}}
EOF
   pod=consumer-session;backend=agent-sandbox
  fi
  k wait pod/"$pod" -n "$namespace" --for=condition=Ready --timeout=120s
  k get pod "$pod" -n "$namespace" -o json >"$child/pod.json"
  uid=$(jq -r .metadata.uid "$child/pod.json");guest_ip=$(jq -r .status.podIP "$child/pod.json")
  jq -e '.spec.runtimeClassName=="kata-prototype" and .spec.automountServiceAccountToken==false' "$child/pod.json" >/dev/null
  test "$(jq -r '.spec.containers[0].image' "$child/pod.json")" = "$image"
  container_id=$(jq -r '.status.containerStatuses[0].containerID|sub("^containerd://";"")' "$child/pod.json")
  docker exec konflux-sandbox-vm-prototype-control-plane ctr -n k8s.io containers info "$container_id" >"$child/container.json"
  test "$(jq -r '.Spec.annotations["io.kubernetes.cri.image-name"]' "$child/container.json")" = "$image"
  runtime_image=$(jq -r .Image "$child/container.json")
  runtime_digest=$(docker exec konflux-sandbox-vm-prototype-control-plane ctr -n k8s.io images ls | awk -v name="$runtime_image" '$1==name {print $3}')
  test "$runtime_digest" = "$(jq -r .toolDigest "$state/config.json")"
  docker exec konflux-sandbox-vm-prototype-control-plane ctr -n k8s.io content get "${image##*@}" >"$child/image-manifest.json"
  test "sha256:$(sha256sum "$child/image-manifest.json"|cut -d' ' -f1)" = "$(jq -r .toolDigest "$state/config.json")"
  jq -n --arg pod "$pod" --arg uid "$uid" --arg backend "$backend" '{pod:$pod,guestUID:$uid,backend:$backend}' | .build/statewrite "$child/backend.json"
  if [[ -f $state/recovery-enabled ]];then
   resource=taskrun/consumer-finite;[[ $kind != session ]]||resource=sandbox/consumer-session
   resource_uid=$(k get "$resource" -n "$namespace" -o jsonpath='{.metadata.uid}')
   sid=$(docker exec konflux-sandbox-vm-prototype-control-plane crictl pods -o json | jq -r --arg uid "$uid" '.items[]|select(.metadata.uid==$uid and .state=="SANDBOX_READY")|.id')
   [[ $sid =~ ^[a-f0-9]{64}$ ]]
   jq -n --arg owner alice --arg request "$request" --arg attempt 1 --arg namespaceUID "$(cat "$state/namespace-uid")" --arg uid "$uid" --arg sid "$sid" --arg resource "$resource" --arg resourceUID "$resource_uid" --arg source "$(jq -r .sourceDigest "$state/config.json")" --arg profile "$(jq -r .profileDigest "$state/config.json")" --arg tool "$(jq -r .toolDigest "$state/config.json")" '{owner:$owner,request:$request,attempt:$attempt,namespaceUID:$namespaceUID,podUID:$uid,runtimeSandboxID:$sid,resource:$resource,resourceUID:$resourceUID,sourceDigest:$source,profileDigest:$profile,toolDigest:$tool}' | .build/statewrite "$child/binding.json"
  fi
  identity=$(jq -n --arg request "$request" --arg uid "$uid" '{owner:"alice",request:$request,attempt:"1",guestUID:$uid}')
  server=$(issue server);bundle "$server" "$child/identity";bundle "$(issue execution)" "$child/identity/execution";bundle "$(issue control)" "$child/control"
  printf '%s\n' "$identity" >"$child/identity/identity.json"
  tar -C "$child" -cf - identity | k exec -i -n "$namespace" "$pod" -- tar -C /workspace -xf -
  k exec -n "$namespace" "$pod" -- sh -c 'nohup sandboxd --listen-host=127.0.0.1 >/tmp/sandboxd.log 2>&1 & nohup identity guest /workspace/identity >/tmp/identity.log 2>&1 &'
  cat <<EOF | k apply -f -
apiVersion: v1
kind: Pod
metadata: {name: relay-$request, namespace: $namespace, labels: {app: relay-$request}}
spec:
  serviceAccountName: consumer-runner
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: 1
  containers:
  - name: relay
    image: konflux-sandbox-runtime:prototype
    imagePullPolicy: Never
    command: [socat, 'TCP-LISTEN:8443,reuseaddr,fork', 'TCP:$guest_ip:8443']
---
apiVersion: v1
kind: Service
metadata: {name: relay-$request, namespace: $namespace}
spec:
  type: NodePort
  selector: {app: relay-$request}
  ports: [{port: 8443, targetPort: 8443}]
EOF
  k wait pod/relay-"$request" -n "$namespace" --for=condition=Ready --timeout=60s
  relay_ip=$(k get pod relay-"$request" -n "$namespace" -o jsonpath='{.status.podIP}')
  node_ip=$(jq -r .nodeIP "$state/platform.json");port=$(k get service relay-"$request" -n "$namespace" -o jsonpath='{.spec.ports[0].nodePort}')
  jq -n --argjson id "$identity" --arg uid "$uid" --arg request "$request" --arg url "https://$node_ip:$port" --arg sni "$(jq -r .serverName <<<"$server")" --arg tls "$child/control" '{active:{("alice/"+$request+"/1"):$uid},routes:{($uid):{identity:$id,url:$url,serverName:$sni,tlsDir:$tls}}}' >"$state/gateway/routes.tmp";mv "$state/gateway/routes.tmp" "$state/gateway/routes.json"
  load
  for _ in {1..100};do if request_tls GET /v1/health -f >/dev/null 2>&1;then break;fi;sleep 0.1;done
  request_tls PUT /v1/files/source.tar --data-binary @"$state/source.tar" -f >/dev/null
  request_tls PUT /v1/files/manifest.json --data-binary @"$state/manifest.json" -f >/dev/null
  source=$(jq -r .sourceDigest "$state/config.json")
  rpc Execute "$(jq -nc --arg source "$source" '{config:{command:["source-helper","import-verify","/workspace/source.tar","/workspace/manifest.json","/workspace/tree",$source],cwd:"/workspace"}}')" >"$child/import.json"
  test "$(jq -r '.exitCode//0' "$child/import.json")" = 0
  jq -r '.stdout|@base64d' "$child/import.json" | grep -q 'PASS source import'
  proxy=$(jq -r .proxy "$state/platform.json");origin=$(jq -r .originIP "$state/platform.json")
  k exec -i -n "$namespace" "$pod" -- sh -c 'mkdir -p /workspace/public;cat > /workspace/public/ca.crt' <"$state/firewall-certs/ca.crt"
  cat >"$child/approved.sh" <<EOF
#!/bin/bash
set -euo pipefail
cd /workspace/tree
$(if [[ -f $state/recovery-enabled ]];then printf 'marker notify http://marker.test:8080/command/%s %s' "$request" "$proxy";else printf ':';fi)
./run.sh
test "\$(cat staged.txt)" = staged
test "\$(cat unstaged.txt)" = unstaged
test "\$(cat selected.txt)" = selected
test "\$(readlink link)" = unstaged.txt
test ! -e deleted.txt
test ! -e excluded.txt
firewall -mode request -proxy '$proxy' -dir /workspace/public -url http://allowed.test:8080/
firewall -mode request -proxy '$proxy' -dir /workspace/public -url https://allowed.test:9443/
firewall -mode request -proxy '$proxy' -dir /workspace/public -url http://blocked.test:8080/ -expect 403
firewall -mode raw -url '$origin:8080'
test ! -e /var/run/secrets/kubernetes.io/serviceaccount/token
echo CHECK_PASSED
EOF
  request_tls PUT /v1/files/approved.sh --data-binary @"$child/approved.sh" -f >/dev/null
  bash ../firewall/fence.sh install "$config" "$child/fence.json" "$namespace" "$pod" "$(jq -r .gatewayIP "$state/platform.json")" "$relay_ip" >"$child/fence-install.log"
  jq -e --arg uid "$uid" '.ready==true and .podUID==$uid' "$child/fence.json" >/dev/null
  if [[ -f $state/recovery-enabled ]];then
   rules_digest=$(bash fence-state.sh "$child/fence.json" | sha256sum | cut -d' ' -f1)
   gateway_uid=$(k get pod firewall-gateway -n "$namespace" -o jsonpath='{.metadata.uid}')
   jq --arg rules "$rules_digest" --arg gateway "$gateway_uid" '.fenceRulesDigest=$rules|.gatewayUID=$gateway' "$child/binding.json" | .build/statewrite "$child/binding.json"
  fi
  request_tls GET /v1/health -f >/dev/null
  k logs firewall-gateway -n "$namespace" >"$child/gateway-before.log"
  echo 'PASS shared source import, actual UID identity, and externally enforced profile ready'
  ;;
 inspect)
  load
  rpc Start '{"config":{"command":["sh","-c","cat tree/selected.txt; echo session-ready; sleep 0.1; echo session-stream"],"cwd":"/workspace"}}' >"$child/inspect.json"
  jq -rs '[.[]|.stdout//empty|@base64d]|join("")' "$child/inspect.json" >"$child/inspect.txt"
  grep -q session-stream "$child/inspect.txt"
  ;;
 finish|execute)
  load
  if [[ $kind == finite ]];then
   request_tls PUT /v1/files/run-approved --data ready -f >/dev/null
   k wait taskrun/consumer-finite -n "$namespace" --for=jsonpath='{.status.completionTime}' --timeout=120s
   k get taskrun consumer-finite -n "$namespace" -o json >"$child/taskrun.json"
   jq -e '.status.conditions[]|select(.type=="Succeeded")|.status=="True"' "$child/taskrun.json" >/dev/null
   k logs "$pod" -n "$namespace" -c step-check >"$child/output.log"
   kernel=$(jq -r '.status.results[]|select(.name=="kernel")|.value' "$child/taskrun.json")
  else
   rpc Execute '{"config":{"command":["bash","/workspace/approved.sh"],"cwd":"/workspace"}}' >"$child/check.json"
   test "$(jq -r '.exitCode//0' "$child/check.json")" = 0
   jq -r '.stdout|@base64d' "$child/check.json" >"$child/output.log"
   rpc Execute '{"config":{"command":["uname","-r"],"cwd":"/workspace"}}' >"$child/kernel.json"
   kernel=$(jq -r '.stdout|@base64d' "$child/kernel.json")
  fi
  grep -q CHECK_PASSED "$child/output.log"
  k logs firewall-gateway -n "$namespace" >"$child/gateway-after.log"
  previous=$(wc -l <"$child/gateway-before.log")
  tail -n "+$((previous+1))" "$child/gateway-after.log" >"$child/gateway-audit.jsonl"
  jq -es 'any(.[];.action=="allow" and (.destination|contains("allowed.test"))) and any(.[];.action=="deny" and (.destination|contains("blocked.test")))' "$child/gateway-audit.jsonl" >/dev/null
  node_kernel=$(docker exec konflux-sandbox-vm-prototype-control-plane uname -r)
  test -n "$kernel";test "$kernel" != "$node_kernel"
  jq -n --arg uid "$uid" --arg source "$(jq -r .sourceDigest "$state/config.json")" --arg profile "$(jq -r .profileDigest "$state/config.json")" --arg kernel "$kernel" --arg node "$node_kernel" '{pod_uid:$uid,runtime_class:"kata-prototype",guest_kernel:$kernel,node_kernel:$node,profile_digest:$profile,source_import:"pinned-manifest-and-bounded-archive",egress:"external-veth-fence-and-policy-gateway",allowed_domain:"observed-pass",forbidden_domain:"observed-403",direct_bypass:"observed-blocked"}' >"$child/observed.json"
  jq -n --arg source "$(jq -r .sourceDigest "$state/config.json")" --arg kernel "$kernel" '{status:"passed",sourceDigest:$source,guestKernel:$kernel}' >"$child/output.json"
  if [[ $action == finish ]];then
   bash "$0" stop "$state" "$request" "$kind"
   jq '.cleanup="guest-and-fence-removed"' "$child/observed.json" >"$child/observed.tmp";mv "$child/observed.tmp" "$child/observed.json"
  fi
  ;;
 adopt|verify-cleanup)
  load
  test "$(jq -r .podUID "$child/binding.json")" = "$uid"
  test "$(jq -r .namespaceUID "$child/binding.json")" = "$(cat "$state/namespace-uid")"
  resource=$(jq -r .resource "$child/binding.json")
  current_resource=$(k get "$resource" -n "$namespace" -o json --ignore-not-found)
  if [[ -n $current_resource ]];then test "$(jq -r .metadata.uid <<<"$current_resource")" = "$(jq -r .resourceUID "$child/binding.json")";fi
  current_pod=$(k get pod "$pod" -n "$namespace" -o json --ignore-not-found)
  sid=$(jq -r .runtimeSandboxID "$child/binding.json")
  cri=$(docker exec konflux-sandbox-vm-prototype-control-plane crictl pods -o json)
  jq -e --arg uid "$uid" --arg sid "$sid" 'all(.items[]; .metadata.uid!=$uid or .state!="SANDBOX_READY" or .id==$sid)' <<<"$cri" >/dev/null
  if [[ -n $current_pod ]];then
   test "$(jq -r .metadata.uid <<<"$current_pod")" = "$uid"
   jq -e --arg owner "$(jq -r .resourceUID "$child/binding.json")" 'any(.metadata.ownerReferences[];.uid==$owner)' <<<"$current_pod" >/dev/null
  fi
  if [[ $action == adopt ]];then
   test -n "$current_pod";test -n "$current_resource"
   jq -e --arg sid "$sid" 'any(.items[];.id==$sid and .state=="SANDBOX_READY")' <<<"$cri" >/dev/null
   jq -e '.spec.runtimeClassName=="kata-prototype" and .spec.automountServiceAccountToken==false' <<<"$current_pod" >/dev/null
   jq -e --arg uid "$uid" --arg sid "$sid" '.ready==true and .podUID==$uid and .runtimeSandboxID==$sid' "$child/fence.json" >/dev/null
   qemu=$(docker exec konflux-sandbox-vm-prototype-control-plane ps -eo pid,comm,args | awk -v sid="$sid" '$2 ~ /^qemu-system/ && index($0,sid)>0 {print $1}')
   test -n "$qemu"
   test "$qemu" = "$(jq -r .qemuPID "$child/fence.json")"
   test "$(bash fence-state.sh "$child/fence.json"|sha256sum|cut -d' ' -f1)" = "$(jq -r .fenceRulesDigest "$child/binding.json")"
   gateway=$(k get pod firewall-gateway -n "$namespace" -o json)
   jq -e --arg uid "$(jq -r .gatewayUID "$child/binding.json")" '.metadata.uid==$uid and any(.status.conditions[];.type=="Ready" and .status=="True")' <<<"$gateway" >/dev/null
   policy_digest=$(k get configmap firewall-policy -n "$namespace" -o json|jq -j '.data["policy.json"]'|sha256sum|cut -d' ' -f1)
   test "sha256:$policy_digest" = "$(jq -r .profileDigest "$child/binding.json")"
   chain=$(jq -r .chain "$child/fence.json");incoming=$(jq -r .incomingChain "$child/fence.json");interface=$(jq -r .interface "$child/fence.json")
   for family in iptables ip6tables;do
    for hook in INPUT FORWARD;do docker exec konflux-sandbox-vm-prototype-control-plane "$family" -C "$hook" -i "$interface" -j "$chain";done
    for hook in OUTPUT FORWARD;do docker exec konflux-sandbox-vm-prototype-control-plane "$family" -C "$hook" -o "$interface" -j "$incoming";done
   done
  fi
  echo 'PASS exact namespace, owner, Pod UID, CRI allocation, and fence binding'
  ;;
 stop)
  if [[ -f $child/backend.json && -f $state/gateway/routes.json ]];then
   load
   jq --arg uid "$uid" --arg request "$request" 'del(.active["alice/"+$request+"/1"],.routes[$uid])' "$state/gateway/routes.json" >"$state/gateway/routes.tmp";mv "$state/gateway/routes.tmp" "$state/gateway/routes.json"
  fi
  if [[ $kind == finite ]];then k delete taskrun consumer-finite -n "$namespace" --ignore-not-found --wait=true --timeout=60s;else k delete sandbox consumer-session -n "$namespace" --ignore-not-found --wait=true --timeout=60s;fi
  if [[ -f $child/backend.json ]];then load;k wait pod/"$pod" -n "$namespace" --for=delete --timeout=60s;fi
  bash ../firewall/fence.sh remove "$config" "$child/fence.json"
  if [[ -f $child/fence.json ]];then jq -e '.runtimeRemovalVerified==true' "$child/fence.json" >/dev/null;fi
  k delete pod relay-"$request" -n "$namespace" --ignore-not-found --wait=true
  k delete service relay-"$request" -n "$namespace" --ignore-not-found
  ;;
 *)echo 'Unsupported backend action' >&2;exit 1;;
esac
