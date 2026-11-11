#!/bin/bash
# © Copyright IBM Corporation 2026.
# LICENSE: Apache License, Version 2.0 (http://www.apache.org/licenses/LICENSE-2.0)
#
# build_couchbase_ee.sh
#
#   Builds Couchbase Server 8.0.3 from source for Linux on IBM Z (s390x):
#   Enterprise Edition by default, Community Edition with --edition community.
#
#   This file is a MODIFIED version of IBM's build script
#       https://github.com/linux-on-ibm-z/scripts
#       Couchbase/8.0.3/build_couchbase.sh  (commit da0867d01803bc8a5379dfbc8bd79d68cbdce940)
#   which is © IBM Corporation 2026 and licensed under the Apache License 2.0.
#   An unmodified copy is kept in upstream/ next to this file.
#
#   What changed: functions marked "# [IBM]" are IBM's code with only the small
#   edits listed in docs/DIFFERENCES-FROM-IBM.md. Everything else (configuration,
#   staging, the Enterprise source sync, the Enterprise-specific dependency
#   builds, patch handling and the server build itself) was rewritten for the
#   Enterprise Edition build, 2026.
#
# Usage:
#   bash build_couchbase_ee.sh --help
#

set -e -o pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The kit's own version: the VERSION file next to this script.
KIT_VERSION=""
[ -r "$KIT_ROOT/VERSION" ] && KIT_VERSION="$(head -n 1 "$KIT_ROOT/VERSION" | tr -d '[:space:]')"
: "${KIT_VERSION:=unknown}"

PACKAGE_NAME="couchbase"
PACKAGE_VERSION="8.0.3"
DATE_AND_TIME="$(date +"%F-%H%M%S")"

# Stages, in the order they run.
ALL_STAGES="preflight prereqs tools deps source patch build test package"
DEFAULT_STAGES="preflight prereqs tools deps source patch build"

function printHelp() {
    cat <<EOF

Usage: bash build_couchbase_ee.sh [options]

  -e, --edition EDITION    enterprise (default) or community
  -w, --workdir DIR        build workspace (default: \$HOME/couchbase-s390x-build)
  -p, --prefix DIR         install prefix (default: <workdir>/couchbase/install;
                           use /opt/couchbase for a build you intend to package)
  -c, --config FILE        settings file (default: build.conf next to this script,
                           if it exists; see build.conf.example)
  -s, --stages LIST        comma-separated stages to run, from:
                             ${ALL_STAGES// /, }
                           (default: ${DEFAULT_STAGES// /, })
      --from STAGE         run the default stages starting at STAGE
  -j, --jobs N             parallel jobs for the server build
  -t, --tests              also build the test targets and run ctest
      --package            also create an installable tarball (scripts/package.sh)
      --without-analytics  do not sync or build the Analytics service
      --without-backup     do not sync or build the Backup service and tools
      --exclude "A B"      extra manifest projects to leave out of the sync
      --reconfigure        make CMake configure again even if build/ exists
      --show-config        print the resolved settings and stages, then exit
  -y                       accepted and ignored (compatibility with IBM's script)
  -V, --version            print the version of this build kit, then exit
  -h, --help               this text

Enterprise builds need read access to Couchbase's private GitHub repositories
from this machine (SSH key by default; see docs/BUILD-GUIDE.md).

EOF
}

# ---------------------------------------------------------------- command line
# Command-line settings are applied after the settings file so they win.
CLI_SETTINGS=()
CONFIG_FILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        -e|--edition|-w|--workdir|-p|--prefix|-c|--config|-s|--stages|--from|-j|--jobs|--exclude)
            [ $# -ge 2 ] || { printf -- "Option %s needs a value\n" "$1" >&2; exit 1; } ;;
    esac
    case "$1" in
        -e|--edition)   CLI_SETTINGS+=("CB_EDITION=$2"); shift 2 ;;
        -w|--workdir)   CLI_SETTINGS+=("SOURCE_ROOT=$2"); shift 2 ;;
        -p|--prefix)    CLI_SETTINGS+=("CB_PREFIX=$2"); shift 2 ;;
        -c|--config)    CONFIG_FILE="$2"; shift 2 ;;
        -s|--stages)    CLI_SETTINGS+=("CB_STAGES=${2//,/ }"); shift 2 ;;
        --from)         CLI_SETTINGS+=("CB_FROM_STAGE=$2"); shift 2 ;;
        -j|--jobs)      CLI_SETTINGS+=("CB_JOBS=$2"); shift 2 ;;
        -t|--tests)     CLI_SETTINGS+=("TESTS=true"); shift ;;
        --package)      CLI_SETTINGS+=("CB_PACKAGE=1"); shift ;;
        --without-analytics) CLI_SETTINGS+=("CB_WITHOUT_ANALYTICS=1"); shift ;;
        --without-backup)    CLI_SETTINGS+=("CB_WITHOUT_BACKUP=1"); shift ;;
        --exclude)      CLI_SETTINGS+=("CB_EXCLUDE_PROJECTS=$2"); shift 2 ;;
        --reconfigure)  CLI_SETTINGS+=("CB_RECONFIGURE=1"); shift ;;
        --show-config)  CLI_SETTINGS+=("CB_SHOW_CONFIG=1"); shift ;;
        -y|-d)          shift ;;
        -V|--version)   printf -- "build_couchbase_ee.sh %s (Couchbase Server %s build kit for s390x)\n" "$KIT_VERSION" "$PACKAGE_VERSION"; exit 0 ;;
        -h|--help|-\?)  printHelp; exit 0 ;;
        *) printf -- "Unknown option: %s\n" "$1" >&2; printHelp; exit 1 ;;
    esac
done

if [ -z "$CONFIG_FILE" ] && [ -f "$KIT_ROOT/build.conf" ]; then
    CONFIG_FILE="$KIT_ROOT/build.conf"
fi
if [ -n "$CONFIG_FILE" ]; then
    [ -f "$CONFIG_FILE" ] || { printf -- "Settings file %s not found\n" "$CONFIG_FILE" >&2; exit 1; }
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi
for _setting in "${CLI_SETTINGS[@]}"; do
    printf -v "${_setting%%=*}" '%s' "${_setting#*=}"
done
unset _setting

# -------------------------------------------------------------------- settings
# Every setting can come from the settings file or the environment; see
# build.conf.example for what each one does.
: "${CB_EDITION:=enterprise}"
: "${CB_BLD_NUM:=9999}"
: "${CB_BUILD_TYPE:=RelWithDebInfo}"
: "${CB_MANIFEST_URL:=https://github.com/couchbase/manifest}"
: "${CB_MANIFEST_FILE:=released/couchbase-server/${PACKAGE_VERSION}.xml}"
: "${CB_SYNC_JOBS:=6}"
: "${CB_REPO_INIT_ARGS:=}"
: "${CB_EXCLUDE_PROJECTS:=}"
: "${CB_WITHOUT_ANALYTICS:=0}"
: "${CB_WITHOUT_BACKUP:=0}"
: "${CB_WITH_VOLTRON:=0}"
: "${CB_GIT_AUTH:=ssh}"
: "${CB_GOPRIVATE:=github.com/couchbase}"
: "${CB_PARALLEL_LINK_JOBS:=2}"
: "${CB_UNITY_BUILD:=OFF}"
: "${CB_INVOKE_MAVEN:=True}"
: "${CB_DOWNLOAD_JAVA:=True}"
: "${CB_EXTRA_CMAKE_OPTIONS:=}"
: "${CB_CURL_TLS:=1}"
: "${CB_RECONFIGURE:=0}"
: "${CB_PACKAGE:=0}"
: "${CB_TRACE:=1}"
: "${TESTS:=false}"
: "${SOURCE_ROOT:=$HOME/couchbase-s390x-build}"

case "$CB_EDITION" in
    enterprise|community) ;;
    *) printf -- "--edition must be 'enterprise' or 'community' (got '%s')\n" "$CB_EDITION" >&2; exit 1 ;;
esac
case "$CB_GIT_AUTH" in
    ssh|https) ;;
    *) printf -- "CB_GIT_AUTH must be 'ssh' or 'https' (got '%s')\n" "$CB_GIT_AUTH" >&2; exit 1 ;;
esac

SOURCE_ROOT="$(realpath -m "$SOURCE_ROOT")"
case "$SOURCE_ROOT" in
    *" "*) printf -- "The workspace path must not contain spaces: %s\n" "$SOURCE_ROOT" >&2; exit 1 ;;
esac

: "${CB_PREFIX:=$SOURCE_ROOT/couchbase/install}"

# Which manifest groups to sync. Enterprise adds the 'enterprise' group (which
# covers analytics, backup and magma) plus 'packaging' for product-metadata
# (the third-party NOTICES file); voltron is removed again in the local manifest.
if [ -z "${CB_SYNC_GROUPS:-}" ]; then
    if [ "$CB_EDITION" = "enterprise" ]; then
        CB_SYNC_GROUPS="default,enterprise,packaging"
    else
        CB_SYNC_GROUPS=""
    fi
fi

# Parallelism for the server build: one job per CPU, but no more than one job
# per 2 GB of RAM (IBM's script used a fixed -j4).
if [ -z "${CB_JOBS:-}" ]; then
    _cpus="$(nproc)"
    _mem_gb="$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 8)"
    CB_JOBS=$(( _mem_gb / 2 ))
    [ "$CB_JOBS" -lt 1 ] && CB_JOBS=1
    [ "$CB_JOBS" -gt "$_cpus" ] && CB_JOBS="$_cpus"
    unset _cpus _mem_gb
fi

# Stage selection.
if [ -z "${CB_STAGES:-}" ]; then
    CB_STAGES="$DEFAULT_STAGES"
    if [ -n "${CB_FROM_STAGE:-}" ]; then
        case " $DEFAULT_STAGES test package " in
            *" $CB_FROM_STAGE "*) ;;
            *) printf -- "--from: unknown stage '%s'\n" "$CB_FROM_STAGE" >&2; exit 1 ;;
        esac
        CB_STAGES="${ALL_STAGES#*"$CB_FROM_STAGE"}"
        CB_STAGES="$CB_FROM_STAGE$CB_STAGES"
        # 'test' and 'package' only run when asked for (below).
        CB_STAGES="${CB_STAGES/ test/}"
        CB_STAGES="${CB_STAGES/ package/}"
        [ "$CB_FROM_STAGE" = "test" ] && TESTS="true"
        [ "$CB_FROM_STAGE" = "package" ] && CB_PACKAGE=1
    fi
    [ "$TESTS" = "true" ] && case " $CB_STAGES " in *" test "*) ;; *) CB_STAGES="$CB_STAGES test" ;; esac
    [ "$CB_PACKAGE" = "1" ] && case " $CB_STAGES " in *" package "*) ;; *) CB_STAGES="$CB_STAGES package" ;; esac
else
    case " $CB_STAGES " in *" test "*) TESTS="true" ;; esac
fi
for _stage in $CB_STAGES; do
    case " $ALL_STAGES " in
        *" $_stage "*) ;;
        *) printf -- "Unknown stage '%s' (valid: %s)\n" "$_stage" "$ALL_STAGES" >&2; exit 1 ;;
    esac
done
unset _stage

if [ "${CB_SHOW_CONFIG:-0}" = "1" ]; then
    cat <<SHOWCFG
kit version:        $KIT_VERSION
edition:            $CB_EDITION
version:            ${PACKAGE_VERSION}-${CB_BLD_NUM} ($CB_BUILD_TYPE)
stages:             $CB_STAGES
workspace:          $SOURCE_ROOT
install prefix:     $CB_PREFIX
manifest:           $CB_MANIFEST_URL  $CB_MANIFEST_FILE
manifest groups:    ${CB_SYNC_GROUPS:-(default)}
excluded projects:  ${CB_EXCLUDE_PROJECTS:-(none)}  analytics excluded: $CB_WITHOUT_ANALYTICS  backup excluded: $CB_WITHOUT_BACKUP
git access:         $CB_GIT_AUTH   GOPRIVATE=$CB_GOPRIVATE
build jobs:         $CB_JOBS (link jobs: $CB_PARALLEL_LINK_JOBS, unity build: $CB_UNITY_BUILD)
curl with TLS:      $CB_CURL_TLS
extra CMake opts:   ${CB_EXTRA_CMAKE_OPTIONS:-(none)}
settings file:      ${CONFIG_FILE:-(none)}
SHOWCFG
    exit 0
fi

mkdir -p "$SOURCE_ROOT"
LOG_DIR="$SOURCE_ROOT/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/${PACKAGE_NAME}-${CB_EDITION}-${PACKAGE_VERSION}-${DATE_AND_TIME}.log"

if [ -f "/etc/os-release" ]; then
  source "/etc/os-release"
else
  printf -- "/etc/os-release file not found. Platform is not supported.\n"
  exit 1
fi

DISTRO=$(echo $(echo $ID | sed 's/sles/suse/g')$VERSION_ID | sed -E -e 's/(rhel[[:digit:]]|suse[[:digit:]]{2}).*/\1/g')

# IBM's script appends its environment settings to ~/.bash_profile and sources
# that file at the start of every function. This kit keeps them in a file of
# its own inside the workspace instead, so the user's login profile is left
# alone and so the custom OpenSSL build never ends up on the library path of
# everyday tools (see docs/DIFFERENCES-FROM-IBM.md).
KIT_STATE_DIR="$SOURCE_ROOT/.cb-s390x-kit"
mkdir -p "$KIT_STATE_DIR/bin"
PRESERVE_ENVARS="$KIT_STATE_DIR/env.sh"
touch "$PRESERVE_ENVARS"

CACHE_DIRECTORY="${CB_DOWNLOAD_DEPS_CACHE:-$HOME/.cbdepscache}"

mkdir -p $SOURCE_ROOT/patch
mkdir -p $CACHE_DIRECTORY

###############################################################################
# Helpers added for this kit
###############################################################################

function log()  { printf -- '\n==== [%s] %s\n' "$(date +%T)" "$*"; }
function warn() { printf -- 'WARNING: %s\n' "$*" >&2; }
function die()  { printf -- '\nERROR: %s\n' "$*" >&2; exit 1; }

# IBM's script downloads each patch from its own repository at build time.
# This kit ships the patches in ./patch, so "fetching" one is a local copy.
function fetchPatch() {
    [ -f "$KIT_ROOT/patch/$1" ] || die "patch file $KIT_ROOT/patch/$1 is missing from the kit"
    mkdir -p "$SOURCE_ROOT/patch"
    cp -f "$KIT_ROOT/patch/$1" "$SOURCE_ROOT/patch/$1"
}

# applyPatch DIR PATCHFILE
#   Applies a patch to a git checkout, and does nothing if it is already there,
#   so the patch stage can be re-run safely.
function applyPatch() {
    local dir="$1" patch="$2"
    [ -d "$dir" ]   || die "cannot apply $(basename "$patch"): directory $dir does not exist"
    [ -f "$patch" ] || die "patch file $patch does not exist"
    if git -C "$dir" apply --reverse --check "$patch" >/dev/null 2>&1; then
        printf -- "Patch %s is already applied in %s\n" "$(basename "$patch")" "$dir"
    elif git -C "$dir" apply --check "$patch"; then
        git -C "$dir" apply "$patch"
        printf -- "Applied %s in %s\n" "$(basename "$patch")" "$dir"
    else
        die "$(basename "$patch") does not apply cleanly in $dir (has the source revision changed, or was the tree edited by hand?)"
    fi
}

# cacheHasPackage STEM  -> true if <cache>/STEM.tgz exists and matches STEM.md5
function cacheHasPackage() {
    local tgz="$CACHE_DIRECTORY/$1.tgz" md5="$CACHE_DIRECTORY/$1.md5"
    [ -f "$tgz" ] && [ -f "$md5" ] || return 1
    [ "$(md5sum "$tgz" | cut -c1-32)" = "$(cut -c1-32 "$md5")" ]
}

