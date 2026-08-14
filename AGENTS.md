# AGENTS.md: Observatory

Instructions for AI coding agents (Claude Code and friends) working in this repo.
Humans: this is also a fine quick-orientation read.

## Project

- **Name:** observatory · **Type:** library · **License:** Apache-2.0
- 

## Conventions (Studio51 standard)

- **Commits:** Conventional Commits, e.g. `feat:`, `fix:`, `docs:`, `chore:`, `refactor:`, `test:`.
  Commits must be verified (signed); `main` rejects unverified commits.
- **Branches:** `feature/…`, `fix/…`, `chore/…`. Never commit to `main`; open a
  PR for every change, however small.
- **Pull requests:** keep them atomic (one PR, one thing), give them a clear
  description of what changed and why, and add a `CHANGELOG.md` entry for any
  user-facing change.
- **Changelog:** add a line under **Unreleased** in `CHANGELOG.md` for any user-facing change.
- **Secrets:** never commit credentials, `.env`, or keys.
- **Authorship:** never set an AI tool as the git commit author or co-author,
  and never add an AI `Co-Authored-By` trailer.
- **Writing style:** never use em dashes; use a comma, or reword, instead.
- **Agent files:** this file is the single source of truth for every agent;
  `CLAUDE.md` / `CURSOR.md` / `CODEX.md` are pointers holding only
  agent-specific instructions. Shared guidance goes here.
- **README:** stays minimal — the **Navigation** section declares the
  Studio51 Solutions standard this repo adheres to and links the docs; all
  prose lives in `docs/`, each section in its own file.

### Comments & documentation

Comments are part of the standard — treat them as required, not optional.

- **Document every public method, class, module, and constant** with a comment
  block directly above it: a short sentence on what it is/does, then a description
  of **each parameter** and the **return value**.
- **Separate the prose from the parameter/return tags with one blank comment line**,
  and keep a blank comment line as the last line of a class/module doc block, right
  before the declaration it documents.
- **One sentence per line** — don't hard-wrap a single sentence across lines.
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
  alongside it. Never lower `.ruby-version`, the CI matrix, or
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
  gets a narrative doc block; every method gets prose plus YARD tags — a
  `@param` for each argument, a `@return`, and `@yieldparam` if it yields —
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
  call `foo(headers:)` when a local named `headers` is in scope — never
  `foo(headers: headers)`. Watch the shadowing trap: inside a method whose
  *parameter* has the same name as the reader you mean, shorthand resolves to
  the parameter — spell those call sites out explicitly.
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

- [ ] Tests pass
- [ ] Lint/format clean
- [ ] `CHANGELOG.md` updated (if user-facing)
- [ ] No secrets or large generated artifacts committed
- [ ] README still accurate for any behavior you changed
- [ ] Atomic, clearly described PR off `main`; commits verified (signed)
- [ ] No em dashes; no AI author or `Co-Authored-By` trailer
