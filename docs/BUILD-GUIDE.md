# Build guide

## 1. Prepare the build host

Any s390x system running one of the supported distributions works: an LPAR, a
z/VM or KVM guest, IBM Cloud or LinuxONE instances, or an s390x container on
such a host.

- **Distribution:** RHEL 8.10, RHEL 9.6/9.8, SLES 15 SP7, Ubuntu 22.04 or
  24.04. Other minor releases of RHEL 8/9 and SLES 15 are accepted with a
  warning.
- **Resources:** 16 GB RAM or more and about 100 GB of free disk in the
  workspace. V8's source and its two build trees alone take well over 10 GB,
  and its link steps need several GB of RAM each.
- **User:** a regular user with `sudo`. The build installs distribution
  packages and a few tools (CMake to `/usr`, Go to `/usr/local/go`, `repo` to
  `/usr/bin`, rebar3 to `/usr/local/bin`), exactly as IBM's script does. If
  `sudo` asks for a password it will ask again whenever its timeout expires
  during the build; raise `timestamp_timeout` with `visudo`, or use
  password-less sudo on a dedicated build machine.
- **Network:** outbound HTTPS to GitHub, go.dev, proxy.golang.org,
  packages.couchbase.com, chromium.googlesource.com, Maven Central and the
  other download sites `scripts/preflight.sh` lists.

Because the script changes system packages, use a machine or container that
is dedicated to the build.

## 2. Access to the private repositories

An Enterprise build syncs 14 private repositories from `github.com/couchbase`
(backup, bhive, cbas, cbas-core, cbbs, cbftx, eventing-ee, gocbcrypto, goxdcr,
hebrew, magma, plasma, query-ee, regulator), and Go fetches at least one
private module (goxdcr) during the build. The build host therefore needs
credentials for a GitHub account that can read them.

**SSH (default, `CB_GIT_AUTH=ssh`).** Make a key with access available to the
build user: forward your agent (`ssh -A buildhost`) or load a key on the host
(`eval "$(ssh-agent)"; ssh-add ~/.ssh/id_ed25519`). Keys with a passphrase
must be in an agent because the build cannot answer prompts. Test with:

    ssh -T git@github.com
    bash scripts/preflight.sh --only access

**HTTPS token (`CB_GIT_AUTH=https`).** Export a token that can read the
repositories and select HTTPS:

    export GITHUB_TOKEN=...          # do not put the token in build.conf
    CB_GIT_AUTH=https bash build_couchbase_ee.sh

The script does not write to `~/.gitconfig`. It generates its own git
configuration in the workspace (which includes yours) and points git at it for
the duration of the build. With SSH, all `github.com/couchbase` URLs are
routed over SSH; with HTTPS, the manifest's `ssh://` URLs are rewritten to
HTTPS and the token is handed to git from the environment when it asks.

## 3. Run the build

    bash build_couchbase_ee.sh [options]

With no options this builds the Enterprise Edition in
`~/couchbase-s390x-build` and installs it to
`~/couchbase-s390x-build/couchbase/install`.

Useful options (`--help` lists all; `build.conf.example` documents every
setting):

| Option | Effect |
|---|---|
| `--workdir DIR` | Put the workspace somewhere else (needs the disk space) |
| `--prefix /opt/couchbase` | Install prefix. Use this for a build you will package; the directory must exist and be writable by the build user |
| `--jobs N` | Parallel compile jobs for the server build (default: per CPU, capped at one per 2 GB RAM) |
| `--from STAGE` / `--stages a,b` | Resume or run selected stages |
| `--tests` | Also build the test programs and run `ctest` |
| `--package` | Also produce an installable tarball |
| `--without-analytics`, `--without-backup`, `--exclude "..."` | Leave components out |
| `--edition community` | Build IBM's Community configuration instead (no private access needed) |
| `--show-config` | Print the resolved settings and exit |

### Stages

