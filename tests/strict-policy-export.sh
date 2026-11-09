#!/usr/bin/env bash
# Exercise the action's scan/export orchestration with the real CCE policy exporter.
# Only the scan is replaced so each mapping scenario is deterministic.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
real_cce="$(command -v cce)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/unknown-gcp.json" <<'JSON'
{"files_scanned":1,"entitlements":[{"provider":"GCP","resource":"storage","operation":"DefinitelyUnknown"}],"summary":{"total_entitlements":1,"by_provider":{"GCP":1}}}
JSON
cat > "$tmp/mixed-gcp.json" <<'JSON'
{"files_scanned":1,"entitlements":[{"provider":"GCP","resource":"storage","operation":"Get"},{"provider":"GCP","resource":"storage","operation":"DefinitelyUnknown"}],"summary":{"total_entitlements":2,"by_provider":{"GCP":2}}}
JSON
cat > "$tmp/catalog-gcp.json" <<'JSON'
{"files_scanned":1,"entitlements":[{"provider":"GCP","resource":"storage","operation":"Get"}],"summary":{"total_entitlements":1,"by_provider":{"GCP":1}}}
JSON
cat > "$tmp/mixed-azure.json" <<'JSON'
{"files_scanned":1,"entitlements":[{"provider":"AZURE","resource":"storage","operation":"getBlobClient"},{"provider":"AZURE","resource":"storage","operation":"DefinitelyUnknown"}],"summary":{"total_entitlements":2,"by_provider":{"AZURE":2}}}
JSON
cat > "$tmp/catalog-azure.json" <<'JSON'
{"files_scanned":1,"entitlements":[{"provider":"AZURE","resource":"storage","operation":"getBlobClient"}],"summary":{"total_entitlements":1,"by_provider":{"AZURE":1}}}
JSON

mkdir "$tmp/bin"
cat > "$tmp/bin/cce" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--folder" ]]; then
  while (($#)); do
    if [[ "$1" == "--output" ]]; then
      cp "$CCE_TEST_REPORT" "$2"
      exit 0
    fi
    shift
  done
  echo "mock scan missing --output" >&2
  exit 1
fi
exec "$CCE_REAL_BIN" "$@"
SH
chmod +x "$tmp/bin/cce"

run_case() {
  local name="$1" report="$2" provider="$3" expected="$4"
  local dir="$tmp/$name" out="$tmp/$name.outputs" role output_key
  mkdir "$dir"
  case "$provider" in
    GCP) role="$dir/gcp-iam.yaml"; output_key=gcp-iam-path ;;
    AZURE) role="$dir/azure-rbac.json"; output_key=azure-rbac-path ;;
    *) echo "unknown test provider: $provider" >&2; return 1 ;;
  esac
  # A failed export must not leave behind an artifact from a prior run.
  printf 'stale unsafe role\n' > "$role"
  CCE_REAL_BIN="$real_cce" CCE_TEST_REPORT="$report" PATH="$tmp/bin:$PATH" \
    INPUT_PATH="$repo_root/testdata/fixture" INPUT_LANGUAGE=PYTHON INPUT_FORMAT=json \
    INPUT_OUTPUT_DIR="$dir" INPUT_EXPORT_POLICIES=true GITHUB_OUTPUT="$out" \
    bash "$repo_root/scripts/run-scan.sh" > "$dir/scan.log" 2>&1
  test -s "$dir/scan.json"
  test -s "$dir/esbom.json"
  grep -Fxq "esbom-path=$dir/esbom.json" "$out"
  if [[ "$expected" == "none" ]]; then
    test ! -e "$role"
    grep -Fxq "$output_key=" "$out"
  else
    test -s "$role"
    grep -Fxq "$output_key=$role" "$out"
    grep -Fq "$expected" "$role"
    if grep -Fq 'definitelyunknown' "$role"; then
      echo "unexpected inferred permission in $role" >&2
      return 1
    fi
  fi
  echo "PASS: $name"
}

run_case unknown-gcp "$tmp/unknown-gcp.json" GCP none
run_case mixed-gcp "$tmp/mixed-gcp.json" GCP none
run_case catalog-gcp "$tmp/catalog-gcp.json" GCP storage.objects.get
run_case mixed-azure "$tmp/mixed-azure.json" AZURE none
run_case catalog-azure "$tmp/catalog-azure.json" AZURE Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read
