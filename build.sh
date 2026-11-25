#!/usr/bin/env bash
#
# Build the EMERSE images: database, solr, tomcat, loader (linux/amd64 + linux/arm64) with Apple's `container` and, with PUSH=1,
# push it to the CHI registry.
#
#   ./build.sh                      build only, nothing leaves this machine
#   PUSH=1 ./build.sh               build, scan, and push $VERSION, $VERSION-g$SHA and latest
#   PRERELEASE=1 PUSH=1 ./build.sh  push only $VERSION-g$SHA
#
# VERSION holds the version of all the images together; escher's .env pins it as TAG.
#
# One-time setup: `container registry login chi-tools.uc.edu` from a desktop terminal and
# `skopeo login chi-tools.uc.edu`. Pushing also needs trivy (scan) and syft (SBOM).
#
# Runs on a dev machine after ./download.sh; escher only pulls, so it needs neither this
# checkout nor GitHub credentials.
#
# $VERSION is year.month.release. A release push needs the git tag v$VERSION on the commit
# being built, so a version names one build and never moves. The EMERSE release inside is
# EMERSE_VERSION in download.sh, recorded as the org.emerse.version label.
#
# Environment overrides:
#   REGISTRY       registry host           (default chi-tools.uc.edu)
#   PLATFORMS      comma-separated targets (default linux/amd64,linux/arm64)
#   IMAGES         which to build          (default "database solr tomcat loader")
#   PUSH           set to 1 to scan and push
#   PRERELEASE     set to 1 to push only the $VERSION-g$SHA tag
#   FORCE          set to 1 to allow pushing from a dirty working tree
#   SCAN           block (default) or warn, for fixable HIGH/CRITICAL findings
#   NO_CACHE       set to 1 to rebuild every layer
#   LOAD           set to podman to copy the image into podman's store too
#   PUSH_ATTEMPTS  tries per tag            (default 4)
#
set -euo pipefail
cd "$(dirname "$0")"

read -ra IMAGE_LIST <<<"${IMAGES:-database solr tomcat loader}"
NAMES=("${IMAGE_LIST[@]/#/emerse-}")
VERSION=$(<VERSION)
VERSION_SOURCE=VERSION
CONTEXT=.
SOURCE=.
OUT=build
PULL=1

# the release download.sh fetches
EMERSE_VERSION=$(sed -n 's/^EMERSE_VERSION=//p' download.sh)
EXTRA_ARGS=(
  --build-arg EMERSE_VERSION="$EMERSE_VERSION"
  --label org.emerse.version="$EMERSE_VERSION"
)

# every Dockerfile takes the repo root as its context (see .dockerignore)
dockerfile_for() { echo "${1#emerse-}/Dockerfile"; }

preflight() {
  local f
  [[ $VERSION =~ ^20[0-9]{2}\.(1[0-2]|[1-9])\.[1-9][0-9]*$ ]] || die "VERSION must be year.month.release, got '$VERSION'"
  for f in emerse.war "fresh-install-v$EMERSE_VERSION.maria.sql" "solr-plugin-$EMERSE_VERSION.jar" solrconfig.xml mariadb-java-client.jar solr-home/solr.xml; do
    [[ -e assets/$f ]] || die "missing assets/$f: run ./download.sh"
  done
}

# The tag must exist and name this commit. A tag on another commit means VERSION was not
# bumped since that release.
release_check() {
  local tagged
  tagged=$(git rev-parse -q --verify "refs/tags/v${VERSION}^{commit}" || true)
  [[ -n $tagged ]] || die "no git tag v${VERSION}. Tag this commit first:
          git tag -a v${VERSION} -m v${VERSION} && git push origin v${VERSION}"
  [[ $tagged == "$(git rev-parse HEAD)" ]] ||
    die "v${VERSION} is already released at $(git rev-parse --short "$tagged"). Bump VERSION for a new release, or use PRERELEASE=1."
}

