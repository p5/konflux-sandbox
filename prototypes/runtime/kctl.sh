#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./context.sh
require_runtime_context "$1" "${REQUIRED_RUNTIME_CONTEXT:-}"
shift
runtime_k "$@"
