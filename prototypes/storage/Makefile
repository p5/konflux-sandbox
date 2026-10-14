SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.NOTPARALLEL:
.PHONY: build run
build:
	REQUIRED_RUNTIME_CONTEXT=kind-konflux-sandbox-vm-prototype bash ../runtime/kctl.sh /tmp/konflux-sandbox-runtime/vm-kubeconfig get node konflux-sandbox-vm-prototype-control-plane
	mkdir -p ../../.prototype-state/storage/bin
	CGO_ENABLED=0 go -C .. build -o $(CURDIR)/../../.prototype-state/storage/bin/storage-filter ./storage
	docker build -t konflux-sandbox-storage:prototype -f Dockerfile ../../.prototype-state/storage/bin
	kind load docker-image konflux-sandbox-storage:prototype --name konflux-sandbox-vm-prototype
run: build
	bash run.sh
