# Contributing to Observatory

Thanks for taking the time to contribute. This project follows the Studio51
shared conventions; they're identical across all our repos, so once you know
them you know them everywhere.

## Getting set up

See [docs/INSTALL.md](docs/INSTALL.md) for install, run, test, and lint
commands. Then enable the commit hook once per clone:

```
git config core.hooksPath .githooks
```

## Workflow

Maintainers commit straight to the integration branch, `develop` if the repo
has one, otherwise `main`, as described in [AGENTS.md](AGENTS.md). Outside
contributions arrive as pull requests:

1. Branch off the integration branch: `feature/…`, `fix/…`, or `chore/…`.
2. Make your change. Keep it atomic: one logical change per PR.
3. Add a line under **Unreleased** in [CHANGELOG.md](CHANGELOG.md) if the change
   is user-facing.
4. Make sure tests and lint pass, and that every commit is signed (verified)
   and has you as its only author.
5. Open a pull request against the integration branch with a clear
   description, filling in the PR template. It is merged with a merge commit,
   never squashed or rebased, so every commit has to stand on its own.

## Commit messages

We use [Conventional Commits](https://www.conventionalcommits.org/), with a
subject that names the change and a body that says why:

```
feat: add globe auto-rotate toggle
fix: correct beam arc easing at the poles
docs: document the data.js schema
chore(deps): bump the npm group with 3 updates
```

`.githooks/commit-msg` checks every message. It rejects `Co-authored-by`
trailers and AI attribution (every commit has exactly one author), `fixup!` /
`squash!` commits, and subjects that don't say anything (`fix: stuff`, `wip`).

## Code style

Formatting and linting are enforced by the configs in this repo (see
[docs/INSTALL.md](docs/INSTALL.md)). Run the formatter before pushing; don't
hand-format.

## Runtime support

Studio51 Solutions tracks the **latest stable runtimes and the latest secure
release of every dependency** (we stay within roughly two patch/minor releases
of upstream) and does not maintain older versions; we're a small team and
don't have the resources to guarantee backwards compatibility. Manifests name
dependencies without version constraints and the lockfile holds the exact
versions. If you need something older supported or held back, open an issue
justifying the why.

## Code of Conduct

By participating you agree to uphold our [Code of Conduct](CODE_OF_CONDUCT.md).

## Questions

Open a [discussion or issue](https://github.com/studio51/observatory/issues) or reach the team at vlad@studio51.solutions.
