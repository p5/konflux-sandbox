#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
cluster=konflux-sandbox-vm-prototype
node=$cluster-control-plane
scratch=${RUNTIME_SCRATCH:-/tmp/konflux-sandbox-runtime}
mkdir -p "$scratch"
if ! kind get clusters | grep -qx "$cluster"; then
  kind create cluster --name "$cluster" --image kindest/node:v1.37.0 --kubeconfig "$scratch/vm-kubeconfig" --wait 120s
fi
kind export kubeconfig --name "$cluster" --kubeconfig "$scratch/vm-kubeconfig"
source ./context.sh
require_runtime_context "$scratch/vm-kubeconfig" kind-konflux-sandbox-vm-prototype
docker exec "$node" test -c /dev/kvm
docker exec "$node" test -c /dev/vhost-vsock
archive=$scratch/kata-static-4.2.0-amd64.tar.zst
if [[ ! -f $archive ]]; then
  curl -fL --retry 2 https://github.com/kata-containers/kata-containers/releases/download/4.2.0/kata-static-4.2.0-amd64.tar.zst -o "$archive"
fi
printf '%s  %s\n' b828904fa3f1e49ddd7dc799c72cb1503cd1e772d354c3987c8d4189b2a623a8 "$archive" | sha256sum --check
if ! docker exec "$node" test -f /opt/kata/VERSION; then
  zstd -dc "$archive" | docker exec -i "$node" tar -xf - -C /
fi
docker exec -i "$node" bash <<'NODE'
set -euo pipefail
mount -o remount,size=2G /dev/shm
if ! command -v dbus-daemon >/dev/null; then
  apt-get update -qq
  apt-get install -y --no-install-recommends dbus
fi
systemctl start dbus
ln -sf /opt/kata/runtime-rs/bin/containerd-shim-kata-v2 /usr/local/bin/containerd-shim-kata-v2
if ! grep -q 'runtimes.kata-prototype' /etc/containerd/config.toml; then
cat >> /etc/containerd/config.toml <<'CONFIG'

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata-prototype]
  runtime_type = "io.containerd.kata.v2"
  privileged_without_host_devices = true
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata-prototype.options]
    ConfigPath = "/opt/kata/share/defaults/kata-containers/runtime-rs/configuration-qemu-runtime-rs.toml"
CONFIG
systemctl restart containerd
fi
NODE
runtime_k wait node "$node" --for=condition=Ready --timeout=120s
cat <<'EOF' | runtime_k apply -f -
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata-prototype
handler: kata-prototype
EOF
echo "Private kubeconfig: $scratch/vm-kubeconfig"
