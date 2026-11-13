# CCE Action developer guide

> Turn source code into Cloud API evidence with GitHub Actions: inventories, PR diffs, IAM access requests, SARIF, and custom lenses.

CCE Action runs [StackGen CCE](https://appcd-dev.github.io/cce/) against the repository where a GitHub workflow is running. It supports Go, Python, Java, and JavaScript. No CCE account is required, field diagnostics are off by default, and reports remain available as workflow artifacts.

## Quick start

Create `.github/workflows/cce.yml`:

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
      filter: cloud
```

Open the workflow run and download the `cce-results` artifact. Use `@v0.3.0` instead of `@v1` when you want an exact action release.

## Use inside an existing job

```yaml
- uses: actions/checkout@v4
- uses: stackgenhq/cce-action@v1
  id: cce
  with:
    language: AUTO
    filter: cloud
- uses: actions/upload-artifact@v4
  with:
    name: cce-results
    path: cce-results/*
```

The reusable workflows perform checkout and artifact upload themselves. Composite actions require `actions/checkout` first.

## Workflows

### Scan

Produces a JSON Cloud API report and, by default, attempts AWS IAM, GCP IAM, Azure RBAC, and cloud-neutral E-SBOM exports. Strict GCP and Azure exports do not publish unverified inferred permissions; check the relevant output path before consuming a role.

Example: <https://github.com/stackgenhq/cce-action/blob/main/examples/scan.yml>

### Pull-request review

Scans the base and head revisions, posts one sticky Cloud API diff, and publishes JSON, Markdown, and optional SARIF evidence.

```yaml
name: CCE Cloud API review
on: [pull_request]
permissions:
  contents: read
  packages: read
  pull-requests: write
  security-events: write
jobs:
  review:
    uses: stackgenhq/cce-action/.github/workflows/pr-review.yml@v1
    with:
      language: AUTO
      filter: cloud
      fail-new: false
```

Set `comment: false` or `upload-sarif: false` to disable either publication. Fork PRs skip comment and SARIF writes when the normal token cannot publish safely; artifacts and summaries remain available.

Example: <https://github.com/stackgenhq/cce-action/blob/main/examples/pr-review.yml>

### IAM access request

Creates a versioned `cce-access-request/v1` JSON artifact containing deduplicated provider/resource/operation evidence, call-site counts, service, commit, and mapping provenance.

```yaml
jobs:
  request:
    uses: stackgenhq/cce-action/.github/workflows/access-request.yml@v1
    with:
      path: .
      service: payments-api
```

The default flow needs no cross-repository token. Download the artifact and attach it to your IAM review process.

Example: <https://github.com/stackgenhq/cce-action/blob/main/examples/access-request.yml>

### Quickstart bundle

Creates a Cloud API BOM, self-contained HTML report, SARIF, lens lockfile, and suggested CI workflow:

```yaml
jobs:
  quickstart:
    uses: stackgenhq/cce-action/.github/workflows/quickstart.yml@v1
    with:
      path: .
```

Example: <https://github.com/stackgenhq/cce-action/blob/main/examples/quickstart.yml>

### Lens Gate 0

Compares current and candidate lenses against committed fixtures. It reports newly mapped and regressed rows and uploads verdict JSON even when a regression fails the job.

```yaml
jobs:
  verify:
    uses: stackgenhq/cce-action/.github/workflows/lens-verify.yml@v1
    with:
      fixture: testdata/lens-fixture
      current: current.yaml
      candidate: candidate.yaml
      language: AUTO
      fail-regression: true
```

Example: <https://github.com/stackgenhq/cce-action/blob/main/examples/lens-verify.yml>

## Custom lenses

A lens is YAML that teaches CCE to recognize internal SDKs, legacy clients, or organization-specific patterns. Local checkout lenses are hashed automatically. HTTPS lenses require `lens-sha256`; non-HTTPS remote URLs are rejected.

```yaml
- uses: actions/checkout@v4
- uses: stackgenhq/cce-action@v1
  with:
    language: AUTO
    lens: .cce/internal-platform.yaml
    filter: all
    lens-required: true
```

Use `filter: all` for custom providers such as `TECH_DEBT`. `lens-required: true` compares against a built-in baseline and fails when the lens adds no unique operations. Outputs include `lens-file-sha256` and `lens-new-operation-count`.

## Requirements and common inputs

- Linux runner with Docker; `ubuntu-latest` is the simplest choice.
- CCE 0.0.38 or newer for PR review, access requests, quickstart, lens verification, and lens hash pinning.
- `path`: directory to scan; defaults to `.`.
- `language`: `AUTO`, `GO`, `PYTHON`, `JAVA`, or `JAVASCRIPT`.
- `filter`: `cloud` or `all`.
- `output-dir`: report directory; defaults to `cce-results` for scans.
- `scan-timeout`: optional wall-clock limit for large scans.
- `image`: optional CCE image override; action releases default to the CCE version their self-tests exercised.

For large repositories, scan a subdirectory or set `scan-timeout` so CI remains bounded.

## Important boundaries

- Static analysis can miss dynamic, reflected, or unrecognized wrapped calls.
- An empty report does not prove that no Cloud APIs or permissions are used.
- IAM access requests are review input, not ready-to-deploy policies.
- Reviewers remain responsible for resource scope, runtime needs, and final approval.
- Field diagnostics are disabled unless `diagnostics: true` is explicitly set.

## References

- [Action repository](https://github.com/stackgenhq/cce-action)
- [Complete inputs and outputs](https://github.com/stackgenhq/cce-action#inputs)
- [CCE documentation](https://appcd-dev.github.io/cce/)
- [Plain-language lens guide](https://appcd-dev.github.io/cce/guides/lenses/)
- [Known CCE limitations](https://appcd-dev.github.io/cce/reference/known-limitations/)
- [LLM site index](llms.txt)
