#!/usr/bin/env bash
#
# Build the three EMERSE images (database, solr, tomcat) for linux/amd64 + linux/arm64 and,
# with PUSH=1, push them to the CHI registry. Runs on a dev machine after ./download.sh;
# escher only pulls, so it needs neither this checkout nor GitHub credentials.
#
#   ./build.sh                     build only, nothing leaves this machine
#   PUSH=1 ./build.sh              build and push $VERSION, $VERSION-g$SHA and latest
#   PRERELEASE=1 PUSH=1 ./build.sh push only $VERSION-g$SHA
#
# $VERSION (the VERSION file, year.month.release) names this repo's release of all three
# images together; escher's .env pins it as TAG. A release push needs the git tag
# v$VERSION on the commit being built, so a version names one build and never moves.
# The EMERSE release inside is EMERSE_VERSION in download.sh, recorded as the
# org.emerse.version label.
#
# Requires a one-time `podman login chi-tools.uc.edu` before pushing.
#
# Environment overrides:
#   REGISTRY    registry host           (default chi-tools.uc.edu)
#   PLATFORMS   comma-separated targets (default linux/amd64,linux/arm64)
#   IMAGES      which to build          (default "database solr tomcat")
#   PUSH        set to 1 to push
#   PRERELEASE  set to 1 to push only the $VERSION-g$SHA tag
#   FORCE       set to 1 to allow pushing from a dirty working tree
#
set -euo pipefail
cd "$(dirname "$0")"

REGISTRY=${REGISTRY:-chi-tools.uc.edu}
PLATFORMS=${PLATFORMS:-linux/amd64,linux/arm64}
IMAGES=${IMAGES:-database solr tomcat}

VERSION=$(cat VERSION)
[[ $VERSION =~ ^20[0-9]{2}\.(1[0-2]|[1-9])\.[1-9][0-9]*$ ]] || { echo "build.sh: VERSION must be year.month.release, got '$VERSION'" >&2; exit 1; }
# the release download.sh fetches
EMERSE_VERSION=$(sed -n 's/^EMERSE_VERSION=//p' download.sh)
REVISION=$(git rev-parse --short HEAD 2>/dev/null || echo uncommitted)
git diff --quiet HEAD -- . 2>/dev/null && [[ -z $(git status --porcelain -- .) ]] || REVISION="${REVISION}-dirty"

for f in emerse.war fresh-install-v$EMERSE_VERSION.maria.sql solr-plugin-$EMERSE_VERSION.jar solrconfig.xml mariadb-java-client.jar solr-home/solr.xml; do
  [[ -e assets/$f ]] || { echo "build.sh: missing assets/$f: run ./download.sh" >&2; exit 1; }
done

if ! command -v podman >/dev/null 2>&1; then
  echo "build.sh: podman is required for multi-arch builds" >&2
  exit 1
fi
ENGINE=podman

for NAME in $IMAGES; do
  IMAGE="${REGISTRY}/emerse-${NAME}"

  # A manifest list left over from a previous run is added to, not replaced, so
  # stale per-arch entries would accumulate. Start clean.
  $ENGINE manifest rm "${IMAGE}:${VERSION}" 2>/dev/null || true

  # Every Dockerfile takes the repo root as its context (see .dockerignore).
  $ENGINE build --pull=newer \
    --platform "$PLATFORMS" \
    --manifest "${IMAGE}:${VERSION}" \
    --build-arg EMERSE_VERSION="$EMERSE_VERSION" \
    --label org.opencontainers.image.version="$VERSION" \
    --label org.emerse.version="$EMERSE_VERSION" \
    --label org.opencontainers.image.revision="$REVISION" \
    --label org.opencontainers.image.created="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    -f "${NAME}/Dockerfile" \
    .

  # Tagging a manifest list gives the same list another name, so all three tags
  # stay multi-arch.
  $ENGINE tag "${IMAGE}:${VERSION}" "${IMAGE}:${VERSION}-g${REVISION}" "${IMAGE}:latest"
done

echo
for NAME in $IMAGES; do
  echo "built ${REGISTRY}/emerse-${NAME}:${VERSION}, :${VERSION}-g${REVISION}, :latest"
done
echo "(EMERSE ${EMERSE_VERSION})"

if [[ ${PUSH:-0} != 1 ]]; then
  echo
  echo "not pushed (set PUSH=1 to push to ${REGISTRY})"
  exit 0
fi

if [[ "$REVISION" == *-dirty || "$REVISION" == uncommitted* ]] && [[ ${FORCE:-0} != 1 ]]; then
  echo >&2
  echo "build.sh: refusing to push a build from a dirty working tree." >&2
  echo "          Commit first, or set FORCE=1 to override." >&2
  exit 1
fi

if [[ ${PRERELEASE:-0} == 1 ]]; then
  TAGS=("${VERSION}-g${REVISION}")
  echo "prerelease: pushing only ${VERSION}-g${REVISION}"
else
  # Released versions are immutable: the tag must exist and name this commit. A tag on
  # another commit means VERSION was not bumped since that release.
  TAGGED=$(git rev-parse -q --verify "refs/tags/v${VERSION}^{commit}" || true)
  if [[ -z "$TAGGED" ]]; then
    echo "build.sh: no git tag v${VERSION}. Tag this commit first:" >&2
    echo "          git tag -a v${VERSION} -m v${VERSION} && git push origin v${VERSION}" >&2
    exit 1
  elif [[ "$TAGGED" != "$(git rev-parse HEAD)" ]]; then
    echo "build.sh: v${VERSION} is already released at $(git rev-parse --short "$TAGGED")." >&2
    echo "          Bump VERSION for a new release, or use PRERELEASE=1." >&2
    exit 1
  fi
  TAGS=("${VERSION}" "${VERSION}-g${REVISION}" latest)
fi

# --all is required: without it only the index is pushed and the per-arch
# manifests it references can be missing from the registry.
for NAME in $IMAGES; do
  IMAGE="${REGISTRY}/emerse-${NAME}"
  for TAG in "${TAGS[@]}"; do
    echo "pushing ${IMAGE}:${TAG}"
    $ENGINE manifest push --all "${IMAGE}:${VERSION}" "docker://${IMAGE}:${TAG}"
  done
done

# Advisory only, as in Tools/monitor: proves each tag exists, not that its per-arch
# manifests are all present, and a registry hiccup here must not fail a good push.
echo
echo "verifying against ${REGISTRY}…"
for NAME in $IMAGES; do
  IMAGE="${REGISTRY}/emerse-${NAME}"
  if REMOTE=$($ENGINE search --list-tags "${IMAGE}" 2>/dev/null) && [[ -n "$REMOTE" ]]; then
    for TAG in "${TAGS[@]}"; do
      if grep -qE "[[:space:]]${TAG}\$" <<<"$REMOTE"; then
        echo "  ok      emerse-${NAME}:${TAG}"
      else
        echo "  MISSING emerse-${NAME}:${TAG}"
      fi
    done
  else
    echo "  could not reach ${REGISTRY} to verify emerse-${NAME}; the push itself succeeded"
  fi
done
