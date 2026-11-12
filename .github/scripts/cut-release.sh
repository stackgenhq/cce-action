#!/usr/bin/env bash
# cut-release.sh — cut a versioned release of cce-action.
#
# Called by .github/workflows/release.yml after Self-test is green on main.
# Also runnable locally with --dry-run for a preview:
#
#   GITHUB_REPOSITORY=stackgenhq/cce-action GITHUB_SHA=$(git rev-parse HEAD) \
#     bash .github/scripts/cut-release.sh --dry-run
#
# Behavior:
#   1. version = RELEASE_VERSION override, else derived from commit subjects
#      since the last reachable tag: conventional feat!/!:/BREAKING or feat ->
#      minor (0.x line: breaking bumps minor, not major), conventional fix ->
#      patch, keyword fallback (add/new/support -> minor, fix -> patch), else
#      patch.
#   2. release notes = NOTES_LINE + commit subjects grouped by that same
#      classification.
#   3. tags the target SHA, pushes the tag, re-points MAJOR_TAG (default v1)
#      at it (best effort: a tag-protection rule may forbid the force push,
#      which must not fail the release), and creates the GitHub release.
#
# Required env: GITHUB_REPOSITORY, GITHUB_SHA (release target).
# Optional env: RELEASE_VERSION, MAJOR_TAG, NOTES_LINE, GH_TOKEN (push/release).
set -euo pipefail

dry_run=false
if [ "${1:-}" = "--dry-run" ]; then
  dry_run=true
fi

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_SHA:?GITHUB_SHA (release target) is required}"
sha="$GITHUB_SHA"
version="${RELEASE_VERSION:-}"
major_tag="${MAJOR_TAG:-v1}"
notes_line="${NOTES_LINE:-}"
ref_name="${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD)}"

cd "$(git rev-parse --show-toplevel)"

if ! git rev-parse -q --verify "${sha}^{commit}" >/dev/null; then
  echo "::error::commit ${sha} not present in this checkout; fetch it first" >&2
  exit 1
fi

# Last *semver* tag reachable from the target. Do NOT use "git describe
# --tags --abbrev=0": the moving major tag (v1) is also a plain tag and
# describe may return it (it did: "v1" is not a version we can bump from).
last_tag=$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --merged "$sha" --sort=-v:refname | head -1)
if [ -z "$last_tag" ]; then
  if [ -z "$version" ]; then
    echo "::error::no previous tag to derive from; set RELEASE_VERSION explicitly" >&2
    exit 1
  fi
  last_tag="<none>"
fi
range="${last_tag}..${sha}"

# subjects one per line; python classifies and derives version + notes.
export CUT_LAST_TAG="$last_tag"
export CUT_VERSION_OVERRIDE="$version"
export CUT_NOTES_LINE="$notes_line"
derived=$(git log --format='%s' "$range" | python3 .github/scripts/classify-commits.py)
# classify-commits.py prints "version<TAB>notes_path" on the last line.
version=$(printf '%s' "$derived" | tail -1 | cut -f1)
notes_path=$(printf '%s' "$derived" | tail -1 | cut -f2)

if [ -z "$version" ]; then
  echo "::error::could not derive a version" >&2
  exit 1
fi
if git rev-parse -q --verify "refs/tags/$version" >/dev/null; then
  echo "::error::tag $version already exists; pass a fresh RELEASE_VERSION" >&2
  exit 1
fi

echo "Release plan:"
echo "  target:    ${sha} (${ref_name})"
echo "  version:   ${version}"
echo "  since:     ${last_tag}"
if [ -n "$major_tag" ]; then
  echo "  major tag: ${major_tag} -> ${version} (best effort)"
fi
echo "  notes:"
sed 's/^/    /' "$notes_path"
echo

if [ "$dry_run" = true ]; then
  echo "dry run; nothing tagged or pushed"
  exit 0
fi

: "${GH_TOKEN:?GH_TOKEN is required to push tags and create the release}"

# Annotated tags need a committer identity; GitHub runners have none. Fall
# back to github-actions[bot] only when the environment provides none, so a
# local manual run still tags with the user's own identity.
if [ -z "$(git config user.email || true)" ]; then
  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
fi

git tag -a "$version" -m "Release $version" "$sha"
git push origin "refs/tags/$version"

if [ -n "$major_tag" ]; then
  if git tag -fa "$major_tag" -m "Moving $major_tag to $version" "$sha" \
     && git push --force origin "refs/tags/$major_tag"; then
    echo "moved ${major_tag} to ${version}"
  else
    echo "::warning::could not re-point ${major_tag} (tag protection rule?); the release ${version} is still published. Update the moving tag manually if needed."
  fi
fi

gh release create "$version" \
  --repo "$GITHUB_REPOSITORY" \
  --verify-tag \
  --title "$version" \
  --notes-file "$notes_path"
echo "released ${version}"
