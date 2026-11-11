![Couchbase Labs](docs/images/couchbase-labs.png)

# Couchbase Server 8.0.3 Enterprise Edition for Linux on IBM Z (s390x)

> **Note:** Couchbase Labs projects are prototypes. They are not part of the Couchbase product line and are not covered by Couchbase Support unless stated otherwise in the individual repository.

Version 0.1.0 ([changelog](CHANGELOG.md))

A build kit that produces Couchbase Server 8.0.3 **Enterprise Edition** from
source on s390x. It is based on IBM's published recipe for building Couchbase
on Linux on IBM Z ([wiki](https://github.com/linux-on-ibm-z/docs/wiki/Building-Couchbase),
[scripts](https://github.com/linux-on-ibm-z/scripts/tree/master/Couchbase/8.0.3)),
which builds the Community Edition without XDCR, and extends it to the
Enterprise source tree. (The wiki page describes 8.0.0; IBM's scripts
repository has the same recipe updated for 8.0.3, which is the version used
here.)

> **Status: not yet run on s390x hardware.**
> The kit was written and checked without an s390x machine and without access
> to Couchbase's private repositories. What has and has not been verified is
> listed below and in [docs/EE-PORTING-STATUS.md](docs/EE-PORTING-STATUS.md).
> Expect the first build to stop inside one of the private Enterprise
> components; the kit is set up to make that loop (find, fix, resume) short.
>
> Binaries built with it are unofficial: Couchbase does not ship or support
> Couchbase Server on s390x.

## What you need

| | |
|---|---|
| Build host | s390x (LPAR, z/VM or KVM guest, or an s390x container) running RHEL 8.10, RHEL 9.6/9.8, SLES 15 SP7, Ubuntu 22.04 or Ubuntu 24.04, the distributions IBM's 8.0.3 script supports |
| Resources | 16 GB RAM or more, about 100 GB free disk, as many CPUs as you can get; the build takes several hours |
| Access | A regular user with `sudo`; outbound HTTPS; **read access to Couchbase's private GitHub repositories** from the build host (SSH key or token) |

## Quick start

Copy this directory to the s390x host (or clone the repository you keep it
in), then:

```bash
cd couchbase-enterprise-8.0.3-ibm-s390x-build

# 1. Check the machine and your access to the private repositories
bash scripts/preflight.sh

# 2. Build (prerequisites, ~40 third-party dependencies, source sync, patches, server)
bash build_couchbase_ee.sh

# 3. Check the result
bash scripts/smoke-test.sh --prefix ~/couchbase-s390x-build/couchbase/install
```

To build inside a container instead: `bash docker/run-build.sh`.
For a build you can install on other machines:
`bash build_couchbase_ee.sh --prefix /opt/couchbase --package`.

The build is staged and resumable. After fixing a problem, continue from the
stage that failed, for example `bash build_couchbase_ee.sh --from build`.
Details, options and troubleshooting: [docs/BUILD-GUIDE.md](docs/BUILD-GUIDE.md).

## What is different from IBM's recipe

IBM's script syncs only the public repositories, removes XDCR and builds what
is effectively the Community Edition. This kit:

- syncs the full Enterprise tree (the manifest's `enterprise` group and the
  private repositories) and configures with `BUILD_ENTERPRISE=TRUE` and the
  options Couchbase's own Linux build uses;
- builds the dependencies an Enterprise build actually links against the way
  Couchbase does: **faiss** from Couchbase's fork with its C API and OpenBLAS,
  and **libcurl with TLS**;
- supplies a stand-in for Couchbase's `cbdep` tool, which has no s390x build
  and which the Enterprise build uses to fetch the JDK for Analytics;
- fixes problems found in the public sources while preparing this: IBM's
  kernel-version patch makes the Index service crash at start-up; the
  Enterprise indexer has no faiss binding for s390x; Eventing's build needs
  breakpad switched off for s390x; `cbcollect_info` cannot start with IBM's
  Python environment;
- makes the long dependency stage safe to interrupt and re-run, and keeps its
  environment changes out of `~/.bash_profile`, `~/.gitconfig` and the system
  OpenSSH.

Every change, with the reason and the evidence for it, is in
[docs/DIFFERENCES-FROM-IBM.md](docs/DIFFERENCES-FROM-IBM.md). The dependency
recipes that did not need to change are IBM's, unmodified.

## What has been verified

Without an s390x machine, checks were done by cross-compiling to s390x and
running the results under QEMU's s390x user-mode emulation, and by running
the kit's own logic against the real 8.0.3 sources:

| Checked | How |
|---|---|
| All patches apply to the 8.0.3 revisions | Real `repo sync` of the release manifest, then the kit's patch stage, twice (second run is a no-op) |
| Every package tlm expects on s390x is built under the right name | Compared the script's package list with `tlm/deps/manifest.cmake` |
| Enterprise sync selects the right projects | `repo init` with the kit's groups and local manifest: 57 projects, every Enterprise project in, the internal packaging project (voltron) out |
| faiss + OpenBLAS recipe | Cross-built for s390x from the pinned sources; exports every C function the Go binding calls; C API index build and search run correctly under emulation |
| Indexer faiss binding for s390x | Built with cgo for s390x against that faiss and run under emulation |
| Kernel-version fix | Patched package built for s390x/amd64/arm64/ppc64le; passes under emulation, where IBM's version panics |
| Breakpad handling | CMake unit test of the patched module for s390x and x86_64 |
| TLS curl recipe | Run natively (x86_64): patch, configure, build, package |
| `cbdep` stand-in | Download URLs for s390x Temurin JDK, rebar3 and uv exist; installed layout matches the real tool |
| Build script logic | shellcheck; stage selection, resume after a failed dependency, the Enterprise access check and the call into Couchbase's `Build.sh`, all run with simulated builds; source sync on a host with no git identity |
| `smoke-test.sh`, `package.sh` | Run against a mock node (stub binaries and REST endpoints) and a mock install tree, not against a real server |

**Not verified:** anything that needs the private sources or real hardware:
whether magma, plasma, goxdcr, eventing-ee, query-ee, bhive, the backup tools
and Analytics compile and run on s390x, and the full build end to end.
[docs/EE-PORTING-STATUS.md](docs/EE-PORTING-STATUS.md) goes through these
component by component, and `scripts/scan-portability.sh` reports the
architecture-specific code in a synced Enterprise tree so the likely problems
can be found before the build reaches them.

## Layout

```
build_couchbase_ee.sh      the build (modified version of IBM's build_couchbase.sh)
build.conf.example         every setting, with defaults
patch/                     source and dependency patches; patch/local/ for your own
scripts/preflight.sh       host and repository-access checks
scripts/cbdep-linux-s390x  stand-in for Couchbase's cbdep tool
scripts/compare-with-ibm.sh  shows how the build script differs from IBM's
scripts/scan-portability.sh  finds architecture-specific code in a source tree
scripts/smoke-test.sh      functional check of a finished build
scripts/package.sh         tarball + installer for other hosts
docker/                    container image and wrapper for the build
docs/                      build guide, porting status, differences from IBM
CHANGELOG.md, VERSION      release notes and the kit's version
upstream/                  IBM's original script and patches, unmodified
```

## Licensing

`build_couchbase_ee.sh` and several patches are derived from IBM's
Apache-2.0-licensed scripts; see [NOTICE](NOTICE). Couchbase Server Enterprise
Edition itself is proprietary: this repository contains none of its source,
and patches you write against the private repositories must stay out of any
public copy of this repository (`patch/local/` is git-ignored for that reason).
