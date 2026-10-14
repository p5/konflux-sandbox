SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.PHONY: run source transport policy receipts import-verify cleanup
run: source transport policy receipts import-verify
source:
	@mkdir -p ../../.prototype-state/artifacts ../../.prototype-results/artifacts
	@go run . ../../.prototype-state/artifacts | tee ../../.prototype-results/artifacts/source.json
transport: source
	@bash ./transport.sh
policy:
	@bash ./policy.sh
receipts:
	@mkdir -p ../../.prototype-state/artifacts ../../.prototype-results/artifacts
	@go run . receipts ../../.prototype-state/artifacts | tee ../../.prototype-results/artifacts/receipts.json
import-verify: source
	@mkdir -p ../../.prototype-state/artifacts/bin
	@CGO_ENABLED=0 go build -o ../../.prototype-state/artifacts/bin/source-helper .
	@state=$$(mktemp -d ../../.prototype-state/artifacts/import-cli.XXXXXX); \
	 digest="sha256:$$(sha256sum ../../.prototype-state/artifacts/manifest.json | cut -d' ' -f1)"; \
	 ../../.prototype-state/artifacts/bin/source-helper import-verify ../../.prototype-state/artifacts/source.tar ../../.prototype-state/artifacts/manifest.json "$$state/valid" "$$digest" | tee ../../.prototype-results/artifacts/import-cli.log; \
	 if ../../.prototype-state/artifacts/bin/source-helper import-verify ../../.prototype-state/artifacts/source.tar ../../.prototype-state/artifacts/manifest.json "$$state/invalid" sha256:wrong > ../../.prototype-results/artifacts/import-cli-negative.log 2>&1; then exit 1; fi; \
	 test ! -e "$$state/invalid"
cleanup:
	@docker rm -fv konflux-sandbox-artifact-registry
