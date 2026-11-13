#!/usr/bin/env bash
# Runs cce against INPUT_PATH and optionally exports provider policies.
# Diagnostics stay off unless CCE_DIAGNOSTICS=true (set from the action input).
set -euo pipefail

path="${INPUT_PATH:-.}"
language="${INPUT_LANGUAGE:-AUTO}"
filter="${INPUT_FILTER:-cloud}"
format="${INPUT_FORMAT:-json}"
output_dir="${INPUT_OUTPUT_DIR:-cce-results}"
export_policies="${INPUT_EXPORT_POLICIES:-true}"
fail_on_empty="${INPUT_FAIL_ON_EMPTY:-false}"
log_level="${INPUT_LOG_LEVEL:-info}"
scan_timeout="${INPUT_SCAN_TIMEOUT:-0}"
lens="${INPUT_LENS:-}"
lens_sha256="${INPUT_LENS_SHA256:-}"
lens_required="${INPUT_LENS_REQUIRED:-false}"

if ! command -v cce >/dev/null 2>&1; then
  echo "::error::cce is not on PATH; install-cce.sh must run first"
  exit 1
fi

if [[ "$path" != /* ]]; then
  path="${GITHUB_WORKSPACE:-$PWD}/$path"
fi
if [[ ! -d "$path" ]]; then
  echo "::error::scan path does not exist: $path"
  exit 1
fi

mkdir -p "$output_dir"
report_path="${output_dir}/scan.${format}"

# One DEBUG line per unmapped call: SDK-heavy repos produced tens of MB of log
# lines in fuzz runs (141k lines / 47MB for one Java monorepo), which can stall
# CI log ingestion. diagnostics=true ships unmapped signatures to the Stackgen
# ingest endpoint instead, without the log flood.
if [[ "$log_level" == "debug" ]]; then
  echo "::warning::log-level=debug streams one DEBUG line per unmapped SDK call; large or SDK-heavy repos can produce tens of MB of logs and may slow CI log ingestion. Prefer diagnostics=true with log-level=info."
fi

if [[ "$lens_required" == "true" && -z "$lens" ]]; then
  echo "::error::lens-required=true requires a lens"
  exit 1
fi
if [[ "$lens_required" == "true" && "$format" != "json" ]]; then
  echo "::error::lens-required=true requires format=json so unique operation growth can be measured"
  exit 1
fi

# A repository-local lens is already pinned by the checkout. Hash its exact
# bytes as provenance and pass that pin to CCE; a remote lens needs a caller-
# supplied expected hash because there is no repository commit protecting it.
lens_args=()
lens_file_sha256=""
if [[ -n "$lens" ]]; then
  if [[ "$lens" =~ ^[Hh][Tt][Tt][Pp][Ss]:// ]]; then
    if [[ -z "$lens_sha256" ]]; then
      echo "::error::lens-sha256 is required for an HTTPS lens so remote content cannot change unnoticed"
      exit 1
    fi
    lens_file_sha256="$lens_sha256"
  elif [[ "$lens" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*:// ]]; then
    echo "::error::lens must be a workspace file or HTTPS URL: $lens"
    exit 1
  else
    if [[ "$lens" != /* ]]; then
      lens="${GITHUB_WORKSPACE:-$PWD}/$lens"
    fi
    if [[ ! -f "$lens" ]]; then
      echo "::error::lens file does not exist: $lens"
      exit 1
    fi
    actual_sha="$(sha256sum "$lens" | awk '{print $1}')"
    if [[ -n "$lens_sha256" && "$lens_sha256" != "$actual_sha" ]]; then
      echo "::error::lens-sha256 mismatch for $lens: expected $lens_sha256, got $actual_sha"
      exit 1
    fi
    lens_sha256="$actual_sha"
    lens_file_sha256="$actual_sha"
  fi
  if ! cce --help 2>&1 | grep -q -- '--mapper-sha256'; then
    echo "::error::Pinned lenses require CCE >= 0.0.38; set image to ghcr.io/stackgenhq/cce:0.0.38 or newer."
    exit 1
  fi
  lens_args=(--mapper-file "$lens" --mapper-sha256 "$lens_sha256")
  if [[ "$filter" == "cloud" ]]; then
    echo "::notice::A lens with custom providers such as TECH_DEBT requires filter=all; filter=cloud keeps cloud providers only."
  fi
fi

echo "Scanning $path (language=$language filter=$filter diagnostics=${CCE_DIAGNOSTICS:-false} lens=${lens:-built-in})"

run_scan() {
  local args=(
    --folder "$path"
    --language "$language"
    --filter "$filter"
    --format "$format"
    --log-level "$log_level"
    --output "$report_path"
    "${lens_args[@]}"
  )
  if [[ "$scan_timeout" != "0" && "$scan_timeout" != "" ]] && command -v timeout >/dev/null 2>&1; then
    # Fail fast on huge repos instead of letting the job burn its whole runner
    # budget and get cancelled by a workflow-level timeout-minutes (observed:
    # a 143k-file Java monorepo scanned for 14 minutes and produced nothing).
    local rc=0
    timeout --signal=INT --kill-after=15s "${scan_timeout}s" cce "${args[@]}" || rc=$?
    if [[ "$rc" -eq 124 ]]; then
      echo "::error::cce scan exceeded scan-timeout=${scan_timeout}s for $path. The repo is likely too large for a single scan; scan subdirectories, raise scan-timeout, or check the repo size first."
      exit 124
    fi
    return "$rc"
  fi
  cce "${args[@]}"
}

run_scan

if [[ ! -f "$report_path" ]]; then
  echo "::error::scan produced no report at $report_path"
  exit 1
fi

entitlement_count=0
if [[ "$format" == "json" ]]; then
  if command -v jq >/dev/null 2>&1; then
    entitlement_count=$(jq -r '.summary.total_entitlements // 0' "$report_path")
  else
    # Container image may not ship jq; keep the count best-effort.
    entitlement_count=$(grep -Eo '"total_entitlements"[[:space:]]*:[[:space:]]*[0-9]+' "$report_path" | head -1 | grep -Eo '[0-9]+$' || echo 0)
  fi
fi

lens_new_operation_count=""
if [[ "$lens_required" == "true" ]]; then
  if ! command -v jq >/dev/null 2>&1; then
    echo "::error::lens-required=true requires jq on the runner"
    exit 1
  fi
  baseline_path="${output_dir}/baseline-without-lens.json"
  lens_diff_path="${output_dir}/lens-added.json"
  echo "Measuring lens value against the built-in catalog (diagnostics disabled for baseline)"
  CCE_DIAGNOSTICS=false cce \
    --folder "$path" --language "$language" --filter "$filter" --format json \
    --log-level "$log_level" --output "$baseline_path"
  cce diff "$baseline_path" "$report_path" --mode tuple --format json -o "$lens_diff_path"
  lens_new_operation_count="$(jq -r '.added | length' "$lens_diff_path")"
  if [[ "$lens_new_operation_count" == "0" ]]; then
    echo "::error::lens added no unique provider/resource/operation mappings (lens-required=true). See $lens_diff_path"
    exit 1
  fi
  echo "Lens added $lens_new_operation_count unique operation(s)"
fi

if [[ "$fail_on_empty" == "true" && "$entitlement_count" == "0" ]]; then
  echo "::error::scan found zero entitlements and fail-on-empty is true"
  exit 1
fi

aws_iam_path=""
gcp_iam_path=""
azure_rbac_path=""
esbom_path=""

try_export() {
  local fmt="$1"
  local provider="$2"
  local out="$3"
  shift 3
  if [[ -n "$provider" ]]; then
    if cce policy export "$report_path" --format "$fmt" --provider "$provider" "$@" -o "$out"; then
      echo "wrote $out"
      return 0
    fi
  else
    if cce policy export "$report_path" --format "$fmt" "$@" -o "$out"; then
      echo "wrote $out"
      return 0
    fi
  fi
  rm -f "$out"
  echo "no ${fmt} policy derived"
  return 0
}

if [[ "$export_policies" == "true" && "$format" == "json" ]]; then
  out_aws="${output_dir}/aws-iam.json"
  out_gcp="${output_dir}/gcp-iam.yaml"
  out_azure="${output_dir}/azure-rbac.json"
  out_esbom="${output_dir}/esbom.json"

  try_export aws-iam AWS "$out_aws"
  [[ -f "$out_aws" ]] && aws_iam_path="$out_aws"

  try_export gcp-iam GCP "$out_gcp"
  [[ -f "$out_gcp" ]] && gcp_iam_path="$out_gcp"

  try_export azure-rbac AZURE "$out_azure"
  [[ -f "$out_azure" ]] && azure_rbac_path="$out_azure"

  try_export esbom "" "$out_esbom"
  [[ -f "$out_esbom" ]] && esbom_path="$out_esbom"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "report-path=$report_path"
    echo "aws-iam-path=$aws_iam_path"
    echo "gcp-iam-path=$gcp_iam_path"
    echo "azure-rbac-path=$azure_rbac_path"
    echo "esbom-path=$esbom_path"
    echo "entitlement-count=$entitlement_count"
    echo "lens-file-sha256=$lens_file_sha256"
    echo "lens-new-operation-count=$lens_new_operation_count"
  } >> "$GITHUB_OUTPUT"
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### CCE scan"
    echo
    echo "- Entitlements: **$entitlement_count**"
    echo "- Report: \`$report_path\`"
    if [[ -n "$lens" ]]; then
      echo "- Lens: \`$lens\`"
      echo "- Lens SHA-256: \`$lens_file_sha256\`"
    fi
    if [[ -n "$lens_new_operation_count" ]]; then
      echo "- Unique operations added by lens: **$lens_new_operation_count**"
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi

echo "CCE scan complete: entitlements=$entitlement_count report=$report_path"
