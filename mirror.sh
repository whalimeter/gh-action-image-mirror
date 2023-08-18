#!/bin/sh

# Failsafe mode: stop on errors and unset vars
set -eu

# Root directory where this script is located
MIRROR_ROOTDIR=${MIRROR_ROOTDIR:-"$( cd -P -- "$(dirname -- "$(command -v -- "$0")")" && pwd -P )"}

# Target registry and path, default to the GHCR
MIRROR_REGISTRY=${MIRROR_REGISTRY:-"ghcr.io"}

# Regular expression matching the tags of the image(s) that we want to mirror
MIRROR_TAGS=${MIRROR_TAGS:-'[0-9]+(\.[0-9]+)+$'}

# Do not perform operation, just print what would be done on stderr
MIRROR_DRYRUN=${MIRROR_DRYRUN:-0}

# Minimum version that the image at the Hub must have to be downloaded and
# mirrored.
MIRROR_MINVER=${MIRROR_MINVER:-"0.0.0"}

# Verbosity level
MIRROR_VERBOSE=${MIRROR_VERBOSE:-0}

usage() {
  # This uses the comments behind the options to show the help. Not extremly
  # correct, but effective and simple.
  echo "$0 mirrors docker images from the Docker Hub to another registry" && \
    grep "[[:space:]].)\ #" "$0" |
    sed 's/#//' |
    sed -r 's/([a-z-])\)/-\1/'
  printf \\nEnvironment:\\n
  set | grep '^MIRROR_' | sed 's/^MIRROR_/    MIRROR_/g'
  exit "${1:-0}"
}

while getopts "m:nr:t:vh-" opt; do
  case "$opt" in
    r) # Root of the target registry
      MIRROR_REGISTRY="$OPTARG";;
    t) # Regular expression for tags to mirror
      MIRROR_TAGS="$OPTARG";;
    m) # Minimum version, older version will not be mirrored
      MIRROR_MINVER="$OPTARG";;
    n) # Do not perform operations
      MIRROR_DRYRUN=1;;
    -) # End of options, everything are the names of the images to mirror
      break;;
    v) # Turn on verbosity, will otherwise log on errors/warnings only
      MIRROR_VERBOSE=1;;
    h) # Print help and exit
      usage;;
    ?)
      usage 1;;
  esac
done
shift $((OPTIND-1))

# PML: Poor Man's Logging
_log() {
    printf '[%s] [%s] [%s] %s\n' \
      "$(basename "$0")" \
      "${2:-LOG}" \
      "$(date +'%Y%m%d-%H%M%S')" \
      "${1:-}" \
      >&2
}
# shellcheck disable=SC2015 # We are fine, this is just to never fail
trace() { [ "$MIRROR_VERBOSE" -ge "2" ] && _log "$1" DBG || true ; }
# shellcheck disable=SC2015 # We are fine, this is just to never fail
verbose() { [ "$MIRROR_VERBOSE" -ge "1" ] && _log "$1" NFO || true ; }
warn() { _log "$1" WRN; }
error() { _log "$1" ERR && exit 1; }

# Check the commands passed as parameters are available and exit on errors.
check_command() {
  for cmd; do
    if ! command -v "$cmd" >/dev/null; then
      error "$cmd not available. This is a stringent requirement. Cannot continue!"
    fi
  done
}

_json_field() {
  grep -F "\"$1\"" |
    head -n 1 |
    sed -E "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\\1/"
}

platforms() {
  _arch=
  _os=
  _variant=
  while IFS= read -r line; do
    case "$line" in
      *architecture*) _arch=$(printf %s\\n "$line" | _json_field architecture);;
      *os*) _os=$(printf %s\\n "$line" | _json_field os);;
      *variant*) _variant=$(printf %s\\n "$line" | _json_field variant);;
      *"}"*)
        if [ -n "$_arch" ] && [ -n "$_os" ] && [ -n "$_variant" ]; then
          printf %s\\n "$_os/$_arch/$_variant"
        elif [ -n "$_arch" ] && [ -n "$_os" ]; then
          printf %s\\n "$_os/$_arch"
        fi
        _arch=
        _os=
        _variant=
        ;;
    esac
  done <<EOF
