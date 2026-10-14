SHELL := /bin/bash
KUBECONFIG ?= /tmp/konflux-sandbox-prototype-qw2Tu2/kubeconfig
UPSTREAM ?= ../../../agent-sandbox
UPSTREAM_COMMIT ?= 5d7608a9fca5aa1d3a12b73fb51ed2ee0d4e9ab1
CLUSTER ?= konflux-sandbox-prototype
RUNTIME_CLASS ?=
.NOTPARALLEL:

.PHONY: run build install test network claims cleanup vm-install vm-run vm-cleanup tekton-install tekton-test composed guard-test
run: guard-test build install test network claims

build:
	REQUIRED_RUNTIME_CONTEXT=kind-$(CLUSTER) bash kctl.sh $(KUBECONFIG) get node $(CLUSTER)-control-plane
	test "$$(git -C $(UPSTREAM) rev-parse HEAD)" = "$(UPSTREAM_COMMIT)"
	mkdir -p .build
	cd $(UPSTREAM) && CGO_ENABLED=0 go build -o $(CURDIR)/.build/sandboxd ./packages/sandboxd/cmd/sandboxd
	docker build -t konflux-sandbox-runtime:prototype -f Dockerfile .build
	kind load docker-image konflux-sandbox-runtime:prototype --name $(CLUSTER)

install:
	bash kctl.sh $(KUBECONFIG) apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v1.0.6/sandbox-with-extensions.yaml
	bash kctl.sh $(KUBECONFIG) rollout status deployment/agent-sandbox-controller -n agent-sandbox-system --timeout=120s

test:
	KUBECONFIG=$(KUBECONFIG) UPSTREAM=$(UPSTREAM) RUNTIME_CLASS=$(RUNTIME_CLASS) bash lifecycle.sh

network:
	KUBECONFIG=$(KUBECONFIG) RUNTIME_CLASS=$(RUNTIME_CLASS) bash network.sh

claims:
	KUBECONFIG=$(KUBECONFIG) RUNTIME_CLASS=$(RUNTIME_CLASS) bash claims.sh

cleanup:
	bash kctl.sh $(KUBECONFIG) delete namespace sandbox-runtime-prototype --ignore-not-found --wait=true

vm-install:
	bash install-kata.sh

vm-run: vm-install
	$(MAKE) run KUBECONFIG=/tmp/konflux-sandbox-runtime/vm-kubeconfig CLUSTER=konflux-sandbox-vm-prototype RUNTIME_CLASS=kata-prototype

vm-cleanup:
	kind delete cluster --name konflux-sandbox-vm-prototype

tekton-install:
	REQUIRED_RUNTIME_CONTEXT=kind-konflux-sandbox-vm-prototype bash kctl.sh /tmp/konflux-sandbox-runtime/vm-kubeconfig apply -f https://github.com/tektoncd/pipeline/releases/download/v1.15.3/release.yaml
	REQUIRED_RUNTIME_CONTEXT=kind-konflux-sandbox-vm-prototype bash kctl.sh /tmp/konflux-sandbox-runtime/vm-kubeconfig rollout status deployment/tekton-pipelines-controller -n tekton-pipelines --timeout=120s
	REQUIRED_RUNTIME_CONTEXT=kind-konflux-sandbox-vm-prototype bash kctl.sh /tmp/konflux-sandbox-runtime/vm-kubeconfig rollout status deployment/tekton-pipelines-webhook -n tekton-pipelines --timeout=120s

tekton-test:
	KUBECONFIG=/tmp/konflux-sandbox-runtime/vm-kubeconfig bash tekton.sh

composed:
	KUBECONFIG=/tmp/konflux-sandbox-runtime/vm-kubeconfig bash composed.sh

guard-test:
	bash guard-test.sh
