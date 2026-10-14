SHELL := /usr/bin/env bash
KUBECONFIG ?= /tmp/konflux-sandbox-prototype-qw2Tu2/kubeconfig
KUBE_CONTEXT ?= kind-konflux-sandbox-prototype
REGISTRY ?= 172.18.0.5:5000
export KUBECONFIG KUBE_CONTEXT REGISTRY

.PHONY: run registry-proxy registry-port-bug integration restore-on-interrupt release cleanup
run:
	$(MAKE) registry-port-bug
	$(MAKE) integration
	$(MAKE) restore-on-interrupt
	$(MAKE) release
registry-proxy:
	./registry-proxy.sh
registry-port-bug:
	./run.sh port-bug
integration: registry-proxy
	./run.sh integration
release:
	./run.sh release
restore-on-interrupt:
	./interrupt.sh
cleanup:
	./run.sh cleanup
