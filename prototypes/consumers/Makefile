SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.NOTPARALLEL:
export GOFLAGS := -p=2
export GOMAXPROCS := 2
.PHONY: build run recovery cleanup
build:
	mkdir -p .build
	CGO_ENABLED=0 go build -o .build/foundation ./cmd/foundation
	CGO_ENABLED=0 go build -o .build/client ./cmd/client
	CGO_ENABLED=0 go build -o .build/finite-client ./cmd/finite-client
	CGO_ENABLED=0 go build -o .build/session-client ./cmd/session-client
	CGO_ENABLED=0 go build -o .build/statewrite ./cmd/statewrite
	CGO_ENABLED=0 go build -o .build/marker ./cmd/marker
	CGO_ENABLED=0 go build -C ../identity -o $(CURDIR)/.build/identity .
	CGO_ENABLED=0 go build -C ../artifacts -o $(CURDIR)/.build/source-helper .
	cp ../../.prototype-state/firewall/bin/firewall .build/firewall
	docker build -t konflux-sandbox-consumers:prototype -f Dockerfile .build
run: build
	REQUIRED_RUNTIME_CONTEXT=kind-konflux-sandbox-vm-prototype bash ../runtime/kctl.sh /tmp/konflux-sandbox-runtime/vm-kubeconfig get node konflux-sandbox-vm-prototype-control-plane
	kind load docker-image konflux-sandbox-consumers:prototype --name konflux-sandbox-vm-prototype
	bash run.sh
recovery: build
	REQUIRED_RUNTIME_CONTEXT=kind-konflux-sandbox-vm-prototype bash ../runtime/kctl.sh /tmp/konflux-sandbox-runtime/vm-kubeconfig get node konflux-sandbox-vm-prototype-control-plane
	kind load docker-image konflux-sandbox-consumers:prototype --name konflux-sandbox-vm-prototype
	CONSUMER_RECOVERY=1 bash run.sh
cleanup:
	bash cleanup.sh
