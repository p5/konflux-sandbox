SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.NOTPARALLEL:
.PHONY: run build guard failure-paths
KUBECONFIG ?= /tmp/konflux-sandbox-runtime/vm-kubeconfig
run: build
	KUBECONFIG="$(KUBECONFIG)" bash run.sh
	KUBECONFIG="$(KUBECONFIG)" bash failures.sh
failure-paths: build
	KUBECONFIG="$(KUBECONFIG)" bash failures.sh
guard:
	REQUIRED_RUNTIME_CONTEXT=kind-konflux-sandbox-vm-prototype bash ../runtime/kctl.sh "$(KUBECONFIG)" get node konflux-sandbox-vm-prototype-control-plane
build: guard
	mkdir -p ../../.prototype-state/firewall/bin
	CGO_ENABLED=0 go build -o ../../.prototype-state/firewall/bin/firewall .
	docker build -f Dockerfile -t konflux-sandbox-firewall:prototype ../../.prototype-state/firewall/bin
	kind load docker-image konflux-sandbox-firewall:prototype --name konflux-sandbox-vm-prototype
