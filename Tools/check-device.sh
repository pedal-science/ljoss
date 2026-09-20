#!/usr/bin/env bash
# Talk to a real namchaind with this app's own client. See Tools/CheckDevice.swift.
#
# usage: check-device.sh [HOST [PORT [TOKEN-FILE [RIG]]]]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${TMPDIR:-/tmp}/rigdesigner-check-device"

host="${1:-127.0.0.1}"
port="${2:-47810}"
token_file="${3:-/tmp/nc/token}"
rig="${4:-gain0}"

[[ -s "$token_file" ]] || { echo "no token at $token_file" >&2; exit 2; }

sources=(
  "$root"/RigDesigner/Model/*.swift
  "$root"/RigDesigner/Store/RigFactory.swift
  "$root"/RigDesigner/Catalogue/Catalogue.swift
  "$root"/RigDesigner/Catalogue/CatalogueData.swift
  "$root"/RigDesigner/Engine/EngineDocument.swift
  "$root"/RigDesigner/Engine/BlockMapping.swift
  "$root"/RigDesigner/Engine/DocumentEncoder.swift
  "$root"/RigDesigner/Engine/EngineProtocol.swift
  "$root"/RigDesigner/Engine/EngineFraming.swift
  "$root"/RigDesigner/Engine/EngineClient.swift
  "$root"/Tools/CheckDevice.swift
)

needs_build=1
if [[ -x "$out" ]]; then
  needs_build=0
  for source in "${sources[@]}"; do
    [[ "$source" -nt "$out" ]] && { needs_build=1; break; }
  done
fi
(( needs_build )) && swiftc -swift-version 6 -O -o "$out" "${sources[@]}"

"$out" "$host" "$port" "$(cat "$token_file")" "$rig"
