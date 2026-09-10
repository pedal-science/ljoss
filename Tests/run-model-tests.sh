#!/usr/bin/env bash
# Compile and run the model-layer assertions.
#
# Model/ has no SwiftUI dependency, so this needs nothing from Xcode beyond a
# toolchain: no test host, no scheme, a few seconds.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

sources=(
  "$root"/RigDesigner/Model/*.swift
  "$root"/RigDesigner/DragEngine/RenderSlotMapping.swift
  "$root"/RigDesigner/Store/RigFactory.swift
  "$root"/Tests/ModelTests.swift
  "$root"/Tests/main.swift
)

swiftc -swift-version 6 -o "$out/model-tests" "${sources[@]}"
"$out/model-tests"
