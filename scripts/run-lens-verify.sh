#!/usr/bin/env bash
# Run lens Gate 0 and preserve machine-readable evidence even when CCE exits
# non-zero for a regression.
set -euo pipefail

fixture="${INPUT_FIXTURE:-}"
candidate="${INPUT_CANDIDATE:-}"
current="${INPUT_CURRENT:-}"
candidate_sha256="${INPUT_CANDIDATE_SHA256:-}"
current_sha256="${INPUT_CURRENT_SHA256:-}"
language="${INPUT_LANGUAGE:-AUTO}"
fail_regression="${INPUT_FAIL_REGRESSION:-true}"
output_dir="${INPUT_OUTPUT_DIR:-cce-results/lens-verify}"
workspace="${GITHUB_WORKSPACE:-$PWD}"

if ! command -v cce >/dev/null 2>&1; then
  echo "::error::cce is not on PATH; install-cce.sh must run first"
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "::error::jq is required to parse the lens verdict and write job outputs"
  exit 1
fi
if ! cce lens verify --help >/dev/null 2>&1; then
  echo "::error::cce lens verify is unavailable. Lens Gate 0 requires CCE >= 0.0.38; use ghcr.io/stackgenhq/cce:0.0.38 or newer."
  exit 1
fi
if [[ -z "$fixture" ]]; then
  echo "::error::fixture is required"
  exit 1
fi
if [[ -z "$candidate" ]]; then
  echo "::error::candidate is required"
  exit 1
fi

resolve_local_path() {
  local value="$1"
  if [[ "$value" = /* ]]; then
    printf '%s\n' "$value"
  else
    printf '%s/%s\n' "${workspace%/}" "$value"
  fi
}

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  else
    echo "::error::sha256sum or shasum is required to pin local lens $path"
    return 1
  fi
}

# Resolve local lenses against the checkout, not the composite action directory.
# Remote lenses are intentionally HTTPS-only and must always be content-pinned.
prepare_lens() {
  local label="$1"
  local value="$2"
  local pin="$3"
  local resolved

  if [[ "$value" =~ ^[hH][tT][tT][pP][sS]:// ]]; then
    if [[ -z "$pin" ]]; then
      echo "::error::${label}-sha256 is required for HTTPS remote lens: $value"
      return 1
    fi
    resolved="$value"
  elif [[ "$value" =~ ^[A-Za-z][A-Za-z0-9+.-]*: ]]; then
    echo "::error::unsupported remote scheme for $label lens: $value (use a local path or pinned HTTPS URL)"
    return 1
  else
    resolved="$(resolve_local_path "$value")"
    if [[ ! -f "$resolved" ]]; then
      echo "::error::$label lens does not exist: $resolved"
      return 1
    fi
    if [[ -z "$pin" ]]; then
      pin="$(sha256_file "$resolved")"
    fi
  fi

  RESOLVED_LENS="$resolved"
  RESOLVED_SHA256="$pin"
}

fixture="$(resolve_local_path "$fixture")"
if [[ ! -d "$fixture" ]]; then
  echo "::error::fixture directory does not exist: $fixture"
  exit 1
fi

prepare_lens candidate "$candidate" "$candidate_sha256"
candidate="$RESOLVED_LENS"
candidate_sha256="$RESOLVED_SHA256"
if [[ -n "$current" ]]; then
  prepare_lens current "$current" "$current_sha256"
  current="$RESOLVED_LENS"
  current_sha256="$RESOLVED_SHA256"
fi

mkdir -p "$output_dir"
verdict_path="${output_dir%/}/verdict.json"
rm -f "$verdict_path"

args=(
  lens verify
  --fixture "$fixture"
  --candidate "$candidate"
  --candidate-sha256 "$candidate_sha256"
  --language "$language"
  --fail-regression="$fail_regression"
  --output "$verdict_path"
)
if [[ -n "$current" ]]; then
  args+=(--current "$current" --current-sha256 "$current_sha256")
fi

verify_status=0
if cce "${args[@]}"; then
  verify_status=0
else
  verify_status=$?
fi

# A regression is a normal Gate 0 result, not a reason to discard its evidence.
# Parse and publish first; restore CCE's status only after outputs are durable.
if [[ ! -f "$verdict_path" ]]; then
  echo "::error::cce lens verify produced no verdict JSON at $verdict_path (exit $verify_status)"
  [[ "$verify_status" -ne 0 ]] && exit "$verify_status"
  exit 1
fi
if ! jq -e . "$verdict_path" >/dev/null 2>&1; then
  echo "::error::cce lens verify produced invalid verdict JSON at $verdict_path"
  [[ "$verify_status" -ne 0 ]] && exit "$verify_status"
  exit 1
fi

verdict="$(jq -r '.verdict // "unknown"' "$verdict_path")"
newly_mapped_count="$(jq -r '(.newly_mapped // []) | length' "$verdict_path")"
regressed_count="$(jq -r '(.regressed // []) | length' "$verdict_path")"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "verdict-path=$verdict_path"
    echo "verdict=$verdict"
    echo "newly-mapped-count=$newly_mapped_count"
    echo "regressed-count=$regressed_count"
    echo "candidate-sha256=$candidate_sha256"
  } >> "$GITHUB_OUTPUT"
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## CCE lens Gate 0"
    echo
    echo "- Verdict: **$verdict**"
    echo "- Newly mapped: **$newly_mapped_count**"
    echo "- Regressed: **$regressed_count**"
    echo "- Evidence: \`$verdict_path\`"
    if [[ "$newly_mapped_count" -gt 0 ]]; then
      echo
      echo "### Newly mapped (first 20)"
      echo
      echo "| Provider | Resource | Operation | File | Line |"
      echo "| --- | --- | --- | --- | ---: |"
      jq -r '(.newly_mapped // [])[:20][] | "| \(.provider // "") | \(.resource // "") | \(.operation // "") | \(.file // "") | \(.line // 0) |"' "$verdict_path"
    fi
    if [[ "$regressed_count" -gt 0 ]]; then
      echo
      echo "### Regressed (first 20)"
      echo
      echo "| Provider | Resource | Operation | File | Line |"
      echo "| --- | --- | --- | --- | ---: |"
      jq -r '(.regressed // [])[:20][] | "| \(.provider // "") | \(.resource // "") | \(.operation // "") | \(.file // "") | \(.line // 0) |"' "$verdict_path"
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi

echo "Lens verify: verdict=$verdict newly-mapped=$newly_mapped_count regressed=$regressed_count evidence=$verdict_path"
if [[ "$verify_status" -ne 0 ]]; then
  echo "::error::cce lens verify exited $verify_status; verdict outputs and evidence were preserved"
  exit "$verify_status"
fi
