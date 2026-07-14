#!/usr/bin/env bash
#
# release.sh — cut a pub.dev release for apple_spatial_capture.
#
# Mirrors .github/workflows/release-apple-spatial-capture.yml locally:
#   1. sets the version in pubspec.yaml (bump segment, --version, or --current)
#   2. updates the dependency constraint in README.md and adds a CHANGELOG entry
#   3. commits and tags (apple_spatial_capture-v<version>)
#   4. validates the clean, committed tree with `flutter pub publish --dry-run`
#   5. pushes (or publishes locally); on validation failure the commit + tag are
#      rolled back so the working tree is left exactly as it started
#
# Pushing the tag triggers .github/workflows/publish-apple-spatial-capture.yml,
# which publishes to pub.dev via trusted publishing (OIDC) — no local
# credentials required. Use --local-publish to publish straight from this
# machine instead (requires `dart pub login`).
#
# Usage:
#   scripts/release.sh [patch|minor|major] [options]
#   scripts/release.sh --version 0.4.0 [options]
#   scripts/release.sh --current [options]   # publish the version already in pubspec
#
# Options:
#   --version <X.Y.Z>     Explicit version (overrides the bump segment).
#   --current             Release the version already in pubspec.yaml (no bump).
#   -m, --message <text>  CHANGELOG bullet (only used when a section is added).
#   --local-publish       Publish from this machine (flutter pub publish --force)
#                         instead of relying on the tag-triggered CI workflow.
#   --no-push             Create the commit + tag but do not push (no release).
#   --dry-run             Print the plan and exit without changing anything.
#   -y, --yes             Skip the confirmation prompt.
#   -h, --help            Show this help.
#
set -euo pipefail

PACKAGE="apple_spatial_capture"
TAG_PREFIX="${PACKAGE}-v"

# --- helpers ---------------------------------------------------------------

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  # Print the leading comment header (skip the shebang, stop at first code line).
  awk 'NR==1 && /^#!/ {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
  exit "${1:-0}"
}

# --- args ------------------------------------------------------------------

SEGMENT="patch"
EXPLICIT_VERSION=""
USE_CURRENT=0
MESSAGE=""
LOCAL_PUBLISH=0
NO_PUSH=0
DRY_RUN=0
ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    patch|minor|major) SEGMENT="$1" ;;
    --version) EXPLICIT_VERSION="${2:-}"; shift ;;
    --version=*) EXPLICIT_VERSION="${1#*=}" ;;
    --current) USE_CURRENT=1 ;;
    -m|--message) MESSAGE="${2:-}"; shift ;;
    --message=*) MESSAGE="${1#*=}" ;;
    --local-publish) LOCAL_PUBLISH=1 ;;
    --no-push) NO_PUSH=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help) usage 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

# --- locate repo -----------------------------------------------------------

command -v git >/dev/null 2>&1 || die "git is not installed."
command -v flutter >/dev/null 2>&1 || die "flutter is not on PATH."

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository."
cd "$REPO_ROOT"

[ -f pubspec.yaml ] || die "pubspec.yaml not found in $REPO_ROOT."
grep -q "^name:[[:space:]]*${PACKAGE}\$" pubspec.yaml \
  || die "pubspec.yaml is not for package '${PACKAGE}'."

# --- version math ----------------------------------------------------------

CURRENT_VERSION="$(grep -E '^version:[[:space:]]*' pubspec.yaml | head -1 | awk '{print $2}')"
[ -n "$CURRENT_VERSION" ] || die "could not read current version from pubspec.yaml."

bump_version() {
  local current="$1" segment="$2" core major minor patch
  core="${current%%[-+]*}"                 # strip -prerelease / +build
  IFS='.' read -r major minor patch <<<"$core"
  case "$core" in
    *.*.*) : ;;
    *) die "cannot auto-increment non-semver version '$current'; pass --version." ;;
  esac
  case "$segment" in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch) patch=$((patch + 1)) ;;
  esac
  printf '%s.%s.%s\n' "$major" "$minor" "$patch"
}

