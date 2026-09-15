#!/bin/sh
# Compiles FillerChain with its simulated-menu-bar tests and runs them.
# No Xcode test target is needed; only swiftc.
set -e
cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/hiddenbar-filler-chain-tests"
swiftc -O -o "$out" hidden/Features/StatusBar/FillerChain.swift tests/FillerChainTests/main.swift
"$out"
