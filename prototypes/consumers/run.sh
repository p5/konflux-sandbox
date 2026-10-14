#!/usr/bin/env bash
set -euo pipefail
umask 077
export GOFLAGS=-p=2 GOMAXPROCS=2
cd "$(dirname "$0")"
source ../runtime/context.sh
require_runtime_context /tmp/konflux-sandbox-runtime/vm-kubeconfig kind-konflux-sandbox-vm-prototype
k(){ runtime_k "$@"; }
namespace=foundation-consumers-prototype
client_namespace=foundation-consumers-clients-prototype
namespace_owned=false
clients_owned=false
mkdir -p .state evidence
state=$(mktemp -d "$PWD/.state/run.XXXXXX")
capture=evidence/run.log
if [[ ${CONSUMER_RECOVERY:-0} == 1 ]];then touch "$state/recovery-enabled";capture=evidence/recovery-run.log;fi
exec > >(tee "$capture") 2>&1
cleanup(){
 status=$?;trap - EXIT;cleanup_safe=true
 if $namespace_owned;then
  if [[ $(k get namespace "$namespace" -o jsonpath='{.metadata.uid}' 2>/dev/null) == "$(cat "$state/namespace-uid")" ]];then
   for req in finite session;do if [[ -f $state/$req/backend.json ]];then bash backend.sh stop "$state" "$req" "$req" >"$state/$req-cleanup.log" 2>&1||{ status=1;cleanup_safe=false; };fi;done
   if $cleanup_safe;then k delete namespace "$namespace" --wait=true --timeout=90s >evidence/cleanup.log 2>&1||status=1;fi
  fi
 fi
 kill "${foundation_pid:-}" "${gateway_pid:-}" "${forward_pid:-}" "${marker_forward_pid:-}" 2>/dev/null||true
 if [[ -f $state/foundation.pid ]];then kill "$(cat "$state/foundation.pid")" 2>/dev/null||true;fi
 if $clients_owned && [[ $(k get namespace "$client_namespace" -o jsonpath='{.metadata.uid}' 2>/dev/null) == "$(cat "$state/client-namespace-uid")" ]];then k delete namespace "$client_namespace" --wait=true --timeout=90s >/dev/null||status=1;fi
 exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
k create namespace "$namespace"
namespace_owned=true
k get namespace "$namespace" -o jsonpath='{.metadata.uid}' >"$state/namespace-uid"
k label namespace "$namespace" konflux-sandbox.prototype/owner=consumers
k create namespace "$client_namespace"
clients_owned=true
k get namespace "$client_namespace" -o jsonpath='{.metadata.uid}' >"$state/client-namespace-uid"
k label namespace "$client_namespace" konflux-sandbox.prototype/owner=consumers
k create serviceaccount consumer-runner -n "$namespace"
k create serviceaccount external-client -n "$client_namespace"
cp ../../.prototype-state/artifacts/source.tar ../../.prototype-state/artifacts/manifest.json "$state/"
.build/firewall -mode certs -dir "$state/firewall-certs"
k create secret generic firewall-certs -n "$namespace" --from-file="$state/firewall-certs"
cat <<EOF | k apply -f -
apiVersion: v1
kind: Pod
metadata: {name: origin, namespace: $namespace}
spec:
  serviceAccountName: consumer-runner
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: 1
  containers:
  - name: origin
    image: konflux-sandbox-firewall:prototype
    imagePullPolicy: Never
    args: [-mode, fixture, -marker, CONSUMER]
    volumeMounts: [{name: certs, mountPath: /certs, readOnly: true}]
    readinessProbe: {tcpSocket: {port: 8080}, periodSeconds: 1}
    resources: {requests: {cpu: 50m, memory: 32Mi}, limits: {memory: 128Mi}}
  volumes: [{name: certs, secret: {secretName: firewall-certs}}]
EOF
k wait pod/origin -n "$namespace" --for=condition=Ready --timeout=60s
origin=$(k get pod origin -n "$namespace" -o jsonpath='{.status.podIP}')
node_ip=$(k get node konflux-sandbox-vm-prototype-control-plane -o json | jq -r '.status.addresses[]|select(.type=="InternalIP")|.address')
host_ip=$(docker inspect konflux-sandbox-vm-prototype-control-plane --format '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}')
marker_ip=
if [[ -f $state/recovery-enabled ]];then
 cat <<EOF | k apply -f -
apiVersion: v1
kind: Pod
metadata: {name: marker, namespace: $namespace}
spec:
  serviceAccountName: consumer-runner
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: 1
  containers:
  - name: marker
    image: konflux-sandbox-consumers:prototype
    imagePullPolicy: Never
    command: [marker, serve]
    readinessProbe: {tcpSocket: {port: 8080}, periodSeconds: 1}
    resources: {requests: {cpu: 50m, memory: 32Mi}, limits: {memory: 128Mi}}
EOF
 k wait pod/marker -n "$namespace" --for=condition=Ready --timeout=60s
 marker_ip=$(k get pod marker -n "$namespace" -o jsonpath='{.status.podIP}')
 k port-forward -n "$namespace" pod/marker 0:8080 >"$state/marker-forward.log" 2>&1 &marker_forward_pid=$!
 for _ in {1..100};do marker_port=$(awk '/Forwarding from 127.0.0.1:/{split($3,a,":");print a[2];exit}' "$state/marker-forward.log");[[ -n $marker_port ]]&&break;sleep 0.05;done
 printf 'http://127.0.0.1:%s' "$marker_port" >"$state/marker-address"
fi
jq -n --arg origin "$origin" --arg node "$node_ip" '{execution:"consumer-foundation",revision:"fixture-v1",domains:["allowed.test"],ips:[],resolvedPrivateIPs:[($origin+"/32")],domainPorts:[8080,9443],ipPorts:[],protected:[($node+"/32"),"10.96.0.0/12"],dns:($origin+":1053"),protocols:["tcp"],ipv6:false,opaqueDomains:false}' >"$state/policy.json"
if [[ -n $marker_ip ]];then jq --arg ip "$marker_ip" '.domains+=["marker.test"]|.resolvedPrivateIPs+=[($ip+"/32")]' "$state/policy.json" >"$state/policy.tmp";mv "$state/policy.tmp" "$state/policy.json";fi
.build/firewall -mode validate -config "$state/policy.json"
k create configmap firewall-policy -n "$namespace" --from-file=policy.json="$state/policy.json"
k patch configmap firewall-policy -n "$namespace" --type merge -p '{"immutable":true}'
cat <<EOF | k apply -f -
apiVersion: v1
kind: Pod
metadata: {name: firewall-gateway, namespace: $namespace}
spec:
  serviceAccountName: consumer-runner
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: 1
  containers:
  - name: gateway
    image: konflux-sandbox-firewall:prototype
    imagePullPolicy: Never
    args: [-mode, gateway, -config, /policy/policy.json]
    env: [{name: POD_IP, valueFrom: {fieldRef: {fieldPath: status.podIP}}}]
    readinessProbe: {tcpSocket: {port: 8080}, periodSeconds: 1}
    resources: {requests: {cpu: 50m, memory: 32Mi}, limits: {memory: 128Mi}}
    volumeMounts: [{name: certs, mountPath: /certs, readOnly: true}, {name: policy, mountPath: /policy, readOnly: true}]
  volumes: [{name: certs, secret: {secretName: firewall-certs}}, {name: policy, configMap: {name: firewall-policy}}]
EOF
k wait pod/firewall-gateway -n "$namespace" --for=condition=Ready --timeout=60s
gateway_ip=$(k get pod firewall-gateway -n "$namespace" -o jsonpath='{.status.podIP}')
k port-forward -n "$namespace" pod/origin 0:9090 >"$state/origin-forward.log" 2>&1 &forward_pid=$!
for _ in {1..100};do admin_port=$(awk '/Forwarding from 127.0.0.1:/{split($3,a,":");print a[2];exit}' "$state/origin-forward.log");[[ -n $admin_port ]]&&break;sleep 0.05;done
curl -fsS --max-time 5 -X PUT "http://127.0.0.1:$admin_port/dns?name=allowed.test&ip=$origin"
if [[ -n $marker_ip ]];then curl -fsS --max-time 5 -X PUT "http://127.0.0.1:$admin_port/dns?name=marker.test&ip=$marker_ip";fi
jq -n --arg host "$host_ip" --arg node "$node_ip" --arg origin "$origin" --arg gateway "$gateway_ip" '{hostIP:$host,nodeIP:$node,originIP:$origin,gatewayIP:$gateway,proxy:("http://"+$gateway+":8080")}' >"$state/platform.json"
image_digest=$(docker exec konflux-sandbox-vm-prototype-control-plane ctr -n k8s.io images ls | awk '$1=="docker.io/library/konflux-sandbox-consumers:prototype" {print $3}')
[[ $image_digest =~ ^sha256:[a-f0-9]{64}$ ]]
image="docker.io/library/konflux-sandbox-consumers@$image_digest"
docker exec konflux-sandbox-vm-prototype-control-plane ctr -n k8s.io images tag --force docker.io/library/konflux-sandbox-consumers:prototype "$image"
printf '%s' "$image" >"$state/image-reference"
jq -n --arg source "sha256:$(sha256sum "$state/manifest.json"|cut -d' ' -f1)" --arg profile "sha256:$(sha256sum "$state/policy.json"|cut -d' ' -f1)" --arg tool "${image##*@}" '{sourceDigest:$source,profileDigest:$profile,toolDigest:$tool}' >"$state/config.json"
bundle(){ local record=$1 destination=$2;mkdir -p "$destination";cp "$(jq -r .ca <<<"$record")" "$destination/ca.crt";cp "$(jq -r .cert <<<"$record")" "$destination/tls.crt";cp "$(jq -r .key <<<"$record")" "$destination/tls.key"; }
for req in finite session;do bundle "$(.build/identity issue "$state/issuer" alice "$req" 1 pending control 300)" "$state/client-$req";done
bundle "$(.build/identity issue "$state/issuer" bob finite 1 pending control 300)" "$state/client-bob"
bundle "$(.build/identity issue "$state/issuer" foundation gateway 1 gateway gateway 300)" "$state/gateway"
printf '{"active":{},"routes":{}}\n' >"$state/gateway/routes.json"
.build/identity gateway "$state/gateway" "$host_ip:0" >"$state/gateway.log" 2>&1 &gateway_pid=$!
.build/foundation "$state" >"$state/foundation.log" 2>&1 &foundation_pid=$!
printf '%s' "$foundation_pid" >"$state/foundation.pid"
for _ in {1..100};do [[ -f $state/address && -f $state/gateway/address ]]&&break;sleep 0.05;done
address=$(cat "$state/address")
if [[ -f $state/recovery-enabled ]];then bash recovery-run.sh "$state";exit 0;fi
for req in finite session bob;do cp "$state/supervisor.pub" "$state/client-$req/supervisor.pub";k create secret generic client-"$req" -n "$client_namespace" --from-file="$state/client-$req";done
client(){
 local name=$1 cert=$2 mode=$3 request=$4
 local command="client $mode"
 [[ $mode != finite ]]||command=finite-client
 [[ $mode != session ]]||command=session-client
 cat <<EOF | k apply -f -
apiVersion: v1
kind: Pod
metadata: {name: $name, namespace: $client_namespace}
spec:
  serviceAccountName: external-client
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  containers:
  - name: client
    image: $(cat "$state/image-reference")
    imagePullPolicy: Never
    command: [sh, -ec]
    args: ['test ! -e /var/run/secrets/kubernetes.io/serviceaccount/token; test ! -S /var/run/docker.sock; test ! -e /root/.kube/config; exec $command /identity $address $request']
    resources: {requests: {cpu: 50m, memory: 32Mi}, limits: {memory: 128Mi}}
    volumeMounts: [{name: identity, mountPath: /identity, readOnly: true}]
  volumes: [{name: identity, secret: {secretName: client-$cert}}]
EOF
 for _ in {1..480};do phase=$(k get pod "$name" -n "$client_namespace" -o jsonpath='{.status.phase}');[[ $phase == Succeeded || $phase == Failed ]]&&break;sleep 0.5;done
 k logs "$name" -n "$client_namespace" | tee "evidence/$name.log"
 k get pod "$name" -n "$client_namespace" -o json >"$state/$name-pod.json"
 jq -e '.spec.automountServiceAccountToken==false and .spec.runtimeClassName==null and ([.spec.volumes[]|has("hostPath")]|any|not)' "$state/$name-pod.json" >/dev/null
 test "$phase" = Succeeded
}
client finite-client finite finite finite
client cross-owner bob cross-owner finite
client session-client session session session
k delete namespace "$namespace" --wait=true --timeout=90s
namespace_owned=false
client archived-session session archived session
client finite-expiry finite expired finite
client session-expiry session expired session
for req in finite session;do cp "$state/$req/observed.json" "evidence/$req-observed.json";cp "$state/$req/output.log" "evidence/$req-output.log";done
jq -n '{finiteClient:"native Kata TaskRun",sessionClient:"Agent Sandbox Kata session",sameFoundationAPI:true,consumerUsesBackendAuthority:false,clientIsolation:"token-free runc Pods; no host or backend credential mounts",immutableInputs:true,actualFirewallBothBackends:true,source:"pinned canonical bytes over mTLS; no OCI transport claimed",signedEvidenceAfterGuestRemoval:true,evidenceAfterNamespaceRemoval:true,retentionExpiry:true}' | tee evidence/result.json
