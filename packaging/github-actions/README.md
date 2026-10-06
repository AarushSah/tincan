# Release workflow draft

`release.yml` is inactive: GitHub runs workflows only from `.github/workflows/`. On `v*` tags it would test the tagged commit, run `./scripts/release.sh`, and attach the archive and its SHA-256 to a draft release. It needs the secrets listed at the top of the file. To enable it, add those secrets and move it:

```sh
git mv packaging/github-actions/release.yml .github/workflows/release.yml
```

CI itself runs from [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml); see [development](../../docs/development.md#test).
