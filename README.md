# cce-action

GitHub Action and reusable workflow that runs [StackGen CCE](https://appcd-dev.github.io/cce/) against the repository where the workflow is running.

Both the composite action and the reusable workflow install `cce` by pulling
[`ghcr.io/stackgenhq/cce`](https://github.com/stackgenhq/homebrew-stackgen/pkgs/container/cce)
and copying `/usr/local/bin/cce` onto `PATH`. That replaces the previous
Homebrew formula download and works on linux amd64 and arm64 runners.

By default it attempts to export AWS IAM, GCP IAM, Azure RBAC, and
cloud-neutral E-SBOM artifacts. GCP IAM and Azure RBAC exports use the CLI's
**strict** permission mapping: the action does not pass `--allow-inferred`.
If any GCP or Azure entitlement with a resource and operation needs an
`sdk_inferred` permission, the entire role export for that provider fails;
no partial or guessed role is published, and its output path is empty. This
applies even when the report mixes catalog-mapped and unknown operations.
The scan report (and other successful exports) remains available, and the
step does not fail solely because a policy cannot be derived. Check the
`gcp-iam-path` / `azure-rbac-path` output before consuming a role. Azure uses
the same strict behavior because its inferred RBAC actions carry the same
risk of publishing an unverified permission. AWS IAM and E-SBOM behavior is
unchanged. `fail-on-empty` checks the report's entitlement count, **not**
whether a provider role was exported.

## Quick start

```yaml
name: CCE
on: [push, pull_request]
permissions:
  contents: read
  packages: read
jobs:
  scan:
    uses: stackgenhq/cce-action/.github/workflows/scan.yml@v1
    with:
      language: AUTO
```

Or inside an existing (host) job. This pulls the image once and copies `cce`
onto `PATH`:

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
| `image` | `ghcr.io/stackgenhq/cce:latest` | Container image used to provide `cce` |

## Outputs

| Output | Description |
|--------|-------------|
| `version` | Installed `cce` version |
| `image` | Image used for install, or `preinstalled` |
| `report-path` | Primary scan report |
| `aws-iam-path` | AWS IAM policy JSON, or empty |
| `gcp-iam-path` | GCP custom role YAML only if all relevant permissions are catalog-mapped; otherwise empty |
| `azure-rbac-path` | Azure role JSON only if all relevant actions are catalog-mapped; otherwise empty |
| `esbom-path` | Cloud-neutral E-SBOM JSON, or empty |
| `entitlement-count` | Total entitlements in the report |

## Requirements

- Linux runner with Docker (`ubuntu-latest`)
- `actions/checkout` before the composite action (the reusable workflow does this for you)
- Network access to pull `ghcr.io/stackgenhq/cce` ([package page](https://github.com/stackgenhq/homebrew-stackgen/pkgs/container/cce))

## Versioning

Use a major tag (`@v1`) or a pinned release (`@v0.1.0`). Tags are published after self-test CI is green. Pin `image` to a version tag (for example `ghcr.io/stackgenhq/cce:0.0.12`) when you need a fixed CLI.