$(docker manifest inspect "$1" | grep -E '("(architecture|os|variant)"|})')
EOF
}

digests() {
  while IFS= read -r line; do
    printf %s\\n "$line" | _json_field digest
  done <<EOF
$(docker manifest inspect "$1" | grep -E '"digest"')
EOF
}

mirror() {
  notag=${1%:*}
  tag=${1##*:}

  # Decide upon name of destination image. When the destination registry has
  # a slash, just use the tail (name) of the image and prepend the registry
  # path.
  if printf %s\\n "$MIRROR_REGISTRY" | grep -qF '/'; then
    name=${notag##*/}
    destimg=${MIRROR_REGISTRY%/}/$name
  else
    rootless=${notag#*/}
    destimg=${MIRROR_REGISTRY%/}/$rootless
  fi

  verbose "Mirroring $1 to $destimg:$tag"

  verbose "Discovering platforms for ${1}..."
  _manifest=$(mktemp -t manifest.XXXXXX)
  docker manifest inspect "$1" > "$_manifest"

  if grep -qF 'distribution.manifest.list' "$_manifest"; then
    verbose "$1 is a multi-platform image, pushing one platform at a time"
    platforms "$1" < "$_manifest" | while IFS= read -r platform; do
      verbose "Fetching $1 at $platform"
      docker image pull --platform "$platform" "$1"
      platform_id=$(printf %s\\n "$platform" | tr '/' '-')
      verbose "Pushing $1 at $platform as $destimg:${tag}-$platform_id"
      docker image tag "$1" "$destimg:${tag}-$platform_id"
      if [ "$MIRROR_DRYRUN" = 1 ]; then
        verbose "Would push image $destimg:${tag}-$platform_id"
      else
        docker image push "$destimg:${tag}-$platform_id"
      fi

      if [ "$MIRROR_DRYRUN" = 1 ]; then
        verbose "Would add $destimg:${tag}-$platform_id to manifest $destimg:$tag"
      else
        verbose "Adding $destimg:${tag}-$platform_id to manifest $destimg:$tag"
        docker manifest create --amend "$destimg:$tag" "$destimg:${tag}-$platform_id"
      fi
    done

    verbose "Pushing manifest $destimg:$tag"
    docker manifest push "$destimg:$tag"
  else
    verbose "$1 is a single-platform image"
    docker image pull "$1"
    docker image tag "$1" "$destimg:$tag"
    if [ "$MIRROR_DRYRUN" = 1 ]; then
      verbose "Would push image $destimg:$tag"
    else
      verbose "Pushing image $destimg:$tag"
      docker image push "$destimg:$tag"
    fi
  fi

  # Cleanup
  rm -f "$_manifest"
  if [ "$MIRROR_DRYRUN" = 1 ]; then
    verbose "Would remove image $destimg:$tag"
  else
    docker image rm -f "$destimg:$tag"
  fi
}

mirror_images() {
  resolved=$(img_canonicalize "$1")
  if [ "${resolved%%/*}" != "docker.io" ]; then
    error "$1 is not at the Docker Hub"
  fi

  rootimg=${1##*/}
  tag=${rootimg#*:}

  if printf %s\\n "$rootimg" | grep -Fq ':'; then
    mirror "$1"
  else
    verbose "Collecting tags matching $MIRROR_TAGS for $1"
    for tag in $(img_tags --filter "$MIRROR_TAGS" -- "$1"); do
      semver=$(printf %s\\n "$tag" | grep -oE '[0-9]+(\.[0-9]+)+')
      if [ "$(img_version "$semver")" -ge "$(img_version "$MIRROR_MINVER")" ]; then
        notag=${resolved%:*}
        mirror "${notag}:$tag"
      else
        verbose "Discarding version $semver, older than $MIRROR_MINVER"
      fi
    done
  fi
}

# Source Docker Hub image API library
# shellcheck disable=SC1091 # Comes as a submodule
. "${MIRROR_ROOTDIR}/reg-tags/image_api.sh"

# Verify we have the docker client
check_command docker

while [ "$#" -gt 0 ]; do
  mirror "$1"
  shift
done
