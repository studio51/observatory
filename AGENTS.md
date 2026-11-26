# AGENTS.md: Observatory

Instructions for AI coding agents (Claude Code and friends) working in this repo.
Humans: this is also a fine quick-orientation read.

## Project

- **Name:** observatory · **Type:** library · **License:** Apache-2.0
- 

## Conventions (Studio51 standard)

These apply to agents and humans alike. Where the **This repository** section
at the end of this file says otherwise, it wins.

### Where work lands

- **Commit straight to the integration branch:** `develop` if this repo has
  one, otherwise `main` (or `master`). No pull request and no pushed feature
  branch for our own work.
- **Local isolation is fine, leftovers are not.** A worktree or local branch
  may hold work in progress; merge it into the integration branch with
  `git merge` (never rebase or squash), push, and delete it.
- **Pull requests are for Dependabot, outside contributors, and releases.**
  They merge with a merge commit, never squash or rebase; the head branch is
  deleted on merge.

### Commits

- **One author, the repo owner, signed.** Commit with the owner's git identity
  and signing key exactly as configured. Never add a co-author of any kind: no
  `Co-authored-by:` trailer (AI or human), no "Generated with …" line, no
  `--author` override, no AI tool as author or committer. The same goes for
  pull request descriptions.
- **Signed and verified.** Never bypass signing (`--no-gpg-sign`,
  `-c commit.gpgsign=false`). If signing fails, stop and fix it, or ask.
- **Meaningful.** Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`,
  `refactor:`, `test:`, `perf:`, `build:`, `ci:`), the subject naming the
  change in the imperative (`fix(auth): refresh expired tokens before
  retrying`) and the body saying why. One logical change per commit, each
  leaving the build green. Never `wip`, `fix stuff` or `address review`, and
  no `fixup!` commits: history is never rewritten, so get the commit right
  before you make it.
- **Merge commits only.** Never squash, rebase, or force-push; bring in the
  remote with `git pull --no-rebase`.
- **Enforced:** `.githooks/commit-msg` checks every message (enable it once per
  clone with `git config core.hooksPath .githooks`), the branches reject
  unsigned commits, and CI re-checks every pushed commit.

### Everything else

- **Changelog:** add a line under **Unreleased** in `CHANGELOG.md` for any user-facing change.
- **Secrets:** never commit credentials, `.env`, or keys.
- **Dependencies:** always the latest secure release. Never pin or bound a
  version in `Gemfile`, a gemspec, `package.json`, `Package.swift` or
  `pyproject.toml`; the committed lockfile holds exact versions and Dependabot
  moves them.
- **Deployment:** apps deploy on Railway, configured by `railway.json` and
  environment variables; nothing persistent lives on the container's disk.
- **Cloudflare & R2:** Cloudflare runs the domain, CDN and storage. Persistent
  files go to this app's own R2 bucket, filed in a folder tree a person can
  browse (`<area>/<owner>/<record>/<role>-<suffix>.<ext>`), never flat random
  keys or catch-all folders: Studio51 mounts the buckets as a drive.
- **Writing style:** never use em dashes; use a comma, or reword, instead.
- **Agent files:** this file is the single source of truth for every agent;
  `CLAUDE.md` / `CURSOR.md` / `CODEX.md` are pointers holding only
  agent-specific instructions. Shared guidance goes here.
- **README:** stays minimal. The **Navigation** section declares the
  Studio51 Solutions standard this repo adheres to and links the docs; all
  prose lives in `docs/`, each section in its own file.

### Comments & documentation

Comments are part of the standard; treat them as required, not optional.

- **Document every public method, class, module, and constant** with a comment
  block directly above it: a short sentence on what it is/does, then a description
  of **each parameter** and the **return value**.
- **Separate the prose from the parameter/return tags with one blank comment line**,
  and keep a blank comment line as the last line of a class/module doc block, right
  before the declaration it documents.
- **One sentence per line**; don't hard-wrap a single sentence across lines.
- **Use inline trailing comments** for accessors, struct fields, and grouped
  constants (annotate the line) rather than a comment paragraph above each.
- **Group related members** under a short `# --- Section ---` divider comment.

See the stack section below for the exact doc-comment syntax in this repo's language.

## Stack: Ruby gem / library

- Install: `bundle install`. The development Ruby is pinned in `.ruby-version` /
  `.tool-versions`; the gem's supported range lives in the `*.gemspec`
  (`required_ruby_version`).
- **Ruby version policy:** Studio51 Solutions does not maintain older Rubies.
  Every repo pins the latest stable Ruby and we aim to stay within two
  patch/minor releases of upstream at all times. We are a small team and don't
  have the resources to guarantee backwards compatibility; anyone who needs an
  older Ruby supported must open an issue justifying the why, with a PR
  alongside it. Never lower `.ruby-version` (CI reads it) or
  `required_ruby_version` without that issue.
