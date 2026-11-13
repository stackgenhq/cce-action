#!/usr/bin/env bash
# Produce CCE's first-run artifact set and package the optional CI workflow.
set -euo pipefail

path="${INPUT_PATH:-.}"
lens="${INPUT_LENS:-}"
lens_sha256="${INPUT_LENS_SHA256:-}"
policy="${INPUT_POLICY:-}"
write_workflow="${INPUT_WRITE_WORKFLOW:-true}"
output_dir="${INPUT_OUTPUT_DIR:-cce-results/quickstart}"

bom_path="${output_dir}/cce-api-bom.json"
html_path="${output_dir}/cce-report.html"
sarif_path="${output_dir}/cce-results.sarif"
lens_lock_path="${output_dir}/cce-lens-lock.yaml"
workflow_path=""

if ! command -v cce >/dev/null 2>&1; then
  echo "::error::cce is not on PATH; install-cce.sh must run first"
  exit 1
fi

command_help=""
if ! command_help="$(cce quickstart --help 2>&1)" || ! grep -q -- '--mapper-sha256' <<<"$command_help" || ! grep -q -- '--write-workflow' <<<"$command_help"; then
  echo "::error::cce quickstart with lens pinning and workflow generation is unavailable. This action requires CCE >= 0.0.38; set image to ghcr.io/stackgenhq/cce:0.0.38 or newer."
  if [[ -n "$command_help" ]]; then
    printf '%s\n' "$command_help"
  fi
  exit 1
fi

if [[ "$path" != /* ]]; then
  path="${GITHUB_WORKSPACE:-$PWD}/$path"
fi
if [[ ! -d "$path" ]]; then
  echo "::error::quickstart path does not exist: $path"
  exit 1
fi
if [[ "$write_workflow" != "true" && "$write_workflow" != "false" ]]; then
  echo "::error::write-workflow must be true or false (got $write_workflow)"
  exit 1
fi

mapper_file=""
args=(quickstart "$path" --output-dir "$output_dir" "--write-workflow=$write_workflow")
if [[ -n "$policy" ]]; then
  args+=(--policy "$policy")
fi

if [[ -n "$lens" ]]; then
  if [[ "$lens" =~ ^[Hh][Tt][Tt][Pp][Ss]:// ]]; then
    # Remote content is mutable: an explicit digest is required to fail closed.
    if [[ "$lens_sha256" =~ ^[[:space:]]*$ ]]; then
      echo "::error::lens-sha256 is required when lens is an HTTPS URL"
      exit 1
    fi
    mapper_file="$lens"
  elif [[ "$lens" =~ ^[A-Za-z][A-Za-z0-9+.-]*:// ]]; then
    echo "::error::lens URL must use HTTPS; non-HTTPS URLs are not supported: $lens"
    exit 1
  else
    mapper_file="$lens"
    if [[ "$mapper_file" != /* ]]; then
      mapper_file="${GITHUB_WORKSPACE:-$PWD}/$mapper_file"
    fi
    if [[ ! -f "$mapper_file" ]]; then
      echo "::error::local lens file does not exist: $mapper_file"
      exit 1
    fi
    if [[ -z "$lens_sha256" ]]; then
      if command -v sha256sum >/dev/null 2>&1; then
        lens_sha256="$(sha256sum "$mapper_file")"
        lens_sha256="${lens_sha256%% *}"
      elif command -v shasum >/dev/null 2>&1; then
        lens_sha256="$(shasum -a 256 "$mapper_file")"
        lens_sha256="${lens_sha256%% *}"
      else
        echo "::error::sha256sum or shasum is required to calculate the local lens SHA-256; otherwise set lens-sha256 explicitly"
        exit 1
      fi
    fi
  fi
  # Always pin custom lenses, including local files whose digest was computed above.
  args+=(--mapper-file "$mapper_file" --mapper-sha256 "$lens_sha256")
fi

mkdir -p "$output_dir"
echo "Running CCE quickstart for $path"
cce "${args[@]}"

for artifact in "$bom_path" "$html_path" "$sarif_path" "$lens_lock_path"; do
  if [[ ! -f "$artifact" ]]; then
    echo "::error::cce quickstart produced no artifact at $artifact"
    exit 1
  fi
done

# CCE itself never overwrites the source workflow. Copy either a newly generated
# workflow or the already-existing source into the artifact bundle when present.
workflow_source="${path}/.github/workflows/cce.yml"
if [[ -f "$workflow_source" ]]; then
  workflow_path="${output_dir}/cce-workflow.yml"
  cp "$workflow_source" "$workflow_path"
fi

entitlement_count=0
if command -v jq >/dev/null 2>&1; then
  entitlement_count="$(jq -r '.summary.total_entitlements // 0' "$bom_path")"
elif command -v python3 >/dev/null 2>&1; then
  entitlement_count="$(python3 - "$bom_path" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    document = json.load(stream)
print(document.get("summary", {}).get("total_entitlements", 0))
PY
)"
else
  entitlement_count="$(grep -Eo '"total_entitlements"[[:space:]]*:[[:space:]]*[0-9]+' "$bom_path" | head -1 | grep -Eo '[0-9]+$' || echo 0)"
fi
if [[ ! "$entitlement_count" =~ ^[0-9]+$ ]]; then
  echo "::error::could not read entitlement count from $bom_path"
  exit 1
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "bom-path=$bom_path"
    echo "html-path=$html_path"
    echo "sarif-path=$sarif_path"
    echo "lens-lock-path=$lens_lock_path"
    echo "workflow-path=$workflow_path"
    echo "entitlement-count=$entitlement_count"
  } >> "$GITHUB_OUTPUT"
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## CCE quickstart"
    echo
    echo "- Entitlements: **$entitlement_count**"
    echo "- API BOM: \`$bom_path\`"
    echo "- HTML report: \`$html_path\`"
    echo "- SARIF: \`$sarif_path\`"
    echo "- Lens lockfile: \`$lens_lock_path\`"
    if [[ -n "$workflow_path" ]]; then
      echo "- CI workflow: \`$workflow_path\` (source workflow left untouched)"
    else
      echo "- CI workflow: not generated (write-workflow=$write_workflow)"
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi

echo "CCE quickstart complete: entitlements=$entitlement_count output=$output_dir"
