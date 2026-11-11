#!/usr/bin/env bash
#
# smoke-test.sh - quick functional check of a freshly built Couchbase Server
#                 on the s390x build host.
#
#   bash scripts/smoke-test.sh --prefix /opt/couchbase
#
# What it does
#   1. Static checks on the install tree (edition, architecture, the pieces an
#      Enterprise build adds, and the things this kit changed relative to
#      IBM's recipe: cbcollect_info's Python modules, libcurl with HTTPS, faiss).
#   2. Starts the server if it is not running and, ONLY IF THE NODE HAS NEVER
#      BEEN SET UP, initialises a single-node cluster with every service the
#      build contains.
#   3. Creates test buckets (smoke_couchstore, and smoke_magma on Enterprise),
#      then exercises Data, Query, Index, Search and - if present - Analytics,
#      Eventing, Backup and XDCR.
#   4. Looks for crashed services in the cluster log.
#
# It never touches a node that is already initialised unless you pass its
# administrator credentials with --user/--password, and then it only adds the
# two smoke_* buckets (removed again unless --keep is given).
#
# Options
#   --prefix DIR        install prefix of the build (required)
#   --user NAME         administrator user (default Administrator)
#   --password PASS     administrator password (default: generated for a new node)
#   --keep              leave the smoke_* buckets in place
#   --stop              stop the server at the end (only if this script started it)
#
set -uo pipefail

PREFIX=""
ADMIN_USER="Administrator"
ADMIN_PASS=""
KEEP=0
STOP_AT_END=0

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)   PREFIX="$2"; shift 2 ;;
        --user)     ADMIN_USER="$2"; shift 2 ;;
        --password) ADMIN_PASS="$2"; shift 2 ;;
        --keep)     KEEP=1; shift ;;
        --stop)     STOP_AT_END=1; shift ;;
        -h|--help)  awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done
[ -n "$PREFIX" ] || { echo "ERROR: --prefix is required" >&2; exit 1; }
BIN="$PREFIX/bin"
[ -x "$BIN/couchbase-server" ] || { echo "ERROR: $BIN/couchbase-server not found" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required" >&2; exit 1; }

PASSED=0; FAILED=0; SKIPPED=0
pass() { printf '  [pass]  %s\n' "$*"; PASSED=$((PASSED + 1)); }
fail() { printf '  [FAIL]  %s\n' "$*"; FAILED=$((FAILED + 1)); }
skip() { printf '  [skip]  %s\n' "$*"; SKIPPED=$((SKIPPED + 1)); }
info() { printf '  [info]  %s\n' "$*"; }

HOST="http://127.0.0.1"
# rest METHOD PORT PATH [curl args...]  -> body on stdout, HTTP status in $HTTP_CODE
HTTP_CODE=000
rest() {
    local method="$1" port="$2" path="$3"; shift 3
    local out
    out="$(curl -sS -m 60 -X "$method" -u "$ADMIN_USER:$ADMIN_PASS" -w '\n%{http_code}' "$HOST:$port$path" "$@" 2>/dev/null)" || true
    HTTP_CODE="${out##*$'\n'}"
    printf '%s' "${out%$'\n'*}"
}
# wait_for SECONDS DESCRIPTION COMMAND...
wait_for() {
    local timeout="$1" waited=0; shift 2   # $2 only describes the wait for readers
    until "$@" >/dev/null 2>&1; do
        sleep 3; waited=$((waited + 3))
        [ "$waited" -ge "$timeout" ] && return 1
    done
    return 0
}
n1ql() { rest POST 8093 /query/service --data-urlencode "statement=$1"; }

# ----------------------------------------------------------------- 1. static
echo "1. Install tree"
VERSION_LINE="$("$BIN/couchbase-server" --version 2>/dev/null)"
info "$VERSION_LINE"
EDITION="community"
case "$VERSION_LINE" in *"(EE)"*) EDITION="enterprise" ;; esac

ARCH_INFO="$(file -b "$BIN/memcached" 2>/dev/null)"
case "$ARCH_INFO" in
    *"IBM S/390"*) pass "memcached is an s390x binary" ;;
    *)             fail "memcached is not an s390x binary: ${ARCH_INFO:-missing}" ;;
esac

for exe in memcached indexer projector cbq-engine cbft couchbase-cli cbcollect_info; do
    if [ -x "$BIN/$exe" ]; then pass "bin/$exe present"; else fail "bin/$exe missing"; fi
