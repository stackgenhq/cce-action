# cce-action

**[Developer guide and examples](https://stackgenhq.github.io/cce-action/)** · [Workflow examples](examples/) · [CCE documentation](https://appcd-dev.github.io/cce/)

GitHub Action and reusable workflows that run [StackGen CCE](https://appcd-dev.github.io/cce/) against the repository where the workflow is running.

Both the composite action and the reusable workflow install `cce` by pulling
[`ghcr.io/stackgenhq/cce`](https://github.com/stackgenhq/homebrew-stackgen/pkgs/container/cce)
and copying `/usr/local/bin/cce` onto `PATH`. That replaces the previous
Homebrew formula download and works on linux amd64 and arm64 runners. Each
action release defaults to the CCE image version its self-tests exercised
(currently `0.0.38`), rather than the moving `latest` tag; `image` remains an
explicit override.

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

## Use a custom lens

A lens teaches CCE your organization's SDK wrappers or inventory categories.
Use a workspace-relative path; the action hashes the local file and passes the
pin to CCE automatically. Custom providers such as `TECH_DEBT` need
`filter: all`.

```yaml
- uses: actions/checkout@v4
- uses: stackgenhq/cce-action@v1
  id: cce
  with:
    language: AUTO
    lens: .cce/tech-debt.yaml
    filter: all
    # Optional: scan a built-in baseline and fail unless this lens adds a
    # unique provider/resource/operation mapping.
    lens-required: true
```

The step outputs `lens-file-sha256` and, when requested,
`lens-new-operation-count`. For a mutable HTTPS lens, supply the expected hash
so changed content fails before any rules load:

```yaml
- uses: stackgenhq/cce-action@v1
  with:
    lens: https://example.com/approved-lens.yaml
    lens-sha256: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
    filter: all
```

## Cloud API review on every PR

The reusable PR workflow handles base/head worktrees, Markdown and JSON diffs,
a paginated sticky comment, SARIF, artifacts, and optional policy gates:

```yaml
jobs:
  cloud-api-review:
    uses: stackgenhq/cce-action/.github/workflows/pr-review.yml@v1
    with:
      language: AUTO
      lens: .cce/cloud.yaml # optional
      filter: all          # use all for custom lens providers
      fail-new: false
```

Set `comment: false` for a read-only workflow. Comment and SARIF publication
are skipped for fork PRs, where the token normally cannot write. The workflow
outputs added/removed counts and report paths.

## Access requests, quickstart, and lens Gate 0

Generate a versioned IAM-review artifact without hand-writing CLI or upload
steps:

```yaml
- uses: stackgenhq/cce-action/access-request@v1
  with:
    service: payments-api
    lens: .cce/cloud.yaml
```

Outputs include `access-request-path`, `operation-count`, `commit`, and
`lens-file-sha256`. The reusable `access-request.yml` wraps checkout and upload.
Cross-repository notification remains a separate, explicit IAM-repository
integration; this action does not require a cross-repo token.

For a shareable first-run bundle (Cloud API BOM, HTML, SARIF, lens lockfile,
and a suggested CI workflow):

```yaml
- uses: stackgenhq/cce-action/quickstart@v1
  with:
    path: .
```

Lens repositories can run deterministic Gate 0 on every lens PR:

```yaml
jobs:
  lens-gate:
    uses: stackgenhq/cce-action/.github/workflows/lens-verify.yml@v1
    with:
      fixture: testdata/lens-fixture
      current: current.yaml
      candidate: candidate.yaml
```

The gate uploads verdict evidence even on failure and reports newly mapped and
regressed rows in the job summary. Regressions fail by default. Local current
and candidate lenses are hashed automatically; HTTPS lenses require their
respective SHA-256 inputs. These workflows and subactions require CCE `0.0.38`
or newer and fail with an upgrade message when an older preinstalled binary
lacks the command.

See [`examples/`](examples/) for complete workflow snippets.

## Diagnostics (off by default)

CCE field diagnostics are **disabled** unless you set `diagnostics: true`.

When enabled, CCE posts unresolved method signatures to StackGen so the next release can close mapper gaps. Leave this off for normal product CI. Opt in only when you intend to contribute those signatures (for example a dedicated fuzz harness).

Prefer `diagnostics: true` with the default `log-level: info` over
`log-level: debug` when scanning large repositories. Debug streams one line
per unmapped SDK call; in fuzz runs SDK-heavy repos produced tens of MB of
log lines in a single scan (141k lines / 47MB for one Java monorepo), which
can slow CI log ingestion.

## Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `path` | `.` | Directory to scan |
| `language` | `AUTO` | `GO`, `PYTHON`, `JAVA`, `JAVASCRIPT`, or `AUTO` |
| `filter` | `cloud` | `cloud` or `all` |
| `format` | `json` | Primary report format |
| `output-dir` | `cce-results` | Where reports are written |
| `diagnostics` | `false` | Opt in to StackGen field diagnostics |
| `lens` | empty | Workspace-relative lens YAML or HTTPS URL |
| `lens-sha256` | empty | Expected lens bytes hash; required for HTTPS, automatic for local files |
| `lens-required` | `false` | Fail if the lens adds no unique operations (JSON; scans a baseline) |
| `export-policies` | `true` | Export aws-iam / gcp-iam / azure-rbac / esbom |
| `fail-on-empty` | `false` | Fail when entitlements == 0 |
| `log-level` | `info` | `debug`, `info`, `warn`, `error` |
| `scan-timeout` | `0` | Wall-clock seconds allowed for the cce scan itself (0 = no limit) |
| `image` | `ghcr.io/stackgenhq/cce:0.0.38` | Action-tested CCE image; override to select another CLI |

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
| `lens-file-sha256` | Verified local digest or configured remote lens pin |
| `lens-new-operation-count` | Unique operations added by the lens when `lens-required` is true |

## Large repositories

A scan that grows with the repository can outlast a job's `timeout-minutes`
before producing any report (observed: a 143k-file Java monorepo scanned for
14 minutes, was cancelled by the workflow timeout, and uploaded nothing).
Set `scan-timeout` so oversized repos fail fast with an actionable error
instead of burning the whole job budget, and consider scanning subdirectories
or checking the repo size in a prior step.

## Requirements

- Linux runner with Docker (`ubuntu-latest`)
- `actions/checkout` before the composite action (the reusable workflow does this for you)
- Network access to pull `ghcr.io/stackgenhq/cce` ([package page](https://github.com/stackgenhq/homebrew-stackgen/pkgs/container/cce))

## Versioning

Use a major tag (`@v1`) or a pinned release (`@v0.3.0`). The action's default image is fixed to its tested CLI release; override `image` (for example `ghcr.io/stackgenhq/cce:0.0.38`) when you deliberately need another CLI.

Releases are cut from the **Release** workflow (Actions tab -> Run workflow on
`main`). The workflow refuses to release unless Self-test is green for the
exact commit being released. Leave the version input empty and the next
version is derived from the commit subjects since the last tag
(`feat`/`feat!` -> minor bump, `fix` -> patch bump; on the 0.x line a breaking
change bumps minor, not major), or pass an explicit version like `v0.2.0`.
The moving major tag (`v1` by default) is re-pointed at the release, and the
release notes list the classified commits. The same logic can be previewed
locally:

```bash
GITHUB_REPOSITORY=stackgenhq/cce-action GITHUB_SHA=$(git rev-parse HEAD) \
  bash .github/scripts/cut-release.sh --dry-run
```
