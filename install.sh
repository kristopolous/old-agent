#!/bin/sh
# oldagent bootstrapper in one file: no tar, gzip, git, sha1, or release assets.
#
#   curl -fsSL <url>/install.sh | sh
#   curl -fsSL <url>/install.sh | sh -s -- --ref v0.1.13
#   curl -fsSL <url>/install.sh | sh -s -- --url http://host/old-agent-as-single-file
#
# It fetches the one-file perl agent (oa1) and installs it as oa1, with oa
# as an alias. The fetched file can also be run directly:
#   curl -fsSL "$URL" | perl

set -eu

DEST="${OLDAGENT_HOME:-$HOME/.oldagent}"
BIN="${OLDAGENT_BIN:-$HOME/.local/bin}"
REPO="${OLDAGENT_REPO:-kristopolous/old-agent}"
REF="${OLDAGENT_REF:-main}"
URL="${OLDAGENT_URL:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --ref|--version) REF="${2:?need ref}"; shift 2 ;;
        --url) URL="${2:?need url}"; shift 2 ;;
        --home) DEST="${2:?need dir}"; shift 2 ;;
        --bin) BIN="${2:?need dir}"; shift 2 ;;
        *) echo "oldagent: unknown argument $1" >&2; exit 2 ;;
    esac
done

[ -n "$URL" ] || URL="https://raw.githubusercontent.com/$REPO/$REF/oa1"

tmp="${TMPDIR:-/tmp}/oa1-fetch-$$"
trap 'rm -f "$tmp"' EXIT INT TERM

if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$URL" -o "$tmp" || { echo "oldagent: fetch failed: $URL" >&2; exit 1; }
elif command -v wget >/dev/null 2>&1; then
    wget -q "$URL" -O "$tmp" || { echo "oldagent: fetch failed: $URL" >&2; exit 1; }
else
    echo "oldagent: need curl or wget to fetch $URL" >&2
    exit 1
fi

[ -s "$tmp" ] || { echo "oldagent: empty download from $URL" >&2; exit 1; }

mkdir -p "$DEST" "$BIN"
cp "$tmp" "$DEST/oa1"
chmod +x "$DEST/oa1"

for tool in oa oa1; do
    cat > "$BIN/$tool" <<EOF
#!/bin/sh
exec perl "$DEST/oa1" "\$@"
EOF
    chmod +x "$BIN/$tool"
done

echo "oldagent: installed $DEST/oa1" >&2
echo "oldagent: try:   oa1 --help" >&2
echo "oldagent: try:   curl -fsSL $URL | perl --version" >&2
if ! printf '%s' "$PATH" | tr ':' '\n' | grep -qx "$BIN"; then
    echo "oldagent: note: add $BIN to your PATH" >&2
fi
