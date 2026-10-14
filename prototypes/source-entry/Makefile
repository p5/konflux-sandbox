SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
KUBECONFIG ?= /tmp/konflux-sandbox-prototype-qw2Tu2/kubeconfig
KUBE_CONTEXT ?= kind-konflux-sandbox-prototype
.PHONY: run build-service pac cluster
run: cluster
build-service:
	@mkdir -p ../../.prototype-results/source-entry
	@go -C build-service run -mod=mod . | tee ../../.prototype-results/source-entry/build-service.jsonl
pac: build-service
	@bash ./pac.sh
cluster: pac
	@KUBECONFIG="$(KUBECONFIG)" KUBE_CONTEXT="$(KUBE_CONTEXT)" bash ./cluster.sh
