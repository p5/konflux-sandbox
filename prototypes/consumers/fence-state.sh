#!/usr/bin/env bash
set -euo pipefail
record=$1
chain=$(jq -r .chain "$record")
incoming=$(jq -r .incomingChain "$record")
for family in iptables ip6tables;do
 docker exec konflux-sandbox-vm-prototype-control-plane "$family" -S "$chain"
 docker exec konflux-sandbox-vm-prototype-control-plane "$family" -S "$incoming"
done
