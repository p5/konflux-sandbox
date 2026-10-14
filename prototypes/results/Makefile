SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
KUBECONFIG ?= /tmp/konflux-sandbox-prototype-qw2Tu2/kubeconfig
KUBE_CONTEXT ?= kind-konflux-sandbox-prototype
.NOTPARALLEL:
.PHONY: run
run:
	@KUBECONFIG="$(KUBECONFIG)" KUBE_CONTEXT="$(KUBE_CONTEXT)" bash ./run.sh
