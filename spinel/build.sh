#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo 'Usage: spinel/build.sh APP.rb OUTPUT' >&2
  exit 2
fi

command -v spinel >/dev/null || { echo 'Spinel compiler not found on PATH' >&2; exit 1; }

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
native_dir="$root/tmp/spinel"
mkdir -p "$native_dir"

cc -c "$root/spinel/puma_parser.c" -o "$native_dir/puma_parser.o"
spinel -I "$root/lib" --link "$native_dir/puma_parser.o" "$1" -o "$2"
