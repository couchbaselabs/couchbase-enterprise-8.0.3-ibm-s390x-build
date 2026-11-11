# Local patches

The Enterprise-only repositories are private, so this kit cannot ship fixes
for them. When one of them needs a change to build or run on s390x, keep the
fix here and the `patch` stage will apply it on every build.

1. Make the change in the synced tree
   (`<workspace>/couchbase/<project>`), then save it:

       cd <workspace>/couchbase/magma
       git diff > <kit>/patch/local/magma-s390x.diff

2. List it in `patch/local/series` (create the file; `series.example` shows
   the format): one line per patch, the project directory relative to
   `<workspace>/couchbase`, then the patch file name.

       magma                                  magma-s390x.diff
       goproj/src/github.com/couchbase/plasma plasma-s390x.diff

3. Re-run from the patch stage:

       bash build_couchbase_ee.sh --from patch

Patches are applied with `git apply`, in the order listed, after the kit's
own patches. A patch that is already applied is skipped; one that no longer
applies stops the build.

**Do not commit these patches to a public repository.** They contain
Couchbase's proprietary source code. Everything in this directory except this
README and `series.example` is ignored by git for that reason.
