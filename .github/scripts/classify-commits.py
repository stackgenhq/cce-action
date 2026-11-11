#!/usr/bin/env python3
"""Classify commit subjects and derive the next version + release notes.

Reads commit subjects on stdin (one per line). Env:
  CUT_LAST_TAG       previous tag, e.g. v0.1.1 (may be "<none>")
  CUT_VERSION_OVERRIDE  explicit version; when set, only notes are generated
  CUT_NOTES_LINE     optional one-line summary for the top of the notes

Prints "version<TAB>notes_path" on the last line; classification goes to
stderr so operators can see how the bump was chosen.

Classification (first match wins, per subject):
  conventional "!:" suffix or "BREAKING CHANGE" -> breaking
  conventional "feat"/"feature"               -> minor
  conventional "fix"                          -> patch
  keyword fallback in the subject text:
    breaking                                  -> breaking
    feat/feature                              -> minor
    add/new/support/introduce                 -> minor
    fix/fixes/bugfix                          -> patch
  anything else                               -> other

Bump choice for the derived version (0.x line: breaking bumps minor, not
major, matching this repo's v0.x releases under the v1 moving tag):
  any breaking or minor -> minor bump
  otherwise             -> patch bump
"""

import os
import re
import sys
import tempfile

CONVENTIONAL = re.compile(r"^(\w+)(?:\([^)]*\))?(!)?:", re.IGNORECASE)


def classify(subject: str) -> str:
    text = subject.strip()
    if not text:
        return "other"
    m = CONVENTIONAL.match(text)
    if m:
        kind, breaking = m.group(1).lower(), bool(m.group(2))
        if breaking or "BREAKING CHANGE" in text.upper():
            return "breaking"
        if kind in ("feat", "feature"):
            return "minor"
        if kind == "fix":
            return "patch"
        return "other"
    low = text.lower()
    if "breaking change" in low:
        return "breaking"
    if re.search(r"\b(feat|feature)\b", low):
        return "minor"
    if re.search(r"\b(add|adds|added|new|support|supports|introduce|introduces)\b", low):
        return "minor"
    if re.search(r"\b(fix|fixes|fixed|bugfix)\b", low):
        return "patch"
    return "other"


def bump_version(last: str, kinds: set) -> str:
    m = re.match(r"v?(\d+)\.(\d+)\.(\d+)", last)
    major, minor, patch = (int(m.group(i)) for i in (1, 2, 3))
    if "breaking" in kinds or "minor" in kinds:
        minor, patch = minor + 1, 0
    else:
        patch += 1
    return f"v{major}.{minor}.{patch}"


def main() -> int:
    last_tag = os.environ.get("CUT_LAST_TAG", "<none>").strip()
    override = os.environ.get("CUT_VERSION_OVERRIDE", "").strip()
    notes_line = os.environ.get("CUT_NOTES_LINE", "").strip()

    subjects = [line.rstrip("\n") for line in sys.stdin if line.strip()]
    # Merge commits ("Merge pull request #N ...") carry no signal of their own;
    # the squashed/PR subjects do. Keep them for notes, but they classify as
    # "other" unless the branch name inside mentions fix/feat.
    kinds = set()
    groups: dict = {"minor": [], "patch": [], "other": []}
    for subject in subjects:
        kind = classify(subject)
        kinds.add(kind)
        if kind == "breaking":
            groups["minor"].append(subject)  # 0.x line reports breaking as minor
        elif kind in groups:
            groups[kind].append(subject)

    if override:
        version = override
    elif last_tag == "<none>":
        version = ""
    else:
        version = bump_version(last_tag, kinds)

    print(f"classification: kinds={sorted(kinds)} subjects={len(subjects)}", file=sys.stderr)

    notes = ["# What changed\n"]
    if notes_line:
        notes.append(f"{notes_line}\n")
    if last_tag != "<none>":
        notes.append(f"## Changes since {last_tag}\n")
    section_titles = [("minor", "Features"), ("patch", "Fixes"), ("other", "Other")]
    for key, title in section_titles:
        if not groups[key]:
            continue
        notes.append(f"### {title}\n")
        for subject in groups[key]:
            notes.append(f"- {subject}")
        notes.append("")
    notes.append(
        "Use the moving major tag (`uses: stackgenhq/cce-action@v1`) or pin the exact "
        f"release (`uses: stackgenhq/cce-action@{version or 'vX.Y.Z'}`).\n"
    )

    with tempfile.NamedTemporaryFile(
        "w", suffix=".md", prefix="release-notes-", delete=False
    ) as fh:
        fh.write("\n".join(notes))
        path = fh.name
    print(f"{version}\t{path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
