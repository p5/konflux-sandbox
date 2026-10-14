#!/usr/bin/env bash
set -euo pipefail

prototype_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd "$prototype_dir/../.." && pwd)
state_dir="$repo_dir/.prototype-state/konflux"
result_dir="$repo_dir/.prototype-results/konflux"
namespace=konflux-lifecycle-prototype
: "${KUBECONFIG:=/tmp/konflux-sandbox-prototype-qw2Tu2/kubeconfig}"
: "${KUBE_CONTEXT:=kind-konflux-sandbox-prototype}"
mkdir -p "$state_dir" "$result_dir"
trap 'exit 130' INT
trap 'exit 143' TERM

"$prototype_dir/guard.sh"

k() { kubectl --kubeconfig "$KUBECONFIG" --context "$KUBE_CONTEXT" --request-timeout=20s "$@"; }
kn() { k -n "$namespace" "$@"; }

wait_json() {
  local resource=$1 name=$2 expression=$3 destination=$4
  local deadline=$((SECONDS + 180))
  while (( SECONDS < deadline )); do
    if kn get "$resource" "$name" -o json > "$destination" 2>/dev/null && jq -e "$expression" "$destination" >/dev/null; then
      return
    fi
    sleep 2
  done
  printf 'Timeout: %s/%s, expression %s\n' "$resource" "$name" "$expression" >&2
  return 1
}

restore_chains() {
  if [[ -f "$state_dir/chains-original-http.json" ]]; then
    local patch
    if jq -e '.present' "$state_dir/chains-original-http.json" >/dev/null; then
      patch=$(jq -c '[{op:"replace",path:"/spec/chain/storage.oci.repository.insecure",value:.value}]' "$state_dir/chains-original-http.json")
    else
      patch='[{"op":"remove","path":"/spec/chain/storage.oci.repository.insecure"}]'
    fi
    k patch tektonconfig config --type=json -p "$patch" > "$result_dir/chains-restore.log" 2>&1
    local expected deadline=$((SECONDS+90))
    expected=$(jq -r '.value // false | tostring' "$state_dir/chains-original-http.json")
    until k -n tekton-pipelines get configmap chains-config -o json | jq -e --arg expected "$expected" '(.data["storage.oci.repository.insecure"]//"false")==$expected' >/dev/null; do
      (( SECONDS < deadline )) || return 1
      sleep 2
    done
    jq -n --arg value "$expected" '{restored:true,effectiveInsecure:$value}' > "$result_dir/chains-restored.json"
  fi
}

configure_chains() {
  k get tektonconfig config -o json | jq '{present:(.spec.chain|has("storage.oci.repository.insecure")),value:.spec.chain["storage.oci.repository.insecure"]}' > "$state_dir/chains-original-http.json"
  trap 'chain_exit_status=$?; restore_chains || chain_exit_status=1; exit "$chain_exit_status"' EXIT
  k patch tektonconfig config --type=merge -p '{"spec":{"chain":{"storage.oci.repository.insecure":true}}}' > "$result_dir/chains-local-http.log"
  local deadline=$((SECONDS + 120))
  until k -n tekton-pipelines get configmap chains-config -o json | jq -e '.data["storage.oci.repository.insecure"]=="true"' >/dev/null; do
    (( SECONDS < deadline )) || return 1
    sleep 2
  done
}

prepare_namespace() {
  if k get namespace "$namespace" -o json > "$state_dir/namespace.json" 2>/dev/null; then
    jq -e '.metadata.labels["sandbox.konflux-ci.dev/prototype"]=="lifecycle"' "$state_dir/namespace.json" >/dev/null
  else
    k create namespace "$namespace"
    k label namespace "$namespace" sandbox.konflux-ci.dev/prototype=lifecycle
  fi
  for account in lifecycle-runner konflux-integration-runner; do
    jq -n --arg name "$account" --arg ns "$namespace" '{apiVersion:"v1",kind:"ServiceAccount",metadata:{name:$name,namespace:$ns},automountServiceAccountToken:false}' | k apply -f -
  done
  kn apply -f "$prototype_dir/fixtures/integration-pipeline.yaml"
}

