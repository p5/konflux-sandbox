#!/usr/bin/env bash
set -euo pipefail
umask 077
cd "$(dirname "$0")"
source ../runtime/context.sh
: "${KUBECONFIG:=/tmp/konflux-sandbox-runtime/vm-kubeconfig}"
require_runtime_context "$KUBECONFIG" kind-konflux-sandbox-vm-prototype
k() { runtime_k "$@"; }
namespace=foundation-broker-network-prototype
n() { k -n "$namespace" "$@"; }
mkdir -p .state evidence
state=$(mktemp -d "$PWD/.state/run.XXXXXX")
exec > >(tee evidence/run.log) 2>&1
namespace_owned=false
forwards=()
stream_pid=''
cleanup() {
  status=$?
  trap - EXIT
  if [[ -n "$stream_pid" ]]; then kill "$stream_pid" 2>/dev/null || true; wait "$stream_pid" 2>/dev/null || true; fi
  for pid in "${forwards[@]}"; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
  if [[ "$namespace_owned" == true ]]; then
    if k delete namespace "$namespace" --ignore-not-found --wait=true --timeout=90s > evidence/cleanup.log 2>&1; then
      for record in "$state/guest-fence.json" "$state/broker-fence.json"; do
        if [[ -f "$record" ]]; then
          if bash ../firewall/fence.sh remove "$KUBECONFIG" "$record" >> evidence/cleanup.log 2>&1; then
            cp "$record" "evidence/$(basename "$record")"
          else
            status=1
          fi
        fi
      done
    else
      echo 'Namespace removal incomplete; packet fences retained' >&2
      status=1
    fi
  fi
  if [[ "$status" == 0 && -f evidence/summary.json ]]; then
    jq '.cleanupVerified=true' evidence/summary.json > evidence/summary.tmp
    mv evidence/summary.tmp evidence/summary.json
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
k create namespace "$namespace"
namespace_owned=true
k label namespace "$namespace" sandbox.p5.dev/prototype=broker-network
./.build/firewall -mode certs -dir "$state/firewall-certs"
./.build/broker-network -mode secret -dir "$state/upstream-secret"
n create secret generic firewall-certs --from-file="$state/firewall-certs"
n create secret generic upstream-secret --from-file=upstream-secret="$state/upstream-secret"
cat <<'YAML' | n apply -f -
apiVersion: v1
kind: Pod
metadata: {name: origin}
spec:
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: 1
  securityContext: {runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000}
  containers:
  - name: dns
    image: konflux-sandbox-broker-network:prototype
    imagePullPolicy: Never
    command: [firewall, -mode, fixture, -marker, BROKER]
    readinessProbe: {tcpSocket: {port: 8080}, periodSeconds: 1}
    resources: {requests: {cpu: 50m, memory: 32Mi}, limits: {memory: 128Mi}}
    securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
    volumeMounts: [{name: certs, mountPath: /certs, readOnly: true}]
  - name: origin
    image: konflux-sandbox-broker-network:prototype
    imagePullPolicy: Never
    command: [broker-network, -mode, origin, -dir, /origin]
    readinessProbe: {tcpSocket: {port: 8081}, periodSeconds: 1}
    resources: {requests: {cpu: 50m, memory: 32Mi}, limits: {memory: 128Mi}}
    securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
    volumeMounts:
    - {name: certs, mountPath: /origin/server.crt, subPath: server.crt, readOnly: true}
    - {name: certs, mountPath: /origin/server.key, subPath: server.key, readOnly: true}
    - {name: secret, mountPath: /origin/upstream-secret, subPath: upstream-secret, readOnly: true}
  volumes:
  - {name: certs, secret: {secretName: firewall-certs}}
  - {name: secret, secret: {secretName: upstream-secret}}
YAML
n wait pod/origin --for=condition=Ready --timeout=90s
origin_ip=$(n get pod origin -o jsonpath='{.status.podIP}')
node_ip=$(k get node konflux-sandbox-vm-prototype-control-plane -o json | jq -r '.status.addresses[]|select(.type=="InternalIP")|.address')
forward() {
  n port-forward "pod/$1" "0:$2" > "$state/$3-forward.log" 2>&1 &
  forwards+=("$!")
  FORWARDED_PORT=''
  for _ in {1..100}; do
    FORWARDED_PORT=$(awk '/Forwarding from 127.0.0.1:/{split($3,a,":");print a[2];exit}' "$state/$3-forward.log")
    [[ -z "$FORWARDED_PORT" ]] || return 0
    sleep 0.05
  done
  return 1
}
forward origin 9090 dns
dns_admin="http://127.0.0.1:$FORWARDED_PORT"
forward origin 9091 origin
origin_admin="http://127.0.0.1:$FORWARDED_PORT"
set_dns() { curl -fsS --max-time 5 -X PUT "$dns_admin/dns?name=$1&ip=$2" >/dev/null; }
for host in allowed.test blocked.test redirect.test rebind.test protected.test sink.test; do set_dns "$host" "$origin_ip"; done
set_dns protected.test "$node_ip"
holding_pod() {
  local name=$1 class=$2
  jq -n --arg name "$name" --arg class "$class" '{apiVersion:"v1",kind:"Pod",metadata:{name:$name},spec:{automountServiceAccountToken:false,terminationGracePeriodSeconds:1,securityContext:{runAsUser:1000,runAsGroup:1000,fsGroup:1000},containers:[{name:"fixture",image:"konflux-sandbox-broker-network:prototype",imagePullPolicy:"Never",command:["sleep","3600"],securityContext:{allowPrivilegeEscalation:false,capabilities:{drop:["ALL"]}},resources:{requests:{cpu:"100m",memory:"128Mi"},limits:{cpu:"1",memory:"512Mi"}}}]}} | if $class!="" then .spec.runtimeClassName=$class else . end' | n apply -f -
  n wait "pod/$name" --for=condition=Ready --timeout=120s
}
holding_pod broker ''
broker_ip=$(n get pod broker -o jsonpath='{.status.podIP}')
broker_uid=$(n get pod broker -o jsonpath='{.metadata.uid}')
jq -n --arg origin "$origin_ip" --arg node "$node_ip" '{execution:"broker-egress",revision:"broker-profile-v1",domains:["allowed.test","redirect.test","rebind.test","protected.test"],ips:[],resolvedPrivateIPs:[($origin+"/32")],domainPorts:[8081,9444],ipPorts:[],protected:[($node+"/32"),"10.96.0.0/12"],dns:($origin+":1053"),protocols:["tcp"],ipv6:false,opaqueDomains:false}' > "$state/egress-policy.json"
jq -n --arg broker "$broker_ip" --arg origin "$origin_ip" --arg node "$node_ip" '{execution:"broker-guest",revision:"broker-hop-v1",domains:[],ips:[($broker+"/32")],resolvedPrivateIPs:[],domainPorts:[],ipPorts:[8443],protected:[($node+"/32"),"10.96.0.0/12"],dns:($origin+":1053"),protocols:["tcp"],ipv6:false,opaqueDomains:false}' > "$state/guest-policy.json"
gateway() {
  local name=$1 policy=$2
  n create configmap "$name" --from-file=policy.json="$policy"
  cat <<YAML | n apply -f -
apiVersion: v1
kind: Pod
metadata: {name: $name}
spec:
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: 1
  securityContext: {runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000}
  containers:
  - name: gateway
    image: konflux-sandbox-broker-network:prototype
    imagePullPolicy: Never
    command: [firewall, -mode, gateway, -config, /policy/policy.json]
    env: [{name: POD_IP, valueFrom: {fieldRef: {fieldPath: status.podIP}}}]
    readinessProbe: {tcpSocket: {port: 8080}, periodSeconds: 1}
    securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
    resources: {requests: {cpu: 50m, memory: 32Mi}, limits: {memory: 128Mi}}
    volumeMounts: [{name: certs, mountPath: /certs, readOnly: true}, {name: policy, mountPath: /policy, readOnly: true}]
  volumes:
  - {name: certs, secret: {secretName: firewall-certs}}
  - {name: policy, configMap: {name: $name}}
YAML
  n wait "pod/$name" --for=condition=Ready --timeout=90s
}
gateway egress-gateway "$state/egress-policy.json"
gateway guest-gateway "$state/guest-policy.json"
egress_ip=$(n get pod egress-gateway -o jsonpath='{.status.podIP}')
guest_gateway_ip=$(n get pod guest-gateway -o jsonpath='{.status.podIP}')
forward egress-gateway 9090 egress
egress_admin="http://127.0.0.1:$FORWARDED_PORT"
holding_pod guest kata-prototype
guest_uid=$(n get pod guest -o jsonpath='{.metadata.uid}')
n exec guest -- uname -r | tee evidence/guest-kernel.txt
test "$(cat evidence/guest-kernel.txt)" != "$(docker exec konflux-sandbox-vm-prototype-control-plane uname -r)"
bundle() {
  local record=$1 destination=$2
  mkdir -p "$destination"
  cp "$(jq -r .ca <<< "$record")" "$destination/ca.crt"
  cp "$(jq -r .cert <<< "$record")" "$destination/tls.crt"
  cp "$(jq -r .key <<< "$record")" "$destination/tls.key"
}
broker_cert=$(./.build/broker-network -mode issue -dir "$state/issuer" -uid "$broker_uid" -role server)
bundle "$broker_cert" "$state/broker"
bundle "$(./.build/broker-network -mode issue -dir "$state/issuer" -uid "$guest_uid")" "$state/client"
cp "$state/upstream-secret" "$state/broker/upstream-secret"
cp "$state/firewall-certs/ca.crt" "$state/broker/upstream-ca.crt"
profile="sha256:$(sha256sum "$state/egress-policy.json" | cut -d' ' -f1)"
deadline=$(date -u -d '+10 minutes' +%Y-%m-%dT%H:%M:%SZ)
jq -n --arg uid "$guest_uid" --arg profile "$profile" --arg proxy "http://$egress_ip:8080" --arg deadline "$deadline" '{identity:{owner:"alice",request:"broker-network",attempt:"1",guestUID:$uid},profileDigest:$profile,proxy:$proxy,deadline:$deadline,budget:32,targets:{allowed:"http://allowed.test:8081/value",secure:"https://allowed.test:9444/value","outside-grant":"http://allowed.test:8081/value","profile-denied":"http://blocked.test:8081/value",redirect:"http://redirect.test:8081/redirect",rebind:"http://rebind.test:8081/value",protected:"http://protected.test:8081/value",stream:"http://allowed.test:8081/stream"},allowed:["allowed","secure","profile-denied","redirect","rebind","protected","stream"]}' > "$state/broker/config.json"
jq -n --arg proxy "http://$guest_gateway_ip:8080" --arg broker "https://$broker_ip:8443" --arg sni "$(jq -r .serverName <<< "$broker_cert")" --arg profile "$profile" '{proxy:$proxy,broker:$broker,serverName:$sni,profileDigest:$profile}' > "$state/client/config.json"
tar -C "$state" -cf - broker | n exec -i broker -- tar -C /workspace -xf -
tar -C "$state" -cf - client | n exec -i guest -- tar -C /workspace -xf -
n exec broker -- sh -c 'nohup broker-network -mode broker -dir /workspace/broker >/workspace/broker/server.log 2>&1 &'
forward broker 9090 broker
broker_admin="http://127.0.0.1:$FORWARDED_PORT"
for _ in {1..100}; do if curl -fsS --max-time 1 "$broker_admin/state" > "$state/broker-initial.json"; then break; fi; sleep 0.1; done
jq -e --arg uid "$guest_uid" '.identity.guestUID==$uid and .revoked==false' "$state/broker-initial.json" >/dev/null
n exec guest -- firewall -mode reach -url "$broker_ip:8443"
n exec guest -- firewall -mode reach -url "$origin_ip:8081"
n exec broker -- firewall -mode reach -url "$origin_ip:8081"
bash ../firewall/fence.sh install "$KUBECONFIG" "$state/broker-fence.json" "$namespace" broker "$egress_ip" "$guest_gateway_ip" > evidence/broker-fence.json
bash ../firewall/fence.sh install "$KUBECONFIG" "$state/guest-fence.json" "$namespace" guest "$guest_gateway_ip" > evidence/guest-fence.json
probe() { n exec guest -- broker-network -mode client -dir /workspace/client "$@"; }
probe -target allowed
probe -target secure
probe -target outside-grant -expect 403
probe -target allowed -action write -expect 403
probe -target allowed -profile changed -expect 403
probe -target profile-denied -expect 403
probe -target redirect -expect 502
probe -target rebind
set_dns rebind.test "$node_ip"
probe -target rebind -expect 403
set_dns rebind.test "$egress_ip"
probe -target rebind -expect 403
set_dns rebind.test "$origin_ip"
probe -target protected -expect 403
n exec guest -- firewall -mode raw -url "$origin_ip:8081"
n exec guest -- firewall -mode raw -url "$broker_ip:8443"
n exec broker -- firewall -mode raw -url "$origin_ip:8081"
for authority in grant profile; do
  stream_log="evidence/$authority-stream.log"
  probe -target stream -stream > "$stream_log" 2>&1 &
  stream_pid=$!
  for _ in {1..100}; do rg -q CHUNK "$stream_log" && break; sleep 0.05; done
  rg -q CHUNK "$stream_log"
  revoke_start=$(date +%s%N)
  if [[ "$authority" == grant ]]; then admin=$broker_admin; code=410; else admin=$egress_admin; code=403; fi
  curl -fsS --max-time 3 -X POST "$admin/revoke" >/dev/null
  wait "$stream_pid"
  stream_pid=''
  revoke_end=$(date +%s%N)
  rg -q 'PASS STREAM_CLOSED' "$stream_log"
  elapsed=$(( (revoke_end-revoke_start)/1000000 ))
  [[ "$elapsed" -lt 3000 ]]
  printf 'PASS %s revoke closes actual upstream stream in %sms\n' "$authority" "$elapsed"
  probe -target allowed -expect "$code"
  curl -fsS --max-time 3 -X POST "$admin/restore" >/dev/null
done
curl -fsS --max-time 5 "$origin_admin/state" > evidence/origin-state.json
jq -e '.cancelled>=2 and .accepted["allowed.test:8081"]>=1 and .accepted["allowed.test:9444"]==1 and .accepted["redirect.test:8081"]==1 and .accepted["rebind.test:8081"]==1 and (.accepted["protected.test:8081"]//0)==0 and (.accepted["blocked.test:8081"]//0)==0 and (.accepted["sink.test:8081"]//0)==0 and (.rejected|length)==0' evidence/origin-state.json >/dev/null
curl -fsS --max-time 5 "$broker_admin/state" > evidence/broker-state.json
n exec broker -- cat /workspace/broker/server.log > evidence/broker-audit.jsonl
n logs egress-gateway > evidence/egress-audit.jsonl
n logs guest-gateway > evidence/guest-gateway-audit.jsonl
rg -q 'hostname outside allowlist' evidence/egress-audit.jsonl
rg -q 'DNS resolved protected or unsupported address' evidence/egress-audit.jsonl
rg -q '"event":"grant-deny"' evidence/broker-audit.jsonl
n delete pod egress-gateway --wait=true
probe -target allowed -expect 502
n exec broker -- firewall -mode raw -url "$origin_ip:8081"
n delete pod guest-gateway --wait=true
probe -target allowed -expect 0
n exec guest -- firewall -mode raw -url "$broker_ip:8443"
n exec guest -- sh -c 'test ! -e /var/run/secrets/kubernetes.io/serviceaccount/token; test ! -e /workspace/client/upstream-secret; test ! -e /workspace/client/ca.key'
if rg -F -q -f "$state/upstream-secret" evidence; then echo 'FAIL synthetic upstream credential entered captured responses'; exit 1; fi
jq -n --arg uid "$guest_uid" --arg profile "$profile" '{status:"passed",guestUID:$uid,profileDigest:$profile,guestIsolation:"actual Kata",brokerIsolation:"token-free runc plus outside packet fence",credentialBoundary:"mTLS guest grant; credential injection outside guest",destinationIntersection:true,directGuestAndBrokerBypassDenied:true,protectedAndReboundAddressesDenied:true,redirectCredentialLeakDenied:true,grantAndProfileRevocationBoundMilliseconds:3000,gatewayRemovalFailsClosed:true,production:false}' | tee evidence/summary.json