done
if [ "$EDITION" = "enterprise" ]; then
    for exe in goxdcr eventing-producer eventing-consumer cbas backup cbbackupmgr; do
        if [ -x "$BIN/$exe" ]; then pass "bin/$exe present (Enterprise)"; else fail "bin/$exe missing (Enterprise component not built?)"; fi
    done
    if ls "$PREFIX"/lib/libfaiss_c.so* >/dev/null 2>&1; then pass "faiss C API library installed"; else fail "lib/libfaiss_c.so missing (vector search)"; fi
    if ls "$PREFIX"/lib/libmagma* >/dev/null 2>&1 || strings "$BIN/memcached" 2>/dev/null | grep -q -m1 magma; then
        pass "magma storage engine present"
    else
        fail "no sign of the magma storage engine"
    fi
fi

# V8 on s390x loads its ICU data from this file next to the executables.
if [ -f "$BIN/icudtb.dat" ]; then pass "V8 ICU data file (bin/icudtb.dat) present"; else fail "bin/icudtb.dat missing; JavaScript (views, Eventing, UDFs) will lack ICU data"; fi

# cbcollect_info imports pyzipper at start-up (missing from IBM's cbpy recipe).
if "$BIN/cbcollect_info" --help >/dev/null 2>&1; then pass "cbcollect_info starts"; else fail "cbcollect_info does not start (Python module missing from lib/python/interp?)"; fi

# libcurl with TLS (IBM's recipe builds it without).
CURL_FEATURES="$("$BIN/curl" --version 2>/dev/null || true)"
case "$CURL_FEATURES" in
    *https*) pass "bundled curl supports https" ;;
    *)       fail "bundled curl has no https support; Eventing's curl() cannot reach https URLs" ;;
esac

# ----------------------------------------------------------------- 2. start
echo
echo "2. Start-up and node initialisation"
STARTED_HERE=0
if ! curl -sS -m 5 -o /dev/null "$HOST:8091/pools" 2>/dev/null; then
    if [ -w "$PREFIX/var/lib/couchbase" ] || [ -w "$PREFIX/var/lib" ] || [ -w "$PREFIX" ]; then
        "$BIN/couchbase-server" --start >/dev/null 2>&1
    else
        info "$PREFIX is not writable by $(id -un); starting the server with sudo"
        sudo "$BIN/couchbase-server" --start >/dev/null 2>&1
    fi
    STARTED_HERE=1
fi
if wait_for 180 "REST API" curl -sS -m 5 -o /dev/null "$HOST:8091/pools"; then
    pass "cluster manager answers on port 8091"
else
    fail "cluster manager did not come up on port 8091 within 3 minutes (see $PREFIX/var/lib/couchbase/logs)"
    echo; echo "Smoke test: $PASSED passed, $FAILED failed, $SKIPPED skipped."; exit 1
fi

POOLS="$(curl -sS -m 10 "$HOST:8091/pools" 2>/dev/null)"
case "$POOLS" in
    *'"isEnterprise":true'*)  [ "$EDITION" = "enterprise" ] && pass "node reports Enterprise Edition" || fail "node reports Enterprise but the start script says Community" ;;
    *'"isEnterprise":false'*) [ "$EDITION" = "community" ] && pass "node reports Community Edition" || fail "node reports Community Edition although this is an Enterprise build" ;;
esac

SERVICES="data,index,query,fts"
if [ "$EDITION" = "enterprise" ]; then
    [ -x "$BIN/eventing-producer" ] && SERVICES="$SERVICES,eventing"
    [ -x "$BIN/cbas" ] && SERVICES="$SERVICES,analytics"
    [ -x "$BIN/backup" ] && SERVICES="$SERVICES,backup"
fi

