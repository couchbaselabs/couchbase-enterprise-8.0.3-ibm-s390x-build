# Enterprise Edition on s390x: status and what to expect

IBM's recipe builds the public (Community) source tree on s390x. This kit
adds the Enterprise tree. That part is new ground: the Enterprise-only
repositories are private, so they have not been built on s390x by IBM, and
they were not available while this kit was written. This page separates what
is known from what is not, and describes how to work through the unknowns.

## Where things stand

| Area | Repositories | State |
|---|---|---|
| Third-party dependencies | (built from upstream sources) | IBM's recipes, unchanged, except faiss and curl (rebuilt Couchbase's way, see below) and extra Python modules |
| Data service, cluster manager, views, Query/Index/Search core | kv_engine, platform, couchstore, ns_server, couchdb, query, indexing, cbft, … (public) | Built on s390x by IBM as Community Edition with the patches in `patch/` |
| Public code that only an Enterprise build compiles | eventing; Enterprise-tagged files in indexing, query, cbft | Reviewed for this kit; three problems found and fixed (below) |
| Enterprise storage and services | magma, plasma, bhive, regulator, goxdcr, gocbcrypto, eventing-ee, query-ee, cbftx, hebrew, backup, cbbs, cbas, cbas-core (private) | **Unknown.** Not seen, not built |
| Analytics Java code | asterixdb, analytics-dcp-client (public), cbas-core (private) | **Unknown.** Java is portable; native Maven artifacts and the JDK are the risks |

### Problems already found and fixed

These were found by reading the public 8.0.3 sources and the official build
recipes, and checked by cross-compiling to s390x and running under QEMU
user-mode emulation.

1. **Index service crashes at start-up with IBM's patch.**
   `indexing/secondary/platform/thp_linux.go` does not compile on s390x as
   shipped, because `syscall.Utsname` uses `uint8` there. IBM's fix casts a
   pointer to the array into a pointer to a slice, which compiles but reads
   the array's bytes as a slice header: `panic: makeslice: cap out of range`.
   The indexer and the projector both call this at start-up
   (`platform.disable_thp` defaults to true). `patch/indexing-s390x.diff`
   uses a correct conversion. This affects IBM's Community build too.

2. **The Enterprise indexer has no faiss/OpenBLAS binding for s390x.**
   `indexing/secondary/vector/codebook` has `linux_openblas_amd64.go` and
   `linux_openblas_arm64.go` only, both excluded from Community builds, so
   only an Enterprise build notices. `patch/indexing-s390x.diff` adds the
   s390x file.

3. **Eventing's build re-includes the breakpad module.** IBM's patch comments
   breakpad out of the top-level build file; eventing (Enterprise only)
   includes `FindCouchbaseBreakpad` again, which then stops CMake because
   there is no breakpad for s390x. `patch/tlm-s390x.diff` handles s390x inside
   the module.

4. **faiss has to be the real thing.** A Community build never links faiss,
   so IBM's static upstream build without the C API is enough there. An
   Enterprise build runs `FIND_PACKAGE(faiss CONFIG REQUIRED)`, installs
   `faiss_c`, and links it into the Index, Search and Query services. The kit
   builds Couchbase's fork (blevesearch/faiss at the commit of the official
   1.11.0-6 package) as shared libraries with the C API and OpenBLAS inside.

5. **libcurl needs TLS.** IBM builds curl `--without-ssl`. Eventing links
   libcurl for its `curl()` bindings. The kit builds curl as Couchbase does,
   against the bundled OpenSSL.

6. **`cbdep` does not exist for s390x.** The Enterprise build uses it to
   download the JDK for Analytics. `scripts/cbdep-linux-s390x` stands in for
   it (Eclipse Temurin has s390x builds).

7. **`cbcollect_info` cannot start** with IBM's Python environment (it
   imports `pyzipper`). The kit adds the modules Couchbase's own `cbpy`
   package has.

One thing looked at and left alone: Eventing's bundled `crc32.cc` takes its
little-endian path on s390x (it tests `_BIG_ENDIAN`, which GCC does not define
there), so its hash differs from other platforms. It is only used to choose a
timer's partition and is self-consistent, so nothing breaks within an s390x
cluster.

## The private components

What each one is, why it might or might not port easily, and what the public
code that uses it tells us.

