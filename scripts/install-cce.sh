#!/usr/bin/env bash
# Puts cce on PATH by copying it out of ghcr.io/stackgenhq/cce (or a caller-
# supplied image). Skips the pull when cce is already available, e.g. when the
# job itself runs inside the CCE container.
set -euo pipefail

image="${INPUT_IMAGE:-ghcr.io/stackgenhq/cce:0.0.38}"

if command -v cce >/dev/null 2>&1; then
  version="$(cce --version 2>/dev/null | head -1 || true)"
  echo "Using existing cce on PATH: ${version:-unknown}"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "version=${version%% *}"
      echo "image=preinstalled"
    } >> "$GITHUB_OUTPUT"
  fi
  exit 0
fi

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "::error::stackgenhq/cce-action currently supports Linux runners only (got $(uname -s))"
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "::error::docker is required to install cce from ${image}"
  exit 1
fi

echo "Pulling ${image}"
docker pull "$image"

cid="$(docker create --entrypoint /usr/local/bin/cce "$image")"
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT

mkdir -p "$HOME/.local/bin"
docker cp "$cid:/usr/local/bin/cce" "$HOME/.local/bin/cce"
chmod +x "$HOME/.local/bin/cce"
echo "$HOME/.local/bin" >> "$GITHUB_PATH"
export PATH="$HOME/.local/bin:$PATH"

version_line="$(cce --version)"
echo "$version_line"
# "0.0.12 (2026-11-04T16:58:57Z)" -> 0.0.12
version="${version_line%% *}"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "version=$version"
    echo "image=$image"
  } >> "$GITHUB_OUTPUT"
fi