case "$POOLS" in
    *'"pools":[]'*)
        [ -n "$ADMIN_PASS" ] || ADMIN_PASS="Smoke-$(head -c 9 /dev/urandom | od -An -tx1 | tr -d ' \n')"
        info "new node: initialising a single-node cluster with services $SERVICES"
        info "administrator: $ADMIN_USER / $ADMIN_PASS"
        INIT_ARGS=(cluster-init -c 127.0.0.1 --cluster-username "$ADMIN_USER" --cluster-password "$ADMIN_PASS"
                   --services "$SERVICES" --cluster-ramsize 1536 --cluster-index-ramsize 512 --cluster-fts-ramsize 256)
        case "$SERVICES" in *eventing*)  INIT_ARGS+=(--cluster-eventing-ramsize 256) ;; esac
        case "$SERVICES" in *analytics*) INIT_ARGS+=(--cluster-analytics-ramsize 1024) ;; esac
        if INIT_OUT="$("$BIN/couchbase-cli" "${INIT_ARGS[@]}" 2>&1)"; then
            pass "couchbase-cli cluster-init"
        else
            fail "couchbase-cli cluster-init: $INIT_OUT"
            echo; echo "Smoke test: $PASSED passed, $FAILED failed, $SKIPPED skipped."; exit 1
        fi
        ;;
    *)
        if [ -z "$ADMIN_PASS" ]; then
            skip "node is already initialised; pass --user/--password to run the service checks"
            echo; echo "Smoke test: $PASSED passed, $FAILED failed, $SKIPPED skipped."
            [ "$FAILED" -eq 0 ]; exit $?
        fi
        info "node is already initialised; using the credentials given"
        ;;
esac

# ---------------------------------------------------------------- 3. services
echo
echo "3. Services"
create_bucket() {
    local name="$1" backend="$2" ram="$3" out
    local backend_args=()
    [ "$EDITION" = "enterprise" ] && backend_args=(--storage-backend "$backend")
    if out="$("$BIN/couchbase-cli" bucket-create -c 127.0.0.1 -u "$ADMIN_USER" -p "$ADMIN_PASS" \
            --bucket "$name" --bucket-type couchbase "${backend_args[@]}" \
            --bucket-ramsize "$ram" --bucket-replica 0 --wait 2>&1)"; then
        pass "bucket $name created ($backend)"
        return 0
    fi
    case "$out" in *"already exists"*) info "bucket $name already exists"; return 0 ;; esac
    fail "bucket $name ($backend): $out"
    return 1
}
create_bucket smoke_couchstore couchstore 256
HAVE_MAGMA_BUCKET=0
if [ "$EDITION" = "enterprise" ]; then
    create_bucket smoke_magma magma 1024 && HAVE_MAGMA_BUCKET=1
fi

