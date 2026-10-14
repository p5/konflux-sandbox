#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
upstream=$(cd "$root/../pipelines-as-code" && pwd)
state="$root/.prototype-state/source-entry"
results="$root/.prototype-results/source-entry"
mkdir -p "$state/bin" "$results"
(cd "$upstream" && go build -mod=vendor -o "$state/bin/tkn-pac" ./cmd/tkn-pac)
cat > "$state/offline-kubeconfig" <<'EOF'
apiVersion: v1
kind: Config
clusters:
- name: intentionally-unavailable-local-api
  cluster:
    server: http://127.0.0.1:1
contexts:
- name: local-only
  context:
    cluster: intentionally-unavailable-local-api
    namespace: source-entry-prototype
current-context: local-only
users: []
EOF
revision=4d54fabd3419d8b99c854dfee0a1bf1b4354ffb9
unset PAC_PROVIDER_TOKEN
"$state/bin/tkn-pac" --kubeconfig "$state/offline-kubeconfig" resolve --no-secret --remoteTask=false --no-generate-name -f "$here/template.yaml" -p "revision=$revision" -p repo_url=https://github.com/konflux-ci/application-api -o "$results/resolved.yaml" > "$results/pac-resolve.log" 2>&1
[[ -s "$results/resolved.yaml" ]]
rg -q "$revision" "$results/resolved.yaml"
rg -q 'taskSpec:' "$results/resolved.yaml"
if rg -q '\{\{|taskRef:' "$results/resolved.yaml"; then echo 'Unresolved template or task reference' >&2; exit 1; fi
awk '/^---$/{exit}{print}' "$here/template.yaml" > "$state/missing-task.yaml"
if "$state/bin/tkn-pac" --kubeconfig "$state/offline-kubeconfig" resolve --no-secret --remoteTask=false --no-generate-name -f "$state/missing-task.yaml" -p "revision=$revision" -p repo_url=https://github.com/konflux-ci/application-api > "$results/pac-missing-task.log" 2>&1; then
  echo 'Unresolved local task unexpectedly succeeded' >&2; exit 1
fi
rg -q 'cannot find referenced task local-check' "$results/pac-missing-task.log"
node --input-type=module - "$results/build-service.jsonl" "$state/trigger-payload.json" <<'EOF'
import fs from 'node:fs';
const rows=fs.readFileSync(process.argv[2],'utf8').split('\n').filter(line=>line.startsWith('{')).map(line=>JSON.parse(line));
const fixture=rows.find(row=>row.scenario==='actual-trigger-post-to-local-denial-fixture');
if (!fixture) throw new Error('Run the build-service target first');
fs.writeFileSync(process.argv[3],JSON.stringify(fixture.payload));
EOF
jq -n --arg originalMain "$upstream/cmd/tkn-pac/main.go" --arg main "$here/overlay/main.go.txt" --arg adapter "$upstream/pkg/adapter/source_entry_prototype.go" --arg export "$here/overlay/adapter-export.go.txt" '{Replace:{($originalMain):$main,($adapter):$export}}' > "$state/parser-overlay.json"
(cd "$upstream" && go build -mod=vendor -overlay "$state/parser-overlay.json" -o "$state/bin/incoming-parser" ./cmd/tkn-pac)
"$state/bin/incoming-parser" "$state/trigger-payload.json" | tee "$results/pac-incoming-parser.jsonl"
git -C "$upstream" rev-parse HEAD > "$results/pac-commit.txt"
git -C "$root/../build-service" rev-parse HEAD > "$results/build-service-commit.txt"
jq -n --arg revision "$revision" '{actual_pac_cli:true,revision:$revision,local_tasks_inlined:true,template_parameters_resolved:true,missing_task_rejected:true,incoming_parser_missing_secret_rejected:true,provider_credentials_created:false,live_kubernetes_api:false,github_api_actions:false}' | tee "$results/pac.json"
