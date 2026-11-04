# cce-action

GitHub Action and reusable workflow that installs [StackGen CCE](https://appcd-dev.github.io/cce/) and scans the repository where the workflow is running.

It resolves the latest `cce` release from [`stackgenhq/homebrew-stackgen/cce.rb`](https://github.com/stackgenhq/homebrew-stackgen/blob/main/cce.rb), scans your checkout, and (by default) exports minimum AWS IAM, GCP IAM, Azure RBAC, and cloud-neutral E-SBOM artifacts.

## Quick start

```yaml
name: CCE
on: [push, pull_request]
permissions:
  contents: read
jobs:
  scan:
    uses: stackgenhq/cce-action/.github/workflows/scan.yml@v1
    with:
      language: AUTO
```

Or inside an existing job:

```yaml
- uses: actions/checkout@v4
- uses: stackgenhq/cce-action@v1
  with:
    language: GO
    filter: cloud
```

See [`examples/scan.yml`](examples/scan.yml).

## Diagnostics (off by default)

CCE field diagnostics are **disabled** unless you set `diagnostics: true`.

When enabled, CCE posts unresolved method signatures to StackGen so the next release can close mapper gaps. Leave this off for normal product CI. Opt in only when you intend to contribute those signatures (for example a dedicated fuzz harness).

## Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `path` | `.` | Directory to scan |
| `language` | `AUTO` | `GO`, `PYTHON`, `JAVA`, `JAVASCRIPT`, or `AUTO` |
| `filter` | `cloud` | `cloud` or `all` |
| `format` | `json` | Primary report format |
| `output-dir` | `cce-results` | Where reports are written |
| `diagnostics` | `false` | Opt in to StackGen field diagnostics |
| `export-policies` | `true` | Export aws-iam / gcp-iam / azure-rbac / esbom |
| `fail-on-empty` | `false` | Fail when entitlements == 0 |
| `log-level` | `info` | `debug`, `info`, `warn`, `error` |

## Outputs

| Output | Description |
|--------|-------------|
| `version` | Installed `cce` version |
| `report-path` | Primary scan report |
| `aws-iam-path` | AWS IAM policy JSON, or empty |
| `gcp-iam-path` | GCP custom role YAML, or empty |
| `azure-rbac-path` | Azure role JSON, or empty |
| `esbom-path` | Cloud-neutral E-SBOM JSON, or empty |
| `entitlement-count` | Total entitlements in the report |

## Requirements

- Linux amd64 runner (`ubuntu-latest`)
- `actions/checkout` before the composite action (the reusable workflow does this for you)
- Network access to download the `cce` release referenced by the Homebrew formula

## Versioning

Use a major tag (`@v1`) or a pinned release (`@v0.1.0`). Tags are published after self-test CI is green.
