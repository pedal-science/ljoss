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
  "$root"/RigDesigner/Store/RigJSON.swift
  "$root"/RigDesigner/Store/ZipArchive.swift
  "$root"/RigDesigner/Store/RigExport.swift
  "$root"/RigDesigner/Store/RigSelection.swift
  "$root"/RigDesigner/Catalogue/Catalogue.swift
  "$root"/RigDesigner/Catalogue/CatalogueData.swift
  "$root"/RigDesigner/Engine/EngineDocument.swift
  "$root"/RigDesigner/Engine/BlockMapping.swift
  "$root"/RigDesigner/Engine/DocumentEncoder.swift
  "$root"/RigDesigner/Engine/EngineProtocol.swift
  "$root"/RigDesigner/Engine/EngineFraming.swift
  "$root"/RigDesigner/Engine/EngineEdits.swift
  "$root"/RigDesigner/Engine/EngineSettings.swift
  "$root"/RigDesigner/App/SavePanel.swift
  "$root"/RigDesigner/App/ExportController.swift
  "$root"/RigDesigner/Engine/LocalEnginePlan.swift
  "$root"/RigDesigner/Assets/AssetEntry.swift
  "$root"/RigDesigner/Assets/NAMSniff.swift
  "$root"/RigDesigner/Assets/MakeHeuristics.swift
  "$root"/RigDesigner/Assets/AssetScan.swift
  "$root"/RigDesigner/Assets/AssetOrder.swift
  "$root"/Tests/ModelTests.swift
  "$root"/Tests/FlowTests.swift
  "$root"/Tests/EncoderTests.swift
  "$root"/Tests/WireTests.swift
  "$root"/Tests/EditTests.swift
  "$root"/Tests/AssetTests.swift
  "$root"/Tests/LocalEngineTests.swift
  "$root"/Tests/ExportTests.swift
  "$root"/Tests/main.swift
)

# `-plugin-path`, spelled out, is what lets this compile outside an Xcode build at all.
# The macro behind `@Observable` is an external macro, and a frontend that has not been
# told where its plugin lives shells out to `swift-plugin-server`; where that server is
# unavailable the compiler reports "could not be found for macro 'Observable()'", which
# reads like a bad source file and is not. Resolved from the active toolchain so a
# different Xcode needs no edit here.
toolchain="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain"
plugins="$toolchain/usr/lib/swift/host/plugins"
extra=()
if [[ -d "$plugins" ]]; then extra=(-plugin-path "$plugins"); fi

swiftc -swift-version 6 "${extra[@]}" -o "$out/model-tests" "${sources[@]}"
"$out/model-tests"
