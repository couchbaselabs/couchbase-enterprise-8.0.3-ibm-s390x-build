#!/usr/bin/env bash
#
# scan-portability.sh - find architecture-specific code in a Couchbase Server
#                       source tree before trying to build it on s390x.
#
#   bash scripts/scan-portability.sh /path/to/couchbase            # Enterprise-only projects
#   bash scripts/scan-portability.sh --all /path/to/couchbase      # every project
#   bash scripts/scan-portability.sh /path/to/magma /path/to/plasma  # individual checkouts
#
# The Enterprise-only repositories are private, so nobody outside Couchbase -
# IBM included - has checked them for s390x. This script reads a synced source
# tree (it does not build anything, and runs on any Linux or macOS machine
# with bash, grep, find and file) and reports the constructs that typically
# break a port to a new, big-endian architecture:
#
#   A. Go files restricted to amd64/arm64 by name or build constraint, and
#      whether the same package also has a file that s390x can use
#   B. Go assembly
#   C. C/C++: #error in architecture checks, x86/ARM intrinsics, inline assembly
#   D. C/C++ and Go: explicit byte-order assumptions worth reviewing
#   E. CMake: architecture conditions, cbdep downloads, extra DECLARE_DEP
#      packages, downloads of prebuilt binaries
#   F. Java (Analytics): native-code dependencies selected by platform
#   G. Prebuilt binaries checked into the tree
#
# The report goes to standard output; redirect it to a file to share it:
#
#   bash scripts/scan-portability.sh ~/couchbase > ee-portability-report.txt
#
# A hit is a place to look, not necessarily a problem (many have a portable
# fallback next to them). No hits in a section is a good sign, not a guarantee.
#
set -uo pipefail

# Enterprise-only project paths in released/couchbase-server/8.0.3.xml.
EE_PROJECTS="analytics backup cbbs cbftx hebrew magma
goproj/src/github.com/couchbase/bhive
goproj/src/github.com/couchbase/cbas
goproj/src/github.com/couchbase/eventing
goproj/src/github.com/couchbase/eventing-ee
goproj/src/github.com/couchbase/gocbcrypto
goproj/src/github.com/couchbase/goxdcr
goproj/src/github.com/couchbase/plasma
goproj/src/github.com/couchbase/query-ee
goproj/src/github.com/couchbase/regulator"

SCAN_ALL=0
ROOTS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --all)     SCAN_ALL=1; shift ;;
        -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
        -*)        echo "unknown option: $1" >&2; exit 1 ;;
        *)         ROOTS+=("$1"); shift ;;
    esac
done
[ "${#ROOTS[@]}" -gt 0 ] || { echo "usage: $0 [--all] SOURCE_DIR..." >&2; exit 1; }

# Work out which directories to scan.
TARGETS=()
for root in "${ROOTS[@]}"; do
    [ -d "$root" ] || { echo "not a directory: $root" >&2; exit 1; }
    root="$(cd "$root" && pwd)"
    if [ "$SCAN_ALL" = "0" ] && [ -d "$root/tlm" ] && [ -d "$root/goproj" ]; then
        # Top of a repo-synced Couchbase tree: Enterprise-only projects.
        for p in $EE_PROJECTS; do
            if [ -d "$root/$p" ]; then TARGETS+=("$root/$p"); else echo "(not present: $p)"; fi
        done
    else
        TARGETS+=("$root")
    fi
done
[ "${#TARGETS[@]}" -gt 0 ] || { echo "nothing to scan (no Enterprise projects found under the given directory)" >&2; exit 1; }

# Paths that are never interesting: VCS data, vendored and generated trees.
PRUNE='/\.git/|/\.repo/|/vendor/|/node_modules/|/third_party/|/thirdparty/|/build/|/target/|/testdata/'

section() { printf '\n--- %s\n' "$*"; }
# list FILES_FROM_STDIN with a cap, relative to the target directory
show() {
    local limit="${1:-40}" n=0 line
    while IFS= read -r line; do
        n=$((n + 1))
        [ "$n" -le "$limit" ] && printf '    %s\n' "${line#"$TARGET"/}"
    done
    [ "$n" -eq 0 ] && printf '    (none)\n'
    [ "$n" -gt "$limit" ] && printf '    ... and %d more\n' "$((n - limit))"
    return 0
}
src_files() {  # src_files EXT...  -> matching files under $TARGET, pruned
    local args=() ext first=1
    for ext in "$@"; do
        [ "$first" = 1 ] || args+=(-o)
        args+=(-name "*.$ext"); first=0
    done
    find "$TARGET" -type f \( "${args[@]}" \) 2>/dev/null | grep -Ev "$PRUNE"
}