| Stage | What it does | Rough duration |
|---|---|---|
| `preflight` | Checks architecture, distribution, memory, disk, download hosts | seconds |
| `prereqs` | Installs distribution packages (IBM's lists, plus an SSH client) | minutes |
| `tools` | Go 1.26.3, CMake 3.27.4, `repo` | minutes |
| `deps` | Builds ~40 third-party packages into `~/.cbdepscache` | hours (V8, gRPC, Erlang and Boost dominate) |
| `source` | `repo init` / `repo sync` of the 8.0.3 release manifest | minutes |
| `patch` | Applies the kit's patches and yours (`patch/local/series`) | seconds |
| `build` | CMake + Ninja build of the server, installed to the prefix | hours |
| `test` | `ctest` (only with `--tests`) | hours |
| `package` | Tarball + installer (only with `--package`) | minutes |

For an Enterprise build, read access to the private repositories is checked
as soon as `prereqs` has installed git, before the long stages start. The
check is skipped when a run contains neither `source` nor `build`, so you can
prepare a host while access is still being arranged:

    bash build_couchbase_ee.sh --stages preflight,prereqs,tools,deps

Every stage can be re-run. In `deps`, a dependency is skipped only when its
package is in the cache with a matching checksum and its build directory still
exists; a dependency whose build was interrupted is rebuilt from scratch.
Keep the workspace and `~/.cbdepscache` together: the server build links
against build directories in the workspace (OpenSSL in particular), not only
against the cached packages.

Logs go to `<workspace>/logs/`, one file per run, with every command traced
(set `CB_TRACE=0` for less).

### In a container

    bash docker/run-build.sh [same options]

builds an Ubuntu 24.04 image and runs the script in it, keeping the workspace,
the dependency cache and `/opt/couchbase` in host directories. It forwards
your ssh-agent (or `GITHUB_TOKEN` with `CB_GIT_AUTH=https`). Run it on an
s390x host. Setting `PLATFORM=linux/s390x` on another architecture uses QEMU
emulation, which is only practical for trying the early stages.

## 4. Check the result

    bash scripts/smoke-test.sh --prefix <prefix>

starts the server if necessary, initialises a single node **only if it has
never been set up**, and exercises Data, Query, Index and Search, plus
Analytics, Eventing, Backup and XDCR when the build contains them. It also
checks the pieces this kit changed relative to IBM's recipe and looks for
crashed services. On a node that is already initialised it needs
`--user`/`--password` and only adds two `smoke_*` buckets, which it removes
again.

To run Couchbase's own unit tests, build with `--tests`. IBM's wiki lists
tests that fail on s390x and x86_64 alike and one s390x-specific failure
(`ep-engine_ep_unit_tests.BloomFilterTest`); treat those as known.

## 5. Package and install elsewhere

A Couchbase install tree contains absolute paths, so build with the prefix you
will install to:

    sudo mkdir -p /opt/couchbase && sudo chown "$USER" /opt/couchbase
    bash build_couchbase_ee.sh --prefix /opt/couchbase --package

`<workspace>/packages/` then contains the tarball, its checksum and
`install-couchbase-server-s390x.sh`. Copy all three to the target host and
run the installer as root. It creates the `couchbase` user, unpacks to
`/opt/couchbase` and, where systemd is running, installs a service unit.

The target must run the same distribution release as the build host. The
binaries use that distribution's system libraries, including the runtime of
the compiler the `prereqs` stage installed (GCC 13, or GCC 14 on SLES; on
Ubuntu 22.04 it comes from the toolchain PPA), and the OpenMP runtime
(`libgomp`) that faiss needs. The installer lists any library the target does
not have.

This is not Couchbase's official RPM/DEB packaging, which lives in the private
`voltron` project and is left out of the sync by default. If you want to try
it, set `CB_WITH_VOLTRON=1` and build the `package-linux` target in
`<workspace>/couchbase/build` yourself; expect it to need changes for s390x.

## 6. When the build stops

The dependency stage and the public parts of the server are IBM's published
recipe. The private Enterprise components have no published s390x build, so
that is where a first build is most likely to stop.
[EE-PORTING-STATUS.md](EE-PORTING-STATUS.md) describes what to expect per
component and how to work through it. The short version:

1. Read the end of the log in `<workspace>/logs/`. Go and C++ compile errors
   name the file; CMake errors name the `CMakeLists.txt`.
2. Fix the source in `<workspace>/couchbase/<project>`.
3. Save the fix as a patch in `patch/local/` and list it in
   `patch/local/series` so it is re-applied on every build.
4. `bash build_couchbase_ee.sh --from build` (or `--from patch` after
   changing patches; add `--reconfigure` after changing CMake files or
   settings that affect configuration).

### Common problems

| Symptom | Cause and fix |
|---|---|
| `Preflight: cannot read: magma plasma ...` | The build host's GitHub credentials cannot read the private repositories. See section 2. |
| `repo sync` fails on a private project with `Permission denied (publickey)` | Same, during the sync. With an SSH key that has a passphrase, load it into an agent first. |
| `go: github.com/couchbase/...: reading ...: 404/410` or `could not read Username` during the build | A private Go module was requested without credentials. Keep `CB_GOPRIVATE=github.com/couchbase` and working git credentials for the whole build. |
| `Failed installing package X with cbdep` / `not handled by the s390x cbdep stand-in` | The build asked `cbdep` for a tool the stand-in does not know. Add a case to `scripts/cbdep-linux-s390x` (the error names the package and version). |
| `Error downloading https://packages.couchbase.com/.../<name>-linux-s390x-...` | tlm wants a prebuilt package that does not exist for s390x and that the `deps` stage did not build, usually a `DECLARE_DEP` inside a private component. Build it and put the `.tgz`/`.md5` in `~/.cbdepscache`, or remove the need for it. |
| `Google Breakpad not found` | `tlm-s390x.diff` is not applied; run the `patch` stage. |
| `build constraints exclude all Go files` / `undefined: ...` in a Go package | The package only has `_amd64.go`/`_arm64.go` variants. Add an s390x (or generic) file; `patch/indexing-s390x.diff` is an example. |
| `#error ... unsupported architecture` or missing intrinsics in C/C++ | Add an s390x/generic branch; `patch/forestdb-s390x.diff` and IBM's `platform.diff` are examples. |
| Linker or compiler killed, `c++: fatal error: Killed signal` | Out of memory. Lower `--jobs` and `CB_PARALLEL_LINK_JOBS`. |
| A compile error in a public component that IBM's recipe builds (kv_engine, platform, couchstore, ...) | This kit builds `RelWithDebInfo` with unity builds off, as Couchbase does; IBM's script uses Build.sh's defaults. To rule the difference out, set `CB_BUILD_TYPE=DebugOptimized` and `CB_UNITY_BUILD=ON` (in `build.conf` or the environment) and run `--from build --reconfigure`. |
| Analytics fails in Maven | Needs Maven Central. If a native artifact has no s390x build, try `--without-analytics` to get the rest built first. |
| OpenSSH: `OpenSSL version mismatch` | Something ran `ssh` with the build's OpenSSL on its library path. The kit prevents this for git; if you set `GIT_SSH_COMMAND` yourself, unset it. |
| CMake does not notice a changed setting | `--reconfigure`, or remove `<workspace>/couchbase/build`. |

### Starting over

- Server build only: remove `<workspace>/couchbase/build` and the install prefix.
- Sources: `cd <workspace>/couchbase && repo forall -c 'git reset --hard; git clean -fdx'`, then `--from source`.
- One dependency: delete its `.tgz` from `~/.cbdepscache` and run `--stages deps`.
- Everything: remove the workspace and `~/.cbdepscache`.
