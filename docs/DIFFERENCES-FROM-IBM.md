# Differences from IBM's recipe

This kit starts from IBM's build script for Couchbase 8.0.3 on Linux on IBM Z:

- repository: <https://github.com/linux-on-ibm-z/scripts>, directory
  `Couchbase/8.0.3/`, commit `da0867d01803bc8a5379dfbc8bd79d68cbdce940`
  (2026-11-05), Apache License 2.0, © IBM Corporation 2026;
- instructions: <https://github.com/linux-on-ibm-z/docs/wiki/Building-Couchbase>.
  When this kit was written the wiki page still described Couchbase 8.0.0;
  the scripts repository already carried the same recipe updated for 8.0.3,
  and that newer script is the base.

An unmodified copy of IBM's script and patches is in
`upstream/linux-on-ibm-z-scripts/`. To see for yourself how
`build_couchbase_ee.sh` relates to it:

    bash scripts/compare-with-ibm.sh --diff

That reports 43 of IBM's 56 functions carried over unchanged, 7 carried over
with the small edits listed in section 3, and 6 replaced by new code.

**How to read the "evidence" notes.** Nothing here was run on s390x hardware.
"Emulation" means cross-compiled for s390x and executed with QEMU's s390x
user-mode emulator. "Sources" means read in the public Couchbase 8.0.3
sources or in Couchbase's public build recipes
([build](https://github.com/couchbase/build),
[build-tools](https://github.com/couchbase/build-tools),
[build-manifests](https://github.com/couchbase/build-manifests),
[tlm](https://github.com/couchbase/tlm)).

## 1. What is built

| | IBM's script | This kit | Why |
|---|---|---|---|
| Edition | Community (private projects removed, XDCR removed, `BUILD_ENTERPRISE` off) | Enterprise by default; `--edition community` reproduces IBM's configuration | The purpose of the kit |
| Source selection | `repo init` of the release manifest, then comments out manifest lines 45, 52 and 86 (gocbcrypto, goxdcr, xdcrDiffer) with `sed` | `repo init -g default,enterprise,packaging` plus a generated local manifest (`.repo/local_manifests/s390x-kit.xml`) that removes `voltron` and `couchdbx-app`. Community: the default group, with the same three projects removed through the local manifest | The Enterprise projects are in the manifest's `enterprise` group, which a default sync skips. A local manifest does not depend on line numbers and leaves the release manifest untouched. Evidence: real `repo init` + `repo list`: 57 projects, all 14 private Enterprise repositories included |
| XDCR | `goxdcr` and `xdcrDiffer` commented out of `tlm/CMakeLists.txt` (in `tlm.diff`, then again with `sed` on lines 519-520) | Kept for Enterprise. The removal lives in a separate patch, `tlm-community-no-xdcr.diff`, applied only for Community | goxdcr is a private repository, so IBM had to drop it; an Enterprise build has it |
| `Build.sh.patch` | Applied: pre-creates a placeholder XDCR audit descriptor | Not used | The file it creates (`goproj/src/github.com/audit_descriptor.json`) is not read by anything in the tree, and kv_engine's audit generator already skips missing descriptors when `CB_PRODUCTION_BUILD` is off. Evidence: sources (`kv_engine/auditd/generator`) |
| Version | `-DPRODUCT_VERSION=8.0.3 -DBUILD_NUMBER=1000` | `-DPRODUCT_VERSION=8.0.3-9999` (`CB_BLD_NUM`) | tlm expects the build number inside `PRODUCT_VERSION` and has no `BUILD_NUMBER` option. 9999 is what Couchbase uses for from-source builds |
| Build type | Build.sh's default, `DebugOptimized` | `RelWithDebInfo` (`CB_BUILD_TYPE`) | What Couchbase ships. **If a public component that IBM's recipe builds fails to compile, retry with `CB_BUILD_TYPE=DebugOptimized`** to rule this difference out |
| CMake options | `-DCB_PRODUCTION_BUILD=OFF`, Erlang include path | The same, plus the options of Couchbase's own Linux build: `-DBUILD_ENTERPRISE=TRUE -DCB_DEVELOPER_BUILD=True -DCB_DOWNLOAD_DEPS=1 -DCB_DOWNLOAD_JAVA=True -DCB_INVOKE_MAVEN=True -DCB_UNITY_BUILD=OFF` | Analytics needs the JDK and Maven options. Unity builds are off in Couchbase's builds (`CB_UNITY_BUILD=ON` restores IBM's behaviour). Evidence: sources (`build/scripts/jenkins/couchbase_server/server-linux-build.sh`) |
| Targets and parallelism | `./Build.sh everything -j4` always | `./Build.sh -i <prefix> -j <N>`: the default `install` target, and `everything` only with `--tests`. `N` defaults to one job per CPU, at most one per 2 GB RAM | `everything` builds all test programs, which is a large part of the build time and only needed to run them. A fixed `-j4` wastes a large machine and can exhaust a small one |
| Install prefix | `-DCMAKE_INSTALL_PREFIX` appended to the CMake options when `-p` is given | Passed to Build.sh with `-i` | Build.sh sets `CMAKE_INSTALL_PREFIX` itself, before the extra options; `-i` is its own switch for this |

## 2. Fixes and additions

### Source patches

| Change | IBM's script | This kit | Evidence |
|---|---|---|---|
| Kernel-version detection in the indexer (`indexing/secondary/platform/thp_linux.go`) | `thp_linux.go.diff` / `sed`: `*(*[]int8)(unsafe.Pointer(&uts.Release))` | `indexing-s390x.diff`: `(*[len(uts.Release)]int8)(unsafe.Pointer(&uts.Release))[:]` | IBM's cast reinterprets the bytes of a `[65]uint8` array as a slice header, so the first use panics (`makeslice: cap out of range`). The indexer and the projector call this at start-up (`platform.disable_thp` defaults to true). Emulation: IBM's expression panics; the kit's returns the kernel release, and the patched package's test passes. Also builds for amd64, arm64 and ppc64le |
| faiss/OpenBLAS binding for the indexer (`indexing/secondary/vector/codebook`) | none (not compiled in a Community build) | `indexing-s390x.diff` adds `linux_openblas_s390x.go` | Upstream has only `_amd64` and `_arm64` variants, both `!community`, so an Enterprise build for s390x fails with undefined functions. Emulation: built with cgo against the kit's faiss and run |
| Breakpad | `#INCLUDE(FindCouchbaseBreakpad)` in the top-level `CMakeLists.txt` | `tlm-s390x.diff` makes `FindCouchbaseBreakpad.cmake` treat s390x as a platform without breakpad | eventing (Enterprise only) includes the module itself, and it stops CMake with "Google Breakpad not found" on a supported Linux platform. CMake test of the patched module: s390x gives `BREAKPAD_FOUND=False`, x86_64 is unchanged, the unpatched module fails |
| forestdb spin-lock initialiser | `sed -i '272s/aarch64/s390x/g'` (replaces the arm64 branch) | `forestdb-s390x.diff` adds `|| defined(__s390x__)` | Same effect on s390x; no line number; arm64 branch kept. Applies to the 8.0.3 revision |
| Other tlm changes (Go and rebar3 lookup, platform list, breakpad dependency removed) | `tlm.diff` | Same hunks, in `tlm-s390x.diff` | Unchanged |
| kv_engine, platform | `kv_engine.diff`, `platform.diff` | The same files | Unchanged |

### Dependencies

| Package | IBM's script | This kit | Why and evidence |
|---|---|---|---|
| faiss 1.11.0 | Upstream `facebookresearch/faiss` v1.11.0, static, no C API, against a default OpenBLAS build | Couchbase's fork (`blevesearch/faiss`, the commit of the official 1.11.0-6 package), shared libraries with the C API, OpenBLAS 0.3.28 (`couchbasedeps/OpenBLAS`, the official commit) linked in statically | An Enterprise build runs `FIND_PACKAGE(faiss CONFIG REQUIRED)`, installs `faiss` and `faiss_c`, and links `libfaiss_c` into the Index, Search and Query services; the Go binding (`blevesearch/go-faiss` v1.0.27) calls 57 C functions, at least a dozen of which exist only in the fork, and the indexer needs the two OpenBLAS thread functions exported from `libfaiss.so`. OpenBLAS is built for a generic z/Architecture baseline with z13/z14 kernels selected at run time, so the result does not depend on the build machine's model. Emulation: cross-built for s390x; the library exports all 57 functions the binding uses; a C API program builds and searches Flat and IVF indexes correctly |
| curl 8.21.0 | curl 8.9.1 built `--without-ssl`, packaged under the 8.21.0 name | `couchbasedeps/curl` at 8.21.0 with Couchbase's CA-bundle patch and launcher, against the OpenSSL and zlib built earlier (`CB_CURL_TLS=0` restores IBM's build, kept as `buildCurlNoTLS`) | The shipped libcurl is used by Eventing's `curl()` and by tools; without TLS it cannot reach `https://` URLs. Built after OpenSSL and zlib instead of before. Recipe run natively on x86_64: builds, has HTTPS, `RUNPATH` is `$ORIGIN/../lib`, package layout matches Couchbase's |
| cbpy (bundled Python) | Miniconda 3.11 with a subset of Couchbase's modules | The same, plus `pyzipper`, `requests-toolbelt`, `idna`, `pyOpenSSL` | `cbcollect_info` imports `pyzipper` unconditionally. Evidence: sources (`build-tools/cbdeps/cbpy/cb-dependencies.txt`) |
| `cbdep` | not needed by a Community build | `scripts/cbdep-linux-s390x` installed into the cbdeps cache as a stand-in | Couchbase publishes no s390x `cbdep`; the Enterprise build calls it to fetch the JDK for Analytics. The stand-in handles the JDK (Eclipse Temurin for s390x), the Analytics jars, Go, rebar3, Node.js, uv and locally cached packages, in the directory layout of the real tool. Download URLs for the s390x JDK, rebar3 and uv checked, and uv installed with it; the JDK path is first exercised by a real Enterprise build |
| All other packages | | The same recipes, unchanged | |

### Behaviour of the script

| Area | IBM's script | This kit | Why |
|---|---|---|---|
| Re-running | Each dependency is skipped when its source directory exists | A dependency is skipped only when its package is in `~/.cbdepscache` with a matching checksum **and** its build directory exists; otherwise leftovers are removed and it is rebuilt | With IBM's rule a build that was interrupted half-way is skipped for good on the next run and its package never reaches the cache. Tested with simulated builds |
| Stages | One pass | `preflight`, `prereqs`, `tools`, `deps`, `source`, `patch`, `build`, `test`, `package`, selectable with `--stages` / `--from` | Porting the Enterprise components means repeating the last stages many times |
| Environment file | Appends `export` lines to `~/.bash_profile` | Appends them to `<workspace>/.cb-s390x-kit/env.sh` | Leaves the login profile alone |
| OpenSSL environment | Writes `LD_LIBRARY_PATH`, `OPENSSL_ROOT_DIR`, `OPENSSL_CONF` for the freshly built OpenSSL into `~/.bash_profile` | Exports them only inside the server build stage | With IBM's approach every later login shell runs system tools against the custom OpenSSL |
| SSH | Builds and installs OpenSSH 10.1p1 into `/usr/local` on Ubuntu 22.04 and SLES 15 (the system `ssh` refuses to run with the custom OpenSSL on its library path) | Does not build OpenSSH. `git` is wrapped, and `GIT_SSH_COMMAND` set, so that git and ssh always run with the system libraries | An Enterprise build depends on SSH to GitHub working throughout; replacing the system's SSH client is a larger change than needed |
| git configuration | `sudo git config --system --add safe.directory '*'`; `git config --global user.*` if unset | A generated configuration file in the workspace (which includes the user's own), selected with `GIT_CONFIG_GLOBAL` for the build only | No system-wide or per-user git settings are changed. Tested: on a host with no git identity the sync still initialises without prompting |
| Private repositories | not used | `CB_GIT_AUTH=ssh` (default) or `https` with `GITHUB_TOKEN`; URL rewriting so the manifest and Go agree on the transport; `GOPRIVATE=github.com/couchbase`; access to the 14 repositories is checked before the long stages | xdcrDiffer requires goxdcr as a Go module, so Go itself must be able to fetch from a private repository during the build. The token is read from the environment when git asks and is not written to disk |
| Patches | Downloaded from IBM's repository `master` at build time | Shipped in `patch/`; source patches applied idempotently with `git apply` | Reproducible, and the patch stage can be re-run |
| Distribution check | Exact match of RHEL 8.10, 9.6, 9.8, SLES 15 SP7, Ubuntu 22.04, 24.04 | Same list; other minor releases of RHEL 8/9 and SLES 15 continue with a warning | A point release should not block an attempt |
| Workspace and logs | The current directory | `--workdir` (default `~/couchbase-s390x-build`), logs in `<workspace>/logs/` | |
| Certificate checks | `wget --no-check-certificate` for the Go and Node.js downloads | Flag removed | These are toolchains that run during the build |
| Extra packages | | `prereqs` also installs an SSH client, `file`, `xz` and `patch` | Needed for the private repositories and by the kit's scripts |

## 3. Edits inside IBM's functions

All of them (`scripts/compare-with-ibm.sh --diff` prints the same list):

| Function | Edit |
|---|---|
| `buildFbuf`, `buildFolly`, `buildV8`, `buildAWSSDK` | `wget $PATCH_URL/<file> -P $SOURCE_ROOT/patch` replaced by `fetchPatch <file>` (copy from the kit's `patch/` directory) |
| `installGo`, `buildPrometheus` | `--no-check-certificate` removed from one `wget` each |
| `buildCurl` | renamed `buildCurlNoTLS`; body unchanged |
| `runTest` | the `if TESTS` wrapper removed (the stage only runs when tests are requested) |

IBM functions that are not carried over: `buildCouchbase` (replaced by
`syncSource`, `patchSource` and `buildServer`), `buildFAISS` and
`buildOpenblas` (replaced by `buildFaissEE`), `buildSSH`, `main` and
`printHelp`.

## 4. Deliberately unchanged

The following are IBM's choices, kept so that the public part of the build
stays on the configuration IBM publishes. Some differ from what Couchbase does
for its own platforms.

- The distribution package lists and toolchain: GCC 13 (GCC 14 on SLES), Go 1.26.3 (to
  `/usr/local/go`), CMake 3.27.4 (built and installed to `/usr`), `repo` (to
  `/usr/bin`), rebar3 (to `/usr/local/bin`). The script still uses `sudo` and
  changes the build host; use a dedicated machine or the container.
- The recipes and versions of every dependency except faiss and curl.
- `installGo` does nothing when some `go` is already on the `PATH`, and the
  patched build then uses that Go whatever its version. `scripts/preflight.sh`
  warns about this.
- In `buildGrpc`, two workarounds meant for RHEL 9 are guarded by
  `[ $ID$VERSION_ID == "rhel9."* ]`, a test that never matches, so they are
  not applied there. Left as it is, because that is how IBM's script behaves
  today and it is the behaviour their RHEL 9 builds have had.
- CRC32C on s390x is computed in software, one byte at a time
  (`platform.diff`).
- No breakpad, so no minidumps.
- The bundled Python is 3.11 under the package name `cbpy 3.14.2`.
- V8 is built with IBM's options (WebAssembly enabled, ICU data in
  `bin/icudtb.dat`), and jemalloc without Couchbase's
  `--with-lg-tcache-limit=15`.
- `tlm-s390x.diff` points the build at `/usr/local/bin/rebar3` and at the Go
  found on the `PATH` unconditionally. That is fine for this kit, which only
  targets s390x, but the patch is not suitable for other platforms.
