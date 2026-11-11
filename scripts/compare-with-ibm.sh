#!/usr/bin/env bash
#
# compare-with-ibm.sh - show exactly how build_couchbase_ee.sh differs from
# IBM's build_couchbase.sh, function by function.
#
#   bash scripts/compare-with-ibm.sh            summary
#   bash scripts/compare-with-ibm.sh --diff     summary plus the changed lines
#
# Functions marked "# [IBM]" in build_couchbase_ee.sh are meant to be IBM's
# code with only the edits listed in docs/DIFFERENCES-FROM-IBM.md. This
# script checks that claim against the unmodified copy kept in
# upstream/linux-on-ibm-z-scripts/: it reports which IBM functions are
# carried over unchanged, which were edited (and how), which were dropped,
# and which functions in the kit's script are new.
#
set -euo pipefail

SHOW_DIFF=0
case "${1:-}" in
    --diff) SHOW_DIFF=1 ;;
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    "") ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
esac

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IBM="$KIT_ROOT/upstream/linux-on-ibm-z-scripts/Couchbase/8.0.3/build_couchbase.sh"
KIT="$KIT_ROOT/build_couchbase_ee.sh"
[ -f "$IBM" ] || { echo "missing $IBM" >&2; exit 1; }
[ -f "$KIT" ] || { echo "missing $KIT" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/ibm" "$TMP/kit"

# Write every top-level function of FILE to DIR/<name>. For the kit's script,
# also record in DIR/.marked which functions carry the "# [IBM]" marker.
split_functions() {
    awk -v dir="$2" '
        /^# \[IBM\]/ { marked = 1; next }
        /^function[ \t]+[A-Za-z0-9_]+[ \t]*\(\)[ \t]*\{/ {
            name = $2; sub(/\(.*/, "", name)
            out = dir "/" name
            if (marked) print name >> (dir "/.marked")
            marked = 0
            infn = 1
        }
        infn { print > out }
        infn && /^}[ \t]*$/ { close(out); infn = 0 }
        !infn && !/^# \[IBM\]/ && !/^[ \t]*$/ { marked = 0 }
    ' "$1"
}
split_functions "$IBM" "$TMP/ibm"
split_functions "$KIT" "$TMP/kit"
touch "$TMP/kit/.marked"

# buildCurl is kept under another name (the kit's default curl build has TLS).
renamed_from() { case "$1" in buildCurlNoTLS) echo buildCurl ;; *) echo "$1" ;; esac; }

unchanged=0 edited=0 changed_lines=0
edited_report="$TMP/edited.txt"; : > "$edited_report"
kept_ibm_names="$TMP/kept.txt"; : > "$kept_ibm_names"

while read -r fn; do
    src="$(renamed_from "$fn")"
    echo "$src" >> "$kept_ibm_names"
    if [ ! -f "$TMP/ibm/$src" ]; then
        echo "  $fn: marked [IBM] but IBM's script has no function '$src'" >> "$edited_report"
        edited=$((edited + 1))
        continue
    fi
    # Compare bodies; the function's own name line is normalised for the rename.
    if diff -q <(sed "1s/$src/$fn/" "$TMP/ibm/$src") "$TMP/kit/$fn" >/dev/null; then
        unchanged=$((unchanged + 1))
        [ "$src" = "$fn" ] || echo "  $fn: IBM's $src, renamed, otherwise unchanged" >> "$edited_report"
    else
        edited=$((edited + 1))
        n="$(diff <(sed "1s/$src/$fn/" "$TMP/ibm/$src") "$TMP/kit/$fn" | grep -c '^>' || true)"
        changed_lines=$((changed_lines + n))
        echo "  $fn: $n line(s) changed" >> "$edited_report"
        if [ "$SHOW_DIFF" = "1" ]; then
            diff <(sed "1s/$src/$fn/" "$TMP/ibm/$src") "$TMP/kit/$fn" | sed 's/^/      /' >> "$edited_report" || true
        fi
    fi
done < "$TMP/kit/.marked"

total_ibm="$(find "$TMP/ibm" -maxdepth 1 -type f ! -name '.*' | wc -l)"
echo "IBM's script:  $total_ibm functions  ($IBM)"
echo "Kit's script:  $(find "$TMP/kit" -maxdepth 1 -type f ! -name '.*' | wc -l) functions, $(wc -l < "$TMP/kit/.marked") of them marked [IBM]"
echo
echo "Carried over unchanged: $unchanged"
echo "Carried over with edits: $edited ($changed_lines changed lines in total)"
cat "$edited_report"
echo
echo "IBM functions not carried over (replaced by the kit's own code):"
for f in "$TMP"/ibm/*; do
    name="$(basename "$f")"
    grep -qx "$name" "$kept_ibm_names" || echo "  $name"
done
echo
echo "Functions that exist only in the kit's script:"
for f in "$TMP"/kit/*; do
    name="$(basename "$f")"
    grep -qx "$name" "$TMP/kit/.marked" || echo "$name"
done | paste -sd' ' - | fold -s -w 76 | sed 's/^/  /; s/ *$//'
