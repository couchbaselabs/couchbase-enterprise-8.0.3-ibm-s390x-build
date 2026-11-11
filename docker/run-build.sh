#!/usr/bin/env bash
#
# run-build.sh - run build_couchbase_ee.sh inside a container on an s390x host.
#
#   bash docker/run-build.sh [options for build_couchbase_ee.sh]
#
# Examples:
#   bash docker/run-build.sh                                  # full Enterprise build
#   bash docker/run-build.sh --from build -j 8                # continue an earlier run
#   WORKSPACE=/data/cb bash docker/run-build.sh --prefix /opt/couchbase --package
#
# What it does
#   * builds the image from docker/Dockerfile.ubuntu24.04 (once)
#   * keeps the workspace and the builder's home directory (dependency cache,
#     Go module cache, Rust toolchain) in host directories, so the build can be
#     stopped and resumed and the result survives the container
#   * gives the container access to GitHub for the private repositories:
#     your ssh-agent if one is running (CB_GIT_AUTH=ssh, the default), or
#     GITHUB_TOKEN if you set CB_GIT_AUTH=https
#
# Environment
#   WORKSPACE         host directory for the build workspace
#                     (default: $HOME/couchbase-s390x-build)
#   BUILDER_HOME      host directory for the container user's home
#                     (default: $WORKSPACE/.builder-home)
#   OPT_COUCHBASE     host directory mounted at /opt/couchbase, for builds with
#                     --prefix /opt/couchbase (default: $WORKSPACE/opt-couchbase)
#   CONTAINER_ENGINE  docker or podman (default: whichever is installed)
#   IMAGE             image name (default: couchbase-s390x-builder)
#   PLATFORM          e.g. linux/s390x to force emulation on another architecture
#
set -euo pipefail

case "${1:-}" in
    -h|--help)
        awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"
        echo "Options are passed on to build_couchbase_ee.sh; see: bash build_couchbase_ee.sh --help"
        exit 0 ;;
esac

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="${WORKSPACE:-$HOME/couchbase-s390x-build}"
BUILDER_HOME="${BUILDER_HOME:-$WORKSPACE/.builder-home}"
OPT_COUCHBASE="${OPT_COUCHBASE:-$WORKSPACE/opt-couchbase}"
IMAGE="${IMAGE:-couchbase-s390x-builder}"
ENGINE="${CONTAINER_ENGINE:-}"
if [ -z "$ENGINE" ]; then
    if command -v docker >/dev/null 2>&1; then ENGINE=docker
    elif command -v podman >/dev/null 2>&1; then ENGINE=podman
    else echo "ERROR: neither docker nor podman is installed" >&2; exit 1
    fi
fi

platform_args=()
[ -n "${PLATFORM:-}" ] && platform_args=(--platform "$PLATFORM")

if [ "$(uname -m)" != "s390x" ] && [ -z "${PLATFORM:-}" ]; then
    echo "ERROR: this host is $(uname -m). Run on an s390x host, or set PLATFORM=linux/s390x" >&2
    echo "       to use emulation (very slow; useful only for trying the first stages)." >&2
    exit 1
fi

mkdir -p "$WORKSPACE" "$BUILDER_HOME" "$OPT_COUCHBASE"

if ! "$ENGINE" image inspect "$IMAGE" >/dev/null 2>&1; then
    "$ENGINE" build "${platform_args[@]}" \
        --build-arg BUILD_UID="$(id -u)" --build-arg BUILD_GID="$(id -g)" \
        -t "$IMAGE" -f "$KIT_ROOT/docker/Dockerfile.ubuntu24.04" "$KIT_ROOT/docker"
fi

run_args=(--rm -i
    -v "$KIT_ROOT:/kit:ro"
    -v "$WORKSPACE:/workspace"
    -v "$BUILDER_HOME:/home/builder"
    -v "$OPT_COUCHBASE:/opt/couchbase"
    -e CB_GIT_AUTH="${CB_GIT_AUTH:-ssh}"
)
[ -t 0 ] && run_args+=(-t)
# podman: keep the invoking user's uid inside the container so the mounts stay writable
[ "$ENGINE" = "podman" ] && run_args+=(--userns=keep-id)

if [ "${CB_GIT_AUTH:-ssh}" = "ssh" ]; then
    if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
        run_args+=(-v "$SSH_AUTH_SOCK:/ssh-agent" -e SSH_AUTH_SOCK=/ssh-agent)
    else
        echo "NOTE: no ssh-agent found. Start one and add a key that can read the private"
        echo "      Couchbase repositories (eval \"\$(ssh-agent)\"; ssh-add), or put a key in"
        echo "      $BUILDER_HOME/.ssh/ - otherwise the Enterprise source sync will fail."
    fi
else
    # Pass the token by name only, so its value never appears in a command line.
    run_args+=(-e GITHUB_TOKEN)
fi

exec "$ENGINE" run "${platform_args[@]}" "${run_args[@]}" "$IMAGE" \
    bash /kit/build_couchbase_ee.sh --workdir /workspace "$@"