# ======== canonical body: edit chi-platform's build-sh/template.sh, then sync.sh ========
#
# Everything from the marker above to the end of the file is identical in every CHI
# build.sh. The settings above it are this repository's own:
#
#   NAMES           image names under $REGISTRY, usually one
#   VERSION         the release being built, and VERSION_SOURCE, where to bump it
#   CONTEXT         build context
#   SOURCE          what counts as "the source" when deciding whether the tree is dirty
#   OUT             scratch directory for SBOMs; ignored by git and by the build
#   PULL            1 to refresh base images on every build
#   EXTRA_ARGS      more `container build` flags
#
# and, optionally, these functions: dockerfile_for NAME, preflight (before anything is
# built), release_check (before a release push), prepare (just before the build).

REGISTRY=${REGISTRY:-chi-tools.uc.edu}
PLATFORMS=${PLATFORMS:-linux/amd64,linux/arm64}
PUSH=${PUSH:-0}
PRERELEASE=${PRERELEASE:-0}
FORCE=${FORCE:-0}
SCAN=${SCAN:-block}
NO_CACHE=${NO_CACHE:-0}
LOAD=${LOAD:-}
PUSH_ATTEMPTS=${PUSH_ATTEMPTS:-4}

die() { echo "build.sh: $*" >&2; exit 1; }
warn() { echo "build.sh: warning: $*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required${2:+ $2}"; }
defined() { declare -F "$1" >/dev/null; }
over_ssh() { [[ -n ${SSH_CONNECTION:-}${SSH_TTY:-} ]]; }
sha256() { shasum -a 256 | cut -d' ' -f1; }
host_platform() { case $(uname -m) in arm64|aarch64) echo linux/arm64 ;; *) echo linux/amd64 ;; esac; }
defined dockerfile_for || dockerfile_for() { echo "${CONTEXT}/Dockerfile"; }

# --- Checks: everything that can fail without building, before building --------------

need jq
need container "(Apple's container tool)"
[[ $VERSION =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ && $VERSION != null ]] ||
  die "'${VERSION}' from ${VERSION_SOURCE} is not usable as an image tag"
[[ $SCAN == block || $SCAN == warn ]] || die "SCAN must be block or warn, not '${SCAN}'"
[[ -z $LOAD || $LOAD == podman ]] || die "LOAD must be podman or unset, not '${LOAD}'"
[[ $PUSH_ATTEMPTS =~ ^[1-9][0-9]*$ ]] || die "PUSH_ATTEMPTS must be a positive number"

IFS=, read -ra PLATFORM_LIST <<<"$PLATFORMS"
has_platform() { local p; for p in "${PLATFORM_LIST[@]}"; do [[ $p == "$1" ]] && return 0; done; return 1; }

# Untracked files count: COPY ships them, so a clean `git diff` alone would label an image
# holding a stray file with a commit that doesn't contain it. The status is read into a
# variable first so that git failing stops the script instead of reading as "clean".
REVISION=$(git rev-parse --short HEAD)
STATUS=$(git status --porcelain -- "$SOURCE")
[[ -z $STATUS ]] || REVISION="${REVISION}-dirty"

# The -g<sha> tag names one commit. The registry's cleanup job recognises exactly
# X.Y.Z and X.Y.Z-g<sha>, and keeps anything else forever.
REVISION_TAG="${VERSION}-g${REVISION}"

# Ask the apiserver itself. Over SSH, `container system status` looks in launchd's
# user/<uid> domain and says "not running" when it is running in gui/<uid>.
container list --quiet >/dev/null 2>&1 ||
  die "container's services are not running. From a desktop terminal: container system start"

# Never start services from SSH: they would land in the wrong launchd domain, without
# access to the login keychain. `container build` starts a stopped builder by itself.
if over_ssh; then
  BUILDER=$(container builder status --format json 2>/dev/null | jq -r '.[0].status.state // empty' 2>/dev/null) || BUILDER=
  [[ $BUILDER == running ]] ||
    die "the builder is not running. From a desktop terminal: container builder start"
fi

[[ $LOAD != podman ]] || need podman "for LOAD=podman"
if defined preflight; then preflight; fi

