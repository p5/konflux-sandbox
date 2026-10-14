SHELL := /usr/bin/env bash
KUBECONFIG ?= /tmp/konflux-sandbox-runtime/vm-kubeconfig
KUBE_CONTEXT ?= kind-konflux-sandbox-vm-prototype
DURABLE_NAMESPACE ?= foundation-durable-prototype
export KUBECONFIG KUBE_CONTEXT DURABLE_NAMESPACE
.NOTPARALLEL:

.PHONY: build install controller watchdog run runtime-guardian cleanup
build:
	mkdir -p ../../.prototype-state/durable/bin
	GOMAXPROCS=2 go build -p 2 -o ../../.prototype-state/durable/bin/controller .
install:
	./install.sh
controller: build
	../../.prototype-state/durable/bin/controller --kubeconfig "$(KUBECONFIG)" --context "$(KUBE_CONTEXT)" --namespace "$(DURABLE_NAMESPACE)" --guard "$(CURDIR)/guard.sh"
watchdog: build
	../../.prototype-state/durable/bin/controller --kubeconfig "$(KUBECONFIG)" --context "$(KUBE_CONTEXT)" --namespace "$(DURABLE_NAMESPACE)" --guard "$(CURDIR)/guard.sh" --watchdog
run: build install
	./run.sh
runtime-guardian: build
	./guardian-run.sh
cleanup:
	./guard.sh
	kubectl --kubeconfig "$(KUBECONFIG)" --context "$(KUBE_CONTEXT)" get namespace "$(DURABLE_NAMESPACE)" -o json | jq -e '.metadata.labels["foundation.sandbox.p5.dev/owner"]=="durable"' >/dev/null
	kubectl --kubeconfig "$(KUBECONFIG)" --context "$(KUBE_CONTEXT)" delete namespace "$(DURABLE_NAMESPACE)" --wait=false