| Component | Language | Used by | Notes |
|---|---|---|---|
| **magma** | C++ | Data service (Enterprise storage engine); the Enterprise indexer links `magma_shared` | The largest unknown. kv_engine itself builds without magma, but the Enterprise indexer's build depends on it unconditionally, so magma has to work for a complete Enterprise build. Likely trouble: byte order in on-disk formats, x86/ARM intrinsics, `#error` on unknown architectures. It uses platform's CRC32C, which IBM's patch already makes portable (in software) |
| **plasma**, **bhive** | Go + cgo (jemalloc, faiss) | Index service | Go ports well unless files are limited to amd64/arm64 or use assembly. Expect the same faiss naming issue as fixed in indexing (`-lfaiss_avx2` vs `-lfaiss`) |
| **goxdcr** | Go | XDCR; xdcrDiffer requires it as a Go module | IBM removes XDCR entirely. Mostly plain Go; uses PCRE through cgo |
| **eventing-ee** | C++ and Go | Eventing; also provides the JavaScript evaluator (`jseval`) that the Enterprise Query service links | C++ against V8. The public half of Eventing has no architecture-specific code. V8 on s390x is IBM's build: it loads ICU data from `bin/icudtb.dat`, which the public Eventing code initialises correctly; check that the evaluator does the same |
| **query-ee**, **regulator**, **cbftx**, **hebrew**, **gocbcrypto** | Go | Query, Search, encryption at rest | Plain Go as far as the public callers show |
| **backup**, **cbbs** | Go | `cbbackupmgr`, `cbimport`/`cbexport`, Backup service | IBM notes sample buckets cannot be loaded because `cbimport` is missing from their build; with the backup repository synced it will be built. Can be left out with `--without-backup` |
| **cbas**, **cbas-core** | Go, Java (Maven) | Analytics | Needs Maven Central. Risk is native Maven artifacts without an s390x variant. Can be left out with `--without-analytics` |

## How to work through it

**1. Scan before you build.** On any machine that has the Enterprise tree
synced (it does not have to be s390x):

    bash scripts/scan-portability.sh /path/to/couchbase > ee-portability-report.txt

The report lists, per private repository, Go files limited to amd64/arm64 and
whether an s390x-capable sibling exists, Go assembly, `#error` in architecture
checks, intrinsics, byte-order code, CMake architecture conditions, extra
`cbdep`/`DECLARE_DEP` requirements, native Maven artifacts and checked-in
binaries. On the public tree it flags exactly the places that needed the
fixes above. "NO obvious fallback" entries in section A and everything in
sections C1 and E are the ones most likely to stop a build.

**2. Build, and fix what stops.** Start the full build. When a component
fails, fix it in `<workspace>/couchbase/<project>`, save the fix under
`patch/local/` (see `patch/local/README.md`), and resume with
`--from build`. The usual shapes of a fix:

- *Go, architecture-limited files:* add a `_s390x.go` file or widen the build
  constraint of the generic one. `patch/indexing-s390x.diff` shows both a new
  file and a type fix.
- *C/C++, `#error` or missing branch:* add `defined(__s390x__)` next to the
  generic or arm64 branch when the code is architecture-neutral
  (`patch/forestdb-s390x.diff`); provide a portable implementation when it
  uses intrinsics (IBM's `patch/platform.diff` does this for CRC32C).
- *Byte order:* s390x is big-endian. tlm defines `WORDS_BIGENDIAN`; folly
  offers `folly::Endian`. Code that copies integers to disk or the network
  with `memcpy` needs explicit conversion if another architecture ever reads
  the data. Within an all-s390x cluster, formats that are merely
  host-endian are consistent.
- *Plain `char`:* unsigned on s390x (as on ARM), signed on x86.
- *CMake:* conditions on `x86_64`/`aarch64` need an s390x case; requests for
  prebuilt packages that do not exist for s390x need either a locally built
  package in `~/.cbdepscache` or a case in `scripts/cbdep-linux-s390x`.

**3. Narrow the build if you need a result sooner.** These are safe to leave
out, because tlm only adds them when their directory exists:

    --without-analytics      # cbas, cbas-core, cbas-ui, asterixdb, analytics-dcp-client
    --without-backup         # backup, cbbs

Other components are wired in unconditionally in an Enterprise build
(eventing-ee, goxdcr, and magma through the indexer), so leaving them out
needs matching build-file changes.

**4. Keep a baseline.** `--edition community` builds IBM's configuration with
this kit's fixes and needs no private access. It is a quick way to tell a
host or toolchain problem from an Enterprise porting problem.

## Known limitations inherited from IBM's recipe

These apply to the Community build as well and were left as they are, to stay
on the configuration IBM publishes:

- **CRC32C is computed in software, a byte at a time**, on s390x
  (`patch/platform.diff`). Correct, but slower than the hardware-accelerated
  paths on x86 and ARM; it is on the Data service's hot path.
- **No breakpad**, so no minidumps on crashes.
- **The bundled Python is 3.11** (Miniconda) although the package is named
  3.14.2 to satisfy the build.
- **V8 is built with IBM's options**, which differ slightly from Couchbase's
  (WebAssembly left enabled, ICU data in a separate file).
- **jemalloc** is built without Couchbase's `--with-lg-tcache-limit=15`.

## What a successful first build still leaves open

A build that completes and passes `scripts/smoke-test.sh` shows that the
services start and answer. It does not show that they are correct or fast
under load on a big-endian machine. Before relying on such a build, run
Couchbase's unit tests (`--tests`), and exercise rebalance, failover, XDCR to
and from another cluster, backup and restore, and index and bucket
persistence across restarts.
