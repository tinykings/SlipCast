#!/bin/zsh
# Writes TestFlight "What to Test" notes from the commits made since the last
# TestFlight build, then tags this commit so the next build knows where to start.
#
# Required workflow environment variable (mark it Secret in Xcode Cloud):
#   GITHUB_TOKEN  fine-grained PAT for tinykings/SlipCast with Contents: read & write
#                 (used only to push the testflight/<build> tag)

set -u

# Only for archives signed for App Store Connect / TestFlight distribution
if [[ ! -d "${CI_APP_STORE_SIGNED_APP_PATH:-}" ]]; then
  echo "Not a TestFlight build; skipping What to Test notes."
  exit 0
fi

REPO="$CI_PRIMARY_REPOSITORY_PATH"
NOTES_DIR="$REPO/TestFlight"
NOTES_FILE="$NOTES_DIR/WhatToTest.en-US.txt"
TAG_PREFIX="testflight/"
mkdir -p "$NOTES_DIR"
cd "$REPO" || exit 0

# Xcode Cloud clones shallowly; fetch full history and existing tags
git fetch --unshallow --quiet 2>/dev/null || git fetch --quiet
git fetch --tags --force --quiet || true

# Newest testflight/* tag that is an ancestor of this commit (excluding this commit itself)
LAST_TAG=""
for tag in $(git tag --list "${TAG_PREFIX}*" --sort=-version:refname); do
  if [[ "$(git rev-list -n 1 "$tag")" != "$CI_COMMIT" ]] && git merge-base --is-ancestor "$tag" HEAD; then
    LAST_TAG="$tag"
    break
  fi
done

# Commits newest first, grouped under a date header (commit date, committer's timezone):
#   Nov 17, 2026
#   • Newest change
#   • Older change that day
#
#   Nov 15, 2026
#   • ...
LOG_FORMAT="%cd%x09%s"
DATE_FORMAT="format:%b %d, %Y"
if [[ -n "$LAST_TAG" ]]; then
  echo "Generating notes for commits since $LAST_TAG"
  RAW=$(git log --no-merges --date="$DATE_FORMAT" --pretty=format:"$LOG_FORMAT" "$LAST_TAG..HEAD")
else
  echo "No previous TestFlight tag found; using the last 10 commits"
  RAW=$(git log --no-merges -10 --date="$DATE_FORMAT" --pretty=format:"$LOG_FORMAT")
fi

LOG=$(print -r -- "$RAW" | awk -F'\t' '
  NF < 2 { next }
  $1 != last { if (NR > 1) print ""; print $1; last = $1 }
  { sub(/^[^\t]*\t/, ""); print "• " $0 }
')

[[ -z "$LOG" ]] && LOG="• Rebuild with no new commits."

# TestFlight limit is 4000 characters; keep whole lines
print -r -- "$LOG" | awk '{ len += length($0) + 1; if (len > 3990) exit; print }' > "$NOTES_FILE"
echo "----- What to Test -----"
cat "$NOTES_FILE"
echo "------------------------"

# Tag this commit so the next build starts from here
TAG="${TAG_PREFIX}${CI_BUILD_NUMBER}"
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  git tag -f "$TAG" "$CI_COMMIT"
  if git push --quiet --force "https://x-access-token:${GITHUB_TOKEN}@github.com/tinykings/SlipCast.git" "refs/tags/$TAG"; then
    echo "Pushed tag $TAG"
  else
    echo "warning: failed to push tag $TAG; next build will repeat these commits"
  fi
else
  echo "warning: GITHUB_TOKEN not set; cannot push $TAG, next build will repeat these commits"
fi

exit 0
