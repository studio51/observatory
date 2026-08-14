# Contributing to Observatory

Thanks for taking the time to contribute. This project follows the Studio51
shared conventions; they're identical across all our repos, so once you know
them you know them everywhere.

## Getting set up

See the **Development** section of the [README](README.md) for install, run,
test, and lint commands.

## Workflow

Never commit to `main` directly; every change, however small, lands through a
pull request.

1. Create a branch off `main`: `feature/…`, `fix/…`, or `chore/…`.
2. Make your change. Keep it atomic: one logical change per PR.
3. Add a line under **Unreleased** in [CHANGELOG.md](CHANGELOG.md) if the change
   is user-facing.
4. Make sure tests and lint pass, and that your commits are verified (signed).
5. Open a pull request with a clear description. Fill in the PR template.

## Commit messages

We use [Conventional Commits](https://www.conventionalcommits.org/):

```
feat: add globe auto-rotate toggle
fix: correct beam arc easing at the poles
docs: document the data.js schema
chore: bump dependencies
```

## Code style

Formatting and linting are enforced by the configs in this repo (see the
**Development** section). Run the formatter before pushing; don't hand-format.

## Runtime support

Studio51 Solutions tracks the **latest stable runtimes only** (we stay within
roughly two patch/minor releases of upstream) and does not maintain older
versions — we're a small team and don't have the resources to guarantee
backwards compatibility. If you need an older runtime supported, open an issue
justifying the why, with a PR alongside it.

## Code of Conduct

By participating you agree to uphold our [Code of Conduct](CODE_OF_CONDUCT.md).

## Questions

Open a [discussion or issue](https://github.com/studio51/observatory/issues) or reach the team at vlad@studio51.solutions.
