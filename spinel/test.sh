#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/tmp/spinel"
mkdir -p "$out"

"$root/spinel/build.sh" "$root/spinel/parser_smoke.rb" "$out/parser_smoke"
"$out/parser_smoke"

"$root/spinel/build.sh" "$root/spinel/selector_smoke.rb" "$out/selector_smoke"
"$out/selector_smoke"

"$root/spinel/build.sh" "$root/spinel/server_smoke.rb" "$out/server_smoke"
ruby "$root/spinel/server_test.rb" "$out/server_smoke"

"$root/spinel/build.sh" "$root/spinel/single_smoke.rb" "$out/single_smoke"
ruby "$root/spinel/server_test.rb" "$out/single_smoke"
