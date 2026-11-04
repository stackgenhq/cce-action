#!/usr/bin/env bash
# Resolves the latest cce release from stackgenhq/homebrew-stackgen/cce.rb,
# downloads the linux amd64 tarball, verifies sha256, and puts cce on PATH.
# Exists so callers do not re-implement formula parsing in every workflow.
set -euo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "::error::stackgenhq/cce-action currently supports Linux runners only (got $(uname -s))"
  exit 1
fi

arch="$(uname -m)"
case "$arch" in
  x86_64|amd64) ;;
  *)
    echo "::error::stackgenhq/cce-action currently supports linux amd64 only (got $arch)"
    exit 1
    ;;
esac

if ! command -v gh >/dev/null 2>&1; then
  echo "::error::gh CLI is required to read the Homebrew formula"
  exit 1
fi

formula="$(gh api repos/stackgenhq/homebrew-stackgen/contents/cce.rb --jq .content | base64 -d)"

version=$(printf '%s\n' "$formula" | grep -m1 -E '^\s*version "' | sed -E 's/.*version "([^"]+)".*/\1/')
if [[ -z "$version" ]]; then
  echo "::error::could not parse cce version from the Homebrew formula"
  exit 1
fi

# cce.rb is GoReleaser-generated: top-level version, then on_macos/on_linux with
# intel-64-bit and arm-64-bit sub-blocks carrying url + sha256.
linux_block=$(printf '%s\n' "$formula" | awk '/on_linux do/{flag=1} flag{print} flag && /^  end$/{exit}')
url=$(printf '%s\n' "$linux_block" | awk '/Hardware::CPU\.intel\? && Hardware::CPU\.is_64_bit\?/{found=1; next} found && /url "/{print; exit}' | sed -E 's/.*url "([^"]+)".*/\1/')
sha256=$(printf '%s\n' "$linux_block" | awk '/Hardware::CPU\.intel\? && Hardware::CPU\.is_64_bit\?/{found=1; next} found && /sha256 "/{print; exit}' | sed -E 's/.*sha256 "([^"]+)".*/\1/')
if [[ -z "$url" || -z "$sha256" ]]; then
  echo "::error::could not parse the linux amd64 url/sha256 from the Homebrew formula"
  exit 1
fi

echo "Installing cce $version from $url"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
curl -fsSL -o "$tmpdir/cce.tar.gz" "$url"
echo "${sha256}  $tmpdir/cce.tar.gz" | sha256sum -c -
mkdir -p "$HOME/.local/bin"
tar xzf "$tmpdir/cce.tar.gz" -C "$HOME/.local/bin" cce
chmod +x "$HOME/.local/bin/cce"
echo "$HOME/.local/bin" >> "$GITHUB_PATH"
export PATH="$HOME/.local/bin:$PATH"

cce --version

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "version=$version"
    echo "url=$url"
  } >> "$GITHUB_OUTPUT"
fi
