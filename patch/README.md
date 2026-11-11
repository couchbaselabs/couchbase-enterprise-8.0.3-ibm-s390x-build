# Patches

Applied by `build_couchbase_ee.sh` (dependency patches in the `deps` stage,
source patches in the `patch` stage). Source patches are applied with
`git apply` and skipped when already present, so the stage can be re-run.

| File | Applied to | Origin | Purpose |
|---|---|---|---|
| `tlm-s390x.diff` | `tlm` | IBM's `tlm.diff`, modified | Use the system Go and the locally built rebar3 on s390x; no breakpad on s390x. Unlike IBM's version it does **not** remove goxdcr/xdcrDiffer from the build, and it disables breakpad inside `FindCouchbaseBreakpad.cmake` so that Enterprise-only projects that include that module (eventing) configure too. |
| `tlm-community-no-xdcr.diff` | `tlm` | this kit | Community edition only: leave goxdcr and xdcrDiffer out (goxdcr is a private repository). |
| `indexing-s390x.diff` | `goproj/src/github.com/couchbase/indexing` | this kit | (1) Kernel-version detection that compiles and works on s390x; replaces IBM's `thp_linux.go.diff`, whose pointer cast makes the indexer and projector panic at start-up. (2) Adds `linux_openblas_s390x.go`, the faiss/OpenBLAS binding the Enterprise indexer needs (upstream has only amd64 and arm64 variants). |
| `forestdb-s390x.diff` | `forestdb` | this kit | Adds s390x to the spin-lock initialiser. Same effect as the `sed` on line 272 in IBM's script, without depending on a line number. |
| `kv_engine.diff` | `kv_engine` | IBM, unmodified | Test fixes for big-endian / s390x allocation sizes. |
| `platform.diff` | `platform` | IBM, unmodified | Byte-at-a-time software CRC32C on s390x; test adjustments. |
| `flatbuffers.diff` | flatbuffers (dependency) | IBM, unmodified | |
| `folly.diff` | folly (dependency) | IBM, unmodified | |
| `v8.diff` | V8 (dependency) | IBM, unmodified | |
| `aws-c-cal.diff` | AWS SDK (dependency, RHEL 9 only) | IBM, unmodified | |

IBM's `Build.sh.patch` is not used: it pre-creates a placeholder XDCR audit
descriptor for builds without goxdcr, which a non-production build does not
need (the audit generator skips missing descriptors) and an Enterprise build
has the real one.

The exact upstream files are in `../upstream/linux-on-ibm-z-scripts/`.

## Your own patches

Fixes you make to the Couchbase sources while porting go in `local/`; see
[`local/README.md`](local/README.md).
