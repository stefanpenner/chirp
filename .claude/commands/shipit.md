Ship it: build, test, commit, push, wait for CI, and release.

## Steps

1. **Build all targets**: `bazel build //...`
   - If the build fails, stop and report. Do not proceed.

2. **Test all targets**: `bazel test //...`
   - If any test fails, stop and report. Do not proceed.

3. **Commit** (if there are uncommitted changes):
   - Stage relevant source and test files (not `.claude/settings.local.json`)
   - Run `bd sync` to sync beads, stage `.beads/issues.jsonl` if changed
   - Commit with a descriptive message
   - If no changes, skip this step.

4. **Push**: `git push`

5. **Wait for CI**: Find the CI run for the pushed commit via `gh run list`, then `gh run watch <id> --exit-status`.
   - If CI fails, stop and report. Do not proceed.

6. **Release**: Fetch tags (`git fetch --tags`), find the latest tag (`git tag --sort=-v:refname | head -1`), increment the patch number.
   - Tag: `git tag v<VERSION>`
   - Push tag: `git push origin v<VERSION>`
   - Report the version and link to the release workflow run.

## Notes
- The release workflow handles build, sign, notarize, GitHub release, appcast.xml update, and Homebrew tap update automatically.
- Tag format: `v<MAJOR>.<MINOR>.<PATCH>` (e.g., `v0.3.3`)
