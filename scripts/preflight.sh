#!/usr/bin/env bash
#
# preflight.sh - check a machine before a Couchbase Server 8.0.3 s390x build.
#
#   --only host     architecture, distribution, CPU/RAM/disk, download hosts
#   --only access   (Enterprise) read access to Couchbase's private repositories
#   (default: both)
#
# The build script runs "host" first and "access" as soon as git is installed.
# It can also be run by hand at any time:
#
#     bash scripts/preflight.sh --edition enterprise --workdir ~/couchbase-s390x-build
#
# Exit status is 0 when nothing blocks the build, 1 otherwise. Warnings do not
# change the exit status.
#
set -uo pipefail

ONLY="all"
EDITION="${CB_EDITION:-enterprise}"
GIT_AUTH="${CB_GIT_AUTH:-ssh}"
WORKDIR="${SOURCE_ROOT:-$HOME/couchbase-s390x-build}"
EXCLUDE="${CB_EXCLUDE_PROJECTS:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --only)      ONLY="$2"; shift 2 ;;
        --edition)   EDITION="$2"; shift 2 ;;
        --git-auth)  GIT_AUTH="$2"; shift 2 ;;
        --workdir)   WORKDIR="$2"; shift 2 ;;
        --exclude)   EXCLUDE="$2"; shift 2 ;;
        -h|--help)   awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

# Private (ssh://git@github.com/couchbase/...) projects in
# released/couchbase-server/8.0.3.xml that an Enterprise build syncs.
PRIVATE_REPOS="backup bhive cbas cbas-core cbbs cbftx eventing-ee gocbcrypto goxdcr hebrew magma plasma query-ee regulator"

FAILURES=0
WARNINGS=0
ok()   { printf '  [ ok ]  %s\n' "$*"; }
note() { printf '  [info]  %s\n' "$*"; }
warn() { printf '  [warn]  %s\n' "$*"; WARNINGS=$((WARNINGS + 1)); }
fail() { printf '  [FAIL]  %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

check_host() {
    echo "Host checks"

    local arch
    arch="$(uname -m)"
    if [ "$arch" = "s390x" ]; then
        ok "architecture is s390x"
    elif [ "${CB_ALLOW_NON_S390X:-0}" = "1" ]; then
        warn "architecture is $arch, not s390x (allowed by CB_ALLOW_NON_S390X=1; the result will not be an s390x build)"
    else
        fail "architecture is $arch; this kit builds on an s390x host (LPAR, z/VM or KVM guest, or an s390x container)"
    fi

    local id="" version_id=""
    if [ -r /etc/os-release ]; then
        id="$(. /etc/os-release && echo "${ID:-}")"
        version_id="$(. /etc/os-release && echo "${VERSION_ID:-}")"
    fi
    case "$id$version_id" in
        rhel8.10|rhel9.6|rhel9.8|sles15.7|ubuntu22.04|ubuntu24.04)
            ok "distribution $id $version_id is supported by IBM's script" ;;
        rhel8.*|rhel9.*|sles15.*)
            warn "distribution $id $version_id: same family as a supported release, but IBM's script does not list this minor release" ;;
        *)
            fail "distribution '$id $version_id' is not supported (RHEL 8.10, RHEL 9.6/9.8, SLES 15 SP7, Ubuntu 22.04/24.04)" ;;
    esac

    if [ "$(id -u)" = "0" ]; then
        warn "running as root; IBM's instructions expect a regular user with sudo"
    elif command -v sudo >/dev/null 2>&1; then
        if sudo -n true 2>/dev/null; then
            ok "sudo works without a password"
        else
            warn "sudo needs a password; the build will stop and ask for it (see the sudo timeout note in docs/BUILD-GUIDE.md)"
        fi
    else
        fail "sudo is not installed; the build installs packages and tools with sudo"
    fi

    # IBM's installGo step is skipped when any 'go' is already on the PATH, and
    # the patched build then uses that Go whatever its version.
    if command -v go >/dev/null 2>&1; then
        local go_version
        go_version="$(go version 2>/dev/null | awk '{print $3}')"
        if [ "$go_version" = "go1.26.3" ]; then
            ok "Go 1.26.3 is installed"
        else
            warn "another Go (${go_version:-unknown version}) is already on the PATH; the build expects Go 1.26.3 and will not install it while a different 'go' is found. Remove it from the PATH first"
        fi
    fi

    local cpus mem_gb
    cpus="$(nproc 2>/dev/null || echo 1)"
    mem_gb="$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0)"
    note "$cpus CPUs, ${mem_gb} GB RAM"
    if [ "$mem_gb" -lt 8 ]; then
        fail "less than 8 GB RAM; V8 and the C++ services will not link"
    elif [ "$mem_gb" -lt 16 ]; then
        warn "less than 16 GB RAM; keep parallelism low (-j 2 or -j 4) and expect a slow build"
    else
        ok "memory"
    fi

    mkdir -p "$WORKDIR" 2>/dev/null
    local free_gb
    free_gb="$(df -Pk "$WORKDIR" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024/1024}')"
    free_gb="${free_gb:-0}"
    note "${free_gb} GB free in $WORKDIR"
    if [ "$free_gb" -lt 60 ]; then
        fail "less than 60 GB free in $WORKDIR; the dependencies (V8 above all) and the server build need more"
    elif [ "$free_gb" -lt 100 ]; then
        warn "less than 100 GB free in $WORKDIR; an Enterprise build with debug information may run out of space"
    else
        ok "disk space"
    fi

    # Hosts the build downloads from. A failure here is only a warning: some
    # sites refuse HEAD requests, and a proxy may need configuring first.
    if command -v curl >/dev/null 2>&1; then
        local host unreachable=""
        local hosts="github.com raw.githubusercontent.com go.dev proxy.golang.org packages.couchbase.com chromium.googlesource.com gn.googlesource.com storage.googleapis.com nodejs.org repo.anaconda.com sh.rustup.rs cmake.org sourceforge.net download.libsodium.org pypi.org"
        [ "$EDITION" = "enterprise" ] && hosts="$hosts repo.maven.apache.org"
        for host in $hosts; do
            curl -sS -o /dev/null --max-time 15 "https://$host/" 2>/dev/null || unreachable="$unreachable $host"
        done
        if [ -z "$unreachable" ]; then
            ok "download hosts are reachable"
        else
            warn "could not reach:$unreachable (check proxy / firewall settings; the build downloads from these)"
        fi
    else
        note "curl is not installed yet; skipping the download-host check"
    fi

    local kit_root missing=""
    kit_root="$(cd "$(dirname "$0")/.." && pwd)"
    local f
    for f in tlm-s390x.diff tlm-community-no-xdcr.diff indexing-s390x.diff forestdb-s390x.diff \
             kv_engine.diff platform.diff flatbuffers.diff folly.diff v8.diff aws-c-cal.diff; do
        [ -f "$kit_root/patch/$f" ] || missing="$missing $f"
    done
    [ -x "$kit_root/scripts/cbdep-linux-s390x" ] || missing="$missing scripts/cbdep-linux-s390x(not executable)"
    if [ -z "$missing" ]; then ok "kit files are complete"; else fail "kit files missing:$missing"; fi
}

