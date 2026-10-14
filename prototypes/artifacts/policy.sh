#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
state="$root/.prototype-state/artifacts"
results="$root/.prototype-results/artifacts"
policy=$(cd "$root/../conforma-policy" && pwd)
mkdir -p "$state/bin" "$results"
ec="$state/bin/ec"
if [[ ! -x "$ec" ]]; then
  (cd "$policy" && go build -o "$ec" github.com/conforma/cli)
fi
base='data.trusted_task_test.attestation_ta'
suffix='with data.trusted_tasks as data.trusted_task_test.trusted_tasks_data with ec.oci.image_manifests as data.trusted_task_test._mock_image_manifests with ec.oci.image_manifest as data.trusted_task_test._mock_image_manifest'
evaluate() {
  "$ec" opa eval --data "$policy/policy" --data "$policy/example/data/rule_data.yml" --format json "$1" | jq -e '.result[0].expressions[-1].value'
}
evaluate "data.trusted_task.deny with input.attestations as [$base] $suffix" | jq . > "$results/policy-valid.json"
bad='oci:registry.invalid/prototype@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'
tampered="json.patch($base, [{\"op\":\"add\",\"path\":\"/statement/predicate/buildConfig/tasks/1/invocation/parameters/F_ARTIFACT\",\"value\":\"$bad\"}])"
evaluate "a := $tampered; data.trusted_task.deny with input.attestations as [a] $suffix" | jq . > "$results/policy-missing-producer.json"
untrusted="json.patch($base, [{\"op\":\"replace\",\"path\":\"/statement/predicate/buildConfig/tasks/2/ref/bundle\",\"value\":\"registry.local/untrusted:1.0@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\"}])"
evaluate "a := $untrusted; data.trusted_task.deny with input.attestations as [a] $suffix" | jq . > "$results/policy-untrusted-producer.json"
claimed="json.patch($tampered, [{\"op\":\"add\",\"path\":\"/statement/predicate/buildConfig/tasks/2/results/-\",\"value\":{\"name\":\"F_ARTIFACT\",\"value\":\"$bad\",\"type\":\"string\"}}])"
evaluate "a := $claimed; data.trusted_task.deny with input.attestations as [a] $suffix" | jq . > "$results/policy-matching-producer-claim.json"
jq -e 'length == 0' "$results/policy-valid.json" >/dev/null
jq -e 'any(.[]; .code == "trusted_task.valid_trusted_artifact_inputs")' "$results/policy-missing-producer.json" >/dev/null
jq -e 'any(.[]; .code == "trusted_task.trusted")' "$results/policy-untrusted-producer.json" >/dev/null
jq -e 'length == 0' "$results/policy-matching-producer-claim.json" >/dev/null
evaluate "$base" | jq '{attestations:[.],snapshot:{components:[]}}' > "$results/upstream-fixture-input.json"
jq -n '{engine:"Conforma ec v0.9.64 embedded OPA",policy:"actual cloned Conforma trusted_task package",upstream_fixture:true,manifest_lookups_stubbed:true,valid_chain_permitted:true,missing_producer_rejected:true,untrusted_producer_rejected:true,matching_producer_claim_permitted:true,cryptographic_verification:false,remote_execution_verified:false}' | tee "$results/policy.json"
git -C "$policy" rev-parse HEAD > "$results/policy-commit.txt"
