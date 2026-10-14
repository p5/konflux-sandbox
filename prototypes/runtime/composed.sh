#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../.. && pwd)
artifact_state=$root/.prototype-state/artifacts
artifact_results=$root/.prototype-results/artifacts
upstream=$root/../build-trusted-artifacts
mkdir -p .build/composed evidence
exec > >(tee evidence/composed.log) 2>&1
KUBECONFIG=${KUBECONFIG:-/tmp/konflux-sandbox-runtime/vm-kubeconfig}
source ./context.sh
require_runtime_context "$KUBECONFIG" kind-konflux-sandbox-vm-prototype
k() { runtime_k "$@"; }
uri=$(cat "$artifact_results/source-reference.txt")
expected_source=$(jq -r .source_digest "$artifact_results/source.json")
[[ $uri =~ ^oci:172\.18\.0\.[0-9]+:5000/prototype/source@sha256:[0-9a-f]{64}$ ]]
[[ $expected_source =~ ^sha256:[0-9a-f]{64}$ ]]
expected_blob=${uri##*@}
archive=.build/composed/envelope.tar.gz
oras blob fetch --plain-http "${uri#oci:}" --output "$archive"
printf '%s  %s\n' "${expected_blob#sha256:}" "$archive" | sha256sum --check
test "$(stat -c %s "$archive")" -lt 1048576
test "$(tar -tzf "$archive")" = $'./\n./source.tar\n./manifest.json'
tar -xOzf "$archive" ./source.tar >.build/composed/source.tar
tar -xOzf "$archive" ./manifest.json >.build/composed/manifest.json
CGO_ENABLED=0 go build -C "$root/prototypes/artifacts" -o "$PWD/.build/composed/source-helper" .
host_destination=$(mktemp -d "$PWD/.build/composed/verified.XXXXXX")
.build/composed/source-helper import-verify .build/composed/source.tar .build/composed/manifest.json "$host_destination/source" "$expected_source"
expected_archive=sha256:$(sha256sum .build/composed/source.tar | cut -d' ' -f1)
echo 'PASS OCI blob digest and canonical source validated before guest execution'
oras_archive=.build/composed/oras_1.3.4_linux_amd64.tar.gz
if [[ ! -f $oras_archive ]]; then
  curl -fL https://github.com/oras-project/oras/releases/download/v1.3.4/oras_1.3.4_linux_amd64.tar.gz -o "$oras_archive"
fi
printf '%s  %s\n' f27adb935022d94df8dc77719c322dda592c78a0d57a6f7dcdd8d900b248c454 "$oras_archive" | sha256sum --check
tar -xzf "$oras_archive" -C .build/composed oras
cp "$upstream/use-oci.sh" "$upstream/oras_opts.sh" "$upstream/select-oci-auth.sh" .build/composed/
printf '#!/bin/bash\nexec "$@"\n' >.build/composed/retry
chmod 755 .build/composed/retry
docker build -t konflux-sandbox-composed:prototype -f Dockerfile.composed .build/composed
kind load docker-image konflux-sandbox-composed:prototype --name konflux-sandbox-vm-prototype
k create namespace sandbox-runtime-prototype --dry-run=client -o yaml | k apply -f -
k delete taskrun composed-check -n sandbox-runtime-prototype --ignore-not-found --wait=true
cat <<'EOF' | k create --dry-run=client -f - -o json | jq --arg uri "$uri" --arg source "$expected_source" --arg archive "$expected_archive" '.spec.params=[{name:"source-ref",value:$uri},{name:"source-digest",value:$source},{name:"archive-digest",value:$archive}]' | k apply -f -
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  name: composed-check
  namespace: sandbox-runtime-prototype
spec:
  podTemplate:
    runtimeClassName: kata-prototype
    automountServiceAccountToken: false
    securityContext:
      fsGroup: 1000
  workspaces:
  - name: source
    emptyDir: {}
  taskSpec:
    params:
    - name: source-ref
    - name: source-digest
    - name: archive-digest
    workspaces:
    - name: source
    results:
    - name: source-digest
    - name: archive-digest
    - name: guest-kernel
    - name: check-result
    steps:
    - name: fetch-and-validate
      image: konflux-sandbox-composed:prototype
      imagePullPolicy: Never
      env:
      - name: SOURCE_REF
        value: $(params.source-ref)
      - name: EXPECTED_SOURCE
        value: $(params.source-digest)
      - name: EXPECTED_ARCHIVE
        value: $(params.archive-digest)
      - name: ORAS_OPTIONS
        value: --plain-http
      - name: AUTHFILE
        value: /tmp/no-upstream-credentials
      script: |
        #!/bin/bash
        set -euo pipefail
        mkdir -p '$(workspaces.source.path)/envelope'
        use-oci.sh "$SOURCE_REF=$(workspaces.source.path)/envelope"
        printf '%s  %s\n' "${EXPECTED_ARCHIVE#sha256:}" '$(workspaces.source.path)/envelope/source.tar' | sha256sum --check
        source-helper import-verify '$(workspaces.source.path)/envelope/source.tar' '$(workspaces.source.path)/envelope/manifest.json' '$(workspaces.source.path)/tree' "$EXPECTED_SOURCE"
        printf '%s' "$EXPECTED_SOURCE" > '$(results.source-digest.path)'
        printf '%s' "$EXPECTED_ARCHIVE" > '$(results.archive-digest.path)'
    - name: check-source
      image: konflux-sandbox-composed:prototype
      imagePullPolicy: Never
      workingDir: $(workspaces.source.path)
      env:
      - name: EXPECTED_SOURCE
        value: $(params.source-digest)
      script: |
        #!/bin/bash
        set -euo pipefail
        cd tree
        ./run.sh
        test "$(cat staged.txt)" = staged
        test "$(cat unstaged.txt)" = unstaged
        test "$(cat selected.txt)" = selected
        test "$(readlink link)" = unstaged.txt
        test "$(cat link)" = unstaged
        test ! -e deleted.txt
        test ! -e excluded.txt
        test ! -e /var/run/secrets/kubernetes.io/serviceaccount/token
        kernel=$(uname -r)
        printf '%s' "$kernel" > '$(results.guest-kernel.path)'
        printf '{"status":"passed","source_digest":"%s","guest_kernel":"%s"}' "$EXPECTED_SOURCE" "$kernel" > '$(results.check-result.path)'
        echo 'PASS selected working-tree bytes, executable, symlink, deletion, and exclusion checks'
EOF
k wait taskrun composed-check -n sandbox-runtime-prototype --for=jsonpath='{.status.completionTime}' --timeout=180s
k get taskrun composed-check -n sandbox-runtime-prototype -o json >evidence/composed-taskrun.json
jq -e '.status.conditions[]|select(.type=="Succeeded")|.status=="True"' evidence/composed-taskrun.json
jq --arg source "$expected_source" --arg archive "$expected_archive" -e '.status.results | (map({key:.name,value:.value}) | from_entries) | .["source-digest"]==$source and .["archive-digest"]==$archive and (.["check-result"]|fromjson|.status)=="passed"' evidence/composed-taskrun.json
guest_kernel=$(jq -r '.status.results[]|select(.name=="guest-kernel")|.value' evidence/composed-taskrun.json)
test "$guest_kernel" != "$(docker exec konflux-sandbox-vm-prototype-control-plane uname -r)"
pod=$(jq -r .status.podName evidence/composed-taskrun.json)
k logs "$pod" -n sandbox-runtime-prototype -c step-fetch-and-validate
k logs "$pod" -n sandbox-runtime-prototype -c step-check-source
jq -n --arg uri "$uri" --arg source "$expected_source" --arg archive "$expected_archive" --arg kernel "$guest_kernel" '{trusted_artifact_uri:$uri,source_digest:$source,archive_digest:$archive,guest_kernel:$kernel,check_status:"passed",transport:"upstream use-oci.sh with ORAS from inside Kata guest",retry:"single attempt adapter"}' | tee evidence/composed-result.json
k delete taskrun composed-check -n sandbox-runtime-prototype --wait=true
echo 'PASS composed source to OCI to Kata TaskRun and cleanup'
