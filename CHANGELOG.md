# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Extracted from games.directory, where the engine was developed in-tree at
  `engines/observatory`. History is preserved: the commits below this line are
  the ones that built it.
- Apache-2.0 licence, replacing the placeholder terms inherited from the host
  repository.
- A dummy Rails application under `test/dummy`, so the suite exercises a real
  engine boot — middleware insertion, subscriber installation, migrations,
  routes and the dashboard — instead of a hand-assembled approximation. It runs
  on SQLite, which also covers the path a host without MySQL takes.
- `config.back_link_path` and `config.back_link_label`, for the one link on the
  dashboard that points out of the engine. Accepts a path or a callable, and
  renders nothing when unset.

### Fixed

Every entry here is a way the engine was quietly depending on its first host.
None could be seen while it lived in-tree; all were found by booting it against
a Rails application that was not games.directory.

- `Incident.by_severity` ordered with MySQL's `FIELD()`, which exists on no other
  adapter — the dashboard raised on PostgreSQL and SQLite. Now a `CASE` derived
  from `SEVERITY_ORDER`, so the Ruby and SQL orderings cannot drift.
- `RequestTrace#concurrent_requests_in_process` used `DATE_ADD(… INTERVAL …
  MICROSECOND)`. Adding a duration column to a timestamp column is the one piece
  of arithmetic the three adapters genuinely spell differently, so it is now the
  gem's only dialect switch.
- `slim` and `turbo-rails` were used by the dashboard but declared by neither the
  gemspec nor a `require`. A host without them got `MissingExactTemplate` on
  every page, and `undefined method 'turbo_frame_tag'` on the request explorer.
- `view_component` was declared as a hard dependency and never used — the engine
  has no components. Removed.
- The layout linked to `main_app.admin_root_path`, a route only games.directory
  has, behind a `respond_to?(:main_app)` guard that is always true in an engine.
  Replaced with the configurable back link above.
- `Probes::Sidekiq.available?` tests for `Sidekiq::Stats`, which `require
  "sidekiq"` does not load. In a host that had not required `sidekiq/api`
  itself, the queue probe reported unavailable and the queue rules silently
  never ran.

## [0.1.0]

### Added

- Request and query instrumentation, with ActiveRecord lookups split into
  executed / cached / schema / transaction and normalised into query
  fingerprints carrying a representative application call site.
- Persistence, minute and daily rollups, dependency probes and retention.
- A deterministic incident analysis engine: thirteen rules that name the
  constrained resource, the workload consuming it, and the evidence both for
  and against that conclusion.
- Sidekiq job tracing, health-check correlation, watchdog event capture and
  deployment markers.
- The dashboard: incidents, requests, jobs and routes.
- Demonstration scenarios, the sweep job and an operator runbook.

[Unreleased]: https://github.com/studio51/observatory/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/studio51/observatory/releases/tag/v0.1.0