query_ok() { case "$(n1ql 'SELECT 1')" in *'"status": "success"'*|*'"status":"success"'*) return 0 ;; esac; return 1; }
if wait_for 180 "query service" query_ok; then
    pass "Query service answers"
    for bucket in smoke_couchstore $([ "$HAVE_MAGMA_BUCKET" = 1 ] && echo smoke_magma); do
        # A new bucket takes a moment to become visible to the query service.
        OUT=""
        write_doc() {
            OUT="$(n1ql "UPSERT INTO \`$bucket\` (KEY, VALUE) VALUES (\"smoke::1\", {\"type\": \"smoke\", \"text\": \"hello from s390x\", \"n\": 42})")"
            case "$OUT" in *'"status": "success"'*|*'"status":"success"'*) return 0 ;; esac
            return 1
        }
        if wait_for 120 "write to $bucket" write_doc; then
            pass "Data: document written to $bucket through N1QL"
        else
            fail "Data: write to $bucket failed: $(echo "$OUT" | tr -d '\n' | cut -c1-300)"
        fi

        # A secondary index exercises the indexer and the projector, both of
        # which crashed at start-up with IBM's kernel-version patch.
        OUT="$(n1ql "CREATE INDEX smoke_idx ON \`$bucket\`(n)")"
        case "$OUT" in
            *'"status": "success"'*|*'"status":"success"'*|*"already exists"*) pass "Index: CREATE INDEX on $bucket" ;;
            *) fail "Index: CREATE INDEX on $bucket failed: $(echo "$OUT" | tr -d '\n' | cut -c1-300)" ;;
        esac
        index_scan() { case "$(n1ql "SELECT RAW text FROM \`$bucket\` WHERE n = 42")" in *"hello from s390x"*) return 0 ;; esac; return 1; }
        if wait_for 120 "index scan" index_scan; then pass "Query + Index: indexed read from $bucket"; else fail "Query + Index: indexed read from $bucket did not return the document"; fi
    done
else
    fail "Query service did not answer on port 8093 within 3 minutes"
fi

# Search
FTS_DEF='{"type":"fulltext-index","name":"smoke_fts","sourceType":"gocbcore","sourceName":"smoke_couchstore","planParams":{"indexPartitions":1},"params":{}}'
rest PUT 8094 /api/index/smoke_fts -H 'Content-Type: application/json' -d "$FTS_DEF" >/dev/null
if [ "$HTTP_CODE" = "200" ]; then
    fts_hit() { case "$(rest POST 8094 /api/index/smoke_fts/query -H 'Content-Type: application/json' -d '{"query":{"query":"hello"},"size":1}')" in *'"total_hits":0'*) return 1 ;; *'"total_hits":'*) return 0 ;; esac; return 1; }
    if wait_for 120 "search hit" fts_hit; then pass "Search: full-text index built and queried"; else fail "Search: index created but the document was never found"; fi
else
    fail "Search: creating a full-text index returned HTTP $HTTP_CODE"
fi

if [ "$EDITION" = "enterprise" ]; then
    case "$SERVICES" in *analytics*)
        analytics_ok() { case "$(rest POST 8095 /analytics/service --data-urlencode 'statement=SELECT VALUE 1')" in *success*) return 0 ;; esac; return 1; }
        if wait_for 240 "analytics" analytics_ok; then pass "Analytics service answers a query"; else fail "Analytics service did not answer on port 8095"; fi ;;
    *) skip "Analytics is not part of this build" ;;
    esac
    case "$SERVICES" in *eventing*)
        eventing_ok() { rest GET 8096 /api/v1/status >/dev/null; [ "$HTTP_CODE" = "200" ]; }
        if wait_for 180 "eventing" eventing_ok; then pass "Eventing service answers"; else fail "Eventing service did not answer on port 8096 (HTTP $HTTP_CODE)"; fi ;;
    *) skip "Eventing is not part of this build" ;;
    esac
    case "$SERVICES" in *backup*)
        backup_ok() { rest GET 8097 /api/v1/cluster/self >/dev/null; [ "$HTTP_CODE" = "200" ]; }
        if wait_for 180 "backup" backup_ok; then pass "Backup service answers"; else fail "Backup service did not answer on port 8097 (HTTP $HTTP_CODE)"; fi ;;
    *) skip "Backup is not part of this build" ;;
    esac
    rest GET 8091 /pools/default/remoteClusters >/dev/null
    if [ "$HTTP_CODE" = "200" ]; then pass "XDCR (goxdcr) answers through the cluster manager"; else fail "XDCR: /pools/default/remoteClusters returned HTTP $HTTP_CODE"; fi
fi

# ------------------------------------------------------------------- 4. logs
echo
echo "4. Crashed services"
# The cluster manager logs "Service 'x' exited with status N. Restarting." when
# one of its services dies.
CLUSTER_LOG="$(rest GET 8091 /logs)"
if [ "$HTTP_CODE" = "200" ]; then
    CRASHES="$(printf '%s' "$CLUSTER_LOG" | grep -oE "Service '[A-Za-z0-9_-]+' exited with status [0-9]+" | sort | uniq -c | sort -rn)"
    if [ -z "$CRASHES" ]; then
        pass "no service crashes in the cluster log"
    else
        fail "the cluster log records crashed services (details in $PREFIX/var/lib/couchbase/logs):"
        printf '%s\n' "$CRASHES" | sed 's/^/            /'
    fi
else
    skip "could not read the cluster log (HTTP $HTTP_CODE)"
fi

# ---------------------------------------------------------------- 5. cleanup
if [ "$KEEP" = "0" ]; then
    rest DELETE 8094 /api/index/smoke_fts >/dev/null
    for bucket in smoke_couchstore smoke_magma; do
        "$BIN/couchbase-cli" bucket-delete -c 127.0.0.1 -u "$ADMIN_USER" -p "$ADMIN_PASS" --bucket "$bucket" >/dev/null 2>&1 || true
    done
fi
if [ "$STOP_AT_END" = "1" ] && [ "$STARTED_HERE" = "1" ]; then
    "$BIN/couchbase-server" --stop >/dev/null 2>&1 || sudo "$BIN/couchbase-server" --stop >/dev/null 2>&1 || true
fi

echo
echo "Smoke test: $PASSED passed, $FAILED failed, $SKIPPED skipped."
[ "$FAILED" -eq 0 ]