if [ "$USE_CURRENT" -eq 1 ]; then
  [ -z "$EXPLICIT_VERSION" ] || die "--current cannot be combined with --version."
  NEXT_VERSION="$CURRENT_VERSION"
elif [ -n "$EXPLICIT_VERSION" ]; then
  NEXT_VERSION="$EXPLICIT_VERSION"
else
  NEXT_VERSION="$(bump_version "$CURRENT_VERSION" "$SEGMENT")"
fi

[[ "$NEXT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] \
  || die "invalid version '$NEXT_VERSION' (expected X.Y.Z)."

TAG="${TAG_PREFIX}${NEXT_VERSION}"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
MESSAGE="${MESSAGE:-Release maintenance updates.}"

# --- preflight -------------------------------------------------------------

info "Preflight checks"

# In --dry-run these are informational (so the plan still prints); otherwise fatal.
block() { if [ "$DRY_RUN" -eq 1 ]; then warn "$*"; else die "$*"; fi; }

[ -z "$(git status --porcelain)" ] \
  || block "working tree is not clean; commit or stash changes first."

if [ "$BRANCH" != "main" ]; then
  warn "you are on branch '$BRANCH', not 'main'."
fi

if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
  block "tag ${TAG} already exists locally."
fi

if git ls-remote --exit-code --tags origin "refs/tags/${TAG}" >/dev/null 2>&1; then
  block "tag ${TAG} already exists on origin."
fi

# Warn (don't fail) if the local branch is behind its upstream.
if UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"; then
  git fetch --quiet origin "$BRANCH" 2>/dev/null || true
  BEHIND="$(git rev-list --count "HEAD..${UPSTREAM}" 2>/dev/null || echo 0)"
  [ "${BEHIND:-0}" -eq 0 ] || warn "local $BRANCH is $BEHIND commit(s) behind $UPSTREAM."
fi

# --- plan ------------------------------------------------------------------

if [ "$LOCAL_PUBLISH" -eq 1 ]; then
  PUBLISH_DESC="publish directly from this machine (flutter pub publish --force)"
elif [ "$NO_PUSH" -eq 1 ]; then
  PUBLISH_DESC="commit + tag locally only (nothing pushed, no publish)"
else
  PUBLISH_DESC="push tag → CI publishes to pub.dev via trusted publishing"
fi

cat <<PLAN

  Package    : ${PACKAGE}
  Version    : ${CURRENT_VERSION}  ->  ${NEXT_VERSION}
  Tag        : ${TAG}
  Branch     : ${BRANCH}
  Changelog  : - ${MESSAGE}
  Release    : ${PUBLISH_DESC}

PLAN

if [ "$DRY_RUN" -eq 1 ]; then
  info "Dry run — no changes made."
  exit 0
fi

if [ "$ASSUME_YES" -eq 0 ]; then
  printf 'Proceed with release? [y/N] '
  read -r reply
  case "$reply" in
    y|Y|yes|YES) : ;;
    *) die "aborted." ;;
  esac
fi

# --- edit files ------------------------------------------------------------
#
# We edit, then COMMIT, then validate on the clean committed tree. pub.dev
# refuses to publish (and warns on --dry-run) when tracked files are modified,
# so validating before committing would always trip that check. PHASE drives
# the rollback in cleanup(): "edited" restores files from backup; "committed"
# hard-resets the commit and deletes the tag.

BACKUP_DIR="$(mktemp -d)"
PHASE="start"      # start -> edited -> committed -> done
PREV_HEAD="$(git rev-parse HEAD)"
MADE_COMMIT=0

