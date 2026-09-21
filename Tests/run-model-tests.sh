#!/usr/bin/env bash
# Compile and run the model-layer and flow-geometry assertions.
#
# None of these sources depend on SwiftUI, so this needs nothing from Xcode beyond a
# toolchain: no test host, no scheme, a few seconds.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

sources=(
  "$root"/RigDesigner/Model/*.swift
  "$root"/RigDesigner/DragEngine/RenderSlotMapping.swift
  "$root"/RigDesigner/DragEngine/FlowGeometry.swift
  "$root"/RigDesigner/Store/RigFactory.swift
  "$root"/RigDesigner/Catalogue/Catalogue.swift
  "$root"/RigDesigner/Catalogue/CatalogueData.swift
  "$root"/RigDesigner/Engine/EngineDocument.swift
  "$root"/RigDesigner/Engine/BlockMapping.swift
  "$root"/RigDesigner/Engine/DocumentEncoder.swift
  "$root"/RigDesigner/Engine/EngineProtocol.swift
  "$root"/RigDesigner/Engine/EngineFraming.swift
  "$root"/RigDesigner/Assets/AssetEntry.swift
  "$root"/RigDesigner/Assets/NAMSniff.swift
  "$root"/RigDesigner/Assets/MakeHeuristics.swift
  "$root"/RigDesigner/Assets/AssetScan.swift
  "$root"/RigDesigner/Assets/AssetOrder.swift
  "$root"/Tests/ModelTests.swift
  "$root"/Tests/FlowTests.swift
  "$root"/Tests/EncoderTests.swift
  "$root"/Tests/WireTests.swift
  "$root"/Tests/AssetTests.swift
  "$root"/Tests/main.swift
)

swiftc -swift-version 6 -o "$out/model-tests" "${sources[@]}"
"$out/model-tests"