check_access() {
    echo "Private repository access ($EDITION edition, $GIT_AUTH)"
    if [ "$EDITION" != "enterprise" ]; then
        ok "community edition: no private repositories are needed"
        return 0
    fi
    if ! command -v git >/dev/null 2>&1; then
        warn "git is not installed yet; repository access will be checked after the prerequisites are installed"
        return 0
    fi

    local base
    if [ "$GIT_AUTH" = "ssh" ]; then
        base="ssh://git@github.com/couchbase"
        if [ -z "${SSH_AUTH_SOCK:-}" ] && ! ls "$HOME"/.ssh/id_* >/dev/null 2>&1; then
            warn "no ssh-agent and no key in ~/.ssh; GitHub will refuse the connection"
        fi
    else
        base="https://github.com/couchbase"
        # (":+set" so the token never appears in a shell trace)
        [ -n "${GITHUB_TOKEN:+set}" ] || note "GITHUB_TOKEN is not set; relying on a git credential helper"
    fi

    local repo denied="" checked=0
    for repo in $PRIVATE_REPOS; do
        case " $EXCLUDE " in *" $repo "*) continue ;; esac
        checked=$((checked + 1))
        if GIT_TERMINAL_PROMPT=0 timeout 60 git ls-remote --exit-code "$base/$repo" HEAD >/dev/null 2>&1; then
            :
        else
            denied="$denied $repo"
        fi
    done
    if [ -z "$denied" ]; then
        ok "all $checked private repositories are readable"
    else
        fail "cannot read:$denied"
        echo "          An Enterprise build needs read access to these github.com/couchbase"
        echo "          repositories from this machine. With CB_GIT_AUTH=ssh, load a key that"
        echo "          has access (ssh-add, or agent forwarding) and try:  ssh -T git@github.com"
        echo "          With CB_GIT_AUTH=https, export GITHUB_TOKEN with 'repo' read scope."
        echo "          See docs/BUILD-GUIDE.md, \"Access to the private repositories\"."
    fi
}

case "$ONLY" in
    host)   check_host ;;
    access) check_access ;;
    all)    check_host; echo; check_access ;;
    *) echo "--only must be host, access or all" >&2; exit 1 ;;
esac

echo
if [ "$FAILURES" -gt 0 ]; then
    echo "Preflight: $FAILURES problem(s) must be fixed before building ($WARNINGS warning(s))."
    exit 1
fi
echo "Preflight: no blocking problems ($WARNINGS warning(s))."
exit 0