integration_case() {
  local outcome=$1 suffix=$2
  local application="lifecycle-$suffix-$run_id" component="fixture-$suffix-$run_id" build="build-$suffix-$run_id" scenario="scenario-$suffix-$run_id"
  jq -n --arg ns "$namespace" --arg app "$application" --arg comp "$component" --arg scenario "$scenario" --arg outcome "$outcome" --arg image "$manifest_reference" '
    {apiVersion:"v1",kind:"List",items:[
      {apiVersion:"appstudio.redhat.com/v1alpha1",kind:"Application",metadata:{name:$app,namespace:$ns},spec:{displayName:$app}},
      {apiVersion:"appstudio.redhat.com/v1alpha1",kind:"Component",metadata:{name:$comp,namespace:$ns},spec:{componentName:$comp,application:$app,containerImage:$image,source:{git:{url:"https://github.com/p5/konflux-sandbox",revision:"main"}}}},
      {apiVersion:"appstudio.redhat.com/v1beta2",kind:"IntegrationTestScenario",metadata:{name:$scenario,namespace:$ns},spec:{application:$app,resolverRef:{resolver:"cluster",params:[{name:"kind",value:"pipeline"},{name:"namespace",value:$ns},{name:"name",value:"lifecycle-integration"}]},params:[{name:"outcome",value:$outcome}]}}
    ]}' > "$result_dir/$suffix-resources.json"
  kn apply -f "$result_dir/$suffix-resources.json"
  sed -e "s|@BUILD@|$build|g" -e "s|@APPLICATION@|$application|g" -e "s|@COMPONENT@|$component|g" -e "s|@IMAGE_URL@|$image_url|g" -e "s|@IMAGE_DIGEST@|$image_digest|g" -e "s|@SOURCE_REVISION@|$source_revision|g" "$prototype_dir/fixtures/build.yaml" > "$result_dir/$suffix-build.yaml"
  kn apply -f "$result_dir/$suffix-build.yaml"
  wait_json pipelinerun "$build" '.metadata.annotations["chains.tekton.dev/signed"]=="true" and .metadata.annotations["appstudio.openshift.io/snapshot"]!=null' "$result_dir/$suffix-build.json"
  local snapshot integration
  snapshot=$(jq -r '.metadata.annotations["appstudio.openshift.io/snapshot"]' "$result_dir/$suffix-build.json")
  local deadline=$((SECONDS + 120))
  while (( SECONDS < deadline )); do
    integration=$(kn get pipelineruns -l "test.appstudio.openshift.io/scenario=$scenario" -o json | jq -r '.items[0].metadata.name // empty')
    [[ -z "$integration" ]] || break
    sleep 2
  done
  [[ -n "$integration" ]]
  if [[ "$outcome" == cancel ]]; then
    wait_json pipelinerun "$integration" '(.status.childReferences//[]|length)>0' "$result_dir/$suffix-integration.json"
    local running_task
    running_task=$(jq -r '.status.childReferences[0].name' "$result_dir/$suffix-integration.json")
    wait_json taskrun "$running_task" 'any(.status.steps[]?; .running.startedAt!=null)' "$result_dir/$suffix-task-before-cancel.json"
    kn patch pipelinerun "$integration" --type=merge -p '{"spec":{"status":"Cancelled"}}'
  fi
  wait_json pipelinerun "$integration" '.status.completionTime!=null' "$result_dir/$suffix-integration.json"
  wait_json snapshot "$snapshot" '.metadata.annotations["test.appstudio.openshift.io/status"]!=null' "$result_dir/$suffix-snapshot.json"
  local status_deadline=$((SECONDS + 90))
  while (( SECONDS < status_deadline )); do
    kn get snapshot "$snapshot" -o json > "$result_dir/$suffix-snapshot.json"
    if jq -e '.metadata.annotations["test.appstudio.openshift.io/status"] | fromjson | tostring | test("TestPassed|TestFail|TestInvalid|TestWarning|Cancelled")' "$result_dir/$suffix-snapshot.json" >/dev/null; then break; fi
    sleep 2
  done
  kn get taskruns -l "tekton.dev/pipelineRun=$integration" -o json > "$result_dir/$suffix-taskruns.json"
  jq -n --arg outcome "$outcome" --arg application "$application" --arg component "$component" --arg build "$build" --arg snapshot "$snapshot" --arg integration "$integration" --slurpfile plr "$result_dir/$suffix-integration.json" --slurpfile snap "$result_dir/$suffix-snapshot.json" '{case:$outcome,application:$application,component:$component,build:$build,snapshot:$snapshot,integration:$integration,tekton:$plr[0].status.conditions,snapshotTests:($snap[0].metadata.annotations["test.appstudio.openshift.io/status"]|fromjson)}' > "$result_dir/$suffix-summary.json"
  cat "$result_dir/$suffix-summary.json"
  local expected=TestFail
  [[ "$outcome" != SUCCESS ]] || expected=TestPassed
  jq -e --arg expected "$expected" '.snapshotTests|length==1 and .[0].status==$expected' "$result_dir/$suffix-summary.json" >/dev/null
}

