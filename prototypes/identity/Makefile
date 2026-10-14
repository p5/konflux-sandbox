SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.NOTPARALLEL:
.PHONY: build run cleanup
build:
	REQUIRED_RUNTIME_CONTEXT=kind-konflux-sandbox-vm-prototype bash ../runtime/kctl.sh /tmp/konflux-sandbox-runtime/vm-kubeconfig get node konflux-sandbox-vm-prototype-control-plane
	mkdir -p .build
	CGO_ENABLED=0 go build -o .build/identity .
	docker build -t konflux-sandbox-identity:prototype -f Dockerfile .build
	kind load docker-image konflux-sandbox-identity:prototype --name konflux-sandbox-vm-prototype
run: build
	bash run.sh
cleanup:
	bash ../runtime/kctl.sh /tmp/konflux-sandbox-runtime/vm-kubeconfig delete namespace foundation-identity-prototype --ignore-not-found --wait=true