# runDep FUNCTION PACKAGE_STEM "BUILD_DIRS" ["EXTRA_PATHS_TO_CLEAN"]
#
#   Runs one of the dependency build functions so that the whole dependency
#   stage can be interrupted and re-run.
#
#   IBM's functions decide "already built" by checking whether the source
#   directory exists, so a build that failed half-way is silently skipped on
#   the next run and its package never reaches the cbdeps cache. Here a
#   dependency counts as done only when its package (with a matching .md5) is
#   in the cache AND its build directories still exist (later dependencies and
#   the server build link against some of them). Otherwise the leftovers are
#   removed and the function runs from scratch.
#
#   BUILD_DIRS and EXTRA_PATHS_TO_CLEAN are space-separated; relative paths
#   are relative to $SOURCE_ROOT.
function runDep() {
    local fn="$1" stem="$2" dirs="$3" extra="${4:-}" d path complete=1

    if cacheHasPackage "$stem"; then
        for d in $dirs; do
            case "$d" in /*) path="$d" ;; *) path="$SOURCE_ROOT/$d" ;; esac
            [ -d "$path" ] || complete=0
        done
        if [ "$complete" = "1" ]; then
            printf -- "Dependency %s is already built and cached; skipping %s.\n" "$stem" "$fn"
            return 0
        fi
    fi

    for d in $dirs $extra; do
        case "$d" in /*) path="$d" ;; *) path="$SOURCE_ROOT/$d" ;; esac
        if [ -e "$path" ]; then
            printf -- "Removing leftovers of an earlier attempt: %s\n" "$path"
            sudo rm -rf "$path"
        fi
    done
    rm -f "$CACHE_DIRECTORY/$stem.tgz" "$CACHE_DIRECTORY/$stem.md5"

    log "Building dependency $stem ($fn)"
    "$fn"
    cacheHasPackage "$stem" || die "$fn finished but $stem.tgz (with a matching .md5) is not in $CACHE_DIRECTORY"
}

# Run a command without the custom-OpenSSL settings in its environment.
function cleanEnv() {
    env -u LD_LIBRARY_PATH -u OPENSSL_CONF -u OPENSSL_ROOT_DIR "$@"
}

# The server build puts the freshly built OpenSSL 3.5.7 on LD_LIBRARY_PATH.
# System tools that then pick it up misbehave: OpenSSH refuses to start when
# libcrypto is not the version it was built against, which is why IBM's script
# compiles its own OpenSSH on some distributions. Instead, this kit makes git
# and ssh always run with the system libraries: a 'git' wrapper at the front
# of PATH and GIT_SSH_COMMAND both drop the custom-OpenSSL variables.
function setupGitEnvironment() {
    local real_git real_ssh wrapper="$KIT_STATE_DIR/bin/git"
    real_git="$(PATH="${PATH//$KIT_STATE_DIR\/bin:/}" command -v git)" || die "git is not installed"
    real_ssh="$(command -v ssh || true)"
    [ -x /usr/bin/ssh ] && real_ssh=/usr/bin/ssh

    cat > "$wrapper" <<EOF
#!/bin/sh
# Generated by build_couchbase_ee.sh: run git with the system libraries.
exec env -u LD_LIBRARY_PATH -u OPENSSL_CONF -u OPENSSL_ROOT_DIR "$real_git" "\$@"
EOF
    chmod 0755 "$wrapper"
    # IBM's functions re-source the environment file (which holds snapshots of
    # PATH) all the time, so the wrapper directory has to be put back by that
    # file too or it would drop off PATH again.
    local path_line="case \":\$PATH:\" in *\":$KIT_STATE_DIR/bin:\"*) ;; *) export PATH=\"$KIT_STATE_DIR/bin:\$PATH\" ;; esac"
    grep -qxF "$path_line" "$PRESERVE_ENVARS" || echo "$path_line" >> "$PRESERVE_ENVARS"
    source "$PRESERVE_ENVARS"

    if [ -z "${GIT_SSH_COMMAND:-}" ] && [ -n "$real_ssh" ]; then
        export GIT_SSH_COMMAND="env -u LD_LIBRARY_PATH -u OPENSSL_CONF -u OPENSSL_ROOT_DIR $real_ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
    fi
    # Never sit at an invisible username/password prompt in the middle of a build.
    export GIT_TERMINAL_PROMPT=0

    # Git settings for the build live in a file of their own (which includes
    # the user's ~/.gitconfig) rather than being written into ~/.gitconfig.
    local cfg="$KIT_STATE_DIR/gitconfig"
    cat > "$cfg" <<EOF
# Generated by build_couchbase_ee.sh on every run - do not edit.
[include]
	path = $HOME/.config/git/config
	path = $HOME/.gitconfig
[safe]
	directory = *
[color]
	ui = false
[advice]
	detachedHead = false
EOF
    if [ "$CB_EDITION" = "enterprise" ]; then
        if [ "$CB_GIT_AUTH" = "ssh" ]; then
            # The manifest already uses ssh:// for the private repositories. Go
            # asks for private modules as https://github.com/couchbase/<repo>, so
            # send those over SSH as well.
            cat >> "$cfg" <<EOF
[url "ssh://git@github.com/couchbase/"]
	insteadOf = https://github.com/couchbase/
EOF
        else
            # HTTPS with a token: rewrite the manifest's ssh:// URLs to https and
            # hand git the token from \$GITHUB_TOKEN when it asks (the token is
            # read from the environment each time; it is not written to disk).
            # (":+set" keeps the token itself out of the 'set -x' trace.)
            [ -n "${GITHUB_TOKEN:+set}" ] || warn "CB_GIT_AUTH=https but GITHUB_TOKEN is not set; private repositories will only work if a credential helper in ~/.gitconfig supplies credentials"
            cat >> "$cfg" <<'EOF'
[url "https://github.com/couchbase/"]
	insteadOf = ssh://git@github.com/couchbase/
[credential "https://github.com"]
	helper = "!f() { test \"$1\" = get && test -n \"$GITHUB_TOKEN\" && echo username=x-access-token && echo \"password=$GITHUB_TOKEN\"; }; f"
EOF
        fi
        # Private Go modules (for example goxdcr, which xdcrDiffer requires as a
        # module) cannot come from proxy.golang.org; fetch Couchbase modules
        # straight from GitHub using the credentials above.
        export GOPRIVATE="$CB_GOPRIVATE"
    fi
    export GIT_CONFIG_GLOBAL="$cfg"
}

# Couchbase's build downloads a prebuilt "cbdep" helper that does not exist for
# s390x; put this kit's stand-in where the build looks for it.
function installCbdepShim() {
    mkdir -p "$CACHE_DIRECTORY/cbdep"
    install -m 0755 "$KIT_ROOT/scripts/cbdep-linux-s390x" "$CACHE_DIRECTORY/cbdep/cbdep-linux-$(uname -m)"
}

# Packages the Enterprise flow needs on top of IBM's lists: an SSH client for
# the private repositories, and a few small tools this kit's scripts use.
function prepareKitExtras() {
    case "$DISTRO" in
        ubuntu*) sudo DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-client ca-certificates file xz-utils patch ;;
        rhel*)   sudo yum install -y openssh-clients ca-certificates file xz patch ;;
        suse*)   sudo zypper install -y openssh ca-certificates file xz patch ;;
    esac
}

# Which of IBM's distribution-preparation functions applies to this host.
# IBM's 8.0.3 script accepts RHEL 8.10, RHEL 9.6/9.8, SLES 15 SP7, Ubuntu 22.04
# and 24.04.
# Other minor releases of the same families are allowed with a warning.
function distroFamily() {
    case "$ID$VERSION_ID" in
        rhel8.10)             echo rhel8 ;;
        rhel9.6|rhel9.8)      echo rhel9 ;;
        sles15.7)             echo suse15 ;;
        ubuntu22.04)          echo ubuntu22 ;;
        ubuntu24.04)          echo ubuntu24 ;;
        rhel8.*)              warn "IBM's script supports RHEL 8.10, not $VERSION_ID; continuing with the RHEL 8 steps"; echo rhel8 ;;
        rhel9.*)              warn "IBM's script supports RHEL 9.6 and 9.8, not $VERSION_ID; continuing with the RHEL 9 steps"; echo rhel9 ;;
        sles15.*)             warn "IBM's script supports SLES 15 SP7, not $VERSION_ID; continuing with the SLES 15 steps"; echo suse15 ;;
        *)                    echo unsupported ;;
    esac
}

###############################################################################
# Distribution preparation, toolchain and third-party dependency builds.
# These functions are IBM's, from linux-on-ibm-z/scripts Couchbase/8.0.3
# (commit da0867d). Each is marked "# [IBM]"; the only edits are listed in
# docs/DIFFERENCES-FROM-IBM.md.
###############################################################################

# [IBM]
function prepareRHEL8() {
    source $PRESERVE_ENVARS
    printf -- "Installing dependencies from repository.\n"
    #sudo subscription-manager repos --enable codeready-builder-for-rhel-8-s390x-rpms
    #sudo subscription-manager repos --enable rhel-8-for-s390x-appstream-rpms
    sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm
    sudo yum install -y gcc-toolset-13 gcc-toolset-13-gcc gcc-toolset-13-gcc-c++ gcc-toolset-13-libatomic-devel gcc-toolset-13-libstdc++-devel
    sudo ln -sf /opt/rh/gcc-toolset-13/root/usr/bin/gcc /usr/local/bin/gcc
    sudo ln -sf /opt/rh/gcc-toolset-13/root/usr/bin/g++ /usr/local/bin/g++
    sudo yum install -y atk-devel autoconf automake binutils-devel bison bzip2 ccache \
        cmake cups-devel flex git gnome-keyring libcurl-devel langpacks-en glibc-all-langpacks \
        libev-devel libtool make ncurses-devel ninja-build openssl-devel perl openssl-perl libpsl-devel\
        python2 python38 python38-devel python38-pip python3-httplib2 tar texinfo unzip wget which xz xz-devel \
        glib2-devel clang diffutils procps asciidoctor jq patch

    sudo ln -sf /usr/bin/python3 /usr/bin/python
    sudo alternatives --set python /usr/bin/python3.8
    sudo alternatives --set python3 /usr/bin/python3.8
    python --version
    python3 --version

    sudo ln -sf /opt/rh/gcc-toolset-13/root/usr/bin/as /usr/bin/as
    pip3 install httplib2 --user
    echo 'export CC=/opt/rh/gcc-toolset-13/root/usr/bin/gcc' >> $PRESERVE_ENVARS
    echo 'export CXX=/opt/rh/gcc-toolset-13/root/usr/bin/g++' >> $PRESERVE_ENVARS
    echo "export PATH=/opt/rh/gcc-toolset-13/root/usr/bin:$PATH" >> $PRESERVE_ENVARS
    echo "export LANG=en_US.UTF-8" >> $PRESERVE_ENVARS
}

# [IBM]
function prepareRHEL9() {
    printf -- "Installing dependencies from repository.\n"
    #sudo subscription-manager repos --enable codeready-builder-for-rhel-9-s390x-rpms
    #sudo subscription-manager repos --enable rhel-9-for-s390x-appstream-rpms
    sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
    sudo yum install -y gcc-toolset-13 gcc-toolset-13-gcc gcc-toolset-13-gcc-c++ gcc-toolset-13-libatomic-devel gcc-toolset-13-libstdc++-devel
    source /opt/rh/gcc-toolset-13/enable
    sudo yum install -y atk-devel autoconf automake binutils-devel bison bzip2 perl \
        cmake cups-devel flex git gnome-keyring libcurl-devel langpacks-en glibc-all-langpacks ccache \
        libtool make ncurses-devel ninja-build openssl-devel openssl-perl perl-core libpsl-devel lz4 lz4-devel \
        python3 python3-devel tar texinfo unzip wget which xz xz-devel glib2-devel clang compat-openssl11 python3-httplib2 asciidoctor jq patch

    sudo ln -sf /usr/bin/python3 /usr/bin/python
    sudo ln -sf /usr/bin/gcc /usr/bin/s390x-linux-gnu-gcc
    sudo ldconfig

    echo 'export CC=/opt/rh/gcc-toolset-13/root/usr/bin/gcc' >> $PRESERVE_ENVARS
    echo 'export CXX=/opt/rh/gcc-toolset-13/root/usr/bin/g++' >> $PRESERVE_ENVARS
    echo 'export PATH=/opt/rh/gcc-toolset-13/root/usr/bin:$PATH' >> $PRESERVE_ENVARS
}

# [IBM]
function buildPython311() {
    sudo zypper install -y gcc make tar xz zlib-devel libffi-devel libopenssl-devel readline-devel sqlite3-devel xz-devel libbz2-devel
    cd $SOURCE_ROOT
    wget https://www.python.org/ftp/python/3.11.9/Python-3.11.9.tgz
    tar -xf "Python-3.11.9.tgz"
    cd "Python-3.11.9"
    ./configure --enable-optimizations --with-ensurepip=install
    make -j4
    sudo make altinstall
}

# [IBM]
function prepareSUSE15() {
    sudo zypper install -y asciidoc autoconf automake cmake curl libcurl-devel flex openssh \
        gcc gcc-c++ gcc14-c++ gcc14 git-core glib2 glib2-devel \
        libopenssl-devel libncurses6 xz glibc-locale bzip2 ccache\
        libexpat1 libexpat-devel libtirpc-devel libtool libxml2-tools libxslt-tools binutils-devel\
        make makedepend ncurses-devel ninja patch pkg-config libpsl-devel\
        python3 python-xml python3-httplib2 re2c ruby sqlite3 tar \
        unixODBC wget which  xmlto python3-pip python3-devel jq

    buildPython311
    sudo ln -sf /usr/local/bin/python3.11 /usr/bin/python3
    sudo ln -sf /usr/bin/python3 /usr/bin/python
    pip3 install pyparsing
    pip3 install httplib2 --user
    python3 -m pip install "httplib2<0.30.0" --user
    export SSL_CERT_FILE=/etc/ssl/ca-bundle.pem
    sudo update-alternatives --install /usr/bin/cc cc /usr/bin/gcc-14 14
    sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-14 14
    sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-14 14
    sudo update-alternatives --install /usr/bin/c++ c++ /usr/bin/g++-14 14
    sudo ln -sf /usr/bin/gcc /usr/bin/s390x-linux-gnu-gcc

    echo 'export CC=/usr/bin/gcc' >> $PRESERVE_ENVARS
    echo 'export CXX=/usr/bin/g++' >> $PRESERVE_ENVARS
    echo "export LANG=en_US.UTF-8" >> $PRESERVE_ENVARS
}

# [IBM]
function prepareUB22() {
    printf -- "Installing dependencies from repository.\n"
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive TZ=America/Toronto apt-get install -y \
        autoconf automake autotools-dev binutils-dev bison ccache cmake curl flex  \
        git libssl-dev libcurl4-openssl-dev ncurses-dev ninja-build python3.10 locales locales-all libpsl-dev \
        python3-httplib2 python3-six pkg-config re2c texinfo tzdata unzip wget libglib2.0-dev libtool software-properties-common
        sudo add-apt-repository -y ppa:ubuntu-toolchain-r/test
        sudo apt-get install -y g++-13 gcc-13 gcc-13-multilib g++-13-multilib jq

    sudo ln -sf /usr/bin/python3 /usr/bin/python
    echo "export LANG=en_US.UTF-8" >> $PRESERVE_ENVARS
    echo "export CC=gcc" >> $PRESERVE_ENVARS
    echo "export CXX=g++" >> $PRESERVE_ENVARS

    sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-13 13
    sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-13 13
}

# [IBM]
function prepareUB24() {
    printf -- "Installing dependencies from repository.\n"
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive TZ=America/Toronto apt-get install -y \
        autoconf automake autotools-dev binutils-dev bison ccache cmake curl flex bzip2 \
        git libssl-dev libcurl4-openssl-dev ncurses-dev ninja-build python3 locales locales-all libpsl-dev \
        python3-httplib2 python3-six pkg-config re2c texinfo tzdata unzip wget xz-utils \
        g++-13 gcc-13 gcc-13-multilib g++-13-multilib libglib2.0-dev libtool tar unzip software-properties-common jq
    sudo add-apt-repository -y ppa:deadsnakes/ppa 
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive TZ=America/Toronto apt-get install -y python3.11 python3.11-venv python3.11-dev
    sudo update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1
    sudo ln -sf /usr/bin/python3 /usr/bin/python
    echo "export LANG=en_US.UTF-8" >> $PRESERVE_ENVARS
    echo "export CC=gcc" >> $PRESERVE_ENVARS
    echo "export CXX=g++" >> $PRESERVE_ENVARS

    sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-13 13
    sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-13 13
}

# [IBM]
function installGo() {
    source $PRESERVE_ENVARS || true
    printf -- "Start building golang.\n"
    if command -v "go" >/dev/null; then
        printf -- "Golang already exists.\n"
        return 0
    fi

    cd $SOURCE_ROOT
    wget https://go.dev/dl/go1.26.3.linux-s390x.tar.gz
    chmod ugo+r go1.26.3.linux-s390x.tar.gz
    sudo tar -C /usr/local -xzf go1.26.3.linux-s390x.tar.gz
    #export GOROOT=/usr/local/go
    echo "export PATH=/usr/local/go/bin:$PATH" >> $PRESERVE_ENVARS
    export PATH=/usr/local/go/bin:$PATH
    echo "export GOPATH=$(go env GOPATH)" >> $PRESERVE_ENVARS
    go version
    cp go1.26.3.linux-s390x.tar.gz $CACHE_DIRECTORY

    printf -- "Finished building golang.\n"
}

# [IBM]
function installCmake() {
    source $PRESERVE_ENVARS
    printf -- "Start building CMake.\n"
    if command -v "cmake" >/dev/null; then
    CMAKE_VERSION=($(cmake --version))
        if [ ${CMAKE_VERSION[2]} == 3.27.4 ]; then
            printf -- "Cmake already exists.\n"
            return 0
        fi
    fi

    cd $SOURCE_ROOT
    rm -rdf cmake-3.27.4
    wget https://cmake.org/files/v3.27/cmake-3.27.4.tar.gz
    tar -xzf cmake-3.27.4.tar.gz
    cd cmake-3.27.4
    ./bootstrap --prefix=/usr
    make -j$(nproc)
    sudo make install
    hash -r

    printf -- "Finished building CMake.\n"
}

# [IBM]
function installRepoTool() {
    source $PRESERVE_ENVARS
    printf -- "Start getting repo .\n"
    if [ -f  /usr/bin/repo ]; then
        printf -- "Repo already exists. Nothing to do. \n"
        return 0
    fi

    cd $SOURCE_ROOT
    curl https://storage.googleapis.com/git-repo-downloads/repo >repo
    chmod a+x repo
    sudo mv repo /usr/bin

    printf -- "Finished getting repo .\n"
}

# [IBM]
function installGflags() {
    source $PRESERVE_ENVARS
    NAME_GFLAGS=gflags
    VERSION_GFLAGS=2.2.2
    BUILD_GFLAGS=1
    PACKAGE_GFLAGS=$NAME_GFLAGS-linux-s390x-$VERSION_GFLAGS-$BUILD_GFLAGS

    # Guard Clause: Skip if exists in cache
    if [ -f "$CACHE_DIRECTORY/$PACKAGE_GFLAGS.tgz" ]; then
        printf -- "Package %s already exists. Skipping build.\n" "$PACKAGE_GFLAGS"
        return 0
    fi

    printf -- "Start building %s .\n" "$PACKAGE_GFLAGS"
    cd "$SOURCE_ROOT"
    
    # Check if directory exists, otherwise download and extract
    if [ ! -d "gflags-$VERSION_GFLAGS" ]; then
        wget https://github.com/gflags/gflags/archive/refs/tags/v$VERSION_GFLAGS.tar.gz
        tar xzf v$VERSION_GFLAGS.tar.gz
    else
        printf -- "gflags source directory already exists, skipping download\n"
    fi
    
    cd "gflags-$VERSION_GFLAGS"
    
    # Clean and create build directory
    rm -rf build
    mkdir -p build && cd build
    cmake .. \
        -D CMAKE_BUILD_TYPE=Release \
        -D BUILD_SHARED_LIBS=OFF \
        -D CMAKE_INSTALL_PREFIX=$(pwd)/_build \
        -D BUILD_STATIC_LIBS=ON \
        -D INSTALL_STATIC_LIBS=ON \
        -D CMAKE_INSTALL_LIBDIR=lib \
        -D CMAKE_POSITION_INDEPENDENT_CODE=ON
    make -j$(nproc)
    sudo make install  

    cd _build
    # Couchbase needs this CMake helper to find the headers and libs
    sudo tee CMakeLists.txt <<EOF > /dev/null
FILE (COPY include DESTINATION "\${CMAKE_INSTALL_PREFIX}")
FILE (COPY lib DESTINATION "\${CMAKE_INSTALL_PREFIX}")
SET_PROPERTY (GLOBAL APPEND PROPERTY CBDEPS_PREFIX_PATH "\${CMAKE_CURRENT_SOURCE_DIR}")
EOF

    # Standard packaging for s390x cache using GNU format
    sudo tar --format=gnu --owner=0 --group=0 -czvf "$PACKAGE_GFLAGS.tgz" ./*
    sudo md5sum "$PACKAGE_GFLAGS.tgz" | cut -d' ' -f1 | sudo tee "$PACKAGE_GFLAGS.md5" > /dev/null
    
    # Copy both tgz and md5 to the cache directory
    sudo cp "$PACKAGE_GFLAGS.tgz" "$PACKAGE_GFLAGS.md5" "$CACHE_DIRECTORY"

    printf -- "Finished building %s .\n" "$PACKAGE_GFLAGS" 

    printf -- "Finished building gflags .\n"
}

# [IBM]
function buildBenchmark() {
    source $PRESERVE_ENVARS
    NAME_BENCHMARK=benchmark
    VERSION_BENCHMARK=v1.9.1
    BUILD_BENCHMARK=cb1
    PACKAGE_BENCHMARK=$NAME_BENCHMARK-linux-s390x-$VERSION_BENCHMARK-$BUILD_BENCHMARK

    printf -- "Start building %s .\n" "$PACKAGE_BENCHMARK"
    if [ -d  $SOURCE_ROOT/$NAME_BENCHMARK ]; then
        printf -- "The file already exists. Nothing to do. \n"
        return 0
    fi

    cd $SOURCE_ROOT
    git clone -b $VERSION_BENCHMARK --depth 1 https://github.com/couchbasedeps/benchmark.git
    cd benchmark
    cmake -D CMAKE_INSTALL_PREFIX=$(pwd)/_build -D CMAKE_BUILD_TYPE=RelWithDebInfo -D CMAKE_INSTALL_LIBDIR=lib -D CMAKE_CXX_STANDARD=17 -D CMAKE_CXX_STANDARD_REQUIRED=ON -D BUILD_SHARED_LIBS=OFF -D BENCHMARK_ENABLE_TESTING=OFF -D BENCHMARK_ENABLE_GTEST_TESTS=OFF -D BENCHMARK_ENABLE_INSTALL=ON -D BENCHMARK_DOWNLOAD_DEPENDENCIES=OFF
    cmake --build . --target install
    cmake -E remove_directory ./_build/lib/pkgconfig
    cd _build
    # Packaging build files
    tar -czvf $PACKAGE_BENCHMARK.tgz *
    MD5_BENCHMARK=($(md5sum $PACKAGE_BENCHMARK.tgz))
    echo $MD5_BENCHMARK > $PACKAGE_BENCHMARK.md5
    # Copy the package to destination
    cp $PACKAGE_BENCHMARK.* $CACHE_DIRECTORY

    printf -- "Finished building %s .\n" "$PACKAGE_BENCHMARK"
}

# [IBM]
function buildBoost() {
    source $PRESERVE_ENVARS
    NAME_BOOST=boost
    VERSION_BOOST=1.86.0
    BUILD_BOOST=cb3
    PACKAGE_BOOST=$NAME_BOOST-linux-s390x-$VERSION_BOOST-$BUILD_BOOST

    printf -- "Start building %s .\n" "$PACKAGE_BOOST"
    if [ -d  $SOURCE_ROOT/boost-1.86.0 ]; then
        printf -- "The file already exists. Nothing to do. \n"
        return 0
    fi

    sudo ldconfig /usr/local/lib64 /usr/local/lib
    cd $SOURCE_ROOT
    TOOLSET=gcc
    URL=https://github.com/boostorg/boost/releases/download/boost-$VERSION_BOOST/boost-$VERSION_BOOST-cmake.tar.gz
    curl -sSL $URL |tar xzf -
    cd boost-1.86.0
    ./bootstrap.sh --with-libraries=context,chrono,date_time,filesystem,program_options,regex,system,thread --prefix=$(pwd)/_build --libdir=$(pwd)/_build/lib
    options=(toolset=$TOOLSET variant=release link=static runtime-link=shared threading=multi --without-python address-model=64 cflags=-fno-omit-frame-pointer cxxflags=-fno-omit-frame-pointer cxxflags=-fPIC cxxflags=-std=c++17)
    ./b2 -j 4 ${options[@]} install
    cd _build
    # Packaging build files
    tar -czvf $PACKAGE_BOOST.tgz *
    MD5_BOOST=($(md5sum $PACKAGE_BOOST.tgz))
    echo $MD5_BOOST >$PACKAGE_BOOST.md5
    # Copy the package to destination
    cp $PACKAGE_BOOST.* $CACHE_DIRECTORY

    printf -- "Finished building %s .\n" "$PACKAGE_BOOST"
}

# [IBM]
function buildCbpy() {
    source $PRESERVE_ENVARS
    NAME_CBPY=cbpy
    VERSION_CBPY=3.14.2
    BUILD_CBPY=4
    PACKAGE_CBPY=$NAME_CBPY-linux-s390x-$VERSION_CBPY-$BUILD_CBPY

    printf -- "Start building %s .\n" "$PACKAGE_CBPY"
    if [ -d  $SOURCE_ROOT/$NAME_CBPY ]; then
        printf -- "The file already exists. Nothing to do. \n"
        return 0
    fi

    cd $SOURCE_ROOT
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source $HOME/.cargo/env

    cd $SOURCE_ROOT
    wget https://repo.anaconda.com/miniconda/Miniconda3-py311_23.5.0-3-Linux-s390x.sh
    chmod a+x Miniconda3-py311_23.5.0-3-Linux-s390x.sh

    ./Miniconda3-py311_23.5.0-3-Linux-s390x.sh -b -p ./cbpy
    cd cbpy
    ./bin/pip3 install msgpack-python
    ./bin/pip3 install natsort
    ./bin/pip3 install pem
    ./bin/pip3 install pycryptodome
    ./bin/pip3 install python-snappy
    ./bin/pip3 install requests
    ./bin/pip3 install cryptography==38.0.4
    # Packaging build files
    tar -czvf $PACKAGE_CBPY.tgz bin lib share ssl
    MD5_CBPY=($(md5sum $PACKAGE_CBPY.tgz))
    echo $MD5_CBPY >$PACKAGE_CBPY.md5
    # Copy the package to destination
    cp $PACKAGE_CBPY.* $CACHE_DIRECTORY

    printf -- "Finished building %s .\n" "$PACKAGE_CBPY"
}

# [IBM]
function buildCurlNoTLS() {
    source $PRESERVE_ENVARS
    NAME_CURL=curl
    VERSION_CURL=8.21.0
    BUILD_CURL=2
    PACKAGE_CURL=$NAME_CURL-linux-s390x-$VERSION_CURL-$BUILD_CURL

    printf -- "Start building %s .\n" "$PACKAGE_CURL"
    if [ -d  $SOURCE_ROOT/$NAME_CURL ]; then
        printf -- "The file already exists. Nothing to do. \n"
        return 0
    fi


    cd $SOURCE_ROOT
    sudo ldconfig /usr/local/lib64 /usr/local/lib
    git clone -b curl-8_9_1 --depth 1 https://github.com/curl/curl.git
    cd curl
    cmake -G "Unix Makefiles" .
    autoreconf -fi
    ./configure --prefix=$(pwd)/_build --libdir=$(pwd)/_build/lib --without-ssl
    make -j$(nproc)
    make install
    hash -r
    cd _build
    cat <<EOF >CMakeLists.txt
FILE (COPY bin lib DESTINATION "\${CMAKE_INSTALL_PREFIX}")
SET_PROPERTY (GLOBAL APPEND PROPERTY CBDEPS_PREFIX_PATH "\${CMAKE_CURRENT_SOURCE_DIR}")
EOF
    echo "$VERSION_CURL-$BUILD_CURL" >VERSION.txt
    # Packaging build files
    tar -czvf $PACKAGE_CURL.tgz *
    MD5_CURL=($(md5sum $PACKAGE_CURL.tgz))
    echo $MD5_CURL >$PACKAGE_CURL.md5
    # Copy the package to destination
    cp $PACKAGE_CURL.* $CACHE_DIRECTORY

    printf -- "Finished building %s .\n" "$PACKAGE_CURL"
}

# [IBM]
function buildDconvertion() {
    source $PRESERVE_ENVARS
    NAME_DCONVERTION=double-conversion
    VERSION_DCONVERTION=3.3.0
    BUILD_DCONVERTION=cb1
    PACKAGE_DCONVERTION=$NAME_DCONVERTION-linux-s390x-$VERSION_DCONVERTION-$BUILD_DCONVERTION

    printf -- "Start building %s .\n" "$PACKAGE_DCONVERTION"
    if [ -d  $SOURCE_ROOT/$NAME_DCONVERTION ]; then
        printf -- "The file already exists. Nothing to do. \n"
        return 0
    fi

    cd $SOURCE_ROOT
    git clone -b v$VERSION_DCONVERTION --depth 1 https://github.com/google/double-conversion.git
    cd double-conversion
    cmake -D BUILD_SHARED_LIBS=OFF -D BUILD_TESTING=OFF -D CMAKE_INSTALL_PREFIX=$(pwd)/_build -D CMAKE_INSTALL_LIBDIR=lib .
    make -j$(nproc)
    make install
    cmake -E remove_directory $(pwd)/_build/lib/cmake
    cd _build
    # Packaging build files
    tar -czvf $PACKAGE_DCONVERTION.tgz *
    MD5_DCONVERTION=($(md5sum $PACKAGE_DCONVERTION.tgz))
    echo $MD5_DCONVERTION >$PACKAGE_DCONVERTION.md5
    # Copy the package to destination
    cp $PACKAGE_DCONVERTION.* $CACHE_DIRECTORY

    printf -- "Finished building %s .\n" "$PACKAGE_DCONVERTION"
}

# [IBM]
function buildErlang() {
    source $PRESERVE_ENVARS
    NAME_ERLANG=erlang
    VERSION_ERLANG=28.5.0.5
    BUILD_ERLANG=1
    PACKAGE_ERLANG=$NAME_ERLANG-linux-s390x-$VERSION_ERLANG-$BUILD_ERLANG

    printf -- "Start building %s .\n" "$PACKAGE_ERLANG"
    if [ -d  $SOURCE_ROOT/$NAME_ERLANG ]; then
        printf -- "The file already exists. Nothing to do. \n"
        return 0
    fi


    cd $SOURCE_ROOT
    git clone -b couchbase-$VERSION_ERLANG --depth 1 https://github.com/couchbasedeps/erlang.git
    cd erlang
    ./configure --prefix=$(pwd)/_build \
            --libdir=$(pwd)/_build/lib \
            --enable-smp-support \
            --disable-hipe \
            --disable-fp-exceptions \
            --without-javac \
            --enable-m64-build \
            CFLAGS="-fno-strict-aliasing -O3 -ggdb3"
    make -j$(nproc)
    make install
    hash -r
    cd _build
    echo $VERSION_ERLANG >VERSION.txt
    cat <<EOF >CMakeLists.txt
FILE (COPY bin lib DESTINATION "\${CMAKE_INSTALL_PREFIX}")
EXECUTE_PROCESS (
    COMMAND "\${CMAKE_INSTALL_PREFIX}/lib/erlang/Install"
        -minimal "\${CMAKE_INSTALL_PREFIX}/lib/erlang"
)
EOF
    # Packaging build files
    tar -czvf $PACKAGE_ERLANG.tgz *
    MD5_ERLANG=($(md5sum $PACKAGE_ERLANG.tgz))
    echo $MD5_ERLANG >$PACKAGE_ERLANG.md5
    # Copy the package to destination
    cp $PACKAGE_ERLANG.* $CACHE_DIRECTORY

    printf -- "Finished building %s .\n" "$PACKAGE_ERLANG"
    printf -- "Start building %s .\n" "rebar3 3.25.1"
    cd $SOURCE_ROOT
    VERSION_REBAR3=3.25.1
    PATH=$PATH:$SOURCE_ROOT/erlang/bin
    git clone -b $VERSION_REBAR3  --depth 1 https://github.com/erlang/rebar3
    cd rebar3
    ./bootstrap
    sudo cp rebar3 /usr/local/bin/
    printf -- "Finished building %s .\n" "rebar3 3.25.1"
}

# [IBM]
function buildFbuf() {
    source $PRESERVE_ENVARS
    NAME_FBUF=flatbuffers
    VERSION_FBUF=v1.10.0
    BUILD_FBUF=cb7
    PACKAGE_FBUF=$NAME_FBUF-linux-s390x-$VERSION_FBUF-$BUILD_FBUF

    printf -- "Start building %s .\n" "$PACKAGE_FBUF"
    if [ -d  $SOURCE_ROOT/$NAME_FBUF ]; then
        printf -- "The file already exists. Nothing to do. \n"
        return 0
    fi


    cd $SOURCE_ROOT
    git clone -b $VERSION_FBUF --depth 1 https://github.com/google/flatbuffers
    cd flatbuffers
    fetchPatch flatbuffers.diff
    git apply $SOURCE_ROOT/patch/flatbuffers.diff
    curl https://github.com/google/flatbuffers/commit/2e865f4d4e67a9b628c137aab7da8140dd9339a4.patch | git apply -
    cmake -G "Unix Makefiles" -D CMAKE_INSTALL_PREFIX=$(pwd)/_build -D CMAKE_BUILD_TYPE=Release -D FLATBUFFERS_BUILD_TESTS=OFF -D CMAKE_INSTALL_LIBDIR=lib -DFLATBUFFERS_WERROR=OFF  -DCMAKE_CXX_FLAGS="-Wno-error -Wno-stringop-overread -Wno-stringop-overflow -Wno-array-bounds"
    make -j $(nproc)
    make install
    hash -r
    cd _build
    touch CMakeLists.txt
    # Packaging build files
    tar -czvf $PACKAGE_FBUF.tgz *
    MD5_FBUF=($(md5sum $PACKAGE_FBUF.tgz))
    echo $MD5_FBUF >$PACKAGE_FBUF.md5
    # Copy the package to destination
    cp $PACKAGE_FBUF.* $CACHE_DIRECTORY

    printf -- "Finished building %s .\n" "$PACKAGE_FBUF"
}

# [IBM]
function buildFmt() {
    source $PRESERVE_ENVARS
    NAME_FMT=fmt
    VERSION_FMT=11.0.0
    BUILD_FMT=cb2
    PACKAGE_FMT=$NAME_FMT-linux-s390x-$VERSION_FMT-$BUILD_FMT

    printf -- "Start building %s .\n" "$PACKAGE_FMT"
    if [ -d  $SOURCE_ROOT/$NAME_FMT ]; then
        printf -- "The file already exists. Nothing to do. \n"
        return 0
    fi

    cd $SOURCE_ROOT
    git clone -b $VERSION_FMT --depth 1 https://github.com/fmtlib/fmt.git
    cd fmt
    cmake -D CMAKE_INSTALL_PREFIX=$(pwd)/_build -D CMAKE_BUILD_TYPE=RelWithDebInfo -D CMAKE_CXX_VISIBILITY_PRESET=hidden -D CMAKE_POSITION_INDEPENDENT_CODE=ON -D CMAKE_INSTALL_LIBDIR=lib .
    make -j$(nproc)
    make install
    cd _build
    # Packaging build files
    tar -czvf $PACKAGE_FMT.tgz *
    MD5_FMT=($(md5sum $PACKAGE_FMT.tgz))
    echo $MD5_FMT >$PACKAGE_FMT.md5
    # Copy the package to destination
    cp $PACKAGE_FMT.* $CACHE_DIRECTORY

    printf -- "Finished building %s .\n" "$PACKAGE_FMT"
}

# [IBM]
function buildSnappy() {
    source $PRESERVE_ENVARS
    NAME_SNAPPY=snappy
    VERSION_SNAPPY=1.1.10
    BUILD_SNAPPY=cb3
    PACKAGE_SNAPPY=$NAME_SNAPPY-linux-s390x-$VERSION_SNAPPY-$BUILD_SNAPPY

    printf -- "Start building %s .\n" "$PACKAGE_SNAPPY"
    if [ -d  $SOURCE_ROOT/snappy ]; then
        printf -- "The file already exists. Nothing to do. \n"
        return 0
    fi

    cd $SOURCE_ROOT
    git clone -b $VERSION_SNAPPY --depth 1 https://github.com/google/snappy.git
    cd snappy
    wget https://raw.githubusercontent.com/couchbase/tlm/8.0.0/deps/packages/snappy/snappy.patch
    git apply snappy.patch
    cmake -D CMAKE_INSTALL_PREFIX=$(pwd)/_build \
        -D SNAPPY_BUILD_TESTS=OFF \
        -D BUILD_SHARED_LIBS=ON \
        -D CMAKE_INSTALL_LIBDIR=lib \
        -D SNAPPY_BUILD_BENCHMARKS=OFF .
    make -j$(nproc)
    make install
    hash -r
    cd _build
    cat <<EOF >CMakeLists.txt
file(GLOB snappy_libs lib/*snappy*)
file(COPY \${snappy_libs} DESTINATION "\${CMAKE_INSTALL_PREFIX}/lib")
EOF
    # Packaging build files
    tar -czvf $PACKAGE_SNAPPY.tgz *
    MD5_SNAPPY=($(md5sum $PACKAGE_SNAPPY.tgz))
    echo $MD5_SNAPPY >$PACKAGE_SNAPPY.md5
    # Copy the package to destination
    cp $PACKAGE_SNAPPY.* $CACHE_DIRECTORY

    printf -- "Finished building %s .\n" "$PACKAGE_SNAPPY"
}

# [IBM]
function buildOssl() {
    source $PRESERVE_ENVARS
    NAME_OSSL=openssl
    VERSION_OSSL=3.5.7
    BUILD_OSSL=1
    PACKAGE_OSSL=$NAME_OSSL-linux-s390x-$VERSION_OSSL-$BUILD_OSSL

    printf -- "Start building %s .\n" "$PACKAGE_OSSL"
    if [ -d  $SOURCE_ROOT/$NAME_OSSL-$VERSION_OSSL ]; then
        printf -- "The file already exists. Nothing to do. \n"
        return 0
    fi


    cd $SOURCE_ROOT
    wget https://github.com/openssl/openssl/releases/download/openssl-$VERSION_OSSL/openssl-$VERSION_OSSL.tar.gz
    tar -xzf openssl-$VERSION_OSSL.tar.gz
    cd openssl-$VERSION_OSSL

    ./config --prefix=$(pwd)/_build --openssldir=$(pwd)/_build/etc/openssl --libdir=$(pwd)/_build/lib
    make -j$(nproc)
    make install
    hash -r
    cd _build
    echo "$VERSION_OSSL-$BUILD_OSSL" >VERSION.txt
    cat <<EOF >CMakeLists.txt
FILE (COPY bin DESTINATION "\${CMAKE_INSTALL_PREFIX}")
FILE (COPY lib DESTINATION "\${CMAKE_INSTALL_PREFIX}")
FILE (COPY etc DESTINATION "\${CMAKE_INSTALL_PREFIX}")
SET_PROPERTY (GLOBAL APPEND PROPERTY CBDEPS_PREFIX_PATH "\${CMAKE_CURRENT_SOURCE_DIR}")
EOF
    # Packaging build files
    tar -czvf $PACKAGE_OSSL.tgz *
    MD5_OSSL=($(md5sum $PACKAGE_OSSL.tgz))
    echo $MD5_OSSL >$PACKAGE_OSSL.md5
    # Copy the package to destination
    cp $PACKAGE_OSSL.* $CACHE_DIRECTORY
    printf -- "Finished building %s .\n" "$PACKAGE_OSSL"
}

# [IBM]
function buildLibevent() {
    source $PRESERVE_ENVARS
    NAME_LIBEVENT=libevent
    VERSION_LIBEVENT=2.1.13
    BUILD_LIBEVENT=cb2
    PACKAGE_LIBEVENT=$NAME_LIBEVENT-linux-s390x-$VERSION_LIBEVENT-$BUILD_LIBEVENT

    printf -- "Start building %s .\n" "$PACKAGE_LIBEVENT"
    if [ -d  $SOURCE_ROOT/$NAME_LIBEVENT ]; then
        printf -- "The file already exists. Nothing to do. \n"
        return 0
    fi

    OPENSSL_BUILD=$SOURCE_ROOT/openssl-3.5.7/_build

    cd $SOURCE_ROOT
    git clone -b release-$VERSION_LIBEVENT-stable --depth 1 https://github.com/libevent/libevent.git
    cd libevent

    cmake -D CMAKE_INSTALL_PREFIX=`pwd`/_build \
        -D CMAKE_INSTALL_LIBDIR=lib \
        -D CMAKE_BUILD_TYPE=RelWithDebInfo \
        -D EVENT__DISABLE_BENCHMARK=ON \
        -D EVENT__DISABLE_REGRESS=ON \
        -D EVENT__DISABLE_SAMPLES=ON \
        -D OPENSSL_ROOT_DIR=$OPENSSL_BUILD .

    make -j$(nproc)
    make install
    cd _build
    cat <<EOF >CMakeLists.txt
FILE (COPY lib DESTINATION \${CMAKE_INSTALL_PREFIX})
EOF
    # Packaging build files
    tar -czvf $PACKAGE_LIBEVENT.tgz *
    MD5_LIBEVENT=($(md5sum $PACKAGE_LIBEVENT.tgz))
    echo $MD5_LIBEVENT >$PACKAGE_LIBEVENT.md5
    # Copy the package to destination
    cp $PACKAGE_LIBEVENT.* $CACHE_DIRECTORY

    printf -- "Finished building %s .\n" "$PACKAGE_LIBEVENT"
}

# [IBM]
function buildGlog() {
    source $PRESERVE_ENVARS
    NAME_GLOG=glog
    VERSION_GLOG=v0.4.0
    BUILD_GLOG=cb3
    PACKAGE_GLOG=$NAME_GLOG-linux-s390x-$VERSION_GLOG-$BUILD_GLOG
    
    printf -- "Start building %s .\n" "$PACKAGE_GLOG"
    if [ -d  $SOURCE_ROOT/$NAME_GLOG ]; then
        printf -- "The file already exists. Nothing to do. \n"
        return 0
    fi
    
    
    cd $SOURCE_ROOT
    git clone -b $VERSION_GLOG --depth 1 https://github.com/google/glog.git
    cd glog 
     # 2. Path to the fixed gflags (required for symbol registration)
    GFLAGS_DIR="$SOURCE_ROOT/couchbase/build/tlm/deps/gflags.exploded"
    
    # 3. Build with explicit gflags support and PIC
    # We use -DWITH_GFLAGS=ON and point to the exploded directory
    cmake -S . -B build \
    -D BUILD_SHARED_LIBS=OFF \
    -D CMAKE_POSITION_INDEPENDENT_CODE=ON \
    -D CMAKE_INSTALL_PREFIX=$(pwd)/_build \
    -D CMAKE_BUILD_TYPE=RelWithDebInfo \
    -D CMAKE_INSTALL_LIBDIR=lib \
    -D WITH_GFLAGS=OFF
        cmake --build build --target install
        
    # 4. Create Couchbase helper and package
    cd _build
    cat <<EOF > CMakeLists.txt
FILE (COPY lib DESTINATION "\${CMAKE_INSTALL_PREFIX}")
FILE (COPY include DESTINATION "\${CMAKE_INSTALL_PREFIX}")
SET_PROPERTY (GLOBAL APPEND PROPERTY CBDEPS_PREFIX_PATH "\${CMAKE_CURRENT_SOURCE_DIR}")
EOF

    # Use GNU format for s390x libarchive compatibility
    tar --format=gnu --owner=0 --group=0 -czvf "$PACKAGE_GLOG.tgz" ./*
    md5sum "$PACKAGE_GLOG.tgz" | cut -d' ' -f1 > "$PACKAGE_GLOG.md5"

    cp "$PACKAGE_GLOG".* "$CACHE_DIRECTORY"

    printf -- "Finished building %s .\n" "$PACKAGE_GLOG"

}

# [IBM]
function buildZstd() {
    source $PRESERVE_ENVARS
    NAME_ZSTD=zstd-cpp
    VERSION_ZSTD=1.5.0
    BUILD_ZSTD=4
    PACKAGE_ZSTD=$NAME_ZSTD-linux-s390x-$VERSION_ZSTD-$BUILD_ZSTD

    printf -- "Start building %s .\n" "$PACKAGE_ZSTD"
    if [ -d  $SOURCE_ROOT/zstd-$VERSION_ZSTD ]; then
        printf -- "The file already exists. Nothing to do. \n"
        return 0
    fi


    cd $SOURCE_ROOT
    wget https://github.com/facebook/zstd/archive/refs/tags/v$VERSION_ZSTD.tar.gz
    tar -xzvf v$VERSION_ZSTD.tar.gz
    cd zstd-$VERSION_ZSTD
    make DESTDIR=$(pwd)/_build install
    cd _build
    cp -r ./usr/local/* . && rm -drf usr bin share
    echo "${VERSION_ZSTD}-4" >VERSION.txt
    cat <<EOF >CMakeLists.txt
FILE (COPY lib DESTINATION "\${CMAKE_INSTALL_PREFIX}")
EOF
    # Packaging build files
    tar -czvf $PACKAGE_ZSTD.tgz *
    MD5_ZSTD=($(md5sum $PACKAGE_ZSTD.tgz))
    echo $MD5_ZSTD >$PACKAGE_ZSTD.md5
    # Copy the package to destination
    cp $PACKAGE_ZSTD.* $CACHE_DIRECTORY

    printf -- "Finished building %s .\n" "$PACKAGE_ZSTD"
}

# [IBM]
function setGitGlobalConfig() {
    user_name=$(git config user.name)
    user_email=$(git config user.email)
    set -e
    if [ -z ${user_name} ] || [ -z ${user_email} ]; then
        printf -- 'Set up git user\n'
        git config --global user.email "tester@email"
        git config --global user.name "tester"
    fi
}

# [IBM]
function buildFolly() {
    buildJemalloc
    source $PRESERVE_ENVARS
    NAME_FOLLY=folly
    VERSION_FOLLY=v2022.05.23.00-couchbase
    BUILD_FOLLY=cb3_avx2
    PACKAGE_FOLLY=$NAME_FOLLY-linux-s390x-$VERSION_FOLLY-$BUILD_FOLLY

    printf -- "Start building %s .\n" "$PACKAGE_FOLLY"
    if [ -d  $SOURCE_ROOT/$NAME_FOLLY ]; then
        printf -- "The file already exists. Nothing to do. \n"
        return 0
    fi

    JEMALLOC_BUILD=$SOURCE_ROOT/jemalloc/_build
    FMT_BUILD=$SOURCE_ROOT/fmt/_build
    GLOG_BUILD=$SOURCE_ROOT/glog/_build
    BOOST_BUILD=$SOURCE_ROOT/boost-1.86.0/_build
    DOUBLE_CONVERSION_BUILD=$SOURCE_ROOT/double-conversion/_build
    LIBEVENT_BUILD=$SOURCE_ROOT/libevent/_build
    OPENSSL_BUILD=$SOURCE_ROOT/openssl-3.5.7/_build
    SNAPPY_BUILD=$SOURCE_ROOT/snappy/_build
    ZSTD_BUILD=$SOURCE_ROOT/zstd-1.5.0/_build

    LIBRARIES="$JEMALLOC_BUILD/lib;$FMT_BUILD/lib;$GLOG_BUILD/lib;$BOOST_BUILD/lib;$DOUBLE_CONVERSION_BUILD/lib;$LIBEVENT_BUILD/lib;$OPENSSL_BUILD/lib;$SNAPPY_BUILD/lib;$ZSTD_BUILD/lib;"
    INCLUDES="$JEMALLOC_BUILD/include;$FMT_BUILD/include;$GLOG_BUILD/include;$BOOST_BUILD/include;$DOUBLE_CONVERSION_BUILD/include;$LIBEVENT_BUILD/include;$OPENSSL_BUILD/include;$SNAPPY_BUILD/include;$ZSTD_BUILD/include"

    cd $SOURCE_ROOT
    git clone -b $VERSION_FOLLY --depth 1 https://github.com/couchbasedeps/folly.git
    cd folly
    fetchPatch folly.diff
    git apply $SOURCE_ROOT/patch/folly.diff
    sudo ldconfig /usr/local/lib64 /usr/local/lib

    cmake \
        -D CMAKE_INCLUDE_PATH=$INCLUDES \
        -D CMAKE_LIBRARY_PATH=$LIBRARIES \
        -D CMAKE_CXX_FLAGS="-fPIC -fvisibility=hidden" \
        -D CMAKE_BUILD_TYPE=RelWithDebInfo \
        -D CMAKE_INSTALL_PREFIX=$(pwd)/_build \
        -D BUILD_SHARED_LIBS:STRING=OFF \
        -D Boost_INCLUDE_DIR=$BOOST_BUILD/include \
        -D Boost_ADDITIONAL_VERSIONS=1.82 \
        -D Boost_USE_STATIC_LIBS=ON \
        -D Boost_NO_SYSTEM_PATHS=ON \
        -D Boost_NO_BOOST_CMAKE=ON \
        -D BOOST_ROOT=$BOOST_BUILD \
        -D CMAKE_PREFIX_PATH=$FMT_BUILD \
        -D CMAKE_DISABLE_FIND_PACKAGE_ZLIB=TRUE .

    make -j$(nproc)
    make install
    cd _build
    echo "${VERSION_FOLLY}-${BUILD_FOLLY}" >VERSION.txt
    # Packaging build files
    tar -czvf $PACKAGE_FOLLY.tgz *
    MD5_FOLLY=($(md5sum $PACKAGE_FOLLY.tgz))
    echo $MD5_FOLLY >$PACKAGE_FOLLY.md5
    # Copy the package to destination
    cp $PACKAGE_FOLLY.* $CACHE_DIRECTORY

    printf -- "Finished building %s .\n" "$PACKAGE_FOLLY"
}

# [IBM]
function buildGtest() {
    source $PRESERVE_ENVARS
    NAME_GTEST=googletest
    VERSION_GTEST=1.15.2
    BUILD_GTEST=cb1
    PACKAGE_GTEST=$NAME_GTEST-linux-s390x-$VERSION_GTEST-$BUILD_GTEST

    printf -- "Start building %s .\n" "$PACKAGE_GTEST"
    if [ -d  $SOURCE_ROOT/$NAME_GTEST ]; then
        printf -- "The file already exists. Nothing to do. \n"
        return 0
    fi


    cd $SOURCE_ROOT
    git clone -b v$VERSION_GTEST --depth 1 https://github.com/google/googletest.git
    cd googletest
    cmake -D CMAKE_INSTALL_PREFIX=$(pwd)/_build \
        -D CMAKE_BUILD_TYPE=RelWithDebInfo \
        -D CMAKE_INSTALL_LIBDIR=lib \
        -D CMAKE_CXX_STANDARD=17 \
        -D CMAKE_CXX_STANDARD_REQUIRED=ON \
        -D BUILD_SHARED_LIBS=OFF \
        -D gtest_force_shared_crt=ON .

    make -j$(nproc)
    make install
    cd _build
    rm -drf ./lib/pkgconfig
    # Packaging build files
    tar -czvf $PACKAGE_GTEST.tgz *
    MD5_GTEST=($(md5sum $PACKAGE_GTEST.tgz))
    echo $MD5_GTEST >$PACKAGE_GTEST.md5
    # Copy the package to destination
    cp $PACKAGE_GTEST.* $CACHE_DIRECTORY

    printf -- "Finished building %s .\n" "$PACKAGE_GTEST"
}

# [IBM]
function buildZlib() {
    source $PRESERVE_ENVARS
    NAME_ZLIB=zlib
    VERSION_ZLIB=1.2.13
    BUILD_ZLIB=2
    PACKAGE_ZLIB=$NAME_ZLIB-linux-s390x-$VERSION_ZLIB-$BUILD_ZLIB

    printf -- "Start building %s .\n" "$PACKAGE_ZLIB"
    if [ -d  $SOURCE_ROOT/$NAME_ZLIB ]; then
        printf -- "The file already exists. Nothing to do. \n"
        return 0
    fi


    cd $SOURCE_ROOT
    git clone -b v$VERSION_ZLIB --depth 1 https://github.com/madler/zlib.git
    cd zlib

    ./configure --prefix=$(pwd)/_build --64
    make -j$(nproc)
    make install
    cd _build
    echo "${VERSION_ZLIB}-2" >VERSION.txt
    cat <<EOF >CMakeLists.txt
FILE (COPY lib DESTINATION "\${CMAKE_INSTALL_PREFIX}")
SET_PROPERTY (GLOBAL APPEND PROPERTY CBDEPS_PREFIX_PATH "\${CMAKE_CURRENT_SOURCE_DIR}")
EOF
    # Packaging build files
    tar -czvf $PACKAGE_ZLIB.tgz *
    MD5_ZLIB=($(md5sum $PACKAGE_ZLIB.tgz))
    echo $MD5_ZLIB >$PACKAGE_ZLIB.md5
    # Copy the package to destination
    cp $PACKAGE_ZLIB.* $CACHE_DIRECTORY

    printf -- "Finished building %s .\n" "$PACKAGE_ZLIB"
}

# [IBM]
function buildGrpc() {
    source $PRESERVE_ENVARS
    NAME_GRPC=grpc
    VERSION_GRPC=1.78.1
    BUILD_GRPC=1
    PACKAGE_GRPC=$NAME_GRPC-linux-s390x-$VERSION_GRPC-$BUILD_GRPC

    printf -- "Start building %s .\n" "$PACKAGE_GRPC"
    if [ -d  $SOURCE_ROOT/$NAME_GRPC ]; then
        printf -- "The file already exists. Nothing to do. \n"
        return 0
    fi


    cd $SOURCE_ROOT
    git clone -b v$VERSION_GRPC https://github.com/grpc/grpc
    cd grpc/
    git submodule update --init --recursive

    if [ $ID$VERSION_ID == "ubuntu22.04" ] || [ $ID$VERSION_ID == "ubuntu24.04" ] || [ $ID$VERSION_ID == "rhel9."* ]; then
        sed -i '59i #undef SIGSTKSZ' third_party/abseil-cpp/absl/debugging/failure_signal_handler.cc
        sed -i '60i #define SIGSTKSZ 16384' third_party/abseil-cpp/absl/debugging/failure_signal_handler.cc
    fi
    if [ $ID$VERSION_ID == "rhel9."* ]; then
        sed -i '20i #include <limits>' third_party/abseil-cpp/absl/flags/usage_config.cc
    fi
    BUILD_DIR=$(pwd)/_build
    # Point to zlib build file.
    ZLIB_BUILD_DIR=$SOURCE_ROOT/zlib/_build
    # Point to OpenSSL build file.
    OPENSSL_BUILD_DIR=$SOURCE_ROOT/openssl-3.5.7/_build
    (
        cd third_party/abseil-cpp
        cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo \
            -DCMAKE_INSTALL_PREFIX="$BUILD_DIR" .
         make -j$(nproc) install
    )
    (
        cd third_party/protobuf
        CXXFLAGS="-fcommon" cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo \
            -DCMAKE_INSTALL_PREFIX="$BUILD_DIR" \
            -Dprotobuf_BUILD_TESTS=OFF \
            -Dprotobuf_ABSL_PROVIDER=package \
            -DCMAKE_PREFIX_PATH="$BUILD_DIR" \
            -D CMAKE_PREFIX_PATH="$ZLIB_BUILD_DIR" .
        make -j$(nproc) install
    )
    (
        cd third_party/cares/cares
        cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo \
            -DCMAKE_INSTALL_PREFIX="$BUILD_DIR" \
            -DCARES_STATIC=ON -DCARES_STATIC_PIC=ON -DCARES_SHARED=OFF .
        make -j$(nproc) install
    )
    (
        cd third_party/re2
        cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo \
            -DCMAKE_INSTALL_PREFIX="$BUILD_DIR" .
        make -j$(nproc) install
    )
    cmake -D CMAKE_BUILD_TYPE=RelWithDebInfo \
        -D CMAKE_INSTALL_PREFIX=$BUILD_DIR \
        -D CMAKE_PREFIX_PATH="$ZLIB_BUILD_DIR;$OPENSSL_BUILD_DIR;$BUILD_DIR" \
        -DgRPC_INSTALL=ON \
        -DgRPC_BUILD_TESTS=OFF \
        -DgRPC_ABSL_PROVIDER=package     \
        -DgRPC_PROTOBUF_PROVIDER=package \
        -DgRPC_ZLIB_PROVIDER=package \
        -DgRPC_CARES_PROVIDER=package \
        -DgRPC_RE2_PROVIDER=package  \
        -DgRPC_SSL_PROVIDER=package \
        -D CMAKE_INSTALL_LIBDIR=lib .
    make -j$(nproc) install
    cd _build
    # Packaging build files
    tar -czvf $PACKAGE_GRPC.tgz *
    MD5_GRPC=($(md5sum $PACKAGE_GRPC.tgz))
    echo $MD5_GRPC >$PACKAGE_GRPC.md5
    # Copy the package to destination
    cp $PACKAGE_GRPC.* $CACHE_DIRECTORY

    printf -- "Finished building %s .\n" "$PACKAGE_GRPC"
}

# [IBM]
function buildJemalloc() {
    source $PRESERVE_ENVARS
    NAME_JEMALLOC=jemalloc
    VERSION_JEMALLOC=5.3.0
    BUILD_JEMALLOC=17
    PACKAGE_JEMALLOC=$NAME_JEMALLOC-linux-s390x-$VERSION_JEMALLOC-$BUILD_JEMALLOC

    printf -- "Start building %s .\n" "$PACKAGE_JEMALLOC"
    if [ -d  $SOURCE_ROOT/$NAME_JEMALLOC ]; then
        printf -- "The file already exists. Nothing to do. \n"
        return 0
    fi


    cd $SOURCE_ROOT
    git clone -b $VERSION_JEMALLOC --depth 1 https://github.com/couchbasedeps/jemalloc.git
    cd jemalloc
    configure_args="--prefix=$(pwd)/_build \
   --with-jemalloc-prefix=je_ \
   --disable-cache-oblivious \
   --disable-zone-allocator \
   --disable-initial-exec-tls \
   --disable-cxx \
   --enable-prof \
   --libdir=$(pwd)/_build/lib"

    ./autogen.sh ${configure_args}
    make -j8 build_lib_shared
    make -j8 check
    make install_lib_shared install_include install_bin

    configure_args="--prefix=$(pwd)/_build \
   --with-jemalloc-prefix=je_ \
   --enable-debug \
   --disable-cache-oblivious \
   --disable-zone-allocator \
   --disable-initial-exec-tls \
   --disable-cxx \
   --enable-prof \
   --with-install-suffix=d \
   --libdir=$(pwd)/_build/lib"

    CFLAGS=-Og ./autogen.sh ${configure_args}
    make -j8 build_lib_shared
    make -j8 check
    make install_lib_shared

    cd _build
    cat <<EOF >CMakeLists.txt
FILE (COPY bin/jeprof DESTINATION "\${CMAKE_INSTALL_PREFIX}/bin")
FILE (COPY lib DESTINATION "\${CMAKE_INSTALL_PREFIX}")
SET_PROPERTY (GLOBAL APPEND PROPERTY CBDEPS_PREFIX_PATH "\${CMAKE_CURRENT_SOURCE_DIR}")
EOF
    mkdir -p cmake && cd cmake
    wget https://raw.githubusercontent.com/couchbase/build-tools/master/cbdeps/jemalloc/package/cmake/JemallocConfig.cmake

    cd $SOURCE_ROOT/jemalloc/_build
    # Packaging build files
    tar -czvf $PACKAGE_JEMALLOC.tgz *
    MD5_JEMALLOC=($(md5sum $PACKAGE_JEMALLOC.tgz))
    echo $MD5_JEMALLOC >$PACKAGE_JEMALLOC.md5
    # Copy the package to destination
    cp $PACKAGE_JEMALLOC.* $CACHE_DIRECTORY

    printf -- "Finished building %s .\n" "$PACKAGE_JEMALLOC"
}

# [IBM]
function buildJemalloc_noprefix() {
    source $PRESERVE_ENVARS
    NAME_JEMALLOC=jemalloc_noprefix
    VERSION_JEMALLOC=5.2.1
    BUILD_JEMALLOC=12
    PACKAGE_JEMALLOC=$NAME_JEMALLOC-linux-s390x-$VERSION_JEMALLOC-$BUILD_JEMALLOC

    if [ -f "$CACHE_DIRECTORY/$PACKAGE_JEMALLOC.tgz" ]; then
        printf -- "Package %s already exists. Skipping.\n" "$PACKAGE_JEMALLOC"
        return 0
    fi

    printf -- "Start building %s .\n" "$PACKAGE_JEMALLOC"
    if [ -d  $SOURCE_ROOT/$NAME_JEMALLOC ]; then
        printf -- "The file already exists. Nothing to do. \n"
        return 0
    fi

    cd $SOURCE_ROOT
    git clone -b $VERSION_JEMALLOC --depth 1 https://github.com/couchbasedeps/jemalloc.git jemalloc_noprefix
    cd jemalloc_noprefix
    configure_args="--prefix=$(pwd)/_build \
   --with-jemalloc-prefix= \
   --with-install-suffix=_noprefix \
   --enable-prof \
   --libdir=$(pwd)/_build/lib"

    ./autogen.sh ${configure_args}
    make -j8 build_lib_shared
    #make -j8 check
    make install_lib_shared install_include install_bin

    configure_args="--prefix=$(pwd)/_build \
   --with-jemalloc-prefix= \
   --enable-debug \
   --with-install-suffix=_noprefix \
   --enable-prof \
   --with-install-suffix=_noprefixd \
   --libdir=$(pwd)/_build/lib"

    CFLAGS=-Og ./autogen.sh ${configure_args}
    make -j8 build_lib_shared
    #make -j8 check
    make install_lib_shared

    cd _build
    cat <<EOF >CMakeLists.txt
FILE (COPY bin/jeprof DESTINATION "\${CMAKE_INSTALL_PREFIX}/bin")
FILE (COPY lib DESTINATION "\${CMAKE_INSTALL_PREFIX}")
SET_PROPERTY (GLOBAL APPEND PROPERTY CBDEPS_PREFIX_PATH "\${CMAKE_CURRENT_SOURCE_DIR}")
EOF

    mkdir -p cmake && cd cmake
    wget https://raw.githubusercontent.com/couchbase/build-tools/master/cbdeps/jemalloc_noprefix/package/cmake/Jemalloc_noprefixConfig.cmake
    # mv Jemalloc_noprefixConfig.cmake Jemalloc_NoprefixConfig.cmake
    cd $SOURCE_ROOT/jemalloc_noprefix/_build
    # Packaging build files
    tar -czvf $PACKAGE_JEMALLOC.tgz *
    MD5_JEMALLOC=($(md5sum $PACKAGE_JEMALLOC.tgz))
    echo $MD5_JEMALLOC >$PACKAGE_JEMALLOC.md5
    # Copy the package to destination
    cp $PACKAGE_JEMALLOC.* $CACHE_DIRECTORY

    printf -- "Finished building %s .\n" "$PACKAGE_JEMALLOC"
}

# [IBM]
function buildJson() {
    source $PRESERVE_ENVARS
    NAME_JSON=json
    VERSION_JSON=3.11.3
    BUILD_JSON=cb2
    PACKAGE_JSON=$NAME_JSON-linux-s390x-$VERSION_JSON-$BUILD_JSON

    printf -- "Start building %s .\n" "$PACKAGE_JSON"
    if [ -d  $SOURCE_ROOT/$NAME_JSON ]; then
        printf -- "The file already exists. Nothing to do. \n"
        return 0
    fi


    cd $SOURCE_ROOT
    git clone -b v$VERSION_JSON --depth 1 https://github.com/nlohmann/json
    cd $SOURCE_ROOT/json
    cmake -D CMAKE_INSTALL_PREFIX=$(pwd)/_build -D CMAKE_BUILD_TYPE=RelWithDebInfo -D JSON_BuildTests=OFF -D JSON_Install=ON -D JSON_MultipleHeaders=ON -D JSON_SystemInclude=ON -D CMAKE_INSTALL_LIBDIR=lib
    cmake --build . --target install
    cd _build
    # Packaging build files
    tar -czvf $PACKAGE_JSON.tgz *
    MD5_JSON=($(md5sum $PACKAGE_JSON.tgz))
    echo $MD5_JSON >$PACKAGE_JSON.md5
    # Copy the package to destination
    cp $PACKAGE_JSON.* $CACHE_DIRECTORY

    printf -- "Finished building %s .\n" "$PACKAGE_JSON"
}

# [IBM]
function buildLiburing() {
    source $PRESERVE_ENVARS
    NAME_LIBURING=liburing
    VERSION_LIBURING=0.6
    BUILD_LIBURING=3
    PACKAGE_LIBURING=$NAME_LIBURING-linux-s390x-$VERSION_LIBURING-$BUILD_LIBURING

    printf -- "Start building %s .\n" "$PACKAGE_LIBURING"
    if [ -d  $SOURCE_ROOT/$NAME_LIBURING ]; then
        printf -- "The file already exists. Nothing to do. \n"
        return 0
    fi


    cd $SOURCE_ROOT
    git clone https://github.com/axboe/liburing.git
    cd liburing
    set +e
    git checkout liburing-$VERSION_LIBURING
    setGitGlobalConfig
    if [[ $DISTRO != rhel8* ]]; then
        git cherry-pick 8aac320ae8445c5434ab3be1761414a5247e5d42
    fi
    set -e
    sed -i 's/|\sMAP_HUGE_2MB\s//g' ./test/io_uring_register.c
    ./configure --prefix=$(pwd)/_build --libdir=$(pwd)/_build/lib
    make -j$(nproc)
    make install
    cd _build
    cat <<EOF >CMakeLists.txt
FILE (COPY lib DESTINATION "\${CMAKE_INSTALL_PREFIX}")
EOF
    # Packaging build files
    tar -czvf $PACKAGE_LIBURING.tgz *
    MD5_LIBURING=($(md5sum $PACKAGE_LIBURING.tgz))
    echo $MD5_LIBURING >$PACKAGE_LIBURING.md5
    # Copy the package to destination
    cp $PACKAGE_LIBURING.* $CACHE_DIRECTORY

    printf -- "Finished building %s .\n" "$PACKAGE_LIBURING"
}

# [IBM]
function buildLibuv() {
    source $PRESERVE_ENVARS
    NAME_LIBUV=libuv
    VERSION_LIBUV=1.20.3
    BUILD_LIBUV=23
    PACKAGE_LIBUV=$NAME_LIBUV-linux-s390x-$VERSION_LIBUV-$BUILD_LIBUV

    printf -- "Start building %s .\n" "$PACKAGE_LIBUV"
    if [ -d  $SOURCE_ROOT/$NAME_LIBUV ]; then
        printf -- "The file already exists. Nothing to do. \n"
        return 0
    fi


    cd $SOURCE_ROOT
    git clone -b v$VERSION_LIBUV --depth 1 https://github.com/couchbasedeps/libuv
    cd libuv
    ./autogen.sh
    ./configure --disable-silent-rules --prefix=$(pwd)/_build --libdir=$(pwd)/_build/lib
    make -j$(nproc)
    make install
    cd _build
    cat <<EOF >CMakeLists.txt
FILE (COPY lib DESTINATION "\${CMAKE_INSTALL_PREFIX}")
EOF
    # Packaging build files
    tar -czvf $PACKAGE_LIBUV.tgz *
    MD5_LIBUV=($(md5sum $PACKAGE_LIBUV.tgz))
    echo $MD5_LIBUV >$PACKAGE_LIBUV.md5
    # Copy the package to destination
    cp $PACKAGE_LIBUV.* $CACHE_DIRECTORY

    printf -- "Finished building %s .\n" "$PACKAGE_LIBUV"
}

# [IBM]
function buildLz4() {
    source $PRESERVE_ENVARS
    NAME_LZ4=lz4
    VERSION_LZ4=1.10.0
    BUILD_LZ4=2
    PACKAGE_LZ4=$NAME_LZ4-linux-s390x-$VERSION_LZ4-$BUILD_LZ4

    printf -- "Start building %s .\n" "$PACKAGE_LZ4"
    if [ -d  $SOURCE_ROOT/$NAME_LZ4-$VERSION_LZ4 ]; then
        printf -- "The file already exists. Nothing to do. \n"
        return 0
    fi

    cd $SOURCE_ROOT
    wget https://github.com/lz4/lz4/archive/refs/tags/v$VERSION_LZ4.tar.gz
    tar -xzf v$VERSION_LZ4.tar.gz
    cd lz4-$VERSION_LZ4
    make -j$(nproc)
    make DESTDIR=$(pwd)/_build install
    hash -r
    cd _build
    cp -r ./usr/local/* . && rm -drf usr
    cat <<EOF >CMakeLists.txt
FILE (COPY lib DESTINATION "\${CMAKE_INSTALL_PREFIX}")
EOF
    # Packaging build files
    tar -czvf $PACKAGE_LZ4.tgz *
    MD5_LZ4=($(md5sum $PACKAGE_LZ4.tgz))
    echo $MD5_LZ4 >$PACKAGE_LZ4.md5
    # Copy the package to destination
    cp $PACKAGE_LZ4.* $CACHE_DIRECTORY

    printf -- "Finished building %s .\n" "$PACKAGE_LZ4"
}

# [IBM]
function buildNumctl() {
    source $PRESERVE_ENVARS
    NAME_NUMCTL=numactl
    VERSION_NUMCTL=2.0.11
    BUILD_NUMCTL=cb4
    PACKAGE_NUMCTL=$NAME_NUMCTL-linux-s390x-$VERSION_NUMCTL-$BUILD_NUMCTL

    printf -- "Start building %s .\n" "$PACKAGE_NUMCTL"
    if [ -d  $SOURCE_ROOT/$NAME_NUMCTL ]; then
        printf -- "The file already exists. Nothing to do. \n"
        return 0
    fi

    cd $SOURCE_ROOT
    # v2.0.11 doesn't work on some distros
    git clone -b v2.0.14 --depth 1 https://github.com/numactl/numactl.git
    cd numactl
    ./autogen.sh
    ./configure --prefix=$(pwd)/_build --libdir=$(pwd)/_build/lib
    make -j$(nproc)
    make install
    cd _build
    cat <<EOF >CMakeLists.txt
FILE (COPY lib DESTINATION "\${CMAKE_INSTALL_PREFIX}")
SET_PROPERTY (GLOBAL APPEND PROPERTY CBDEPS_PREFIX_PATH "\${CMAKE_CURRENT_SOURCE_DIR}")
EOF
    rm -dfr share bin
    # Packaging build files
    tar -czvf $PACKAGE_NUMCTL.tgz *
    MD5_NUMCTL=($(md5sum $PACKAGE_NUMCTL.tgz))
    echo $MD5_NUMCTL >$PACKAGE_NUMCTL.md5
    # Copy the package to destination
    cp $PACKAGE_NUMCTL.* $CACHE_DIRECTORY

    printf -- "Finished building %s .\n" "$PACKAGE_NUMCTL"
}

# [IBM]
function buildPcre() {
    source $PRESERVE_ENVARS
    NAME_PCRE=pcre
    VERSION_PCRE=8.44
    BUILD_PCRE=cb4
    PACKAGE_PCRE=$NAME_PCRE-linux-s390x-$VERSION_PCRE-$BUILD_PCRE

    printf -- "Start building %s .\n" "$PACKAGE_PCRE"
    if [ -d  $SOURCE_ROOT/$NAME_PCRE-$VERSION_PCRE ]; then
        printf -- "The file already exists. Nothing to do. \n"
        return 0
    fi


    cd $SOURCE_ROOT
    wget https://sourceforge.net/projects/pcre/files/pcre/$VERSION_PCRE/pcre-$VERSION_PCRE.tar.gz
    tar -xzf pcre-$VERSION_PCRE.tar.gz
    cd pcre-$VERSION_PCRE
    ./configure --prefix=$(pwd)/_build --libdir=$(pwd)/_build/lib
    make -j$(nproc)
    make install
    cd _build
    cat <<EOF >CMakeLists.txt
FILE (COPY bin lib DESTINATION "\${CMAKE_INSTALL_PREFIX}")
SET_PROPERTY (GLOBAL APPEND PROPERTY CBDEPS_PREFIX_PATH "\${CMAKE_CURRENT_SOURCE_DIR}")
EOF
    # Packaging build files
    tar -czvf $PACKAGE_PCRE.tgz *
    MD5_PCRE=($(md5sum $PACKAGE_PCRE.tgz))
    echo $MD5_PCRE >$PACKAGE_PCRE.md5
    # Copy the package to destination
    cp $PACKAGE_PCRE.* $CACHE_DIRECTORY

    printf -- "Finished building %s .\n" "$PACKAGE_PCRE"
}

# [IBM]
function buildPrometheus() {
    source $PRESERVE_ENVARS
    cd $SOURCE_ROOT
    NAME_PROM=prometheus
    VERSION_PROM=2.53.5
    BUILD_PROM=9
    PACKAGE_PROM=$NAME_PROM-linux-s390x-$VERSION_PROM-$BUILD_PROM
    printf -- "Start building %s .\n" "$PACKAGE_PROM"
    if [ -d  $GOPATH/src/github.com/$NAME_PROM ]; then
        printf -- "The file already exists. Nothing to do. \n"
        return 0
    fi

    cd $SOURCE_ROOT
    wget https://nodejs.org/dist/v20.15.0/node-v20.15.0-linux-s390x.tar.xz
    tar xf node-v20.15.0-linux-s390x.tar.xz
    export PATH=$SOURCE_ROOT/node-v20.15.0-linux-s390x/bin:$PATH
    echo "export PATH=$SOURCE_ROOT/node-v20.15.0-linux-s390x/bin:$PATH" >> $PRESERVE_ENVARS
    npm install -g yarn
    mkdir -p $GOPATH/src/github.com
    cd $GOPATH/src/github.com
    git clone -b v$VERSION_PROM --depth 1 https://github.com/couchbasedeps/prometheus.git
    cd prometheus
    make build
    mkdir -p _build/bin && cp prometheus _build/bin && cd _build
    echo "${VERSION_PROM}-${BUILD_PROM}" >VERSION.txt
    mkdir -p META
    go version | cut -d ' ' -f 3 > META/go-version.txt
    cat <<EOF >CMakeLists.txt
FILE (COPY bin DESTINATION "\${CMAKE_INSTALL_PREFIX}")
EOF
    # Packaging build files
    tar -czvf $PACKAGE_PROM.tgz *
    MD5_PROM=($(md5sum $PACKAGE_PROM.tgz))
    echo $MD5_PROM >$PACKAGE_PROM.md5
    # Copy the package to destination
    cp $PACKAGE_PROM.* $CACHE_DIRECTORY

    printf -- "Finished building %s .\n" "$PACKAGE_PROM"
}

# [IBM]
function buildPromcpp() {
    source $PRESERVE_ENVARS
    NAME_PROMCPP=prometheus-cpp
    VERSION_PROMCPP=v1.2.1-couchbase
    BUILD_PROMCPP=cb1
    PACKAGE_PROMCPP=$NAME_PROMCPP-linux-s390x-$VERSION_PROMCPP-$BUILD_PROMCPP

    printf -- "Start building %s .\n" "$PACKAGE_PROMCPP"
    if [ -d  $SOURCE_ROOT/$NAME_PROMCPP ]; then
        printf -- "The file already exists. Nothing to do. \n"
        return 0
    fi

    # Point to zlib build file.
    ZLIB_BUILD_DIR=$SOURCE_ROOT/zlib/_build

    cd $SOURCE_ROOT
    git clone -b $VERSION_PROMCPP --depth 1 https://github.com/couchbasedeps/prometheus-cpp.git
    cd prometheus-cpp
    git submodule init
    git submodule update
    mkdir _build
    cd _build

    cmake -DBUILD_SHARED_LIBS=OFF \
        -D ENABLE_PUSH=OFF \
        -D CMAKE_POSITION_INDEPENDENT_CODE=ON \
        -D CMAKE_INSTALL_PREFIX=$(pwd)/_build \
        -D CMAKE_BUILD_TYPE=RelWithDebInfo \
        -D ZLIB_ROOT=$ZLIB_BUILD_DIR \
        -D CMAKE_INSTALL_LIBDIR=lib ..

    make -j$(nproc)
    make install
    cd _build
    # Packaging build files
    tar -czvf $PACKAGE_PROMCPP.tgz *
    MD5_PROMCPP=($(md5sum $PACKAGE_PROMCPP.tgz))
    echo $MD5_PROMCPP >$PACKAGE_PROMCPP.md5
    # Copy the package to destination
    cp $PACKAGE_PROMCPP.* $CACHE_DIRECTORY

    printf -- "Finished building %s .\n" "$PACKAGE_PROMCPP"
}

# [IBM]
function buildProtoc() {
    source $PRESERVE_ENVARS
    NAME_PROTOC=protoc-gen-go
    VERSION_PROTOC=1.2.5
    BUILD_PROTOC=7
    PACKAGE_PROTOC=$NAME_PROTOC-linux-s390x-$VERSION_PROTOC-$BUILD_PROTOC

    printf -- "Start building %s .\n" "$PACKAGE_PROTOC"
    if [ -d  $SOURCE_ROOT/$NAME_PROTOC ]; then
        printf -- "The file already exists. Nothing to do. \n"
        return 0
    fi

    mkdir -p $SOURCE_ROOT/protoc-gen-go/bin && cd $SOURCE_ROOT/protoc-gen-go
    go install github.com/golang/protobuf/protoc-gen-go@v1.2.0
    cp $GOPATH/bin/protoc-gen-go ./bin
    # Packaging build files
    tar -czvf $PACKAGE_PROTOC.tgz *
    MD5_PROTOC=($(md5sum $PACKAGE_PROTOC.tgz))
    echo $MD5_PROTOC >$PACKAGE_PROTOC.md5
    # Copy the package to destination
    cp $PACKAGE_PROTOC.* $CACHE_DIRECTORY

    printf -- "Finished building %s .\n" "$PACKAGE_PROTOC"
}

# [IBM]
function buildSpdlog() {
    source $PRESERVE_ENVARS
    NAME_SPDLOG=spdlog
    VERSION_SPDLOG=v1.15.0
    BUILD_SPDLOG=cb4
    PACKAGE_SPDLOG=$NAME_SPDLOG-linux-s390x-$VERSION_SPDLOG-$BUILD_SPDLOG

    printf -- "Start building %s .\n" "$PACKAGE_SPDLOG"
    if [ -d  $SOURCE_ROOT/$NAME_SPDLOG ]; then
        printf -- "The file already exists. Nothing to do. \n"
        return 0
    fi

    cd $SOURCE_ROOT
    # Point to fmt build file.
    FMT_BUILD_DIR=$SOURCE_ROOT/fmt/_build
    git clone -b $VERSION_SPDLOG --depth 1 https://github.com/gabime/spdlog.git
    cd spdlog
    wget https://raw.githubusercontent.com/couchbase/tlm/8.0.0/deps/packages/spdlog/custom_level_names.patch
    git apply custom_level_names.patch
    mkdir build && cd build
    cmake \
        -D CMAKE_CXX_VISIBILITY_PRESET=hidden \
        -D CMAKE_POSITION_INDEPENDENT_CODE=ON \
        -D SPDLOG_BUILD_EXAMPLE=OFF \
        -D SPDLOG_FMT_EXTERNAL=ON \
        -D CMAKE_PREFIX_PATH=$FMT_BUILD_DIR \
        -D CMAKE_BUILD_TYPE=RelWithDebInfo \
        -D CMAKE_INSTALL_PREFIX=$(pwd)/_build \
        -D CMAKE_INSTALL_LIBDIR=lib ..

    make -j$(nproc)
    make install
    cd _build
    # Packaging build files
    tar -czvf $PACKAGE_SPDLOG.tgz *
    MD5_SPDLOG=($(md5sum $PACKAGE_SPDLOG.tgz))
    echo $MD5_SPDLOG >$PACKAGE_SPDLOG.md5
    # Copy the package to destination
    cp $PACKAGE_SPDLOG.* $CACHE_DIRECTORY

    printf -- "Finished building %s .\n" "$PACKAGE_SPDLOG"
}

# [IBM]
function buildLibsodium() {
    source $PRESERVE_ENVARS
    NAME_LIBSODIUM=libsodium
    VERSION_LIBSODIUM=1.0.21
    BUILD_LIBSODIUM=1
    PACKAGE_LIBSODIUM=$NAME_LIBSODIUM-linux-s390x-$VERSION_LIBSODIUM-$BUILD_LIBSODIUM

    printf -- "Start building %s .\n" "$PACKAGE_LIBSODIUM"
    if [ -d  $SOURCE_ROOT/$NAME_LIBSODIUM-$VERSION_LIBSODIUM ]; then
        printf -- "The file already exists. Nothing to do. \n"
        return 0
    fi

    cd $SOURCE_ROOT
    wget https://download.libsodium.org/libsodium/releases/libsodium-${VERSION_LIBSODIUM}.tar.gz
    tar -xzf libsodium-${VERSION_LIBSODIUM}.tar.gz
    cd libsodium-${VERSION_LIBSODIUM}
    ./configure --prefix=$(pwd)/_build --libdir=$(pwd)/_build/lib
    make -j$(nproc)
    make install
    cd _build
    cat <<EOF >CMakeLists.txt
FILE (COPY lib DESTINATION "\${CMAKE_INSTALL_PREFIX}")
EOF
    # Packaging build files
    tar -czvf $PACKAGE_LIBSODIUM.tgz *
    MD5_LIBSODIUM=($(md5sum $PACKAGE_LIBSODIUM.tgz))
    echo $MD5_LIBSODIUM >$PACKAGE_LIBSODIUM.md5
    # Copy the package to destination
    cp $PACKAGE_LIBSODIUM.* $CACHE_DIRECTORY

    printf -- "Finished building %s .\n" "$PACKAGE_LIBSODIUM"
}

# [IBM]
function buildSimdutf() {
    source $PRESERVE_ENVARS
    NAME_SIMDUTF=simdutf
    VERSION_SIMDUTF=7.0.0
    BUILD_SIMDUTF=2_generic
    PACKAGE_SIMDUTF=$NAME_SIMDUTF-linux-s390x-$VERSION_SIMDUTF-$BUILD_SIMDUTF

    printf -- "Start building %s .\n" "$PACKAGE_SIMDUTF"
    if [ -d  $SOURCE_ROOT/$NAME_SIMDUTF ]; then
        printf -- "The file already exists. Nothing to do. \n"
        return 0
    fi

    cd $SOURCE_ROOT
    git clone -b v$VERSION_SIMDUTF --depth 1 https://github.com/simdutf/simdutf.git
    cd simdutf
    cmake\
        -D CMAKE_BUILD_TYPE=RelWithDebInfo \
        -D CMAKE_CXX_STANDARD=17 \
        -D CMAKE_CXX_STANDARD_REQUIRED=ON \
        -D BUILD_SHARED_LIBS=OFF \
        -D CMAKE_INSTALL_PREFIX=$(pwd)/_build \
        -D CMAKE_INSTALL_LIBDIR=lib
    make -j$(nproc)
    make PREFIX=$(pwd)/_build install
    cd _build
    # Packaging build files
    tar -czvf $PACKAGE_SIMDUTF.tgz *
    MD5_SIMDUTF=($(md5sum $PACKAGE_SIMDUTF.tgz))
    echo $MD5_SIMDUTF >$PACKAGE_SIMDUTF.md5
    # Copy the package to destination
    cp $PACKAGE_SIMDUTF.* $CACHE_DIRECTORY

    printf -- "Finished building %s .\n" "$PACKAGE_SIMDUTF"
}

# [IBM]
function buildDepotTools() {
    source $PRESERVE_ENVARS

    printf -- "Start building depot tools .\n"
    if [ -d  $SOURCE_ROOT/depot_tools ]; then
        printf -- "The file already exists. Nothing to do. \n"
        return 0
    fi

    cd $SOURCE_ROOT
    git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
    cd $SOURCE_ROOT/depot_tools
    git checkout 98b7273c8d49aba8d200a568c0d300fdb4d707fd
    echo "export PATH=$PATH:$SOURCE_ROOT/depot_tools/" >> $PRESERVE_ENVARS
    echo 'export VPYTHON_BYPASS="manually managed python not supported by chrome operations"' >> $PRESERVE_ENVARS
    echo "export DEPOT_TOOLS_UPDATE=0" >> $PRESERVE_ENVARS
}

# [IBM]
function buildGn() {
    source $PRESERVE_ENVARS

    printf -- "Start building gn .\n"
    if [ -d  $SOURCE_ROOT/gn ]; then
        printf -- "The file already exists. Nothing to do. \n"
        return 0
    fi

    cd $SOURCE_ROOT
    git clone https://gn.googlesource.com/gn
    cd gn
    git checkout ab638bd7cbb9ac8468bf2fbe60c74ed4706a14a7
    sed -i -e 's/-Wl,--icf=all//g' ./build/gen.py
    sed -i -e 's/-Werror//g' ./build/gen.py
    python3 build/gen.py
    ninja -C out gn gn_unittests
    out/gn_unittests
    echo "export PATH=$SOURCE_ROOT/gn/out:$PATH" >> $PRESERVE_ENVARS
}

# [IBM]
function buildV8() {
    buildDepotTools
    buildGn

    source $PRESERVE_ENVARS
    NAME_V8=v8
    VERSION_V8=13.4.115
    BUILD_V8=3
    PACKAGE_V8=$NAME_V8-linux-s390x-$VERSION_V8-$BUILD_V8

    printf -- "Start building %s .\n" "$PACKAGE_V8"
    if [ -d  $SOURCE_ROOT/$NAME_V8 ]; then
        printf -- "The file already exists. Nothing to do. \n"
        return 0
    fi

    cd $SOURCE_ROOT
    sudo ldconfig /usr/local/lib64 /usr/local/lib
    cat >.gclient <<EOF
solutions = [
  {
    "url": "https://chromium.googlesource.com/v8/v8.git@$VERSION_V8",
    "managed": False,
    "name": "v8",
    "deps_file": "DEPS",
  },
];
EOF
    export DEPOT_TOOLS_UPDATE=0
    gclient sync --nohooks



    cd v8
    fetchPatch v8.diff
    git apply $SOURCE_ROOT/patch/v8.diff
    sed -i 's/-Wl,-z,relro/-Wl,-z,relro,-lstdc++/' ./build/config/compiler/BUILD.gn
    sed -i 's/-mmark-bti-property//g' third_party/icu/BUILD.gn
    sed -ie 's/toolprefix = ".*"/toolprefix = ""/' build/toolchain/linux/BUILD.gn
    V8_ARGS='is_component_build=true target_cpu="s390x" v8_target_cpu="s390x" use_goma=false goma_dir="None" v8_enable_backtrace=true treat_warnings_as_errors=false is_clang=false use_custom_libcxx_for_host=false use_custom_libcxx=false v8_use_external_startup_data=false use_sysroot=false use_gold=false linux_use_bundled_binutils=false v8_enable_pointer_compression=false fatal_linker_warnings=false'
    # build release
    gn gen out/s390x.release --args="$V8_ARGS is_debug=false"
    LD_LIBRARY_PATH=$SOURCE_ROOT/v8/out/s390x.release ninja -C $SOURCE_ROOT/v8/out/s390x.release -j$(nproc)
    gn gen out/s390x.debug --args="$V8_ARGS is_debug=true v8_optimized_debug=true symbol_level=1 v8_enable_slow_dchecks=true"
    LD_LIBRARY_PATH=$SOURCE_ROOT/v8/out/s390x.debug ninja -C $SOURCE_ROOT/v8/out/s390x.debug -j4

    INSTALL_DIR=$(pwd)/_build
    mkdir -p \
        $INSTALL_DIR/lib/Release \
        $INSTALL_DIR/lib/Debug \
        $INSTALL_DIR/include/libplatform \
        $INSTALL_DIR/include/cppgc \
        $INSTALL_DIR/include/unicode
    (
        cd out/s390x.release
        cp -avi libv8*.* $INSTALL_DIR/lib/Release
        cp -avi libchrome*.* $INSTALL_DIR/lib/Release
        cp -avi libcppgc*.* $INSTALL_DIR/lib/Release
        cp -avi libicu*.* $INSTALL_DIR/lib/Release
        cp -avi icu*.* $INSTALL_DIR/lib/Release
        cp -avi libthird_party*.* $INSTALL_DIR/lib/Release
        rm -f $INSTALL_DIR/lib/Release/*.TOC
        rm -f $INSTALL_DIR/lib/Release/*for_testing*
        rm -f $INSTALL_DIR/lib/Release/*debug_helper*
    )
    (
        cd include
        cp -avi v8*.h $INSTALL_DIR/include
        cp -avi libplatform/[a-z]*.h $INSTALL_DIR/include/libplatform
        cp -avi cppgc/* $INSTALL_DIR/include/cppgc
    )
    (
        cd third_party/icu/source/common/unicode
        cp -avi *.h $INSTALL_DIR/include/unicode
    )
    (
        cd third_party/icu/source/io/unicode
        cp -avi *.h $INSTALL_DIR/include/unicode
    )
    (
        cd third_party/icu/source/i18n/unicode
        cp -avi *.h $INSTALL_DIR/include/unicode
    )
    (
        cd third_party/icu/source/extra/uconv/unicode
        cp -avi *.h $INSTALL_DIR/include/unicode
    )
    (
        cd out/s390x.debug
        cp -avi libv8*.* $INSTALL_DIR/lib/Debug
        cp -avi libchrome*.* $INSTALL_DIR/lib/Debug
        cp -avi libcppgc*.* $INSTALL_DIR/lib/Debug
        cp -avi libicu*.* $INSTALL_DIR/lib/Debug
        cp -avi icu*.* $INSTALL_DIR/lib/Debug
        cp -avi libthird_party*.* $INSTALL_DIR/lib/Debug
        rm -f $INSTALL_DIR/lib/Debug/*.TOC
        rm -f $INSTALL_DIR/lib/Debug/*for_testing*
        rm -f $INSTALL_DIR/lib/Debug/*debug_helper*
    )

    cd _build
    cat <<EOF >CMakeLists.txt
FILE(MAKE_DIRECTORY \${CMAKE_INSTALL_PREFIX}/bin)

# Determine which directory to copy libs from
IF (CMAKE_BUILD_TYPE STREQUAL "Debug" AND
    IS_DIRECTORY "\${CMAKE_CURRENT_SOURCE_DIR}/lib/Debug")
    SET (LIB_DIR Debug)
ELSE()
    SET (LIB_DIR Release)
ENDIF ()

FILE (COPY lib/\${LIB_DIR}/
      DESTINATION "\${CMAKE_INSTALL_PREFIX}/lib"
      PATTERN .dat EXCLUDE)
FILE (COPY lib/\${LIB_DIR}/icudtb.dat DESTINATION "\${CMAKE_INSTALL_PREFIX}/bin")
EOF
    # Packaging build files
    tar -czvf $PACKAGE_V8.tgz *
    MD5_V8=($(md5sum $PACKAGE_V8.tgz))
    echo $MD5_V8 >$PACKAGE_V8.md5
    # Copy the package to destination
    cp $PACKAGE_V8.* $CACHE_DIRECTORY

    printf -- "Finished building %s .\n" "$PACKAGE_V8"
}

# [IBM]
function buildAWSSDK() {
    source $PRESERVE_ENVARS
    NAME_AWS=AWSSDK
    VERSION_AWS=1.11.450
    BUILD_AWS=2
    PACKAGE_AWS=$NAME_AWS-linux-s390x-$VERSION_AWS-$BUILD_AWS

    if [ -f "$CACHE_DIRECTORY/$PACKAGE_AWS.tgz" ]; then
        printf -- "Package %s already exists. Skipping.\n" "$PACKAGE_AWS"
        return 0
    fi

    printf -- "Start building %s .\n" "$PACKAGE_AWS"
    cd $SOURCE_ROOT
    if [ ! -d aws-sdk-cpp ]; then
        git clone --recurse-submodules -b "$VERSION_AWS" --depth 1 \
            https://github.com/aws/aws-sdk-cpp.git
    else
        echo "aws-sdk-cpp already exists, skipping clone"
    fi
    if [[ "$ID$VERSION_ID" == rhel9.* ]]; then
        fetchPatch aws-c-cal.diff
        cd aws-sdk-cpp/crt/aws-crt-cpp/crt/aws-c-cal
        git apply $SOURCE_ROOT/patch/aws-c-cal.diff
    fi
    cd $SOURCE_ROOT/aws-sdk-cpp
    mkdir -p build && cd build
    cmake .. -DCMAKE_BUILD_TYPE=RelWithDebInfo -DBUILD_ONLY="core;s3;transfer" -DBUILD_SHARED_LIBS=OFF -DENABLE_UNITY_BUILD=ON -DCMAKE_INSTALL_PREFIX=$(pwd)/_build -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DENABLE_TESTING=OFF
    make -j$(nproc)
    make install
    
    cd _build
    cat <<EOF > CMakeLists.txt
FILE (COPY lib DESTINATION "\${CMAKE_INSTALL_PREFIX}")
FILE (COPY include DESTINATION "\${CMAKE_INSTALL_PREFIX}")
SET_PROPERTY (GLOBAL APPEND PROPERTY CBDEPS_PREFIX_PATH "\${CMAKE_CURRENT_SOURCE_DIR}")
EOF
    # Ensure headers are actually there
    if [ ! -d "include" ]; then cp -r ../../aws-cpp-sdk-core/include . ; fi

    tar --format=gnu --owner=0 --group=0 -czvf $PACKAGE_AWS.tgz ./*
    md5sum $PACKAGE_AWS.tgz | cut -d' ' -f1 > $PACKAGE_AWS.md5
    cp $PACKAGE_AWS.* $CACHE_DIRECTORY

    printf -- "Finished building %s .\n" "$PACKAGE_AWS"
}

# [IBM]
function buildFastFloat() {
    source $PRESERVE_ENVARS
    NAME_FF=fast_float
    VERSION_FF=v7.0.0
    BUILD_FF=1
    PACKAGE_FF=$NAME_FF-linux-s390x-7.0.0-$BUILD_FF

    # Guard Clause: Skip if exists in cache
    if [ -f "$CACHE_DIRECTORY/$PACKAGE_FF.tgz" ]; then
        printf -- "Package %s already exists. Skipping.\n" "$PACKAGE_FF"
        return 0
    fi

    printf -- "Start building %s .\n" "$PACKAGE_FF"
    cd $SOURCE_ROOT
    if [ ! -d fast_float ]; then
        git clone -b $VERSION_FF --depth 1 https://github.com/fastfloat/fast_float.git
    else
        echo "fast_float already exists, skipping clone"
    fi    
    cd fast_float
    
    mkdir -p build && cd build
    cmake .. -DCMAKE_INSTALL_PREFIX=$(pwd)/_build
    make install

    cd _build
    # Couchbase needs this CMake helper to find the headers during its own build
    cat <<EOF > CMakeLists.txt
FILE (COPY include DESTINATION "\${CMAKE_INSTALL_PREFIX}")
SET_PROPERTY (GLOBAL APPEND PROPERTY CBDEPS_PREFIX_PATH "\${CMAKE_CURRENT_SOURCE_DIR}")
EOF

    # Standard packaging for s390x cache
    tar --format=gnu --owner=0 --group=0 -czvf $PACKAGE_FF.tgz ./*
    md5sum $PACKAGE_FF.tgz | cut -d' ' -f1 > $PACKAGE_FF.md5
    
    cp $PACKAGE_FF.* $CACHE_DIRECTORY

    printf -- "Finished building %s .\n" "$PACKAGE_FF"
}

# [IBM]
function buildFuzzTest() {
    source "$PRESERVE_ENVARS"

    NAME_FUZZ=fuzztest
    VERSION_FUZZ=v2025-02-14
    BUILD_FUZZ=cb2
    PACKAGE_FUZZ="${NAME_FUZZ}-linux-s390x-${VERSION_FUZZ}-${BUILD_FUZZ}"

    # 1) Guard clause: skip if package already in cache
    if [ -f "$CACHE_DIRECTORY/${PACKAGE_FUZZ}.tgz" ]; then
        printf -- "Package %s already exists in cache. Skipping.\n" "$PACKAGE_FUZZ"
        return 0
    fi

    printf -- "Start building %s\n" "$PACKAGE_FUZZ"
    cd "$SOURCE_ROOT"

    # 2) Clone the **couchbasedeps** fork at the exact tag Couchbase expects
    if [ ! -d "fuzztest" ]; then
        git clone https://github.com/couchbasedeps/fuzztest.git
        cd fuzztest
        git checkout "${VERSION_FUZZ}"
    else
        cd fuzztest
        # Ensure we are on the expected tag
        git fetch --tags
        git checkout "${VERSION_FUZZ}"
    fi

    # 3) Configure & build (library-only; no tests/examples)
    rm -rf build
    mkdir build && cd build

    cmake .. \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$PWD/_build" \
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
      -DCMAKE_CXX_STANDARD=17 \
      -DCMAKE_INSTALL_LIBDIR=lib \
      -DBUILD_TESTING=OFF

    make -j"$(nproc)"
    sudo make install

    # 4) Prepare cbdeps package layout from inside the install prefix
    cd _build

    # Write the cbdeps helper CMakeLists.txt
    sudo tee CMakeLists.txt >/dev/null <<'EOF'
FILE (COPY include DESTINATION "${CMAKE_INSTALL_PREFIX}")
FILE (COPY lib     DESTINATION "${CMAKE_INSTALL_PREFIX}")
SET_PROPERTY (GLOBAL APPEND PROPERTY CBDEPS_PREFIX_PATH "${CMAKE_CURRENT_SOURCE_DIR}")
EOF

    # Remove bundled gtest/gmock bits if present (ignore if missing)
    sudo rm -rf include/gmock include/gtest lib/libgtest* lib/libgmock*

    # 5) Create the tarball with **ONLY** include, lib, CMakeLists.txt at root
    sudo rm -f "${PACKAGE_FUZZ}.tgz" "${PACKAGE_FUZZ}.md5"
    sudo tar --format=gnu --owner=0 --group=0 -czvf "$PACKAGE_FUZZ.tgz" ./*

    # 6) Sanity-check tar contents (must NOT include share/, _build/, etc.)
    if tar tzf "${PACKAGE_FUZZ}.tgz" | egrep -q '^(share/|_build/|lib64/|lib/cmake/|lib/pkgconfig/)'; then
        echo "ERROR: Tarball contains unexpected top-level entries. Aborting."
        exit 1
    fi

    md5sum "${PACKAGE_FUZZ}.tgz" | cut -d' ' -f1 | sudo tee "${PACKAGE_FUZZ}.md5" >/dev/null

    # 7) Copy to Couchbase cbdeps cache
    sudo cp "${PACKAGE_FUZZ}.tgz" "${PACKAGE_FUZZ}.md5" "$CACHE_DIRECTORY"

    printf -- "Finished building %s\n" "$PACKAGE_FUZZ"
}

# [IBM]
function printSystemDetails() {
  printf -- 'SYSTEM DETAILS\n'
  cat "/etc/os-release"
  cat /proc/version
  printf -- "\nDetected %s \n"  "$PRETTY_NAME"
  printf -- "Request details : PACKAGE NAME= %s , VERSION= %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION"
}

###############################################################################
# Dependency builds added or replaced for the Enterprise Edition
###############################################################################

# curl, built the way Couchbase builds its own curl package: from the
# couchbasedeps fork at the version tlm asks for (8.21.0), against the OpenSSL
# and zlib built above, with Couchbase's patch that lets libcurl take its CA
# bundle from $CURL_CA_BUNDLE at run time (bin/couchbase-server exports it).
#
# IBM's recipe (kept above as buildCurlNoTLS) builds curl 8.9.1 --without-ssl.
# That is enough to compile the server, but libcurl then cannot speak HTTPS,
# and the Eventing service - Enterprise only - uses libcurl for its curl()
# bindings. Set CB_CURL_TLS=0 to fall back to IBM's recipe.
function buildCurlTLS() {
    source $PRESERVE_ENVARS
    NAME_CURL=curl
    VERSION_CURL=8.21.0
    BUILD_CURL=2
    PACKAGE_CURL=$NAME_CURL-linux-s390x-$VERSION_CURL-$BUILD_CURL
    # couchbasedeps/curl at tag curl-8_21_0, and the couchbase/build-tools
    # revision the official curl 8.21.0 package was built from
    # (couchbase/build-manifests: cbdeps/curl/8.21.0/8.21.0.xml).
    local curl_commit=68720b4837284335b2d63cb358f8f6ce65f5bc55
    local buildtools_commit=5428cf0076e8f68544293c2c4a741a3463d8cd3f
    local buildtools_raw="https://raw.githubusercontent.com/couchbase/build-tools/$buildtools_commit/cbdeps/curl"
    local srcdir=$SOURCE_ROOT/curl-couchbase
    local openssl_dir=$SOURCE_ROOT/openssl-3.5.7/_build
    local zlib_dir=$SOURCE_ROOT/zlib/_build

    printf -- "Start building %s (with TLS).\n" "$PACKAGE_CURL"
    [ -d "$openssl_dir" ] || die "buildCurlTLS needs the OpenSSL build in $openssl_dir (buildOssl runs first)"
    [ -d "$zlib_dir" ]    || die "buildCurlTLS needs the zlib build in $zlib_dir (buildZlib runs first)"

    mkdir -p "$srcdir"
    cd "$srcdir"
    git init -q
    git remote add origin https://github.com/couchbasedeps/curl.git
    git fetch -q --depth 1 origin "$curl_commit"
    git checkout -q FETCH_HEAD
    wget -q "$buildtools_raw/curl_linux_cabundle_env.patch"
    wget -q "$buildtools_raw/curl_wrapper.sh"
    git apply curl_linux_cabundle_env.patch

    # The options are Couchbase's (build-tools: cbdeps/curl/curl_unix.sh). The
    # last six are added so that optional libraries which merely happen to be
    # installed on the build host (brotli, LDAP, ...) are not linked in: the
    # shipped libcurl must only depend on libraries the server ships.
    (
        export LDFLAGS="-Wl,-rpath,'\$\$ORIGIN/../lib' -L$openssl_dir/lib -L$zlib_dir/lib"
        export CPPFLAGS="-I$openssl_dir/include -I$zlib_dir/include"
        export LD_LIBRARY_PATH="$openssl_dir/lib:$zlib_dir/lib:$LD_LIBRARY_PATH"
        autoreconf -i
        ./configure --prefix="$(pwd)/_build" \
                    --libdir="$(pwd)/_build/lib" \
                    --disable-debug \
                    --enable-optimize \
                    --disable-warnings \
                    --disable-werror \
                    --disable-curldebug \
                    --enable-shared \
                    --disable-static \
                    --without-libssh2 \
                    --with-ssl=$openssl_dir \
                    --with-ca-bundle=env \
                    --with-zlib=$zlib_dir \
                    --without-nghttp2 \
                    --without-libidn2 \
                    --without-libpsl \
                    --without-zstd \
                    --without-brotli \
                    --without-libgsasl \
                    --without-nghttp3 \
                    --without-ngtcp2 \
                    --disable-ldap \
                    --disable-ldaps
        make -j$(nproc) all
        make install
    )
    hash -r

    cd _build
    rm -rf bin/curl-config lib/pkgconfig share lib/libcurl.la
    # Same launcher Couchbase ships: find the distribution's CA bundle, then run the real curl.
    mv bin/curl bin/curl.real
    cp "$srcdir/curl_wrapper.sh" bin/curl
    chmod 0755 bin/curl
    local curl_version
    curl_version="$(LD_LIBRARY_PATH="$(pwd)/lib:$openssl_dir/lib:$zlib_dir/lib:$LD_LIBRARY_PATH" bin/curl.real --version)"
    case "$curl_version" in
        *https*) ;;
        *) die "the curl that was just built has no HTTPS support" ;;
    esac

    cat <<EOF >CMakeLists.txt
FILE (COPY bin lib DESTINATION "\${CMAKE_INSTALL_PREFIX}")
SET_PROPERTY (GLOBAL APPEND PROPERTY CBDEPS_PREFIX_PATH "\${CMAKE_CURRENT_SOURCE_DIR}")
EOF
    echo "$VERSION_CURL-$BUILD_CURL" >VERSION.txt
    # Packaging build files
    tar -czf $PACKAGE_CURL.tgz bin include lib CMakeLists.txt VERSION.txt
    md5sum $PACKAGE_CURL.tgz | cut -d' ' -f1 > $PACKAGE_CURL.md5
    # Copy the package to destination
    cp $PACKAGE_CURL.tgz $PACKAGE_CURL.md5 $CACHE_DIRECTORY

    printf -- "Finished building %s .\n" "$PACKAGE_CURL"
}

# faiss (vector search), built the way Couchbase builds its own package.
#
# In an Enterprise build faiss is really used: tlm does
# FIND_PACKAGE(faiss CONFIG REQUIRED) and installs the faiss_c and faiss shared
# libraries, and the Index, Search and Query services link libfaiss_c through
# cgo. That needs
#   - Couchbase's faiss fork (blevesearch/faiss, branch morpheus), which adds
#     C API functions that the Go bindings call,
#   - the C API (FAISS_ENABLE_C_API) built as shared libraries, and
#   - OpenBLAS linked statically into libfaiss.so, which then exports
#     openblas_set_num_threads/openblas_get_num_threads for the indexer.
# IBM's recipe builds upstream faiss as a static library with no C API; that
# satisfies a Community build (which never links faiss) but not an Enterprise one.
#
# The package must still be called "...-6_avx2" because that is the name
# tlm/deps/manifest.cmake asks for; on s390x faiss builds its "generic" level
# and the library is libfaiss.so (as on arm64), not libfaiss_avx2.so.
function buildFaissEE() {
    source $PRESERVE_ENVARS
    NAME_FAISS=faiss
    VERSION_FAISS=1.11.0
    BUILD_FAISS=6_avx2
    PACKAGE_FAISS=$NAME_FAISS-linux-s390x-$VERSION_FAISS-$BUILD_FAISS
    # Exact sources of Couchbase's faiss 1.11.0-6 and openblas 0.3.28-1 packages
    # (couchbase/build-manifests: cbdeps/faiss/1.11.0, cbdeps/openblas/0.3.28).
    local faiss_commit=246f93d767a0620466d138a348348b23485c78c1
    local openblas_commit=5ef8b1964658f9cb6a6324a06f6a1a022609b0c5
    local openblas_src=$SOURCE_ROOT/openblas-couchbase
    local openblas_prefix=$openblas_src/_install
    local faiss_src=$SOURCE_ROOT/faiss-blevesearch
    # Portable OpenBLAS: generic z/Architecture baseline plus z13 and z14
    # kernels chosen at run time (the settings Debian and Fedora use on s390x);
    # threaded, with the bundled C translation of LAPACK so no Fortran compiler
    # is needed.
    local openblas_flags="TARGET=ZARCH_GENERIC DYNAMIC_ARCH=1 BINARY=64 USE_THREAD=1 NUM_THREADS=128 NOFORTRAN=1 NO_SHARED=1"

    printf -- "Start building %s .\n" "$PACKAGE_FAISS"

    mkdir -p "$openblas_src"
    cd "$openblas_src"
    git init -q
    git remote add origin https://github.com/couchbasedeps/OpenBLAS.git
    git fetch -q --depth 1 origin "$openblas_commit"
    git checkout -q FETCH_HEAD
    make -j$(nproc) $openblas_flags libs netlib
    make $openblas_flags PREFIX="$openblas_prefix" install

    mkdir -p "$faiss_src"
    cd "$faiss_src"
    git init -q
    git remote add origin https://github.com/blevesearch/faiss.git
    git fetch -q --depth 1 origin "$faiss_commit"
    git checkout -q FETCH_HEAD
    cmake -B build -S . \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DCMAKE_PREFIX_PATH="$openblas_prefix" \
        -DFAISS_ENABLE_GPU=OFF -DFAISS_ENABLE_PYTHON=OFF -DFAISS_ENABLE_C_API=ON \
        -DFAISS_OPT_LEVEL=generic \
        -DCMAKE_INSTALL_PREFIX="$faiss_src/_build" -DCMAKE_INSTALL_LIBDIR=lib \
        -DBUILD_TESTING=OFF -DBUILD_SHARED_LIBS=ON \
        -DCMAKE_INSTALL_RPATH='$ORIGIN'
    make -C build -j$(nproc) install

    cd "$faiss_src/_build"
    rm -rf lib/pkgconfig
    # Check the properties the Enterprise server build depends on before packaging.
    [ -f lib/libfaiss.so ] && [ -f lib/libfaiss_c.so ] || die "faiss build did not produce lib/libfaiss.so and lib/libfaiss_c.so"
    [ -f share/faiss/faiss-config.cmake ] || [ -f lib/cmake/faiss/faiss-config.cmake ] \
        || die "faiss build did not install its CMake package files"
    local sym symbols
    symbols="$(nm -D --defined-only lib/libfaiss.so)"
    for sym in openblas_set_num_threads openblas_get_num_threads; do
        case "$symbols" in
            *" $sym"*) ;;
            *) die "lib/libfaiss.so does not export $sym (OpenBLAS was not linked in statically?)" ;;
        esac
    done
    symbols="$(nm -D --defined-only lib/libfaiss_c.so)"
    case "$symbols" in
        *" faiss_Index_search"*) ;;
        *) die "lib/libfaiss_c.so does not export the faiss C API" ;;
    esac

    # As in Couchbase's package there is no CMakeLists.txt at the top level:
    # tlm then sets faiss_ROOT to the unpacked directory and FIND_PACKAGE picks
    # up share/faiss/faiss-config.cmake from it.
    tar --format=gnu --owner=0 --group=0 -czf $PACKAGE_FAISS.tgz include lib share
    md5sum $PACKAGE_FAISS.tgz | cut -d' ' -f1 > $PACKAGE_FAISS.md5
    cp $PACKAGE_FAISS.tgz $PACKAGE_FAISS.md5 $CACHE_DIRECTORY

    printf -- "Finished building %s .\n" "$PACKAGE_FAISS"
}

# cbpy is the Python environment shipped inside the server. Couchbase's own
# package (build-tools: cbdeps/cbpy/cb-dependencies.txt) contains modules that
# IBM's Miniconda-based recipe leaves out. cbcollect_info - the log collection
# tool, which Support relies on - imports pyzipper unconditionally and cannot
# start without it. Add the missing modules and repackage.
function augmentCbpy() {
    source $PRESERVE_ENVARS
    local name=cbpy-linux-s390x-3.14.2-4
    local py=$SOURCE_ROOT/cbpy/bin/python3
    local mod missing=""
    [ -x "$py" ] || die "augmentCbpy: $py not found (buildCbpy runs first)"
    for mod in pyzipper requests_toolbelt OpenSSL idna; do
        "$py" -c "import $mod" >/dev/null 2>&1 || missing="$missing $mod"
    done
    if [ -z "$missing" ] && cacheHasPackage "$name"; then
        printf -- "cbpy already contains the extra modules.\n"
        return 0
    fi

    printf -- "Adding modules to cbpy (missing:%s).\n" "$missing"
    # pycryptodomex (needed by pyzipper) compiles C code; cramjam and
    # cryptography may need the Rust toolchain that buildCbpy installed.
    [ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"
    "$py" -m pip install pyzipper
    # IBM's recipe pins cryptography 38.0.4 (built from source with Rust on
    # s390x). Naming it again here stops pip from replacing it; pyOpenSSL
    # releases before 23.3 work with it.
    "$py" -m pip install requests-toolbelt idna "pyopenssl>=22.1,<23.3" "cryptography==38.0.4" \
        || warn "could not add requests-toolbelt/idna/pyopenssl to cbpy; continuing"
    "$py" -c "import pyzipper" || die "pyzipper could not be installed into cbpy; cbcollect_info would not start"

    cd $SOURCE_ROOT/cbpy
    tar -czf $name.tgz bin lib share ssl
    md5sum $name.tgz | cut -d' ' -f1 > $name.md5
    cp $name.tgz $name.md5 $CACHE_DIRECTORY
}
###############################################################################
# Couchbase Server source: sync and patches
###############################################################################

# Projects this build leaves out of the sync.
function excludedProjects() {
    local removals=""
    if [ "$CB_EDITION" = "enterprise" ]; then
        # voltron is Couchbase's internal packaging project (it adds itself to
        # the build when present) and couchdbx-app is the macOS app wrapper.
        [ "$CB_WITH_VOLTRON" = "1" ] || removals="$removals voltron couchdbx-app"
        [ "$CB_WITHOUT_ANALYTICS" = "1" ] && removals="$removals analytics-dcp-client asterixdb cbas cbas-core cbas-ui"
        [ "$CB_WITHOUT_BACKUP" = "1" ] && removals="$removals backup cbbs"
    else
        # Private repositories in the default group, and xdcrDiffer which
        # needs goxdcr. Without them there is no XDCR in the build.
        removals="$removals gocbcrypto goxdcr xdcrDiffer"
    fi
    echo "$removals $CB_EXCLUDE_PROJECTS"
}

# The exclusions are written as a repo "local manifest", so the release
# manifest itself stays untouched. (IBM's script comments out manifest lines by
# line number, which also drops projects an Enterprise build needs.)
function writeLocalManifest() {
    local removals p
    local file="$SOURCE_ROOT/couchbase/.repo/local_manifests/s390x-kit.xml"
    # shellcheck disable=SC2046,SC2116,SC2005
    removals="$(echo $(excludedProjects))"      # (normalises the spacing)

    mkdir -p "$(dirname "$file")"
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<!-- Generated by build_couchbase_ee.sh on every run - do not edit. -->'
        echo '<manifest>'
        for p in $removals; do
            echo "  <remove-project name=\"$p\" optional=\"true\" />"
        done
        echo '</manifest>'
    } > "$file"
    printf -- "Projects excluded from the sync: %s\n" "${removals:-(none)}"
}

function syncSource() {
    local init_args=(-u "$CB_MANIFEST_URL" -m "$CB_MANIFEST_FILE")
    [ -n "$CB_SYNC_GROUPS" ] && init_args+=(-g "$CB_SYNC_GROUPS")

    # (IBM's setGitGlobalConfig switches 'set -e' back on itself.)
    set +e
    setGitGlobalConfig
    mkdir -p $SOURCE_ROOT/couchbase
    cd $SOURCE_ROOT/couchbase
    # shellcheck disable=SC2086
    cleanEnv repo init "${init_args[@]}" $CB_REPO_INIT_ARGS < /dev/null
    writeLocalManifest
    cleanEnv repo sync --jobs="$CB_SYNC_JOBS" < /dev/null

    if [ "$CB_EDITION" = "enterprise" ]; then
        # Fail here, with a clear message, rather than deep inside CMake.
        # goxdcr and eventing-ee are added to an Enterprise build unconditionally.
        local missing="" d
        for d in goxdcr eventing-ee; do
            case " $CB_EXCLUDE_PROJECTS " in *" $d "*) continue ;; esac
            [ -d "$SOURCE_ROOT/couchbase/goproj/src/github.com/couchbase/$d" ] || missing="$missing $d"
        done
        [ -z "$missing" ] || die "Enterprise sources are missing after the sync:$missing"
    fi
}

function patchSource() {
    local cb=$SOURCE_ROOT/couchbase
    [ -d "$cb/tlm" ] || die "no Couchbase source in $cb (run the 'source' stage first)"

    # Build system: Go and rebar3 lookup, breakpad (no s390x port).
    applyPatch "$cb/tlm" "$KIT_ROOT/patch/tlm-s390x.diff"
    if [ "$CB_EDITION" = "community" ]; then
        applyPatch "$cb/tlm" "$KIT_ROOT/patch/tlm-community-no-xdcr.diff"
    fi
    # IBM's s390x fixes for kv_engine tests and platform's CRC32C.
    applyPatch "$cb/kv_engine" "$KIT_ROOT/patch/kv_engine.diff"
    applyPatch "$cb/platform" "$KIT_ROOT/patch/platform.diff"
    # forestdb: s390x in the spin-lock initialiser.
    applyPatch "$cb/forestdb" "$KIT_ROOT/patch/forestdb-s390x.diff"
    # indexing: kernel-version detection, and the s390x faiss/OpenBLAS binding.
    applyPatch "$cb/goproj/src/github.com/couchbase/indexing" "$KIT_ROOT/patch/indexing-s390x.diff"

    # Your own patches (typically fixes for the private Enterprise repositories
    # found while porting): one "<project dir> <patch file>" pair per line in
    # patch/local/series. See patch/local/README.md.
    local series="$KIT_ROOT/patch/local/series" dir file
    if [ -f "$series" ]; then
        while read -r dir file || [ -n "$dir" ]; do
            case "$dir" in ''|'#'*) continue ;; esac
            [ -n "$file" ] || die "patch/local/series: no patch file given for '$dir'"
            applyPatch "$cb/$dir" "$KIT_ROOT/patch/local/$file"
        done < "$series"
    fi

    # tlm/CMakeLists.txt is copied to the top of the tree by repo, and the
    # build refuses to run if the two copies differ.
    if ! cmp -s "$cb/tlm/CMakeLists.txt" "$cb/CMakeLists.txt"; then
        chmod u+w "$cb/CMakeLists.txt"
        cp "$cb/tlm/CMakeLists.txt" "$cb/CMakeLists.txt"
    fi
}
###############################################################################
# Server build, tests, packaging
###############################################################################

function buildServer() {
    local cb=$SOURCE_ROOT/couchbase
    local openssl_dir=$SOURCE_ROOT/openssl-3.5.7/_build
    [ -f "$cb/Build.sh" ]  || die "no Couchbase source in $cb (run the 'source' and 'patch' stages first)"
    [ -d "$openssl_dir" ]  || die "the OpenSSL build tree $openssl_dir is missing (run the 'deps' stage first)"
    source $PRESERVE_ENVARS

    # As in IBM's script, the build uses the OpenSSL built in the deps stage.
    # Unlike IBM's script these settings are only exported here, for the
    # build itself, and are not written to a profile file.
    export PATH=$openssl_dir/bin:$PATH
    export LD_LIBRARY_PATH=$openssl_dir/lib:$LD_LIBRARY_PATH
    export OPENSSL_ROOT_DIR=$openssl_dir
    export OPENSSL_CONF=$openssl_dir/etc/openssl

    sudo ldconfig
    installCbdepShim

    # [IBM] Point the Erlang NIF builds at the headers of the Erlang package.
    export LOCAL_ERL_INCLUDE="$SOURCE_ROOT/couchbase/build/tlm/deps/erlang.exploded/lib/erlang/usr/include"

    export CMAKE_OPTIONS="-DERL_NIF_INCLUDE_PATH=$LOCAL_ERL_INCLUDE"

    export CFLAGS="$CFLAGS -I$LOCAL_ERL_INCLUDE"
    export CXXFLAGS="$CXXFLAGS -I$LOCAL_ERL_INCLUDE"
    export ERL_CFLAGS="$ERL_CFLAGS -I$LOCAL_ERL_INCLUDE"

    # TRUE/FALSE, spelled as Couchbase's own build spells them: ns_server's
    # start script compares the literal text to decide whether to call the
    # build "(EE)" or "(CE)".
    local enterprise=FALSE
    [ "$CB_EDITION" = "enterprise" ] && enterprise=TRUE

    # The options Couchbase's own Linux build passes (build repo:
    # scripts/jenkins/couchbase_server/server-linux-build.sh), plus IBM's.
    local cmake_options="$CMAKE_OPTIONS"
    cmake_options+=" -DPRODUCT_VERSION=${PACKAGE_VERSION}-${CB_BLD_NUM}"
    cmake_options+=" -DBUILD_ENTERPRISE=$enterprise"
    cmake_options+=" -DCB_PRODUCTION_BUILD=OFF"
    cmake_options+=" -DCB_DEVELOPER_BUILD=True"
    cmake_options+=" -DCB_DOWNLOAD_DEPS=1"
    cmake_options+=" -DCB_UNITY_BUILD=$CB_UNITY_BUILD"
    if [ "$enterprise" = "TRUE" ]; then
        # Analytics: fetch a JDK (through the cbdep stand-in) and build with Maven.
        cmake_options+=" -DCB_DOWNLOAD_JAVA=$CB_DOWNLOAD_JAVA -DCB_INVOKE_MAVEN=$CB_INVOKE_MAVEN"
    fi
    if [[ $DISTRO != ubuntu* ]]; then
        cmake_options+=" -DGIT_EXECUTABLE=/usr/bin/git"
    fi
    cmake_options+=" $CB_EXTRA_CMAKE_OPTIONS"

    cd $SOURCE_ROOT/couchbase/
    sudo ldconfig /usr/local/lib64 /usr/local/lib

    if [ "$CB_RECONFIGURE" = "1" ]; then
        rm -f "$cb/build/build.ninja"
    fi

    local targets=""
    [ "$TESTS" = "true" ] && targets="everything"

    local ld_path="$LD_LIBRARY_PATH"
    if [[ $DISTRO == ubuntu* ]]; then
        ld_path="$CB_PREFIX/lib:$LD_LIBRARY_PATH"
    fi

    log "Building Couchbase Server ${PACKAGE_VERSION}-${CB_BLD_NUM} ($CB_EDITION, $CB_BUILD_TYPE, -j $CB_JOBS) into $CB_PREFIX"
    LD_LIBRARY_PATH="$ld_path" CC=$CC CXX=$CXX \
        CMAKE_BUILD_TYPE="$CB_BUILD_TYPE" \
        CB_PARALLEL_LINK_JOBS="$CB_PARALLEL_LINK_JOBS" \
        EXTRA_CMAKE_OPTIONS="$cmake_options" \
        ./Build.sh -i "$CB_PREFIX" -j "$CB_JOBS" $targets

    [ -x "$CB_PREFIX/bin/couchbase-server" ] || die "the build finished but $CB_PREFIX/bin/couchbase-server does not exist"
    printf -- "\nBuilt: %s\n" "$("$CB_PREFIX/bin/couchbase-server" --version 2>/dev/null || echo "$CB_PREFIX/bin/couchbase-server")"
}

# [IBM] (adapted)
function runTest() {
  set +e
  cd $SOURCE_ROOT/couchbase/build
  printf -- '\nRunning Couchbase tests...\n'
  sudo ctest --timeout 1000
  set -e
}

function packageServer() {
    bash "$KIT_ROOT/scripts/package.sh" \
        --prefix "$CB_PREFIX" \
        --version "${PACKAGE_VERSION}-${CB_BLD_NUM}" \
        --edition "$CB_EDITION" \
        --output "$SOURCE_ROOT/packages"
}
###############################################################################
# Stages
###############################################################################

function stagePreflight() {
    bash "$KIT_ROOT/scripts/preflight.sh" --only host --edition "$CB_EDITION" --workdir "$SOURCE_ROOT"
}

function stagePrereqs() {
    printf -- "Start Distro specific preperation for %s\n" "$ID$VERSION_ID"
    case "$(distroFamily)" in
        rhel8)    prepareRHEL8 ;;
        rhel9)    prepareRHEL9 ;;
        suse15)   prepareSUSE15 ;;
        ubuntu22) prepareUB22 ;;
        ubuntu24) prepareUB24 ;;
        *)
            printf -- "%s is not supported \n" "$ID$VERSION_ID"
            exit 1
            ;;
    esac
    prepareKitExtras
}

# [IBM] Certificate bundle for tools that end up using the OpenSSL built in
# the deps stage. As in IBM's script this is exported after the distribution
# packages are installed; it runs on every invocation (not only when the
# 'prereqs' stage does) because every later stage needs it.
function exportCertificateSettings() {
    if [[ $DISTRO == ubuntu* ]]; then
        export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
        export SSL_CERT_DIR=/etc/ssl/certs/
    elif [[ $DISTRO == rhel* ]]; then
        export SSL_CERT_FILE=/etc/pki/tls/certs/ca-bundle.crt
    else
        export SSL_CERT_FILE=/etc/ssl/ca-bundle.pem
    fi
}

function stageTools() {
    # [IBM]
    if [[ $DISTRO == rhel* ]]; then
        python3 -m pip install "httplib2<0.30.0" PySocks --user
    elif [[ $DISTRO != ubuntu* ]]; then
        python3 -m pip install "httplib2<0.30.0" --user
    fi
    installGo
    echo "export GOPATH=$(go env GOPATH)"
    installCmake
    installRepoTool
}

function stageDeps() {
    printf -- "Building dependencies from source.\n"
    source $PRESERVE_ENVARS
    local gopath
    gopath="$(go env GOPATH)"

    # The order is IBM's, except that curl now comes after OpenSSL and zlib
    # (it links against them) and faiss is built by buildFaissEE.
    runDep installGflags          gflags-linux-s390x-2.2.2-1                    "gflags-2.2.2" "v2.2.2.tar.gz"
    runDep buildBenchmark         benchmark-linux-s390x-v1.9.1-cb1              "benchmark"
    runDep buildBoost             boost-linux-s390x-1.86.0-cb3                  "boost-1.86.0"
    runDep buildCbpy              cbpy-linux-s390x-3.14.2-4                     "cbpy" "Miniconda3-py311_23.5.0-3-Linux-s390x.sh"
    augmentCbpy
    runDep buildDconvertion       double-conversion-linux-s390x-3.3.0-cb1       "double-conversion"
    runDep buildErlang            erlang-linux-s390x-28.5.0.5-1                 "erlang" "rebar3"
    runDep buildFbuf              flatbuffers-linux-s390x-v1.10.0-cb7           "flatbuffers"
    runDep buildFmt               fmt-linux-s390x-11.0.0-cb2                    "fmt"
    runDep buildSnappy            snappy-linux-s390x-1.1.10-cb3                 "snappy"
    runDep buildOssl              openssl-linux-s390x-3.5.7-1                   "openssl-3.5.7" "openssl-3.5.7.tar.gz"
    runDep buildLibevent          libevent-linux-s390x-2.1.13-cb2               "libevent"
    runDep buildGlog              glog-linux-s390x-v0.4.0-cb3                   "glog"
    runDep buildZstd              zstd-cpp-linux-s390x-1.5.0-4                  "zstd-1.5.0" "v1.5.0.tar.gz"
    runDep buildJemalloc          jemalloc-linux-s390x-5.3.0-17                 "jemalloc"
    runDep buildFolly             folly-linux-s390x-v2022.05.23.00-couchbase-cb3_avx2 "folly"
    runDep buildGtest             googletest-linux-s390x-1.15.2-cb1             "googletest"
    runDep buildZlib              zlib-linux-s390x-1.2.13-2                     "zlib"
    if [ "$CB_CURL_TLS" = "1" ]; then
        runDep buildCurlTLS       curl-linux-s390x-8.21.0-2                     "curl-couchbase" "curl"
    else
        warn "CB_CURL_TLS=0: building IBM's curl without TLS; Eventing's curl() will not reach https:// URLs"
        runDep buildCurlNoTLS     curl-linux-s390x-8.21.0-2                     "curl" "curl-couchbase"
    fi
    runDep buildGrpc              grpc-linux-s390x-1.78.1-1                     "grpc"
    runDep buildJemalloc_noprefix jemalloc_noprefix-linux-s390x-5.2.1-12        "jemalloc_noprefix"
    runDep buildJson              json-linux-s390x-3.11.3-cb2                   "json"
    runDep buildLiburing          liburing-linux-s390x-0.6-3                    "liburing"
    runDep buildLibuv             libuv-linux-s390x-1.20.3-23                   "libuv"
    runDep buildLz4               lz4-linux-s390x-1.10.0-2                      "lz4-1.10.0" "v1.10.0.tar.gz"
    runDep buildNumctl            numactl-linux-s390x-2.0.11-cb4                "numactl"
    runDep buildPcre              pcre-linux-s390x-8.44-cb4                     "pcre-8.44" "pcre-8.44.tar.gz"
    runDep buildPrometheus        prometheus-linux-s390x-2.53.5-9               "$gopath/src/github.com/prometheus" "node-v20.15.0-linux-s390x.tar.xz"
    runDep buildPromcpp           prometheus-cpp-linux-s390x-v1.2.1-couchbase-cb1 "prometheus-cpp"
    runDep buildProtoc            protoc-gen-go-linux-s390x-1.2.5-7             "protoc-gen-go"
    runDep buildSpdlog            spdlog-linux-s390x-v1.15.0-cb4                "spdlog"
    runDep buildLibsodium         libsodium-linux-s390x-1.0.21-1                "libsodium-1.0.21" "libsodium-1.0.21.tar.gz"
    runDep buildFaissEE           faiss-linux-s390x-1.11.0-6_avx2               "faiss-blevesearch openblas-couchbase" "faiss OpenBLAS"
    runDep buildSimdutf           simdutf-linux-s390x-7.0.0-2_generic           "simdutf"
    runDep buildV8                v8-linux-s390x-13.4.115-3                     "v8" ".gclient .gclient_entries depot_tools gn"
    runDep buildAWSSDK            AWSSDK-linux-s390x-1.11.450-2                 "aws-sdk-cpp"
    runDep buildFastFloat         fast_float-linux-s390x-7.0.0-1                "fast_float"
    runDep buildFuzzTest          fuzztest-linux-s390x-v2025-02-14-cb2          "fuzztest"
    printf -- "Finished Building dependencies from source.\n"
}

function stageSource() {
    printf -- "Fetching the Couchbase Server %s source (%s).\n" "$PACKAGE_VERSION" "$CB_EDITION"
    syncSource
}

function main() {
    log "Couchbase Server $PACKAGE_VERSION $CB_EDITION edition for s390x - stages: $CB_STAGES"
    printf -- "Build kit version: %s\nWorkspace: %s\nInstall prefix: %s\ncbdeps cache: %s\nLog: %s\n" \
        "$KIT_VERSION" "$SOURCE_ROOT" "$CB_PREFIX" "$CACHE_DIRECTORY" "$LOG_FILE"

    source $PRESERVE_ENVARS

    local stage
    for stage in $CB_STAGES; do
        # git and ssh are installed by 'prereqs'; from then on every stage runs
        # with this kit's git settings. If this run is going to need the
        # private repositories (to sync them, or for the private Go modules the
        # server build fetches), check that they can be read now, before
        # spending hours on dependencies. A run limited to the earlier stages
        # (for example --stages prereqs,tools,deps) is not held up by this.
        if [ "$stage" != "preflight" ] && [ "$stage" != "prereqs" ] && [ -z "${KIT_ENV_READY:-}" ]; then
            exportCertificateSettings
            setupGitEnvironment
            KIT_ENV_READY=1
            if [ "$CB_EDITION" = "enterprise" ]; then
                case " $CB_STAGES " in
                    *" source "*|*" build "*)
                        bash "$KIT_ROOT/scripts/preflight.sh" --only access --edition "$CB_EDITION" \
                            --git-auth "$CB_GIT_AUTH" --exclude "$(excludedProjects)" ;;
                esac
            fi
        fi

        log "Stage: $stage"
        case "$stage" in
            preflight) stagePreflight ;;
            prereqs)   stagePrereqs ;;
            tools)     stageTools ;;
            deps)      stageDeps ;;
            source)    stageSource ;;
            patch)     patchSource ;;
            build)     buildServer ;;
            test)      runTest ;;
            package)   packageServer ;;
        esac
        source $PRESERVE_ENVARS
    done

    log "Finished stages: $CB_STAGES"
    if [ -x "$CB_PREFIX/bin/couchbase-server" ]; then
        printf -- '\nRun following command to run couchbase server.\n'
        printf -- "\n    sudo $CB_PREFIX/bin/couchbase-server --start\n"
        printf -- '\nThe Couchbase UI can be viewed at http://hostname:8091\n'
        printf -- "\nThen check the build with:  bash %s/scripts/smoke-test.sh --prefix %s\n" "$KIT_ROOT" "$CB_PREFIX"
        printf -- '\nFor more help visit https://docs.couchbase.com/home/server.html \n'
    fi
}

if [ "$CB_TRACE" = "1" ]; then
    set -x
fi

printSystemDetails  |&  tee -a "$LOG_FILE"
# main workflow process
main  |&  tee -a "$LOG_FILE"
