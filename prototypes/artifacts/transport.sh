#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
state="$root/.prototype-state/artifacts"
results="$root/.prototype-results/artifacts"
upstream=$(cd "$root/../build-trusted-artifacts" && pwd)
mkdir -p "$state/bin" "$results"
if ! docker inspect konflux-sandbox-artifact-registry >/dev/null 2>&1; then
  docker run -d --name konflux-sandbox-artifact-registry --network kind registry:2@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373
fi
registry=$(docker inspect konflux-sandbox-artifact-registry --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'):5000
curl -fsS "http://$registry/v2/" >/dev/null
printf '%s\n' "$registry" > "$results/registry-endpoint.txt"
printf '{"auths":{}}\n' > "$state/auth.json"
printf '#!/bin/bash\nexec "$@"\n' > "$state/bin/retry"
chmod 700 "$state/bin/retry"
export PATH="$state/bin:$upstream:$PATH"
export AUTHFILE="$state/auth.json" ORAS_OPTIONS=--plain-http
source_dir=$(mktemp -d "$state/payload.XXXXXX")
cp "$state/source.tar" "$state/manifest.json" "$source_dir/"
cd "$upstream"
bash ./create-oci.sh --store "$registry/prototype/source:latest" "$state/source-reference=$source_dir" | tee "$results/create.log"
uri=$(cat "$state/source-reference")
restored=$(mktemp -d "$state/restored.XXXXXX")
printf 'synthetic stale file\n' > "$restored/stale.txt"
bash ./use-oci.sh "$uri=$restored" | tee "$results/restore.log"
cmp "$source_dir/source.tar" "$restored/source.tar"
cmp "$source_dir/manifest.json" "$restored/manifest.json"
[[ -f "$restored/stale.txt" ]]
printf '%s\n' "$uri" > "$results/source-reference.txt"
manifest_digest=$(oras manifest fetch --plain-http --descriptor "$registry/prototype/source:latest" | jq -r .digest)
printf '%s\n' "$registry/prototype/source@$manifest_digest" > "$results/manifest-reference.txt"
blob_digest=${uri##*@}
oras blob fetch --plain-http "$registry/prototype/source@$blob_digest" --output "$state/download.tar.gz"
printf '%s  %s\n' "${blob_digest#sha256:}" "$state/download.tar.gz" | sha256sum -c - | tee "$results/blob-check.log"
touch -d '2020-01-01 UTC' "$source_dir/manifest.json"
bash ./create-oci.sh --store "$registry/prototype/source:timestamp-change" "$state/changed-reference=$source_dir" > "$results/timestamp-change.log"
if [[ "$uri" == "$(cat "$state/changed-reference")" ]]; then
  echo 'Expected archive metadata to change digest' >&2; exit 1
fi
jq -n --arg registry "$registry" --arg uri "$uri" --arg manifest "$registry/prototype/source@$manifest_digest" '{registry:$registry,trusted_artifact_uri:$uri,manifest_subject:$manifest,roundtrip:true,blob_digest_verified:true,helper_tar_metadata_not_canonical:true,helper_retains_existing_destination_files:true,retry_adapter:"single attempt; upstream retry binary unavailable"}' | tee "$results/transport.json"
