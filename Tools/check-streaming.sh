#!/usr/bin/env bash
# Turn knobs on a real namchaind through the app's own EngineSession, and say whether the
# engine ramped them or rebuilt. See Tools/CheckStreaming.swift.
#
# usage: check-streaming.sh [HOST [PORT [TOKEN-FILE]]]
#
# TOKEN-FILE may be a pipe, so a token never touches the disk:
#   check-streaming.sh vip 47810 <(ssh vip sudo -n cat /etc/namchain/token)
#
# Any daemon will do. On a Mac, namchain's tools/macos/run-namchaind.sh is one (it needs
# listen.sh running, and you will hear the test); a daemon on `--backend null` is a paced
# clock with nothing to listen to.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${TMPDIR:-/tmp}/rigdesigner-check-streaming"

host="${1:-127.0.0.1}"
port="${2:-47810}"
token_file="${3:-/tmp/nc/token}"

# -r, not -s: a pipe such as <(ssh host cat token) has no size.
[[ -r "$token_file" ]] || { echo "no token at $token_file" >&2; exit 2; }

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
  "$root"/RigDesigner/Engine/EngineEdits.swift
  "$root"/RigDesigner/Engine/EngineClient.swift
  "$root"/RigDesigner/Engine/EngineSettings.swift
  "$root"/RigDesigner/Engine/EngineSession.swift
  "$root"/Tools/TestRigs.swift
  "$root"/Tools/CheckStreaming.swift
)

needs_build=1
if [[ -x "$out" ]]; then
  needs_build=0
  for source in "${sources[@]}"; do
    [[ "$source" -nt "$out" ]] && { needs_build=1; break; }
  done
fi
(( needs_build )) && swiftc -swift-version 6 -O -o "$out" "${sources[@]}"

# The token file's path, not its contents: an argument is visible to every process in `ps`.
"$out" "$host" "$port" "$token_file"
