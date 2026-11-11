# Changelog

## v0.1.0 (2026-11-11)

First release: a build kit for Couchbase Server 8.0.3 Enterprise Edition on
Linux on IBM Z (s390x), based on IBM's `Couchbase/8.0.3` build script
([linux-on-ibm-z/scripts](https://github.com/linux-on-ibm-z/scripts), commit
`da0867d`).

Not yet run on s390x hardware, and not yet built against Couchbase's private
repositories. The README lists what has and has not been verified.

- `build_couchbase_ee.sh`: staged, resumable build of the Enterprise source
  tree, or of IBM's Community configuration with `--edition community`.
- Dependency recipes an Enterprise build needs beyond IBM's: Couchbase's faiss
  fork with its C API and OpenBLAS, libcurl with TLS, extra modules in the
  bundled Python, and a stand-in for Couchbase's `cbdep` tool.
- Source patches: corrected kernel-version detection for the indexer (IBM's
  patch makes it panic at start-up), an s390x faiss binding for the Enterprise
  indexer, breakpad switched off for s390x inside the CMake module, and a
  pattern-based forestdb fix.
- Helper scripts: preflight checks, portability scan, smoke test, packaging,
  and a comparison with IBM's script; an Ubuntu 24.04 build container.
- Documentation: build guide, Enterprise porting status, and the differences
  from IBM's recipe.
