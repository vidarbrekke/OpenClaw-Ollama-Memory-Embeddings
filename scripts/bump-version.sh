#!/usr/bin/env bash
# Bump dist/VERSION.txt (and sync version in dist/SKILL.md frontmatter).
# Usage: scripts/bump-version.sh [patch|minor|major] [--commit]
# Default: patch. With --commit, git add and commit the version files.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="${ROOT}/dist/VERSION.txt"
SKILL_FILE="${ROOT}/dist/SKILL.md"
Bump="${1:-patch}"
DO_COMMIT=0
[ "${2:-}" = "--commit" ] && DO_COMMIT=1

if [ ! -f "$VERSION_FILE" ]; then
  echo "Missing $VERSION_FILE" >&2
  exit 1
fi

current="$(cat "$VERSION_FILE" | tr -d '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' || true)"
if [ -z "$current" ]; then
  echo "Invalid or missing version in $VERSION_FILE" >&2
  exit 1
fi

major="${current%%.*}"
rest="${current#*.}"
minor="${rest%%.*}"
patch="${rest#*.}"

case "$Bump" in
  major) major=$((major + 1)); minor=0; patch=0 ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  patch) patch=$((patch + 1)) ;;
  *) echo "Usage: $0 [patch|minor|major] [--commit]" >&2; exit 1 ;;
esac

new_version="${major}.${minor}.${patch}"
echo "$new_version" > "$VERSION_FILE"

# Update version in SKILL.md frontmatter (version: "X.Y.Z")
if [ -f "$SKILL_FILE" ]; then
  if grep -q '^version:' "$SKILL_FILE"; then
    case "$(uname -s)" in
      Darwin) sed -i '' "s/^version: .*/version: \"${new_version}\"/" "$SKILL_FILE" ;;
      *)      sed -i "s/^version: .*/version: \"${new_version}\"/" "$SKILL_FILE" ;;
    esac
  fi
fi

echo "$new_version"

if [ "$DO_COMMIT" -eq 1 ]; then
  git add "$VERSION_FILE" "$SKILL_FILE"
  git commit -m "chore: bump version to ${new_version}"
fi