integration() {
  local reference_file="$result_dir/portless-manifest-reference.txt"
  manifest_reference=${MANIFEST_REFERENCE:-$(cat "$reference_file")}
  image_url=${manifest_reference%@*}
  image_digest=${manifest_reference##*@}
  source_revision=$(git -C "$repo_dir" rev-parse HEAD)
  run_id=$(date -u +%H%M%S)
  prepare_namespace
  configure_chains
  integration_case SUCCESS pass
  integration_case FAILURE fail
  integration_case malformed malformed
  integration_case cancel cancel
  k -n tekton-pipelines get secret public-key -o jsonpath='{.data.cosign\.pub}' | base64 -d > "$result_dir/chains-public.pem"
  cosign verify --key "$result_dir/chains-public.pem" --insecure-ignore-tlog --allow-insecure-registry "$manifest_reference" > "$result_dir/cosign-image-verification.json" 2> "$result_dir/cosign-image-verification.log"
  cosign verify-attestation --key "$result_dir/chains-public.pem" --insecure-ignore-tlog --allow-insecure-registry --type slsaprovenance "$manifest_reference" > "$result_dir/cosign-attestation-verification.json" 2> "$result_dir/cosign-attestation-verification.log"
  new_model_gate
  failed_marker_boundary
  kn get snapshots -o json > "$result_dir/all-snapshots.json"
  kn get pipelineruns -o json > "$result_dir/all-pipelineruns.json"
}

registry_port_bug() {
  manifest_reference=$(cat "$repo_dir/.prototype-results/artifacts/manifest-reference.txt")
  image_url=${manifest_reference%@*}
  image_digest=${manifest_reference##*@}
  source_revision=$(git -C "$repo_dir" rev-parse HEAD)
  run_id=$(date -u +%H%M%S)
  [[ "$image_url" == *:*/* ]]
  prepare_namespace
  configure_chains
  integration_case SUCCESS port-bug
  local actual expected
  actual=$(jq -r '.spec.components[0].containerImage' "$result_dir/port-bug-snapshot.json")
  expected="${image_url%%:*}@$image_digest"
  [[ "$actual" == "$expected" && "$actual" != "$manifest_reference" ]]
  k -n tekton-pipelines get secret public-key -o jsonpath='{.data.cosign\.pub}' | base64 -d > "$result_dir/chains-public.pem"
  jq .spec "$result_dir/port-bug-snapshot.json" > "$result_dir/port-bug-snapshot-spec.json"
  mkdir -p "$state_dir/empty-auth"
  if DOCKER_CONFIG="$state_dir/empty-auth" "$repo_dir/.prototype-state/artifacts/bin/ec" validate image --images "$result_dir/port-bug-snapshot-spec.json" --public-key "$result_dir/chains-public.pem" --policy '{"sources":[]}' --ignore-rekor --timeout=20s --output "json=$result_dir/port-bug-conforma.json" > "$result_dir/port-bug-conforma.log" 2>&1; then
    printf 'Malformed Snapshot unexpectedly passed Conforma validation.\n' >&2
    return 1
  fi
  jq -n --arg original "$manifest_reference" --arg actual "$actual" '{input:$original,controllerSnapshot:$actual,referencePreserved:false,conformaAccepted:false,fixture:"Actual signed PipelineRun and controller-created Snapshot; image metadata synthetic"}' > "$result_dir/port-bug-summary.json"
}

failed_marker_boundary() {
  local build="build-failed-marker-$run_id" application="marker-$run_id" component="marker-component-$run_id"
  local registry="${image_url%%/*}" unsigned_url backend_url unsigned_digest
  unsigned_url="$registry/prototype/lifecycle-denied"
  backend_url="${REGISTRY:-172.18.0.5:5000}/prototype/lifecycle-denied"
  printf 'Unsigned synthetic lifecycle subject: %s\n' "$run_id" > "$state_dir/unsigned.txt"
  (cd "$state_dir" && oras push --plain-http "$backend_url:fixture-$run_id" --artifact-type application/vnd.konflux.prototype.fixture.v1 unsigned.txt:text/plain) > "$result_dir/failed-marker-artifact.log"
  unsigned_digest=$(oras resolve --plain-http "$backend_url:fixture-$run_id")
  jq -n --arg ns "$namespace" --arg app "$application" --arg comp "$component" --arg image "$unsigned_url@$unsigned_digest" '{apiVersion:"v1",kind:"List",items:[
    {apiVersion:"appstudio.redhat.com/v1alpha1",kind:"Application",metadata:{name:$app,namespace:$ns},spec:{displayName:$app}},
    {apiVersion:"appstudio.redhat.com/v1alpha1",kind:"Component",metadata:{name:$comp,namespace:$ns},spec:{componentName:$comp,application:$app,containerImage:$image,source:{git:{url:"https://github.com/p5/konflux-sandbox",revision:"main"}}}}
  ]}' | kn apply -f -
  sed -e "s|@BUILD@|$build|g" -e "s|@APPLICATION@|$application|g" -e "s|@COMPONENT@|$component|g" -e "s|@IMAGE_URL@|$unsigned_url|g" -e "s|@IMAGE_DIGEST@|$unsigned_digest|g" -e "s|@SOURCE_REVISION@|$source_revision|g" "$prototype_dir/fixtures/build.yaml" |
    k create --dry-run=client -f - -o json |
    jq '.spec.pipelineSpec.results[0].value="$(tasks.fixture-build.results.fixture-url)" |
      .spec.pipelineSpec.results[1].value="$(tasks.fixture-build.results.fixture-digest)" |
      .spec.pipelineSpec.tasks[0].taskSpec.results[0].name="fixture-url" |
      .spec.pipelineSpec.tasks[0].taskSpec.results[1].name="fixture-digest" |
      .spec.pipelineSpec.tasks[0].taskSpec.steps[0].script |= (gsub("results.IMAGE_URL.path";"results.fixture-url.path")|gsub("results.IMAGE_DIGEST.path";"results.fixture-digest.path"))' > "$result_dir/failed-marker-input.json"
  kn apply -f "$result_dir/failed-marker-input.json"
  wait_json pipelinerun "$build" '.metadata.annotations["chains.tekton.dev/signed"]=="failed" and .metadata.annotations["appstudio.openshift.io/snapshot"]!=null' "$result_dir/failed-marker-build.json"
  jq -e '.metadata.annotations["chains.tekton.dev/signed"]=="failed"' "$result_dir/failed-marker-build.json" >/dev/null
  if cosign verify --key "$result_dir/chains-public.pem" --insecure-ignore-tlog --allow-insecure-registry "$unsigned_url@$unsigned_digest" > "$result_dir/failed-marker-verification.json" 2> "$result_dir/failed-marker-verification.log"; then
    printf 'Unsigned fixture unexpectedly passed cryptographic verification.\n' >&2
    return 1
  fi
  k -n tekton-pipelines logs deployment/tekton-chains-controller --since=5m | rg "$build|lifecycle-denied" > "$result_dir/failed-marker-controller.log"
  jq -n --arg name "$build" --arg image "$unsigned_url@$unsigned_digest" '{build:$name,image:$image,marker:"failed",markerInjected:false,writeDenialInjected:true,snapshotCreated:true,cryptographicVerification:false,scope:"Actual Chains failure after local proxy denies fixture-repository writes"}' > "$result_dir/failed-marker-summary.json"
}

new_model_gate() {
  local build="build-new-model-$run_id"
  sed -e "s|@BUILD@|$build|g" -e "s|@APPLICATION@|unused|g" -e "s|@COMPONENT@|fixture-new-model|g" -e "s|@IMAGE_URL@|$image_url|g" -e "s|@IMAGE_DIGEST@|$image_digest|g" -e "s|@SOURCE_REVISION@|$source_revision|g" "$prototype_dir/fixtures/build.yaml" |
    k create --dry-run=client -f - -o json |
    jq 'del(.metadata.labels["pipelines.appstudio.openshift.io/type"],.metadata.labels["appstudio.openshift.io/application"],.metadata.labels["appstudio.openshift.io/component"]) | .metadata.labels["pipelines.konflux-ci.dev/type"]="build" | .metadata.labels["build.konflux-ci.dev/component"]="fixture-new-model"' > "$result_dir/new-model-input.json"
  kn apply -f "$result_dir/new-model-input.json"
  wait_json pipelinerun "$build" '.metadata.annotations["chains.tekton.dev/signed"]=="true"' "$result_dir/new-model-build.json"
  sleep 5
  kn get pipelinerun "$build" -o json > "$result_dir/new-model-build.json"
  jq -e '.metadata.annotations["appstudio.openshift.io/snapshot"]==null and .metadata.annotations["appstudio.openshift.io/snapshots"]==null and all(.metadata.finalizers[]?; .!="test.appstudio.openshift.io/pipelinerun" and .!="test.appstudio.openshift.io/nudge-pipelinerun")' "$result_dir/new-model-build.json" >/dev/null
  k -n integration-service logs deployment/integration-service-controller-manager --since=3m | rg "Skipping new-model.*|$build" > "$result_dir/new-model-controller.log"
  jq -n --arg name "$build" --slurpfile plr "$result_dir/new-model-build.json" '{build:$name,signed:true,snapshotCreated:false,finalizers:$plr[0].metadata.finalizers,scope:"new-model label gate only; no complete ComponentGroup workflow exercised"}' > "$result_dir/new-model-summary.json"
}

release() {
  [[ -f "$result_dir/pass-summary.json" && -f "$result_dir/chains-public.pem" ]]
  local application snapshot run_id release_plan
  application=$(jq -r .application "$result_dir/pass-summary.json")
  snapshot=$(jq -r .snapshot "$result_dir/pass-summary.json")
  run_id=$(date -u +%H%M%S)
  release_plan="lifecycle-local-$run_id"
  if k get konfluxreleaseservice konflux-release-service -o json > "$state_dir/release-original.json" 2>/dev/null; then
    jq '{value:.spec.debug}' "$state_dir/release-original.json" > "$state_dir/release-original-debug.json"
  else
    printf '%s\n' '{"value":null}' > "$state_dir/release-original-debug.json"
  fi
  trap 'release_exit_status=$?; restore_release_debug || release_exit_status=1; exit "$release_exit_status"' EXIT
  k apply -f "$prototype_dir/fixtures/operator-services.yaml" > "$result_dir/release-services-install.log"
  k wait --for=condition=Ready konfluxreleaseservice/konflux-release-service --timeout=180s >> "$result_dir/release-services-install.log"
  local initial_deadline=$((SECONDS+90))
  until k -n release-service get releaseserviceconfig release-service-config -o json | jq -e '.spec.debug==false' >/dev/null; do
    (( SECONDS < initial_deadline )) || return 1
    sleep 2
  done
  local image_dir="$state_dir/image"
  mkdir -p "$image_dir"
  cp "$repo_dir/.prototype-state/artifacts/bin/ec-static" "$image_dir/ec"
  install -m 755 "$(command -v kubectl)" "$image_dir/kubectl"
  cp "$result_dir/chains-public.pem" "$image_dir/chains-public.pem"
  mkdir -p "$image_dir/policy"
  cp -R "$repo_dir/../conforma-policy/policy/." "$image_dir/policy/"
  git -C "$repo_dir/../conforma-policy" rev-parse HEAD > "$result_dir/release-policy-commit.txt"
  cp "$prototype_dir/fixtures/Dockerfile" "$image_dir/Dockerfile"
  docker build -t konflux-sandbox-lifecycle-tools:prototype "$image_dir" > "$result_dir/release-image-build.log" 2>&1
  KIND_EXPERIMENTAL_PROVIDER=docker kind load docker-image konflux-sandbox-lifecycle-tools:prototype --name "${KUBE_CONTEXT#kind-}" > "$result_dir/release-image-load.log" 2>&1
  kn apply -f "$prototype_dir/fixtures/release-pipeline.yaml"
  jq -n --arg ns "$namespace" --arg app "$application" --arg plan "$release_plan" '{apiVersion:"v1",kind:"List",items:[
    {apiVersion:"v1",kind:"ServiceAccount",metadata:{name:"lifecycle-release-runner",namespace:$ns},automountServiceAccountToken:true},
    {apiVersion:"rbac.authorization.k8s.io/v1",kind:"Role",metadata:{name:"lifecycle-snapshot-reader",namespace:$ns},rules:[{apiGroups:["appstudio.redhat.com"],resources:["snapshots"],verbs:["get"]}]},
    {apiVersion:"rbac.authorization.k8s.io/v1",kind:"RoleBinding",metadata:{name:"lifecycle-snapshot-reader",namespace:$ns},roleRef:{apiGroup:"rbac.authorization.k8s.io",kind:"Role",name:"lifecycle-snapshot-reader"},subjects:[{kind:"ServiceAccount",name:"lifecycle-release-runner",namespace:$ns}]},
    {apiVersion:"appstudio.redhat.com/v1alpha1",kind:"EnterpriseContractPolicy",metadata:{name:"lifecycle-permit",namespace:$ns},spec:{publicKey:"/public/chains.pem",sources:[{name:"fixture-provenance",policy:["/policy/release","/policy/lib"],config:{include:["slsa_provenance_available","attestation_type"]},ruleData:{allowed_predicate_types:["https://slsa.dev/provenance/v0.2"]}}]}},
    {apiVersion:"appstudio.redhat.com/v1alpha1",kind:"EnterpriseContractPolicy",metadata:{name:"lifecycle-reject",namespace:$ns},spec:{publicKey:"/public/chains.pem",sources:[{name:"fixture-provenance",policy:["/policy/release","/policy/lib"],config:{include:["slsa_provenance_available","attestation_type"]},ruleData:{allowed_predicate_types:["https://invalid.example/provenance"]}}]}},
    {apiVersion:"appstudio.redhat.com/v1alpha1",kind:"ReleasePlan",metadata:{name:$plan,namespace:$ns,labels:{"release.appstudio.openshift.io/auto-release":"false","release.appstudio.openshift.io/releasePlanAdmission":$plan}},spec:{application:$app,target:$ns}},
    {apiVersion:"appstudio.redhat.com/v1alpha1",kind:"ReleasePlanAdmission",metadata:{name:$plan,namespace:$ns},spec:{applications:[$app],origin:$ns,policy:"lifecycle-permit",pipeline:{pipelineRef:{resolver:"cluster",params:[{name:"kind",value:"pipeline"},{name:"namespace",value:$ns},{name:"name",value:"lifecycle-managed-release"}]},serviceAccountName:"lifecycle-release-runner",maxRetries:0,timeouts:{pipeline:"5m",tasks:"4m",finally:"1m"}}}}
  ]}' > "$result_dir/release-resources.json"
  jq '.items|=map(select(.kind!="ReleasePlan"))' "$result_dir/release-resources.json" | kn apply -f -
  wait_json releaseplanadmission "$release_plan" '(.status.conditions//[]|length)>0' "$result_dir/release-admission-initial.json"
  jq '.items|=map(select(.kind=="ReleasePlan"))' "$result_dir/release-resources.json" | kn apply -f -
  wait_json releaseplan "$release_plan" '.status.releasePlanAdmission.name!=null' "$result_dir/release-plan.json"
  release_case debug-blocked "$snapshot" "$run_id"
  jq -e 'any(.status.conditions[]; .type=="Validated" and .status=="False" and (.message|contains("debug")))' "$result_dir/release-debug-blocked.json" >/dev/null
  jq -e '.items|length==0' "$result_dir/release-debug-blocked-pipelines.json" >/dev/null
  k patch konfluxreleaseservice konflux-release-service --type=merge -p '{"spec":{"debug":true}}' > "$result_dir/release-enable-local-resolver.log"
  local deadline=$((SECONDS+90))
  until k -n release-service get releaseserviceconfig release-service-config -o json | jq -e '.spec.debug==true' >/dev/null; do
    (( SECONDS < deadline )) || return 1
    sleep 2
  done
  release_case permit "$snapshot" "$run_id"
  jq -e 'any(.status.conditions[]; .type=="Released" and .status=="True")' "$result_dir/release-permit.json" >/dev/null
  jq -e '.items|length==1 and any(.[0].status.results[]; .name=="DESTINATION_REACHED" and .value=="local-noop")' "$result_dir/release-permit-pipelines.json" >/dev/null
  kn patch releaseplanadmission "$release_plan" --type=merge -p '{"spec":{"policy":"lifecycle-reject"}}'
  release_case reject "$snapshot" "$run_id"
  jq -e 'any(.status.conditions[]; .type=="Released" and .status=="False")' "$result_dir/release-reject.json" >/dev/null
  jq -e '.items|length==1 and all(.[0].status.results[]?; .name!="DESTINATION_REACHED")' "$result_dir/release-reject-pipelines.json" >/dev/null
  jq -e 'any(.items[].status.steps[]; .name=="conforma-gate" and .terminated.exitCode==1) and any(.items[].status.steps[]; .name=="local-noop-destination" and .terminationReason=="Skipped")' "$result_dir/release-reject-taskruns.json" >/dev/null
  rg -q 'slsa_provenance_available.attestation_predicate_type_accepted' "$result_dir/release-reject-task-logs.txt"
  k get konfluxreleaseservice,konfluxenterprisecontract -o json > "$result_dir/release-service-status.json"
}

restore_release_debug() {
  local patch expected deadline=$((SECONDS+90))
  patch=$(jq -c '{spec:{debug:.value}}' "$state_dir/release-original-debug.json")
  expected=$(jq -r '.value // false' "$state_dir/release-original-debug.json")
  k patch konfluxreleaseservice konflux-release-service --type=merge -p "$patch" > "$result_dir/release-debug-restore.log"
  until k -n release-service get releaseserviceconfig release-service-config -o json | jq -e --argjson expected "$expected" '.spec.debug==$expected' >/dev/null; do
    (( SECONDS < deadline )) || return 1
    sleep 2
  done
  jq -n --argjson expected "$expected" '{restored:true,debug:$expected}' > "$result_dir/release-debug-restored.json"
}

release_case() {
  local suffix=$1 snapshot=$2 run_id=$3 name="release-$1-$3"
  jq -n --arg ns "$namespace" --arg name "$name" --arg snapshot "$snapshot" --arg plan "$release_plan" '{apiVersion:"appstudio.redhat.com/v1alpha1",kind:"Release",metadata:{name:$name,namespace:$ns},spec:{snapshot:$snapshot,releasePlan:$plan}}' > "$result_dir/release-$suffix-input.json"
  kn apply -f "$result_dir/release-$suffix-input.json"
  wait_json release "$name" '.status.completionTime!=null' "$result_dir/release-$suffix.json"
  kn get pipelineruns -l "release.appstudio.openshift.io/name=$name" -o json > "$result_dir/release-$suffix-pipelines.json"
  local pipeline
  pipeline=$(jq -r '.items[0].metadata.name // empty' "$result_dir/release-$suffix-pipelines.json")
  if [[ -n "$pipeline" ]]; then
    kn get taskruns -l "tekton.dev/pipelineRun=$pipeline" -o json > "$result_dir/release-$suffix-taskruns.json"
    kn logs -l "tekton.dev/pipelineRun=$pipeline" --all-containers=true --prefix=true > "$result_dir/release-$suffix-task-logs.txt" 2>&1 || true
  fi
  jq '{name:.metadata.name,conditions:.status.conditions,managedProcessing:.status.managedProcessing,managedPipelineAttempts:.status.managedPipelineAttempts}' "$result_dir/release-$suffix.json"
}

case "${1:-integration}" in
  integration) integration ;;
  port-bug) registry_port_bug ;;
  release) release ;;
  cleanup) k delete namespace "$namespace" --wait=false ;;
  *) printf 'Usage: %s {integration|release|cleanup}\n' "$0" >&2; exit 2 ;;
esac