# 0 if the reference exists, 1 if the registry says it does not; anything else is fatal,
# because "could not ask" must not be read as "does not exist".
in_registry() {
  local out
  if out=$(skopeo inspect --raw "docker://$1" 2>&1); then return 0; fi
  grep -qiE 'manifest unknown|name unknown' <<<"$out" || die "could not check $1 in the registry: ${out}"
  return 1
}

if [[ $PUSH == 1 ]]; then
  [[ $REVISION != *-dirty || $FORCE == 1 ]] ||
    die "refusing to push from a dirty working tree. Commit first, or set FORCE=1."
  for t in skopeo trivy syft; do need "$t" "to push"; done
  REGISTRY_HOST=${REGISTRY%%/*}
  grep -qxF -- "$REGISTRY_HOST" <<<"$(container registry list --quiet 2>/dev/null)" ||
    die "not logged in: container registry login ${REGISTRY_HOST}"
  skopeo login --get-login "$REGISTRY_HOST" >/dev/null 2>&1 ||
    die "not logged in: skopeo login ${REGISTRY_HOST}"
  [[ -n $(git branch --remotes --contains HEAD 2>/dev/null) ]] ||
    warn "${REVISION} is on no remote branch; the image will name a commit nobody else can find"
  if [[ $PRERELEASE != 1 ]]; then
    if defined release_check; then release_check; fi
    for NAME in "${NAMES[@]}"; do
      if in_registry "${REGISTRY}/${NAME}:${VERSION}"; then
        die "${REGISTRY}/${NAME}:${VERSION} already exists, and released versions are never replaced. Bump ${VERSION_SOURCE}, or use PRERELEASE=1."
      fi
    done
  fi
fi

# --- Scan databases: before building, so that a failed download costs no build --------

# Trivy's databases last about a day. A VPN that carries only IPv4 can leave this machine
# with IPv6 addresses that go nowhere, and trivy does not always fall back; a container has
# no IPv6 route, so the same download is retried in one. An expired database is never used.
TRIVY_SKIP=()
refresh_db() {
  local flag=$1 attempt version
  for attempt in 1 2 3; do
    if trivy image --quiet "$flag"; then return 0; fi
    (( attempt == 3 )) || sleep $((attempt * 2))
  done
  warn "trivy could not download its database (${flag}); trying from a container"
  version=$(trivy version --format json | jq -r .Version)
  mkdir -p "$TRIVY_CACHE_DIR"
  container run --rm --progress none --volume "${TRIVY_CACHE_DIR}:/cache" "docker.io/aquasec/trivy:${version}" \
    image --quiet --cache-dir /cache "$flag" ||
    die "trivy could not download its database (${flag}). Nothing was built."
}

if [[ $PUSH == 1 ]]; then
  # trivy's own default on macOS, named so that the container writes to the same place.
  export TRIVY_CACHE_DIR=${TRIVY_CACHE_DIR:-$HOME/Library/Caches/trivy}
  refresh_db --download-db-only
  TRIVY_SKIP+=(--skip-db-update)
  # Only images that contain Java need this one, and it is large: refreshed if it is in
  # use here, and otherwise left to the scan.
  if [[ -d $TRIVY_CACHE_DIR/java-db ]]; then
    refresh_db --download-java-db-only
    TRIVY_SKIP+=(--skip-java-db-update)
  fi
fi

# --- Build ---------------------------------------------------------------------------

WORK=$(mktemp -d "${TMPDIR:-/tmp}/build-sh.XXXXXX")
trap 'rm -rf -- "${WORK:?}"' EXIT

if defined prepare; then prepare; fi

ARGS=()
for p in "${PLATFORM_LIST[@]}"; do ARGS+=(--platform "$p"); done
[[ $PULL != 1 ]] || ARGS+=(--pull)
[[ $NO_CACHE != 1 ]] || ARGS+=(--no-cache)
CREATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ARGS+=(
  --build-arg VERSION="$VERSION" --build-arg REVISION="$REVISION" --build-arg CREATED="$CREATED"
  --label org.opencontainers.image.version="$VERSION"
  --label org.opencontainers.image.revision="$REVISION"
  --label org.opencontainers.image.created="$CREATED"
)

for NAME in "${NAMES[@]}"; do
  IMAGE="${REGISTRY}/${NAME}"
  echo "building ${IMAGE}:${VERSION} @ ${REVISION} (${PLATFORMS})"
  container build "${ARGS[@]}" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} \
    -f "$(dockerfile_for "$NAME")" -t "${IMAGE}:${VERSION}" "$CONTEXT"
  for TAG in "$REVISION_TAG" latest; do container image tag "${IMAGE}:${VERSION}" "${IMAGE}:${TAG}" >/dev/null; done
done

echo
for NAME in "${NAMES[@]}"; do
  for TAG in "$VERSION" "$REVISION_TAG" latest; do echo "built ${REGISTRY}/${NAME}:${TAG}"; done
done

# container keeps its images in its own store, where podman cannot see them.
if [[ $LOAD == podman ]]; then
  LOAD_PLATFORM=$(host_platform)
  has_platform "$LOAD_PLATFORM" || LOAD_PLATFORM=${PLATFORM_LIST[0]}
  for NAME in "${NAMES[@]}"; do
    IMAGE="${REGISTRY}/${NAME}"
    echo "loading ${IMAGE} (${LOAD_PLATFORM}) into podman"
    container image save --platform "$LOAD_PLATFORM" -o "${WORK}/load.tar" "${IMAGE}:${VERSION}" >/dev/null
    podman load --quiet --input "${WORK}/load.tar" >/dev/null
    podman tag "${IMAGE}:${VERSION}" "${IMAGE}:${REVISION_TAG}" "${IMAGE}:latest"
    rm -f -- "${WORK}/load.tar"
  done
fi

if [[ $PUSH != 1 ]]; then
  echo
  echo "not pushed (set PUSH=1 to push to ${REGISTRY})"
  exit 0
fi

# --- Scan: every image, before any is pushed -----------------------------------------

# amd64 is what our servers run.
SCAN_PLATFORM=linux/amd64
has_platform "$SCAN_PLATFORM" || SCAN_PLATFORM=${PLATFORM_LIST[0]}
SBOM_TAG=$VERSION
[[ $PRERELEASE != 1 ]] || SBOM_TAG=$REVISION_TAG
mkdir -p "$OUT"
BLOCKED=()
for NAME in "${NAMES[@]}"; do
  IMAGE="${REGISTRY}/${NAME}"
  LAYOUT="${WORK}/${NAME}"
  echo
  echo "scanning ${IMAGE}:${VERSION} (${SCAN_PLATFORM})"
  container image save --platform "$SCAN_PLATFORM" -o "${LAYOUT}.tar" "${IMAGE}:${VERSION}" >/dev/null
  mkdir "$LAYOUT"
  tar -xf "${LAYOUT}.tar" -C "$LAYOUT"
  rm -f -- "${LAYOUT}.tar"
  # By default trivy skips language packages that a .deb or .rpm installed, trusting the
  # distro's advisories to cover them. They don't cover third-party packages: Shiny
  # Server's bundles its own Node modules. comprehensive scans those too.
  #
  # 10 is ours; any other failure is trivy's own and is not a finding.
  rc=0
  trivy image --quiet "${TRIVY_SKIP[@]}" --input "$LAYOUT" --detection-priority comprehensive \
    --severity HIGH,CRITICAL --ignore-unfixed --exit-code 10 || rc=$?
  case $rc in
    0) ;;
    10) BLOCKED+=("$NAME") ;;
    *) die "trivy could not scan ${IMAGE} (exit ${rc})" ;;
  esac
  syft -q "oci-dir:${LAYOUT}" -o "spdx-json=${OUT}/${NAME}-${SBOM_TAG}.spdx.json"
  echo "SBOM: ${OUT}/${NAME}-${SBOM_TAG}.spdx.json"
  rm -rf -- "${LAYOUT:?}"
done
if (( ${#BLOCKED[@]} > 0 )); then
  [[ $SCAN == warn ]] ||
    die "fixable HIGH/CRITICAL findings in: ${BLOCKED[*]}. Nothing was pushed.
          NO_CACHE=1 rebuilds with current packages; .trivyignore records accepted findings;
          SCAN=warn pushes anyway, this once."
  warn "pushing despite fixable HIGH/CRITICAL findings in: ${BLOCKED[*]} (SCAN=warn)"
fi

# --- Push ----------------------------------------------------------------------------

# Large blobs sometimes fail mid-upload with an HTTP/2 stream error; a retry resumes
# quickly, because finished blobs are skipped.
push() {
  local ref=$1 attempt
  for (( attempt = 1; attempt <= PUSH_ATTEMPTS; attempt++ )); do
    echo "pushing ${ref}"
    if container image push "$ref"; then return 0; fi
    (( attempt < PUSH_ATTEMPTS )) || break
    warn "push of ${ref} failed (attempt ${attempt}/${PUSH_ATTEMPTS}); retrying in $((attempt * 10))s"
    sleep $((attempt * 10))
  done
  die "could not push ${ref} after ${PUSH_ATTEMPTS} attempts"
}

# PRERELEASE exists so a build can be tested on a real deployment without claiming either
# of the two tags that mean "this is the release".
#
# $VERSION goes last: its presence is what marks the release as done, so a push that
# failed partway can simply be run again.
if [[ $PRERELEASE == 1 ]]; then
  PUSH_TAGS=("$REVISION_TAG")
  echo
  echo "prerelease: pushing only ${REVISION_TAG}"
else
  PUSH_TAGS=("$REVISION_TAG" latest "$VERSION")
fi
echo
for TAG in "${PUSH_TAGS[@]}"; do
  for NAME in "${NAMES[@]}"; do push "${REGISTRY}/${NAME}:${TAG}"; done
done

# --- Verify --------------------------------------------------------------------------

# A failed push has already stopped the script. This catches a push that succeeded at the
# wrong thing: a tag on another build, an index whose per-platform manifests are missing,
# a stale revision label. It lists every remote tag, not just the ones this run pushed,
# so that PRERELEASE quietly moving latest would show. Advisory: a registry hiccup after a
# good push must not fail the script.
verify() {
  local image=$1 want raw got tag p digest revision bad=0
  want=$(container image inspect "${image}:${VERSION}" | jq -r '.[0].configuration.descriptor.digest') || return 1
  for tag in "${PUSH_TAGS[@]}"; do
    raw=${WORK}/manifest.json
    if ! skopeo inspect --raw "docker://${image}:${tag}" >"$raw" 2>/dev/null; then
      echo "  MISSING  ${tag}"; bad=1; continue
    fi
    got="sha256:$(sha256 <"$raw")"
    if [[ $got == "$want" ]]; then echo "  ok       ${tag}  ${got:7:12}"; else echo "  MISMATCH ${tag}  ${got:7:12}, built ${want:7:12}"; bad=1; fi
    for p in "${PLATFORM_LIST[@]}"; do
      digest=$(jq -r --arg p "$p" 'first(.manifests[]? | select("\(.platform.os)/\(.platform.architecture)" as $q | $p == $q or ($p | startswith($q + "/"))) | .digest) // empty' "$raw")
      if [[ -z $digest ]] || ! skopeo inspect --raw "docker://${image}@${digest}" >/dev/null 2>&1; then
        echo "  MISSING  ${tag} ${p}"; bad=1; continue
      fi
      revision=$(skopeo inspect --config "docker://${image}@${digest}" 2>/dev/null | jq -r '.config.Labels["org.opencontainers.image.revision"] // empty') || revision=
      [[ $revision == "$REVISION" ]] || { echo "  MISMATCH ${tag} ${p}: revision label is '${revision}', not '${REVISION}'"; bad=1; }
    done
  done
  echo "  all tags now in the registry:"
  skopeo list-tags "docker://${image}" 2>/dev/null | jq -r '.Tags[] | "    " + .' || bad=1
  return "$bad"
}

for NAME in "${NAMES[@]}"; do
  echo
  echo "verifying ${REGISTRY}/${NAME}"
  verify "${REGISTRY}/${NAME}" ||
    warn "could not confirm ${REGISTRY}/${NAME}; every push reported success, so look before redeploying"
done
