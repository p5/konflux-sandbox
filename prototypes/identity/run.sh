#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ../runtime/context.sh
require_runtime_context /tmp/konflux-sandbox-runtime/vm-kubeconfig kind-konflux-sandbox-vm-prototype
k(){ runtime_k "$@"; }
namespace=foundation-identity-prototype
mkdir -p .state evidence
exec > >(tee evidence/run.log) 2>&1
state=$(mktemp -d "$PWD/.state/run.XXXXXX")
issuer=$state/issuer
host_ip=$(docker inspect konflux-sandbox-vm-prototype-control-plane --format '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}')
k create namespace "$namespace" --dry-run=client -o yaml | k apply -f -
cleanup(){ kill "${broker_pid:-}" "${gateway_pid:-}" "${stream_pid:-}" 2>/dev/null || true; k delete pod session tls-relay -n "$namespace" --ignore-not-found --wait=true >/dev/null; k delete service tls-relay -n "$namespace" --ignore-not-found >/dev/null; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
issue(){ .build/identity issue "$issuer" "$1" "$2" "$3" "$4" "$5" "$6"; }
bundle(){ local record=$1 destination=$2; mkdir -p "$destination"; cp "$(jq -r .ca <<<"$record")" "$destination/ca.crt"; cp "$(jq -r .cert <<<"$record")" "$destination/tls.crt"; cp "$(jq -r .key <<<"$record")" "$destination/tls.key"; }
create_guest(){
  k delete pod tls-relay -n "$namespace" --ignore-not-found --wait=true >/dev/null
  k delete pod session -n "$namespace" --ignore-not-found --wait=true >/dev/null
  cat <<EOF | k apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: session
  namespace: $namespace
spec:
  runtimeClassName: kata-prototype
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: 2
  containers:
  - name: runtime
    image: konflux-sandbox-identity:prototype
    imagePullPolicy: Never
    command: [sleep, '3600']
    resources:
      requests: {cpu: 100m, memory: 128Mi}
      limits: {cpu: '1', memory: 512Mi}
EOF
  k wait pod/session -n "$namespace" --for=condition=Ready --timeout=120s
  uid=$(k get pod session -n "$namespace" -o jsonpath='{.metadata.uid}')
  guest_ip=$(k get pod session -n "$namespace" -o jsonpath='{.status.podIP}')
  cat <<EOF | k apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: tls-relay
  namespace: $namespace
  labels: {app: identity-tls-relay}
spec:
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
metadata:
  name: tls-relay
  namespace: $namespace
spec:
  type: NodePort
  selector: {app: identity-tls-relay}
  ports:
  - port: 8443
    targetPort: 8443
EOF
  k wait pod/tls-relay -n "$namespace" --for=condition=Ready --timeout=60s
  node_ip=$(docker inspect konflux-sandbox-vm-prototype-control-plane --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
  node_port=$(k get service tls-relay -n "$namespace" -o jsonpath='{.spec.ports[0].nodePort}')
  identity=$(jq -n --arg uid "$uid" '{owner:"alice",request:"check-1",attempt:"attempt-1",guestUID:$uid}')
  server_record=$(issue alice check-1 attempt-1 "$uid" server 300)
  control_record=$(issue alice check-1 attempt-1 "$uid" control 300)
  execution_record=$(issue alice check-1 attempt-1 "$uid" execution 300)
  bundle "$server_record" "$state/guest-$uid/identity"
  bundle "$execution_record" "$state/guest-$uid/identity/execution"
  bundle "$control_record" "$state/control-$uid"
  printf '%s\n' "$identity" >"$state/guest-$uid/identity/identity.json"
  tar -C "$state/guest-$uid" -cf - identity | k exec -i -n "$namespace" session -- tar -C /workspace -xf -
  k exec -n "$namespace" session -- sh -c 'nohup sandboxd --listen-host=127.0.0.1 >/tmp/sandboxd.log 2>&1 & nohup identity guest /workspace/identity >/tmp/tls-proxy.log 2>&1 &'
  sni=$(jq -r .serverName <<<"$server_record")
}
create_guest
old_uid=$uid
old_identity=$identity
bundle "$(issue fixture broker attempt-1 broker broker 300)" "$state/broker"
bundle "$(issue fixture gateway attempt-1 gateway gateway 300)" "$state/gateway"
jq -n --argjson id "$identity" --arg uid "$uid" '{active:{"alice/check-1/attempt-1":$uid},grants:{grant1:{identity:$id,expires:(now+300|todateiso8601),action:"read-fixture",revoked:false}}}' >"$state/broker/grants.json"
route(){ jq -n --argjson id "$identity" --arg uid "$uid" --arg url "https://$node_ip:$node_port" --arg sni "$sni" --arg tls "$state/control-$uid" '{active:{"alice/check-1/attempt-1":$uid},routes:{($uid):{identity:$id,url:$url,serverName:$sni,tlsDir:$tls}}}' >"$state/gateway/routes.json"; }
route
.build/identity broker "$state/broker" "$host_ip:0" >evidence/broker.log 2>&1 & broker_pid=$!
.build/identity gateway "$state/gateway" "$host_ip:0" >evidence/gateway.log 2>&1 & gateway_pid=$!
for _ in {1..100}; do [[ -f $state/broker/address && -f $state/gateway/address ]] && break; sleep 0.05; done
broker=https://$(cat "$state/broker/address")
gateway_address=$(cat "$state/gateway/address")
gateway=https://$gateway_address
request(){ local control=$1 guest=$2 method=$3 path=$4; shift 4; curl -sS --max-time 5 --noproxy '*' --cacert "$control/ca.crt" --cert "$control/tls.crt" --key "$control/tls.key" --resolve "gateway.prototype:${gateway_address##*:}:$host_ip" -H "X-Guest-UID: $guest" -X "$method" "https://gateway.prototype:${gateway_address##*:}$path" "$@"; }
for _ in {1..100}; do if request "$state/control-$uid" "$uid" GET /v1/health -f > /dev/null 2>&1; then break; fi; sleep 0.05; done
if curl -sS --max-time 5 --noproxy '*' --cacert "$state/control-$uid/ca.crt" --resolve "gateway.prototype:${gateway_address##*:}:$host_ip" "https://gateway.prototype:${gateway_address##*:}/v1/health" >evidence/anonymous.txt 2>&1;then echo 'FAIL anonymous TLS accepted';exit 1;fi
grep -Eqi 'certificate required|bad certificate' evidence/anonymous.txt
bundle "$execution_record" "$state/execution-role"
test "$(request "$state/execution-role" "$uid" GET /v1/health -o /dev/null -w '%{http_code}')" = 403
jq --arg uid "$uid" '.routes[$uid].serverName="wrong-destination.prototype"' "$state/gateway/routes.json" >"$state/gateway/routes.tmp";mv "$state/gateway/routes.tmp" "$state/gateway/routes.json"
test "$(request "$state/control-$uid" "$uid" GET /v1/health -o /dev/null -w '%{http_code}')" = 502
grep -q 'x509: certificate is valid for.*wrong-destination.prototype' evidence/gateway.log
route
echo 'PASS missing client identity, execution-role control, and wrong destination server identity rejected'
request "$state/control-$uid" "$uid" PUT /v1/files/input.txt --data 'private synthetic input' -f >/dev/null
test "$(request "$state/control-$uid" "$uid" GET /v1/files/input.txt -f)" = 'private synthetic input'
echo 'PASS mTLS file upload and download through independently authorized gateway into actual Kata guest'
proto=../../../agent-sandbox/packages/sandboxd/spec
rpc(){ local dir=$1 guest=$2 method=$3 data=$4; grpcurl -max-time 15 -cacert "$dir/ca.crt" -cert "$dir/tls.crt" -key "$dir/tls.key" -servername gateway.prototype -H "X-Guest-UID: $guest" -import-path "$proto" -proto process/v1/process.proto -d "$data" "$gateway_address" "process.v1.ProcessService/$method"; }
rpc "$state/control-$uid" "$uid" Start '{"config":{"command":["sh","-c","cat input.txt; echo; uname -r; echo first; sleep 2; echo second"],"cwd":"/workspace"}}' >evidence/command-stream.json & stream_pid=$!
observed_early=false
for _ in {1..100}; do
  if jq -es 'any(.[];(.stdout//""|@base64d|contains("first"))) and all(.[];.exit==null)' evidence/command-stream.json >/dev/null 2>&1;then observed_early=true;break;fi
  sleep 0.02
done
test "$observed_early" = true
wait "$stream_pid";unset stream_pid
jq -es 'any(.[];.init!=null) and any(.[];.exit!=null)' evidence/command-stream.json >/dev/null
guest_kernel=$(jq -rs '[.[]|.stdout//empty|@base64d]|join("")|split("\n")[1]' evidence/command-stream.json)
test -n "$guest_kernel"
test "$guest_kernel" != "$(docker exec konflux-sandbox-vm-prototype-control-plane uname -r)"
echo 'PASS TLS HTTP/2 streaming command transport'
wrong=$(issue bob check-1 attempt-1 "$uid" control 300);bundle "$wrong" "$state/wrong-control"
test "$(request "$state/wrong-control" "$uid" GET /v1/files/input.txt -o /dev/null -w '%{http_code}')" = 403
wrong=$(issue alice check-1 attempt-2 "$uid" control 300);bundle "$wrong" "$state/wrong-attempt-control"
test "$(request "$state/wrong-attempt-control" "$uid" GET /v1/files/input.txt -o /dev/null -w '%{http_code}')" = 403
echo 'PASS trusted gateway rejects cross-owner and wrong-attempt control before guest forwarding'
rpc "$state/control-$uid" "$uid" Start '{"config":{"command":["sh","-c","echo running; sleep 5; echo done"],"cwd":"/workspace"}}' >evidence/control-revocation.json 2>evidence/control-revocation.log & stream_pid=$!
observed_running=false
for _ in {1..100};do if jq -es 'any(.[];(.stdout//""|@base64d|contains("running")))' evidence/control-revocation.json >/dev/null 2>&1;then observed_running=true;break;fi;sleep 0.02;done
test "$observed_running" = true
start=$(date +%s)
jq '.active["alice/check-1/attempt-1"]="revoked"' "$state/gateway/routes.json" >"$state/gateway/routes.tmp";mv "$state/gateway/routes.tmp" "$state/gateway/routes.json"
if wait "$stream_pid";then echo 'FAIL active control stream survived revocation';exit 1;fi
unset stream_pid
test "$(( $(date +%s)-start ))" -lt 3
route
echo 'PASS external authorization revocation interrupts active command stream'
command=$(jq -nc --arg url "$broker/operation" '{config:{command:["identity","client","/workspace/identity/execution","broker.prototype",$url,"grant1","200","/workspace/broker-result.txt"],cwd:"/workspace"}}')
rpc "$state/control-$uid" "$uid" Execute "$command" >evidence/broker-command.json
test "$(jq -r '.exitCode//0' evidence/broker-command.json)" = 0
request "$state/control-$uid" "$uid" GET /v1/files/broker-result.txt -f >evidence/broker-result.txt
grep -q upstream-secret-injected evidence/broker-result.txt
echo 'PASS guest execution certificate and grant authorize broker; upstream secret injected outside guest'
for case in wrong-owner wrong-attempt; do
  owner=alice;attempt=attempt-1;[[ $case != wrong-owner ]] || owner=bob;[[ $case != wrong-attempt ]] || attempt=attempt-2
  bundle "$(issue "$owner" check-1 "$attempt" "$uid" execution 300)" "$state/$case"
  .build/identity client "$state/$case" broker.prototype "$broker/operation" grant1 403 "evidence/$case.txt"
done
bundle "$(issue expired check-1 attempt-1 "$uid" execution 1)" "$state/expired"
sleep 2
.build/identity client "$state/expired" broker.prototype "$broker/operation" grant1 tls-denied evidence/expired.txt
stream_command=$(jq -nc --arg url "$broker/operation?stream=true" '{config:{command:["identity","client","/workspace/identity/execution","broker.prototype",$url,"grant1","200","/workspace/stream.txt"],cwd:"/workspace"}}')
rpc "$state/control-$uid" "$uid" Execute "$stream_command" >evidence/active-command.json & stream_pid=$!
for _ in {1..100}; do [[ $(cat "$state/broker/upstream-count" 2>/dev/null || echo 0) -ge 2 ]] && break; sleep 0.02; done
observed_chunk=false
for _ in {1..100}; do
  if request "$state/control-$uid" "$uid" GET /v1/files/stream.txt -f 2>/dev/null | grep -q chunk-;then observed_chunk=true;break;fi
  sleep 0.02
done
test "$observed_chunk" = true
start=$(date +%s)
jq '.grants.grant1.revoked=true' "$state/broker/grants.json" >"$state/broker/grants.tmp";mv "$state/broker/grants.tmp" "$state/broker/grants.json"
wait "$stream_pid";unset stream_pid
test "$(jq -r '.exitCode//0' evidence/active-command.json)" = 0
test "$(cat "$state/broker/upstream-cancelled")" = cancelled
test "$(( $(date +%s)-start ))" -lt 3
request "$state/control-$uid" "$uid" GET /v1/files/stream.txt -f >evidence/revoked-stream.txt
test "$(wc -l <evidence/revoked-stream.txt)" -lt 200
bundle "$execution_record" "$state/old-execution"
.build/identity client "$state/old-execution" broker.prototype "$broker/operation" grant1 403 evidence/revoked.txt
echo 'PASS revocation interrupts active upstream stream and rejects subsequent requests'
create_guest
test "$uid" != "$old_uid"
route
jq --arg uid "$uid" --argjson id "$identity" '.active["alice/check-1/attempt-1"]=$uid|.grants.grant1.revoked=false|.grants.grant2={identity:$id,expires:(now+300|todateiso8601),action:"read-fixture",revoked:false}' "$state/broker/grants.json" >"$state/broker/grants.tmp";mv "$state/broker/grants.tmp" "$state/broker/grants.json"
.build/identity client "$state/old-execution" broker.prototype "$broker/operation" grant1 403 evidence/replaced-identity.txt
test "$(request "$state/control-$old_uid" "$old_uid" GET /v1/health -o /dev/null -w '%{http_code}')" = 403
for _ in {1..100}; do if request "$state/control-$uid" "$uid" GET /v1/health -f >/dev/null 2>&1;then break;fi;sleep 0.05;done
request "$state/control-$uid" "$uid" PUT /v1/files/reconnected.txt --data fresh-guest -f >/dev/null
test "$(request "$state/control-$uid" "$uid" GET /v1/files/reconnected.txt -f)" = fresh-guest
command=$(jq -nc --arg url "$broker/operation" '{config:{command:["identity","client","/workspace/identity/execution","broker.prototype",$url,"grant2","200","/workspace/new-broker.txt"],cwd:"/workspace"}}')
rpc "$state/control-$uid" "$uid" Execute "$command" >evidence/reconnected-broker.json
test "$(jq -r '.exitCode//0' evidence/reconnected-broker.json)" = 0
echo 'PASS replacement invalidates old execution/control identity and reconnects correct fresh guest'
upstream_secret=$(cat "$state/broker/upstream-secret")
if grep -RF "$upstream_secret" "$state/guest-$uid" evidence/command-stream.json evidence/broker-result.txt evidence/revoked-stream.txt >/dev/null;then echo 'FAIL upstream secret leaked';exit 1;fi
jq -n --arg old "$old_uid" --arg current "$uid" '{actualKata:true,tls:"TLS1.3 mTLS; external gateway and in-guest TLS termination",oldGuestUID:$old,newGuestUID:$current,fileTransport:true,commandStreaming:true,anonymousDenied:true,executionRoleControlDenied:true,wrongDestinationDenied:true,crossOwnerDenied:true,wrongAttemptDenied:true,expiredCertificateDenied:true,activeControlRevocation:true,activeRevocation:true,replacementIdentityDenied:true,reconnect:true,upstreamCredentialsInGuest:false}' | tee evidence/result.json
