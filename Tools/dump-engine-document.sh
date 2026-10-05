#!/usr/bin/env bash
# Print the engine document for a named test rig, or a rig the app saved (--file), as the app
# would send it.
#
# Same source list as Tests/run-model-tests.sh: none of it needs SwiftUI, so this needs
# nothing from Xcode beyond a toolchain. See Tools/DumpDocument.swift for why it exists.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${TMPDIR:-/tmp}/rigdesigner-dump-document"

sources=(
  "$root"/Ljoss/Model/*.swift
  "$root"/Ljoss/Store/RigFactory.swift
  "$root"/Ljoss/Catalogue/Catalogue.swift
  "$root"/Ljoss/Catalogue/CatalogueData.swift
  "$root"/Ljoss/Engine/EngineDocument.swift
  "$root"/Ljoss/Engine/BlockMapping.swift
  "$root"/Ljoss/Engine/DocumentEncoder.swift
  "$root"/Tools/TestRigs.swift
  "$root"/Tools/DumpDocument.swift
)

# Rebuilt only when a source is newer than the binary: this gets called in a loop by
# namchain's test scripts, and a four-second compile each time is four seconds each time.
needs_build=1
if [[ -x "$out" ]]; then
  needs_build=0
  for source in "${sources[@]}"; do
    [[ "$source" -nt "$out" ]] && { needs_build=1; break; }
  done
fi
(( needs_build )) && swiftc -swift-version 6 -O -o "$out" "${sources[@]}"

"$out" "$@"
