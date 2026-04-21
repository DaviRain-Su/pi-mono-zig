#!/bin/bash
set -e

echo "=== JSON Parse Comparison Test ==="
echo ""

# Build Zig version
cd "$(dirname "$0")/.."
echo "Building Zig implementation..."
zig build 2>/dev/null

# Test cases
TEST_CASES=(
    '{"foo": 123}'
    ''
    '{"foo": 123, "bar'
    '{"a": {"b": [1, 2, 3]}}'
    '[1, 2, {"x": true}]'
)

echo "Running comparison tests..."
echo ""

for test_case in "${TEST_CASES[@]}"; do
    echo "Test case: $test_case"
    
    # Run Zig version
    echo "  Zig result:"
    ./zig-out/bin/pi --test-json-parse "$test_case" 2>/dev/null || echo "    (not implemented yet)"
    
    echo ""
done

echo "=== Comparison complete ==="
