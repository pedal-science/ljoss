#!/usr/bin/env bash
# Compile and run the model-layer and flow-geometry assertions.
#
# None of these sources depend on SwiftUI, so this needs nothing from Xcode beyond a
# toolchain and its macro plugins: no test host, no scheme, a few seconds.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

sources=(
  "$root"/Ljoss/Model/*.swift
  "$root"/Ljoss/DragEngine/RenderSlotMapping.swift
  "$root"/Ljoss/DragEngine/FlowGeometry.swift
  "$root"/Ljoss/Store/AppDirectories.swift
  "$root"/Ljoss/Store/RigFactory.swift
  "$root"/Ljoss/Store/RigJSON.swift
  "$root"/Ljoss/Store/ZipArchive.swift
  "$root"/Ljoss/Store/RigExport.swift
  "$root"/Ljoss/Store/RigSelection.swift
  "$root"/Ljoss/Catalogue/Catalogue.swift
  "$root"/Ljoss/Catalogue/CatalogueData.swift
  "$root"/Ljoss/Engine/EngineDocument.swift
  "$root"/Ljoss/Engine/BlockMapping.swift
  "$root"/Ljoss/Engine/DocumentEncoder.swift
  "$root"/Ljoss/Engine/EngineProtocol.swift
  "$root"/Ljoss/Engine/EngineCost.swift
  "$root"/Ljoss/Engine/EngineFraming.swift
  "$root"/Ljoss/Engine/EngineEdits.swift
  "$root"/Ljoss/Engine/EngineSettings.swift
  "$root"/Ljoss/Views/LevelMeters.swift
  "$root"/Ljoss/App/SavePanel.swift
  "$root"/Ljoss/App/ExportController.swift
  "$root"/Ljoss/Engine/LocalEnginePlan.swift
  "$root"/Ljoss/Assets/AssetEntry.swift
  "$root"/Ljoss/Assets/NAMSniff.swift
  "$root"/Ljoss/Assets/MakeHeuristics.swift
  "$root"/Ljoss/Assets/AssetScan.swift
  "$root"/Ljoss/Assets/AssetOrder.swift
  "$root"/Ljoss/Assets/AssetSync.swift
  "$root"/Ljoss/Assets/AssetStore.swift
  "$root"/Tests/ModelTests.swift
  "$root"/Tests/FlowTests.swift
  "$root"/Tests/EncoderTests.swift
  "$root"/Tests/WireTests.swift
  "$root"/Tests/CostTests.swift
  "$root"/Tests/EditTests.swift
  "$root"/Tests/AssetTests.swift
  "$root"/Tests/AssetStoreTests.swift
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
#
# Two directories, because the plugins are not all in one place: `@Model`, which the asset
# store uses, comes from the platform's own set, beside the frameworks it belongs to
# (libSwiftDataMacros.dylib). Miss it and the failure has the same shape as the one above,
# for 'Model()'.
toolchain="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain"
plugins="$toolchain/usr/lib/swift/host/plugins"
platform_plugins="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"
extra=()
if [[ -d "$plugins" ]]; then extra+=(-plugin-path "$plugins"); fi
if [[ -d "$platform_plugins" ]]; then extra+=(-plugin-path "$platform_plugins"); fi

swiftc -swift-version 6 "${extra[@]}" -o "$out/model-tests" "${sources[@]}"
"$out/model-tests"
