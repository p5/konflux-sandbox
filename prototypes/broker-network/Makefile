SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.NOTPARALLEL:
export GOFLAGS := -p=2
export GOMAXPROCS := 2
KUBECONFIG ?= /tmp/konflux-sandbox-runtime/vm-kubeconfig
.PHONY: build run check capture
build:
	mkdir -p .build
	CGO_ENABLED=0 go build -o .build/broker-network .
	CGO_ENABLED=0 go build -C ../firewall -o $(CURDIR)/.build/firewall .
	docker build -t konflux-sandbox-broker-network:prototype -f Dockerfile .build
run: build
	REQUIRED_RUNTIME_CONTEXT=kind-konflux-sandbox-vm-prototype bash ../runtime/kctl.sh "$(KUBECONFIG)" get node konflux-sandbox-vm-prototype-control-plane
	kind load docker-image konflux-sandbox-broker-network:prototype --name konflux-sandbox-vm-prototype
	KUBECONFIG="$(KUBECONFIG)" bash run.sh
check:
	go vet ./...
	bash -n run.sh
capture:
	uid=$$(jq -r .guestUID evidence/summary.json); for record in .state/run.*/guest-fence.json; do if [[ $$(jq -r .podUID "$$record") == "$$uid" ]]; then jq -e '.removed==true and .runtimeRemovalVerified==true' "$$record" >/dev/null; cp "$$record" evidence/guest-fence.json; broker="$${record%guest-fence.json}broker-fence.json"; jq -e '.removed==true and .runtimeRemovalVerified==true' "$$broker" >/dev/null; cp "$$broker" evidence/broker-fence.json; fi; done
	jq -e --arg uid "$$(jq -r .guestUID evidence/summary.json)" '.runtimeRemovalVerified==true and .podUID==$$uid' evidence/guest-fence.json >/dev/null
	jq -e '.runtimeRemovalVerified==true' evidence/broker-fence.json >/dev/null
	jq '.cleanupVerified=true' evidence/summary.json > evidence/summary.tmp
	mv evidence/summary.tmp evidence/summary.json
