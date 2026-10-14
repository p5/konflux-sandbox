#!/usr/bin/env bash
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../.." && pwd)
"$here/guard.sh"
state="$root/.prototype-state/konflux"
results="$root/.prototype-results/konflux"
name=konflux-sandbox-lifecycle-registry-proxy
mkdir -p "$state" "$results"
cat > "$state/nginx.conf" <<'EOF'
pid /tmp/nginx.pid;
error_log /dev/stderr;
events {}
http {
  access_log /dev/stdout;
  client_body_temp_path /tmp/client_temp;
  proxy_temp_path /tmp/proxy_temp;
  fastcgi_temp_path /tmp/fastcgi_temp;
  uwsgi_temp_path /tmp/uwsgi_temp;
  scgi_temp_path /tmp/scgi_temp;
  server {
    listen 80;
    client_max_body_size 0;
    location ~ ^/v2/prototype/lifecycle-denied/ {
      if ($request_method !~ ^(GET|HEAD)$) { return 403; }
      proxy_pass http://konflux-sandbox-artifact-registry:5000;
      proxy_set_header Host $http_host;
      proxy_request_buffering off;
      proxy_buffering off;
    }
    location / {
      proxy_pass http://konflux-sandbox-artifact-registry:5000;
      proxy_set_header Host $http_host;
      proxy_request_buffering off;
      proxy_buffering off;
    }
  }
}
EOF
if docker inspect "$name" >/dev/null 2>&1; then
  [[ $(docker inspect "$name" --format '{{index .Config.Labels "sandbox.konflux-ci.dev/prototype"}}') == lifecycle-registry-proxy ]]
  if [[ $(docker inspect "$name" --format '{{.State.Running}}') != true ]]; then
    docker start "$name" > "$results/registry-proxy-create.log"
  else
    docker exec "$name" /usr/sbin/nginx -c /etc/nginx/nginx.conf -s reload > "$results/registry-proxy-reload.log" 2>&1
  fi
else
  docker run -d --name "$name" --network kind \
    --label sandbox.konflux-ci.dev/prototype=lifecycle-registry-proxy \
    --cap-drop=ALL --security-opt=no-new-privileges --read-only --tmpfs /tmp \
    --mount "type=bind,src=$state/nginx.conf,dst=/etc/nginx/nginx.conf,readonly" \
    registry.access.redhat.com/hi/nginx@sha256:9d2390b5ba1f9b9688a0f345dd2216d866322540e4659fb0a84cff2a0ffe600a \
    -c /etc/nginx/nginx.conf -e /dev/stderr -g 'daemon off;' > "$results/registry-proxy-create.log"
fi
address=$(docker inspect "$name" --format '{{with index .NetworkSettings.Networks "kind"}}{{.IPAddress}}{{end}}')
[[ "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
curl --fail --silent --max-time 10 --retry 5 --retry-connrefused --retry-delay 1 "http://$address/v2/" > "$results/registry-proxy-health.json"
reference=$(cat "$root/.prototype-results/artifacts/manifest-reference.txt")
printf '%s/%s\n' "$address" "${reference#*/}" > "$results/portless-manifest-reference.txt"
jq -n --arg name "$name" --arg address "$address" '{container:$name,address:$address,port:80,hostPortPublished:false,backend:"konflux-sandbox-artifact-registry:5000",scope:"Synthetic registry proxy; workaround for Integration Service port parsing"}' > "$results/registry-proxy.json"
cat "$results/portless-manifest-reference.txt"
