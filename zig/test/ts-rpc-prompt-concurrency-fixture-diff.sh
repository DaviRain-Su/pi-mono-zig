#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

actual="$(mktemp "${TMPDIR:-/tmp}/pi-ts-rpc-prompt-concurrency.XXXXXX")"
trap 'rm -f "$actual"' EXIT

PI_TS_RPC_FIXTURE=prompt-concurrency-queue-order \
	./zig-out/bin/pi --mode ts-rpc --provider faux --no-session \
	< test/golden/ts-rpc/prompt-concurrency-queue-order.input.jsonl \
	> "$actual"

diff -u test/golden/ts-rpc/prompt-concurrency-queue-order.jsonl "$actual"
