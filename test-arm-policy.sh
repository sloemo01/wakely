#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMP_ROOT="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
TEST_DIR="$(mktemp -d "${TEMP_ROOT}/wakely-arm-policy.XXXXXX")"
cleanup() {
    # Only remove the exact temporary directory created above.
    if [[ -n "$TEST_DIR" && "$TEST_DIR" == "$TEMP_ROOT"/wakely-arm-policy.* && -d "$TEST_DIR" ]]; then
        rm -rf -- "$TEST_DIR"
    fi
}
trap cleanup EXIT

swiftc -module-cache-path "$TEST_DIR/module-cache" \
    "$ROOT/Sources/ArmPolicy.swift" \
    "$ROOT/Tests/ArmPolicyTests.swift" \
    -o "$TEST_DIR/arm-policy-tests"
"$TEST_DIR/arm-policy-tests"