TOTAL_FLAGS=0
flag() { TOTAL_FLAGS=$((TOTAL_FLAGS + 1)); }

for TARGET in "${TARGETS[@]}"; do
    printf '\n==============================================================================\n'
    printf '%s\n' "$TARGET"
    if [ -d "$TARGET/.git" ] || [ -f "$TARGET/.git" ]; then
        printf 'revision: %s\n' "$(git -C "$TARGET" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    fi
    printf '==============================================================================\n'

    GO_FILES="$(src_files go)"
    C_FILES="$(src_files c cc cpp cxx h hh hpp hxx)"
    CMAKE_FILES="$(find "$TARGET" -type f \( -name CMakeLists.txt -o -name '*.cmake' \) 2>/dev/null | grep -Ev "$PRUNE")"

    # ------------------------------------------------------------------ A
    section "A. Go packages with files limited to amd64/arm64"
    # Files limited by name (_amd64.go) or by a build constraint that names
    # amd64/arm64/386 without also naming s390x.
    ARCH_GO="$( { printf '%s\n' "$GO_FILES" | grep -E '_(amd64|arm64|386|arm)(_test)?\.go$';
                  printf '%s\n' "$GO_FILES" | grep -v '^$' | xargs -r grep -lE '^//(go:build| \+build).*\b(amd64|arm64|386)\b' 2>/dev/null \
                      | xargs -r grep -LE '^//(go:build| \+build).*\bs390x\b' 2>/dev/null; } | grep -v '^$' | sort -u)"
    if [ -z "$ARCH_GO" ]; then
        printf '    (none)\n'
    else
        printf '%s\n' "$ARCH_GO" | xargs -r -n1 dirname | sort -u | while IFS= read -r dir; do
            # Is there a file in the package that linux/s390x could use instead:
            # one whose build constraint names s390x or excludes the listed
            # architectures ("!amd64"), or a conventionally named generic file -
            # ignoring files that are themselves tied to another OS.
            fallback=""
            for cand in "$dir"/*.go; do
                [ -f "$cand" ] || continue
                base="$(basename "$cand")"
                case "$base" in *_test.go|*_darwin*|*_windows*|*_freebsd*|*_amd64.go|*_arm64.go|*_386.go|*_arm.go) continue ;; esac
                constraint="$(grep -m1 -E '^//go:build ' "$cand" 2>/dev/null || grep -m1 -E '^// \+build ' "$cand" 2>/dev/null || true)"
                case "$constraint" in
                    *darwin*|*windows*|*freebsd*) case "$constraint" in *linux*) ;; *) continue ;; esac ;;
                esac
                usable=0
                case "$constraint" in *s390x*|*'!amd64'*|*'!arm64'*) usable=1 ;; esac
                case "$base" in *_generic.go|*_other.go|*_noasm.go|*_purego.go|*_fallback.go|*_default.go|*_stub.go) usable=1 ;; esac
                [ "$usable" = 1 ] && fallback="$fallback$base "
            done
            printf '    %s/\n' "${dir#"$TARGET"/}"
            printf '%s\n' "$ARCH_GO" | grep -F "$dir/" | while IFS= read -r f; do
                [ "$(dirname "$f")" = "$dir" ] && printf '        %s\n' "$(basename "$f")"
            done
            if [ -n "$fallback" ]; then
                printf '        -> possible fallback for s390x: %s\n' "$fallback"
            else
                printf '        -> NO obvious fallback: s390x probably needs its own file here\n'
            fi
        done
        flag
    fi

    # ------------------------------------------------------------------ B
    section "B. Go assembly (.s) - needs an s390x version or a pure-Go fallback"
    find "$TARGET" -type f -name '*.s' 2>/dev/null | grep -Ev "$PRUNE" | grep -v '_s390x\.s$' | show 30

    # ------------------------------------------------------------------ C
    section "C1. C/C++ #error inside architecture / platform checks"
    printf '%s\n' "$C_FILES" | grep -v '^$' | xargs -r grep -nE '^[[:space:]]*#[[:space:]]*error' 2>/dev/null \
        | grep -iE 'arch|platform|cpu|endian|unsupported|unknown|x86|arm|64' | show 40

    section "C2. C/C++ files using x86 or ARM intrinsics / CPU feature headers"
    printf '%s\n' "$C_FILES" | grep -v '^$' \
        | xargs -r grep -lE '#[[:space:]]*include[[:space:]]*<(immintrin|emmintrin|xmmintrin|smmintrin|nmmintrin|tmmintrin|wmmintrin|x86intrin|cpuid|arm_neon|arm_acle|arm_sve)\.h>|_mm_(pause|crc32|prefetch)|__builtin_ia32_|__get_cpuid' 2>/dev/null | show 40

    section "C3. C/C++ files with architecture conditionals (check each has a generic #else)"
    printf '%s\n' "$C_FILES" | grep -v '^$' \
        | xargs -r grep -lE '__x86_64__|__amd64__|__aarch64__|__arm64__|_M_X64|_M_ARM64|__i386__' 2>/dev/null | show 60

    section "C4. C/C++ inline assembly"
    printf '%s\n' "$C_FILES" | grep -v '^$' | xargs -r grep -nE '\b(__asm__|__asm|asm)[[:space:]]*(volatile)?[[:space:]]*\(' 2>/dev/null | show 30

    # ------------------------------------------------------------------ D
    section "D1. C/C++ byte-order handling (s390x is big-endian) - review"
    printf '%s\n' "$C_FILES" | grep -v '^$' \
        | xargs -r grep -lE '__BYTE_ORDER|__LITTLE_ENDIAN|__BIG_ENDIAN|_BIG_ENDIAN|WORDS_BIGENDIAN|kIsLittleEndian|kIsBigEndian|le(16|32|64)toh|hto(le|be)(16|32|64)|be(16|32|64)toh|__builtin_bswap|folly::Endian|boost::endian' 2>/dev/null | show 60

    section "D2. Go code reading or writing integers through unsafe/native byte order - review"
    printf '%s\n' "$GO_FILES" | grep -v '^$' \
        | xargs -r grep -lE 'binary\.NativeEndian|\(\*\[[0-9A-Za-z_.]*\](u?int(16|32|64)|byte)\)\(unsafe\.Pointer|\(\*u?int(16|32|64)\)\(unsafe\.Pointer|reflect\.SliceHeader|unsafe\.Slice\(\(\*byte\)' 2>/dev/null \
        | grep -v '_test\.go$' | show 60

    # ------------------------------------------------------------------ E
    section "E1. CMake architecture conditions"
    printf '%s\n' "$CMAKE_FILES" | grep -v '^$' \
        | xargs -r grep -nE 'CMAKE_SYSTEM_PROCESSOR|CB_SYSTEM_PROCESSOR|x86_64|aarch64|arm64|AMD64' 2>/dev/null | show 40

    section "E2. CMake: cbdep installs, extra dependency packages, downloads"
    printf '%s\n' "$CMAKE_FILES" | grep -v '^$' \
        | xargs -r grep -nE 'CBDEP_INSTALL|\$\{CBDEP\}|DECLARE_DEP[[:space:]]*\(|FILE[[:space:]]*\([[:space:]]*DOWNLOAD|ExternalProject_Add|FetchContent_Declare' 2>/dev/null | show 40

    # ------------------------------------------------------------------ F
    POMS="$(find "$TARGET" -type f -name pom.xml 2>/dev/null | grep -Ev "$PRUNE")"
    if [ -n "$POMS" ]; then
        section "F. Maven: platform-specific (native) artifacts"
        printf '%s\n' "$POMS" | xargs -r grep -nE 'os\.detected|<classifier>[^<]*(linux|x86|amd64|aarch|osx|windows)[^<]*</classifier>|protoc|tcnative|rocksdbjni|netty-transport-native|snappy-java|zstd-jni|lz4-java|jna' 2>/dev/null | show 40
    fi

    # ------------------------------------------------------------------ G
    section "G. Prebuilt executables and libraries checked into the tree"
    find "$TARGET" -type f \( -perm -u+x -o -name '*.so' -o -name '*.so.*' -o -name '*.a' -o -name '*.dylib' -o -name '*.dll' -o -name '*.exe' -o -name '*.jar' \) 2>/dev/null \
        | grep -Ev '/\.git/|/\.repo/' | while IFS= read -r f; do
            kind="$(file -b "$f" 2>/dev/null)"
            case "$kind" in
                ELF*|Mach-O*|PE32*|*"ar archive"*) printf '%s  [%s]\n' "$f" "$(printf '%s' "$kind" | cut -c1-60)" ;;
            esac
        done | show 30
done

printf '\n==============================================================================\n'
printf 'Scanned %d director%s. Sections A-G list places to review for s390x;\n' "${#TARGETS[@]}" "$([ "${#TARGETS[@]}" -eq 1 ] && echo y || echo ies)"
printf 'see docs/EE-PORTING-STATUS.md for how to act on them.\n'