- Tests: `bundle exec rake` (RSpec or Minitest, per the repo).
- Lint: `bundle exec rubocop` (`-A` to auto-correct).
- **Public API lives in `lib/`.** Keep a thin top-level entrypoint
  (`lib/<gem>.rb`) that requires the rest; everything else under `lib/<gem>/`.
- **`Gemfile.lock` is not committed** for a library; let consumers resolve their
  own versions. (It's only committed for applications.)
- **Releasing:** bump `version.rb`, add a dated `CHANGELOG.md` entry, then
  `bundle exec rake release`. Never hand-edit built `.gem` artifacts.

### Ruby style

The code should read as if the whole portfolio were written by a single
developer. Lint is the source of truth: `bundle exec rubocop` (omakase + the
`rubocop-studio51` house cops) must be clean.

- **Comments are many, and they are part of the standard.** Every class/module
  gets a narrative doc block; every method gets prose plus YARD tags: a
  `@param` for each argument, a `@return`, and `@yieldparam` if it yields,
  including `initialize`.
- **Comment-block shape** (`Studio51/CommentBlockTermination`): separate prose
  from `@` tag lines with one bare `#`; when a block ends in prose right above
  code, terminate it with a bare `#`; when it ends with a tag, no terminator.
- **Let methods breathe** (`Studio51/EmptyLineBeforeTrailingExpression` +
  `Layout/EmptyLineAfterGuardClause`): guard clauses group at the top with an
  empty line after the group; a multi-statement body puts an empty line before
  its final expression. Parallel setup (an `initialize` of assignments) stays
  tight.
- **Interpolations breathe** (`Layout/SpaceInsideStringInterpolation: space`):
  `"#{ value }"`, never `"#{value}"`.
- **Blank line after a namespace `module` / `class << self` opening** (RuboCop's
  `Layout/EmptyLinesAround{Module,Class}Body` are disabled in `.rubocop.yml` for this).
- **Trailing inline comments on `attr_*` and grouped constants**, not a paragraph above.
- **Hash-value shorthand (Ruby ≥ 3.1, `Style/HashSyntax` shorthand `always`):**
  call `foo(headers:)` when a local named `headers` is in scope, never
  `foo(headers: headers)`. Watch the shadowing trap: inside a method whose
  *parameter* has the same name as the reader you mean, shorthand resolves to
  the parameter; spell those call sites out explicitly.
- **`.freeze` string-literal constants** (`SERVICE = "authapi.v1.API".freeze`).
- **Redact secrets in `inspect`.** Any object holding credentials (tokens,
  passwords, keys) overrides `#inspect` so consoles, logs, and error reporters
  print `[REDACTED]`, never the live value. The same goes for logging hooks:
  redact credential-bearing request fields before they reach a logger.

### API client gems

- **Capture real responses.** Exercise every read-only endpoint against the
  live API and commit redacted example payloads (`docs/examples/`) plus an
  inferred per-endpoint schema (`docs/SCHEMA.md`). Generated clients are not
  exempt: examples prove the wire shape and are the contract for tests.
- **Flag the unverified.** Anything reverse-engineered or guessed (field names,
  request bodies) is marked as such in the doc comment *and* the user docs, with
  the tool or procedure that can confirm it.

```ruby
# frozen_string_literal: true

module Acme
  module Widgets

    # A single widget binding.
    #
    # @return [Client] the new client
    class Client
      attr_reader :config # parsed configuration

      # @param config [Configuration] the configuration
      # @return [Client] the new client
      def initialize(config:)
        @config = config
      end

      # Fetch a widget by id.
      #
      # @param id [String] the widget id
      # @param headers [Hash] extra request headers
      # @return [Hash] the widget
      def fetch(id, headers: {})
        return cached(id) if cached?(id)

        response = transport.get("/widgets/#{ id }", headers:)

        parse(response)
      end
    end
  end
end
```

## Before you finish

Work is not finished until it leaves nothing behind.

- [ ] Tests pass; lint/format clean
- [ ] `CHANGELOG.md` updated (if user-facing)
- [ ] No secrets or large generated artifacts committed
- [ ] README and `docs/` still accurate for any behaviour you changed
- [ ] Every commit signed by the owner, Conventional and meaningful, with no co-author or AI attribution
- [ ] Everything pushed to the integration branch
- [ ] Every worktree you created removed, every local branch you created deleted
- [ ] `git status` clean and level with the remote
- [ ] No em dashes

## This repository

<!-- REPO_SECTION: kept as-is by `npx @studio51/create update`. State here
anything this repo does differently from the conventions above, such as a
different target branch or a release step, plus anything else specific to it. -->

Nothing differs from the Studio51 standard.

<!-- /REPO_SECTION -->
