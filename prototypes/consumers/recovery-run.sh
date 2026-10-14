#!/usr/bin/env bash
set -euo pipefail
state=$1
source ../runtime/context.sh
require_runtime_context /tmp/konflux-sandbox-runtime/vm-kubeconfig kind-konflux-sandbox-vm-prototype
k(){ runtime_k "$@"; }
request=
call(){
 local method=$1 path=$2 want=$3;shift 3
 local address status
 address=$(cat "$state/address")
 status=$(curl -sS --noproxy '*' --max-time 180 --cacert "$state/client-$request/ca.crt" --cert "$state/client-$request/tls.crt" --key "$state/client-$request/tls.key" --resolve "gateway.prototype:${address##*:}:${address%:*}" -X "$method" "https://gateway.prototype:${address##*:}$path" -o "$state/response.json" -w '%{http_code}' "$@")
 test "$status" = "$want"
}
restart(){
 local pid
 pid=$(cat "$state/foundation.pid")
 kill -TERM "$pid" 2>/dev/null||true
 rm -f "$state/address"
 .build/foundation "$state" >"$state/foundation-restart-$request.log" 2>&1 &pid=$!
 printf '%s' "$pid" >"$state/foundation.pid"
 for _ in {1..1000};do [[ -f $state/address ]]&&break;kill -0 "$pid";sleep 0.1;done
 test -f "$state/address"
}
counts(){ curl -fsS --max-time 5 "$(cat "$state/marker-address")/counts"; }
for request in finite session;do
 spec=$(jq --arg kind "$request" '{kind:$kind,sourceDigest,profileDigest}' "$state/config.json")
 call POST "/requests/$request" 201 --data "$spec"
 cp "$state/$request/binding.json" "$state/$request/binding-before.json"
 cp "$state/records/$request.json" "evidence/recovery-$request-ready-before.json"
 counts | jq -e --arg key "startup/$request" '.[$key]==1' >/dev/null
 restart
 call GET "/requests/$request" 200
 jq -e '.status=="Ready"' "$state/response.json" >/dev/null
 cmp "$state/$request/binding-before.json" "$state/$request/binding.json"
 call POST "/requests/$request" 200 --data "$spec"
 counts | jq -e --arg startup "startup/$request" --arg command "command/$request" '.[$startup]==1 and (.[$command]//0)==0' >/dev/null
 echo "PASS $request restart adopts exact UID/SID without startup or command replay"
 # A different expected SID must not adopt the unchanged Pod UID.
 jq '.runtimeSandboxID=("0"*64)' "$state/$request/binding.json" >"$state/$request/binding-wrong.json"
 cp "$state/$request/binding-wrong.json" "$state/$request/binding.json"
 if bash backend.sh adopt "$state" "$request" "$request" >"$state/$request/wrong-sid.log" 2>&1;then echo 'Wrong SID adopted' >&2;exit 1;fi
 cp "$state/$request/binding-before.json" "$state/$request/binding.json"
 echo "PASS $request adoption rejects changed SID with unchanged Pod UID"
 touch "$state/crash-after-ack"
 set +e
 call POST "/requests/$request/finish" 200 >"$state/$request/crash-response.log" 2>&1
 status=$?
 set -e
 test "$status" != 0
 for _ in {1..100};do process_state=$(ps -o stat= -p "$(cat "$state/foundation.pid")"||true);[[ -z $process_state || $process_state == Z* ]]&&break;sleep 0.1;done
 test ! -f "$state/$request/receipt.json"
 jq -e '.status=="CommandIntent" and .attempt==1 and .binding.runtimeSandboxID!=""' "$state/records/$request.json" >/dev/null
 counts | jq -e --arg startup "startup/$request" --arg command "command/$request" '.[$startup]==1 and .[$command]==1' >/dev/null
 rm "$state/crash-after-ack"
 restart
 call GET "/requests/$request" 200
 jq -e '.status=="UnknownOutcome" and .cleanup=="Verified"' "$state/response.json" >/dev/null
 call POST "/requests/$request/finish" 409
 call GET "/requests/$request/evidence/receipt" 409
 counts | jq -e --arg startup "startup/$request" --arg command "command/$request" '.[$startup]==1 and .[$command]==1' >/dev/null
 jq -e '.runtimeRemovalVerified==true and .removed==true' "$state/$request/fence.json" >/dev/null
 cp "$state/records/$request.json" "evidence/recovery-$request-final.json"
 cp "$state/$request/fence.json" "evidence/recovery-$request-fence.json"
 echo "PASS $request acknowledged-command crash recovers UnknownOutcome; verified disposal; no command replay"
 done
counts >evidence/recovery-counts.json
jq -e '."startup/finite"==1 and ."command/finite"==1 and ."startup/session"==1 and ."command/session"==1' evidence/recovery-counts.json >/dev/null
jq -n '{nativeTaskRunAdopted:true,agentSandboxAdopted:true,exactRuntimeBinding:true,durableCommandIntent:true,unknownOutcomeAfterAcknowledgement:true,commandReplay:false,startupReplay:false,verifiedDisposal:true,externalMarkerCounts:"recovery-counts.json"}' | tee evidence/recovery-result.json