cleanup() {
  local ec=$?
  case "$PHASE" in
    edited)
      for f in pubspec.yaml README.md CHANGELOG.md; do
        [ -f "$BACKUP_DIR/$f" ] && cp "$BACKUP_DIR/$f" "$f"
      done
      [ "$ec" -ne 0 ] && warn "reverted working-tree changes."
      ;;
    committed)
      git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null && git tag -d "$TAG" >/dev/null
      [ "$MADE_COMMIT" -eq 1 ] && git reset --hard "$PREV_HEAD" >/dev/null
      [ "$ec" -ne 0 ] && warn "rolled back the release commit and tag."
      ;;
  esac
  rm -rf "$BACKUP_DIR"
}
trap cleanup EXIT

for f in pubspec.yaml README.md CHANGELOG.md; do
  [ -f "$f" ] && cp "$f" "$BACKUP_DIR/$f"
done
PHASE="edited"

info "Setting version ${NEXT_VERSION} in pubspec.yaml"
perl -0pi -e "s/^version:\\s*\\S+/version: ${NEXT_VERSION}/m" pubspec.yaml

if [ -f README.md ]; then
  info "Updating README.md dependency constraint"
  perl -pi -e "s/${PACKAGE}:\\s*\\^[0-9A-Za-z.+-]+/${PACKAGE}: ^${NEXT_VERSION}/" README.md
fi

if [ -f CHANGELOG.md ]; then
  if grep -qxF "## ${NEXT_VERSION}" CHANGELOG.md; then
    info "CHANGELOG.md already has a ## ${NEXT_VERSION} section — leaving it"
  else
    info "Prepending CHANGELOG.md entry"
    { printf '## %s\n\n- %s\n\n' "$NEXT_VERSION" "$MESSAGE"; cat CHANGELOG.md; } \
      > "$BACKUP_DIR/CHANGELOG.new"
    mv "$BACKUP_DIR/CHANGELOG.new" CHANGELOG.md
  fi
fi

info "flutter pub get"
flutter pub get

# --- commit + tag ----------------------------------------------------------

git add pubspec.yaml
[ -f README.md ] && git add README.md
[ -f CHANGELOG.md ] && git add CHANGELOG.md
[ -f pubspec.lock ] && git add pubspec.lock   # pub get may refresh it

if git diff --cached --quiet; then
  info "No file changes needed — tagging current HEAD as ${TAG}"
else
  info "Committing release v${NEXT_VERSION}"
  git commit -m "chore(${PACKAGE}): release v${NEXT_VERSION}"
  MADE_COMMIT=1
fi

git tag -a "$TAG" -m "${PACKAGE} v${NEXT_VERSION}"
PHASE="committed"

# --- validate (clean, committed tree) --------------------------------------

info "flutter pub publish --dry-run"
if ! flutter pub publish --dry-run; then
  die "package validation failed — see the output above. Nothing was published."
fi

# Validation passed: from here on we keep the commit + tag.
PHASE="done"

# --- publish / push --------------------------------------------------------

if [ "$LOCAL_PUBLISH" -eq 1 ]; then
  info "Publishing to pub.dev from this machine"
  flutter pub publish --force
  if [ "$NO_PUSH" -eq 0 ]; then
    info "Pushing commit and tag"
    git push origin "HEAD:${BRANCH}"
    git push origin "$TAG"
    warn "the CI publish workflow will run on the pushed tag and fail (version already published) — that is expected with --local-publish."
  else
    warn "--no-push set: commit and tag stay local. Remember: with --local-publish the package is already live on pub.dev."
  fi
elif [ "$NO_PUSH" -eq 1 ]; then
  warn "--no-push set: commit and tag created locally but NOT pushed; no release was published."
  info "Push manually when ready: git push origin HEAD:${BRANCH} && git push origin ${TAG}"
else
  info "Pushing commit and tag (CI will publish to pub.dev)"
  git push origin "HEAD:${BRANCH}"
  git push origin "$TAG"
  info "Watch the publish run: https://github.com/A7ALABS/apple-spatial-capture/actions"
fi

info "Done — ${PACKAGE} v${NEXT_VERSION}"
