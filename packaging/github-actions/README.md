# GitHub Actions drafts

These workflows are inactive. GitHub runs workflows only from `.github/workflows/`, and this repository doesn't have one yet. Until then, `./scripts/check.sh` is the gate; see [development](../../docs/development.md#test).

| Draft | What it does |
| --- | --- |
| `ci.yml` | On pushes to `main` and pull requests: `swift build` and `./scripts/check.sh` on `macos-26` with Xcode 26.6 (Swift 6.3), with `.build` cached; the test job runs `./scripts/check.sh --no-lint`. A second job runs `./scripts/lint.sh` in a `swift:6.3` Linux container and fails the run on any finding. |
| `release.yml` | On `v*` tags: tests the tagged commit, runs `./scripts/release.sh` and attaches the archive and its SHA-256 to a draft release. It needs the secrets listed at the top of the file. |

To enable one, move it into `.github/workflows/`:

```sh
mkdir -p .github/workflows
git mv packaging/github-actions/ci.yml .github/workflows/ci.yml
```

macOS runners are slow and scarce, so `ci.yml` cancels superseded runs, only `main` saves the build cache, and formatting runs on Linux.
