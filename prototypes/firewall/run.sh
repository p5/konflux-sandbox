#!/usr/bin/env bash
set -euo pipefail
umask 077
cd "$(dirname "$0")"
source ../runtime/context.sh
: "${KUBECONFIG:=/tmp/konflux-sandbox-runtime/vm-kubeconfig}"
require_runtime_context "$KUBECONFIG" kind-konflux-sandbox-vm-prototype
root=$(cd ../.. && pwd)
state="$root/.prototype-state/firewall"
results=${FIREWALL_RESULTS_DIR:-"$root/.prototype-results/firewall"}
node=konflux-sandbox-vm-prototype-control-plane
namespace=foundation-firewall-prototype
mkdir -p "$state/certs" "$results"
exec > >(tee "$results/run.log") 2>&1
k() { runtime_k "$@"; }
n() { k -n "$namespace" "$@"; }
chain=''
veth=''
fence_record=''
forwards=()
stream_pid=''
namespace_owned=false
remove_fence() {
  if [[ -n "$fence_record" && -f "$fence_record" ]]; then
    bash ./fence.sh remove "$KUBECONFIG" "$fence_record"
  fi
  veth=''
  fence_record=''
}
cleanup() {
  status=$?
  trap - EXIT
  if [[ -n "$stream_pid" ]]; then kill "$stream_pid" 2>/dev/null || true; wait "$stream_pid" 2>/dev/null || true; fi
  for pid in "${forwards[@]}"; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
  if [[ "$namespace_owned" != true ]]; then exit "$status"; fi
  n delete sandbox client --ignore-not-found --wait=true --timeout=60s > "$results/cleanup-sandbox.log" 2>&1 || status=1
  n delete pod client --ignore-not-found --wait=true --timeout=60s > "$results/cleanup-client.log" 2>&1 || status=1
  n delete taskrun firewall-native --ignore-not-found --wait=true --timeout=60s > "$results/cleanup-task.log" 2>&1 || status=1
  if k delete namespace "$namespace" --ignore-not-found --wait=true --timeout=90s > "$results/cleanup-namespace.log" 2>&1; then
    remove_fence || status=1
  else
    echo 'Cleanup incomplete; external fence retained' >&2
    status=1
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if k get namespace "$namespace" -o json > "$state/namespace.json" 2>/dev/null; then
  jq -e '.metadata.labels["sandbox.p5.dev/prototype"]=="firewall"' "$state/namespace.json" >/dev/null
  namespace_owned=true
else
  k create namespace "$namespace"
  namespace_owned=true
  k label namespace "$namespace" sandbox.p5.dev/prototype=firewall
fi
cat <<'YAML' | n apply -f -
apiVersion: v1
kind: ServiceAccount
metadata: {name: firewall-runner}
automountServiceAccountToken: false
YAML
"$state/bin/firewall" -mode certs -dir "$state/certs"
n create secret generic firewall-certs --from-file="$state/certs" --dry-run=client -o yaml | n apply -f -
n create configmap firewall-public-ca --from-file=ca.crt="$state/certs/ca.crt" --dry-run=client -o yaml | n apply -f -
for marker in A B; do
  name="fixture-${marker,,}"
  cat <<YAML | n apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: $name
spec:
  serviceAccountName: firewall-runner
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: 1
  securityContext: {runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000}
  containers:
  - name: fixture
    image: konflux-sandbox-firewall:prototype
    imagePullPolicy: Never
    args: [-mode, fixture, -marker, $marker]
    securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
    resources: {requests: {cpu: 50m, memory: 32Mi}, limits: {cpu: '1', memory: 128Mi}}
    readinessProbe: {tcpSocket: {port: 8080}, periodSeconds: 1}
    volumeMounts: [{name: certs, mountPath: /certs, readOnly: true}]
  volumes: [{name: certs, secret: {secretName: firewall-certs}}]
YAML
done
n wait pod/fixture-a pod/fixture-b --for=condition=Ready --timeout=90s
fixture_a=$(n get pod fixture-a -o jsonpath='{.status.podIP}')
fixture_b=$(n get pod fixture-b -o jsonpath='{.status.podIP}')
node_ip=$(k get node "$node" -o json | jq -r '.status.addresses[]|select(.type=="InternalIP")|.address')
api_ip=$(k get service kubernetes -n default -o jsonpath='{.spec.clusterIP}')
dns_ip=$(k get service kube-dns -n kube-system -o jsonpath='{.spec.clusterIP}')
jq -n --arg a "$fixture_a" --arg b "$fixture_b" --arg node "$node_ip" '{execution:"firewall-attempt-1",revision:"profile-sha256-fixture-v1",domains:["allowed.test","changing.test","rebind.test","shared.test","protected.test","mismatch.test","*.sub.test"],ips:[($b+"/32")],resolvedPrivateIPs:[($a+"/32"),($b+"/32")],domainPorts:[8080,9443],ipPorts:[8080,7070],protected:[($node+"/32"),"10.96.0.0/12"],dns:($a+":1053"),protocols:["tcp"],ipv6:false,opaqueDomains:false}' > "$state/policy.json"
for rule in '.ipv6=true' '.opaqueDomains=true' '.protocols=["tcp","udp"]' '.unrecognizedBypass=true'; do
  jq "$rule" "$state/policy.json" > "$state/unsupported.json"
  if "$state/bin/firewall" -mode validate -config "$state/unsupported.json" >> "$results/unsupported-profiles.log" 2>&1; then echo 'FAIL unsupported profile admitted'; exit 1; fi
done
echo 'PASS unsupported IPv6, opaque-domain, UDP, and unknown policy fields rejected'
n create configmap firewall-policy --from-file=policy.json="$state/policy.json" --dry-run=client -o yaml | n apply -f -
cat <<'YAML' | n apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: gateway
spec:
  serviceAccountName: firewall-runner
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: 1
  securityContext: {runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000}
  containers:
  - name: gateway
    image: konflux-sandbox-firewall:prototype
    imagePullPolicy: Never
    args: [-mode, gateway, -config, /policy/policy.json]
    env: [{name: POD_IP, valueFrom: {fieldRef: {fieldPath: status.podIP}}}]
    securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
    resources: {requests: {cpu: 50m, memory: 32Mi}, limits: {cpu: '1', memory: 128Mi}}
    readinessProbe: {tcpSocket: {port: 8080}, periodSeconds: 1}
    volumeMounts:
    - {name: certs, mountPath: /certs, readOnly: true}
    - {name: policy, mountPath: /policy, readOnly: true}
  volumes:
  - {name: certs, secret: {secretName: firewall-certs}}
  - {name: policy, configMap: {name: firewall-policy}}
YAML
n wait pod/gateway --for=condition=Ready --timeout=90s
gateway_ip=$(n get pod gateway -o jsonpath='{.status.podIP}')
forward() {
  local pod=$1 remote=$2 logfile=$3
  kubectl --kubeconfig "$RUNTIME_KUBECONFIG" --context "$RUNTIME_CONTEXT" -n "$namespace" port-forward "pod/$pod" "0:$remote" > "$logfile" 2>&1 &
  forwards+=("$!")
  local port=''
  for _ in {1..60}; do
    port=$(awk '/Forwarding from 127.0.0.1:/{split($3,a,":");print a[2];exit}' "$logfile")
    [[ -z "$port" ]] || break
    sleep 0.1
  done
  [[ -n "$port" ]]
  FORWARDED_PORT=$port
}
forward fixture-a 9090 "$results/fixture-forward.log"
fixture_admin="http://127.0.0.1:$FORWARDED_PORT"
forward gateway 9090 "$results/gateway-forward.log"
gateway_admin="http://127.0.0.1:$FORWARDED_PORT"
set_dns() { curl --silent --show-error --fail -X PUT "$fixture_admin/dns?name=$1&ip=$2" >/dev/null; }
for host in allowed.test changing.test rebind.test shared.test blocked.test a.sub.test sub.test evilsub.test mismatch.test; do set_dns "$host" "$fixture_a"; done
set_dns protected.test "$node_ip"
proxy="http://$gateway_ip:8080"
fence() {
  local pod=$1
  client_ip=$(n get pod "$pod" -o jsonpath='{.status.podIP}')
  fence_record="$state/$case_name-fence.json"
  bash ./fence.sh install "$KUBECONFIG" "$fence_record" "$namespace" "$pod" "$gateway_ip"
  veth=$(jq -r .interface "$fence_record")
  chain=$(jq -r .chain "$fence_record")
  docker exec "$node" iptables -S "$chain" > "$results/$case_name-fence.txt"
  docker exec "$node" ip6tables -S "$chain" > "$results/$case_name-fence-ipv6.txt"
  printf 'ENFORCEMENT_READY %s %s %s\n' "$pod" "$client_ip" "$veth"
}
run_probe() { n exec "$client_pod" -- /usr/local/bin/firewall -dir /public -proxy "$proxy" "$@"; }
for case_name in ordinary session; do
  if [[ "$case_name" == ordinary ]]; then
    cat <<'YAML' | n apply -f -
apiVersion: v1
kind: Pod
metadata: {name: client}
spec:
  serviceAccountName: firewall-runner
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: 1
  securityContext: {runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000}
  containers:
  - name: client
    image: konflux-sandbox-firewall:prototype
    imagePullPolicy: Never
    command: [sleep, '3600']
    securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
    volumeMounts: [{name: ca, mountPath: /public, readOnly: true}]
  volumes: [{name: ca, configMap: {name: firewall-public-ca}}]
YAML
  else
    cat <<'YAML' | n apply -f -
apiVersion: agents.x-k8s.io/v1beta1
kind: Sandbox
metadata: {name: client}
spec:
  podTemplate:
    spec:
      serviceAccountName: firewall-runner
      runtimeClassName: kata-prototype
      automountServiceAccountToken: false
      terminationGracePeriodSeconds: 1
      securityContext: {runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000}
      containers:
      - name: client
        image: konflux-sandbox-firewall:prototype
        imagePullPolicy: Never
        command: [sleep, '3600']
        resources: {requests: {cpu: 100m, memory: 128Mi}, limits: {cpu: '1', memory: 512Mi}}
        securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
        volumeMounts: [{name: ca, mountPath: /public, readOnly: true}]
      volumes: [{name: ca, configMap: {name: firewall-public-ca}}]
YAML
    n wait sandbox/client --for=condition=Ready --timeout=120s
  fi
  n wait pod/client --for=condition=Ready --timeout=120s
  client_pod=client
  run_probe -mode reach -url "$node_ip:6443"
  run_probe -mode reach -url "$fixture_a:8080"
  run_probe -mode udp -url "$fixture_a:1053"
  peer_interface=$(docker exec "$node" ip -j route get "$(n get pod "$client_pod" -o jsonpath='{.status.podIP}')" | jq -r '.[0].dev')
  peer_ipv6=$(docker exec "$node" ip -j -6 addr show dev "$peer_interface" | jq -r '.[0].addr_info[]|select(.scope=="link")|.local')
  [[ -n "$peer_ipv6" ]]
  n exec "$client_pod" -- cat /proc/sys/net/ipv6/conf/eth0/disable_ipv6 > "$results/$case_name-ipv6-disabled.txt"
  if [[ $(cat "$results/$case_name-ipv6-disabled.txt") == 1 ]]; then
    echo "PASS IPv6 disabled before admission: $case_name"
  else
    if run_probe -mode reach -url "[$peer_ipv6%eth0]:6443" > "$results/$case_name-ipv6-baseline.log" 2>&1; then
      echo "OBSERVED IPv6 baseline reachable: $case_name"
    else
      echo "OBSERVED IPv6 baseline unavailable; installed-rule evidence only: $case_name"
    fi
  fi
  fence "$client_pod"
  n exec "$client_pod" -- uname -r > "$results/$case_name-kernel.txt"
  n exec "$client_pod" -- cat /proc/net/if_inet6 > "$results/$case_name-ipv6.txt"
  n exec "$client_pod" -- sh -c 'test ! -e /var/run/secrets/kubernetes.io/serviceaccount/token'
  for url in http://allowed.test:8080/ https://allowed.test:9443/ http://a.sub.test:8080/ http://shared.test:8080/; do run_probe -mode request -url "$url"; done
  run_probe -mode request -url http://mismatch.test:8080/
  run_probe -mode request -url https://mismatch.test:9443/ -expect 403
  for url in http://blocked.test:8080/ http://sub.test:8080/ http://evilsub.test:8080/ http://b.a.sub.test:8080/ http://allowed.test:7070/ http://protected.test:8080/ "http://$fixture_a:8080/" "http://$node_ip:6443/" "http://$api_ip:443/" http://169.254.169.254:80/; do run_probe -mode request -url "$url" -expect 403; done
  run_probe -mode request -url "http://$fixture_b:8080/"
  run_probe -mode request -url "tcp://$fixture_b:7070"
  run_probe -mode request -url "tcp://$fixture_a:7070" -expect 403
  run_probe -mode fronting -url host
  run_probe -mode fronting -url sni
  run_probe -mode request -url http://allowed.test:8080/redirect -expect 403
  for address in "$fixture_a:8080" "$fixture_b:7070" "$node_ip:6443" "$api_ip:443" "$dns_ip:53" "$gateway_ip:9090" 169.254.169.254:80; do run_probe -mode raw -url "$address"; done
  run_probe -mode udp -url "$fixture_a:1053" -expect 0
  run_probe -mode raw -url "[$peer_ipv6%eth0]:6443"
  set_dns changing.test "$fixture_a"
  run_probe -mode request -url http://changing.test:8080/ | tee "$results/$case_name-dns-a.log"
  rg -q 'fixture-A' "$results/$case_name-dns-a.log"
  set_dns changing.test "$fixture_b"
  run_probe -mode request -url http://changing.test:8080/ | tee "$results/$case_name-dns-b.log"
  rg -q 'fixture-B' "$results/$case_name-dns-b.log"
  set_dns rebind.test "$node_ip"
  run_probe -mode request -url http://rebind.test:8080/ -expect 403
  set_dns rebind.test "$gateway_ip"
  run_probe -mode request -url http://rebind.test:8080/ -expect 403
  set_dns rebind.test "$fixture_a"
  for stream_case in http https tcp; do
    stream_mode=stream
    stream_url=http://allowed.test:8080/stream
    stream_marker=stream-A-
    if [[ "$stream_case" == https ]]; then stream_url=https://allowed.test:9443/stream; fi
    if [[ "$stream_case" == tcp ]]; then stream_mode=tcpstream; stream_url="tcp://$fixture_b:7070"; stream_marker=tcp-B; fi
    stream_log="$results/$case_name-$stream_case-stream.log"
    run_probe -mode "$stream_mode" -url "$stream_url" > "$stream_log" 2>&1 &
    stream_pid=$!
    for _ in {1..50}; do rg -q "$stream_marker" "$stream_log" && break; sleep 0.1; done
    rg -q "$stream_marker" "$stream_log"
    revocation_start=$(date +%s%N)
    curl --silent --show-error --fail -X POST "$gateway_admin/revoke" >/dev/null
    wait "$stream_pid"
    stream_pid=''
    rg -q 'PASS STREAM_CLOSED' "$stream_log"
    revocation_end=$(date +%s%N)
    [[ $(( (revocation_end-revocation_start)/1000000 )) -lt 3000 ]]
    echo "PASS revocation terminates established $stream_case stream under3000ms: $case_name"
    run_probe -mode request -url http://allowed.test:8080/ -expect 403
    curl --silent --show-error --fail -X POST "$gateway_admin/restore" >/dev/null
  done
  curl --silent --show-error --fail -X POST "$gateway_admin/revoke" >/dev/null
  run_probe -mode request -url http://allowed.test:8080/ -expect 403
  curl --silent --show-error --fail -X POST "$gateway_admin/restore" >/dev/null
  curl --silent --show-error --fail -X POST "$gateway_admin/fail" >/dev/null
  run_probe -mode request -url http://allowed.test:8080/ -expect 403
  curl --silent --show-error --fail -X POST "$gateway_admin/restore" >/dev/null
  run_probe -mode request -url http://allowed.test:8080/
  docker exec "$node" iptables -L "$chain" -nv > "$results/$case_name-fence-counters.txt"
  docker exec "$node" ip6tables -L "$chain" -nv > "$results/$case_name-fence-ipv6-counters.txt"
  if [[ "$case_name" == session ]]; then n delete sandbox client --wait=true; n wait pod/client --for=delete --timeout=60s; else n delete pod client --wait=true; fi
  remove_fence
done
case_name=tekton
cat <<YAML | n apply -f -
apiVersion: tekton.dev/v1
kind: TaskRun
metadata: {name: firewall-native}
spec:
  serviceAccountName: firewall-runner
  podTemplate:
    runtimeClassName: kata-prototype
    automountServiceAccountToken: false
    securityContext: {runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000}
    volumes: [{name: ca, configMap: {name: firewall-public-ca}}]
  taskSpec:
    steps:
    - name: probe
      image: konflux-sandbox-firewall:prototype
      imagePullPolicy: Never
      volumeMounts: [{name: ca, mountPath: /public, readOnly: true}]
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
      computeResources: {requests: {cpu: 100m, memory: 128Mi}, limits: {cpu: '1', memory: 512Mi}}
      script: |
        #!/bin/sh
        set -eu
        while [ ! -f /workspace/admitted ]; do sleep 0.1; done
        firewall -mode request -dir /public -proxy '$proxy' -url http://allowed.test:8080/
        firewall -mode request -dir /public -proxy '$proxy' -url https://allowed.test:9443/
        firewall -mode request -dir /public -proxy '$proxy' -url http://blocked.test:8080/ -expect 403
        firewall -mode raw -dir /public -url '$fixture_a:8080'
        touch /workspace/probed
        while [ ! -f /workspace/gateway-removed ]; do sleep 0.1; done
        firewall -mode request -dir /public -proxy '$proxy' -url http://allowed.test:8080/ -expect 0
        firewall -mode raw -dir /public -url '$fixture_a:8080'
        uname -r
YAML
n wait taskrun/firewall-native --for=jsonpath='{.status.podName}' --timeout=90s
client_pod=$(n get taskrun firewall-native -o jsonpath='{.status.podName}')
n wait "pod/$client_pod" --for=condition=Ready --timeout=120s
fence "$client_pod"
n exec "$client_pod" -c step-probe -- touch /workspace/admitted
for _ in {1..90}; do
  if n exec "$client_pod" -c step-probe -- test -f /workspace/probed 2>/dev/null; then break; fi
  sleep 1
done
n exec "$client_pod" -c step-probe -- test -f /workspace/probed
n logs gateway > "$results/audit.jsonl"
rg -q '"action":"deny"' "$results/audit.jsonl"
rg -q '"action":"allow"' "$results/audit.jsonl"
rg -q 'SNI differs from CONNECT name' "$results/audit.jsonl"
rg -q 'HTTPS Host differs from CONNECT name' "$results/audit.jsonl"
rg -q 'not mismatch.test' "$results/audit.jsonl"
n delete pod gateway --wait=true
n exec "$client_pod" -c step-probe -- touch /workspace/gateway-removed
n wait taskrun/firewall-native --for=condition=Succeeded --timeout=120s
n get taskrun firewall-native -o json > "$results/tekton.json"
n logs "$client_pod" -c step-probe > "$results/tekton.log"
rg -q 'PASS request' "$results/tekton.log"
n delete taskrun firewall-native --wait=true
n wait "pod/$client_pod" --for=delete --timeout=60s
remove_fence
jq -n '{status:"passed",paths:["ordinary-container","AgentSandbox-Kata","native-Tekton-Kata"],domainProtocols:["HTTP/1.1","TLS1.3-inspected-HTTP/1.1"],ipProtocol:"TCP-through-explicit-CONNECT",ipv6:"all workload traffic rejected by external per-veth rules; IPv6 allow profiles rejected",revocationBoundMilliseconds:3000,enforcement:"dedicated outside-guest gateway plus per-veth node INPUT/FORWARD fence",dns:"gateway-controlled resolver; no connection reuse or address cache",upstreamCredentials:"none in guest",production:false}' | tee "$results/summary.json"
echo 'PASS firewall foundation scenarios; all denied outcomes asserted'
