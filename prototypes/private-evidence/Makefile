SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.NOTPARALLEL:
.PHONY: run build
build:
	@mkdir -p ../../.prototype-state/private-evidence
	@go build -o ../../.prototype-state/private-evidence/evidence ./cmd
run: build
	@mkdir -p ../../.prototype-results/private-evidence
	@../../.prototype-state/private-evidence/evidence -state ../../.prototype-state/private-evidence | tee ../../.prototype-results/private-evidence/summary.json
