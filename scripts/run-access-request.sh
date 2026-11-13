#!/usr/bin/env bash
# Generate a code-evidenced access request for review by an IAM/platform team.
set -euo pipefail

path="${INPUT_PATH:-.}"
lens="${INPUT_LENS:-}"
lens_sha256="${INPUT_LENS_SHA256:-}"
service="${INPUT_SERVICE:-}"
commit="${INPUT_COMMIT:-}"
output_dir="${INPUT_OUTPUT_DIR:-cce-results/access-request}"
report_path="${output_dir}/cce-access-request.json"

if ! command -v cce >/dev/null 2>&1; then
  echo "::error::cce is not on PATH; install-cce.sh must run first"
  exit 1
fi

command_help=""
if ! command_help="$(cce access-request --help 2>&1)" || ! grep -q -- '--mapper-sha256' <<<"$command_help"; then
  echo "::error::cce access-request with lens pinning is unavailable. This action requires CCE >= 0.0.38; set image to ghcr.io/stackgenhq/cce:0.0.38 or newer."
  if [[ -n "$command_help" ]]; then
    printf '%s\n' "$command_help"
  fi
  exit 1
fi

if [[ "$path" != /* ]]; then
  path="${GITHUB_WORKSPACE:-$PWD}/$path"
fi
if [[ ! -d "$path" ]]; then
  echo "::error::access-request path does not exist: $path"
  exit 1
fi

mapper_file=""
lens_file_sha256=""
args=(access-request "$path" --output "$report_path")
if [[ -n "$service" ]]; then
  args+=(--service "$service")
fi
if [[ -n "$commit" ]]; then
  args+=(--commit "$commit")
fi

if [[ -n "$lens" ]]; then
  if [[ "$lens" =~ ^[Hh][Tt][Tt][Pp][Ss]:// ]]; then
    # Remote content is mutable: an explicit digest is required to fail closed.
    if [[ "$lens_sha256" =~ ^[[:space:]]*$ ]]; then
      echo "::error::lens-sha256 is required when lens is an HTTPS URL"
      exit 1
    fi
    mapper_file="$lens"
    lens_file_sha256="$lens_sha256"
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
    lens_file_sha256="$lens_sha256"
  fi
  # Always pin custom lenses, including local files whose digest was computed above.
  args+=(--mapper-file "$mapper_file" --mapper-sha256 "$lens_file_sha256")
fi

mkdir -p "$output_dir"
echo "Generating access request for $path"
cce "${args[@]}"

if [[ ! -f "$report_path" ]]; then
  echo "::error::cce access-request produced no report at $report_path"
  exit 1
fi

operation_count=0
document_commit=""
document_lens_sha256=""
if command -v jq >/dev/null 2>&1; then
  operation_count="$(jq -r '.operations | length' "$report_path")"
  document_commit="$(jq -r '.commit // ""' "$report_path")"
  document_lens_sha256="$(jq -r '.provenance.lens_file_sha256 // ""' "$report_path")"
elif command -v python3 >/dev/null 2>&1; then
  metadata="$(python3 - "$report_path" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    document = json.load(stream)
print(len(document.get("operations", [])))
print(document.get("commit", ""))
print(document.get("provenance", {}).get("lens_file_sha256", ""))
PY
)"
  operation_count="$(sed -n '1p' <<<"$metadata")"
  document_commit="$(sed -n '2p' <<<"$metadata")"
  document_lens_sha256="$(sed -n '3p' <<<"$metadata")"
else
  # GitHub-hosted runners include jq. Keep a narrow fallback for the formatted
  # access-request schema on minimal runners rather than requiring an install.
  operation_count="$(grep -c '"operation"[[:space:]]*:' "$report_path" || true)"
  document_commit="$(sed -n 's/^[[:space:]]*"commit"[[:space:]]*:[[:space:]]*"\([^"]*\)".*$/\1/p' "$report_path" | head -1)"
  document_lens_sha256="$(sed -n 's/^[[:space:]]*"lens_file_sha256"[[:space:]]*:[[:space:]]*"\([^"]*\)".*$/\1/p' "$report_path" | head -1)"
fi

if [[ ! "$operation_count" =~ ^[0-9]+$ ]]; then
  echo "::error::could not read operation count from $report_path"
  exit 1
fi
# Prefer the document's verified provenance, with the effective pin as a
# fallback for compatible producers that omit the optional provenance field.
if [[ -n "$document_lens_sha256" ]]; then
  lens_file_sha256="$document_lens_sha256"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "access-request-path=$report_path"
    echo "operation-count=$operation_count"
    echo "commit=$document_commit"
    echo "lens-file-sha256=$lens_file_sha256"
  } >> "$GITHUB_OUTPUT"
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## CCE access request"
    echo
    echo "- Operations: **$operation_count**"
    echo "- Commit: \`${document_commit:-not detected}\`"
    echo "- Lens file SHA-256: \`${lens_file_sha256:-built-in rules only}\`"
    echo "- Artifact: \`$report_path\`"
    echo
    echo "Static code evidence only; review operations against policy before granting access."
  } >> "$GITHUB_STEP_SUMMARY"
fi

echo "CCE access request complete: operations=$operation_count report=$report_path"
