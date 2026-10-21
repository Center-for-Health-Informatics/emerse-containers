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
# $VERSION is the EMERSE release. Our own changes (the Valve, Tomcat config, the lock-down)
# move it without a new release, so the -g$SHA tag is what names one build exactly: pin it
# as TAG in escher's .env to roll back.
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

# the release download.sh fetches
VERSION=7.2.1
REVISION=$(git rev-parse --short HEAD 2>/dev/null || echo uncommitted)
git diff --quiet HEAD -- . 2>/dev/null && [[ -z $(git status --porcelain -- .) ]] || REVISION="${REVISION}-dirty"

for f in emerse.war fresh-install-v$VERSION.maria.sql solr-plugin-$VERSION.jar solrconfig.xml mariadb-java-client.jar solr-home/solr.xml; do
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
    --label org.opencontainers.image.version="$VERSION" \
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
