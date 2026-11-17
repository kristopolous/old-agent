#!/bin/sh
# Build the single-file artifact that a web host can serve, and that runs as
#   curl <url> | perl
#
# oa1 is already one self-contained perl file, so this just names and checks
# it: no bundling, no tar, no gzip.
set -eu
src="${1:-oa1}"
out="${2:-old-agent-as-single-file}"

[ -f "$src" ] || { echo "make-onefile: no $src" >&2; exit 1; }
cp "$src" "$out"
chmod +x "$out"
echo "$out"
