#!/usr/bin/env bash
# Puts a new demo recording in the README. GitHub plays a video inline only when it's
# hosted as an attachment, so this posts docs/media/demo.mp4 as a comment on the repo's
# "README media" issue and points the README at the new attachment. Run it after
# record.sh, then commit.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
ISSUE="$(gh issue list --repo "$REPO" --state all --search 'in:title "README media"' --json number -q '.[0].number')"
[[ -n "$ISSUE" ]] || { echo "no \"README media\" issue in $REPO" >&2; exit 1; }

comment="$(gh issue comment "$ISSUE" --repo "$REPO" --attach docs/media/demo.mp4 \
  --body "Demo recorded at $(git rev-parse --short HEAD).")"
id="${comment##*issuecomment-}"
url="$(gh api "repos/$REPO/issues/comments/$id" -q .body | grep -o 'https://github.com/user-attachments/assets/[0-9a-f-]*' | head -1)"
[[ -n "$url" ]] || { echo "the upload didn't return an attachment URL" >&2; exit 1; }

perl -pi -e "s#https://github.com/user-attachments/assets/[0-9a-f-]+#$url#" README.md
grep -q "$url" README.md || { echo "README has no attachment line to replace; add $url yourself" >&2; exit 1; }
echo "README now plays $url"
