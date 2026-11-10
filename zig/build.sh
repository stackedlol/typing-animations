#!/bin/sh
# Builds the editor to ../pastel.wasm. Needs Zig 0.17 (brew install zig).
set -e
cd "$(dirname "$0")"
zig build-exe src/main.zig -target wasm32-freestanding -fno-entry -rdynamic -O ReleaseFast -fstrip -femit-bin=../pastel.wasm
echo "built ../pastel.wasm ($(wc -c < ../pastel.wasm | tr -d ' ') bytes)"
