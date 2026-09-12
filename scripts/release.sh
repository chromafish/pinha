#!/usr/bin/env bash
#
# Packages a production release from a tag.
#
#     scripts/release.sh v0.1.0
#     scripts/release.sh v0.1.0 --out /tmp/builds
#
# Checks the tag out, builds it with MIX_ENV=prod, and writes the tarball, its
# SHA-256, and a manifest naming the revision, the toolchain, and the
# platform. The repo is left at the tag.
#
# Packaging is all it does: whatever runs it is responsible for having run the
# suite. A release carries the BEAM it was built against, so it runs on the OS
# and architecture it was built on and no other.

set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() {
  printf 'release: %s\n' "$1" >&2
  exit 1
}

step() {
  printf '\n\033[1m==> %s\033[0m\n' "$1"
}

usage() {
  sed -n '3,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

TAG=""
OUT="$ROOT/dist"

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help) usage 0 ;;
    --out)
      shift
      [ $# -gt 0 ] || die "--out needs a directory"
      OUT="$1"
      ;;
    -*) die "unknown option: $1" ;;
    *)
      [ -z "$TAG" ] || die "one tag at a time (got '$TAG' and '$1')"
      TAG="$1"
      ;;
  esac
  shift
done

[ -n "$TAG" ] || usage 1

# The tag names the release; the version inside it is the project version, so
# `v0.1.0` and `0.1.0` package the same thing.
VERSION="${TAG#v}"

command -v mix >/dev/null || die "mix is not on PATH"
command -v git >/dev/null || die "git is not on PATH"

cd "$ROOT"

step "Checking out $TAG"

git rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null ||
  die "no tag $TAG in this repo"

git checkout --detach --quiet "refs/tags/$TAG"

REVISION="$(git rev-parse HEAD)"
printf '%s is %s\n' "$TAG" "$REVISION"

PROJECT_VERSION="$(sed -n 's/^ *version: "\([^"]*\)".*/\1/p' mix.exs | head -1)"

[ "$PROJECT_VERSION" = "$VERSION" ] ||
  die "$TAG does not match the version in mix.exs at that tag ($PROJECT_VERSION)"

step "Building $TAG"

# config/runtime.exs is evaluated by Mix for this build and again by the
# release at boot. These stand in for the first evaluation only: nothing
# computed here reaches the artifact, which reads the real environment when an
# operator starts it.
export SECRET_KEY_BASE="${SECRET_KEY_BASE:-$(printf '%064d' 0)}"
export DATABASE_URL="${DATABASE_URL:-postgresql://build:build@localhost/build}"
export MIX_ENV=prod

mix deps.get --only prod
mix compile --warnings-as-errors
mix release --overwrite

TARBALL="$ROOT/_build/prod/pinha-$VERSION.tar.gz"

if [ ! -f "$TARBALL" ]; then
  # Both the name and the tar step come from the `releases:` block in mix.exs,
  # so a tag from before that block was added builds a directory under a stale
  # version and stops here.
  FOUND="$(ls "$ROOT"/_build/prod/pinha-*.tar.gz 2>/dev/null | head -1 || true)"
  [ -z "$FOUND" ] || die "expected pinha-$VERSION.tar.gz, found $(basename "$FOUND")"

  die "no tarball at $TARBALL: does mix.exs at $TAG carry releases/0 with the tar step?"
fi

step "Packaging"

mkdir -p "$OUT"
ARTIFACT="$OUT/pinha-$VERSION.tar.gz"
cp "$TARBALL" "$ARTIFACT"

if command -v sha256sum >/dev/null; then
  (cd "$OUT" && sha256sum "pinha-$VERSION.tar.gz" > "pinha-$VERSION.tar.gz.sha256")
else
  (cd "$OUT" && shasum -a 256 "pinha-$VERSION.tar.gz" > "pinha-$VERSION.tar.gz.sha256")
fi

CHECKSUM="$(cut -d' ' -f1 < "$ARTIFACT.sha256")"

cat > "$OUT/pinha-$VERSION.manifest.txt" <<MANIFEST
name        pinha
tag         $TAG
version     $VERSION
revision    $REVISION
built       $(date -u +%Y-%m-%dT%H:%M:%SZ)
platform    $(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)
elixir      $(elixir --version | sed -n 's/^Elixir \([^ ]*\).*/\1/p')
erlang      $(erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().')
sha256      $CHECKSUM
MANIFEST

step "Done"

cat "$OUT/pinha-$VERSION.manifest.txt"

cat <<NEXT

Artifacts in $OUT:

  pinha-$VERSION.tar.gz
  pinha-$VERSION.tar.gz.sha256
  pinha-$VERSION.manifest.txt
NEXT
