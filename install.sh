#!/bin/sh
# Installs the trio CLI, then runs `trio apply`.
#   curl -fsSL https://raw.githubusercontent.com/febritecno/trio-cli/main/install.sh | sh
#
# Environment:
#   TRIO_VERSION      release tag to install (default: latest)
#   TRIO_INSTALL_DIR  where to put the binary (default: ~/.local/bin)
#   TRIO_NO_APPLY=1   install only, skip `trio apply`
set -eu

main() {

REPO="febritecno/trio-cli"
DIR="${TRIO_INSTALL_DIR:-$HOME/.local/bin}"

say() { printf '%s\n' "$*"; }
die() { printf 'trio install: %s\n' "$*" >&2; exit 1; }

case "$(uname -s)" in
  Darwin) os=darwin ;;
  Linux) os=linux ;;
  *) die "unsupported OS: $(uname -s) (macOS and Linux only)" ;;
esac
case "$(uname -m)" in
  arm64 | aarch64) arch=arm64 ;;
  x86_64 | amd64) arch=x64 ;;
  *) die "unsupported CPU: $(uname -m)" ;;
esac

asset="trio-$os-$arch.tar.gz"
if [ -n "${TRIO_VERSION:-}" ]; then
  base="https://github.com/$REPO/releases/download/$TRIO_VERSION"
else
  base="https://github.com/$REPO/releases/latest/download"
fi

if command -v curl >/dev/null 2>&1; then
  fetch() { curl -fsSL "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then
  fetch() { wget -qO "$2" "$1"; }
else
  die "curl or wget is required"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

say "Downloading $asset"
fetch "$base/$asset" "$tmp/$asset" || die "download failed: $base/$asset"

if fetch "$base/SHA256SUMS" "$tmp/SHA256SUMS" 2>/dev/null; then
  want=$(grep " $asset\$" "$tmp/SHA256SUMS" | cut -d' ' -f1)
  if command -v sha256sum >/dev/null 2>&1; then got=$(sha256sum "$tmp/$asset" | cut -d' ' -f1)
  elif command -v shasum >/dev/null 2>&1; then got=$(shasum -a 256 "$tmp/$asset" | cut -d' ' -f1)
  else got=$want; say "Warning: no sha256 tool found, checksum not verified"; fi
  [ -n "$want" ] && [ "$want" = "$got" ] || die "checksum mismatch for $asset"
else
  say "Warning: SHA256SUMS not available, checksum not verified"
fi

tar -xzf "$tmp/$asset" -C "$tmp"
mkdir -p "$DIR"
mv "$tmp/trio" "$DIR/trio"
chmod +x "$DIR/trio"
say "Installed $("$DIR/trio" version) to $DIR/trio"

case ":$PATH:" in
  *":$DIR:"*) ;;
  *) say "Note: $DIR is not on your PATH. Add this to your shell profile:"
     say "  export PATH=\"$DIR:\$PATH\"" ;;
esac

if [ -z "${TRIO_NO_APPLY:-}" ]; then
  say ""
  "$DIR/trio" apply
fi
}

main "$@"
