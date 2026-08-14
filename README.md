# Observatory

> Causal observability for Rails. Not "is it up?" — "what is consuming capacity,
> why, and what proves it?"

Observatory is a self-contained Rails engine. `rails` and `view_component` are
its only hard dependencies; Puma, Sidekiq, MySQL and Redis are each detected at
boot and instrumented through a guarded adapter, so it installs cleanly into an
application that uses none of them.

It was built in-tree at `engines/observatory` inside
[games.directory](https://games.directory) and extracted here with its history.

## The problem it exists to solve

Every infrastructure dashboard is green:

```
CPU: 40%      MySQL: idle      Redis: 7.6%      Puma: alive      Sidekiq: processing
```

And the site is down. Requests to one route are performing eighty-six thousand
ActiveRecord lookups each. Ninety-seven per cent of them are served by the
ActiveRecord query cache, so MySQL never sees them and stays idle. The time goes
into Ruby building queries, allocating objects and collecting garbage. Those
requests occupy every Puma thread. `/up` cannot get a thread, so the watchdog
concludes the process is dead and restarts a process that was merely full.

No component-level monitor can see this, because no component is unhealthy. What
is exhausted is *request capacity*, and what exhausted it is application code.

Observatory is built to say:

```
Puma request capacity exhausted

Primary contributor:  GET /steam/achievements/:id

Evidence:
- 6 concurrent requests, 14.4s median duration
- 59,349-86,359 ActiveRecord lookups per request
- 97.4% served from the ActiveRecord query cache
- 1.8-5.4s of estimated GC activity
- all request threads occupied
- MySQL remained mostly idle
- /up waited behind application traffic

Likely failure mode:  repeated ActiveRecord lookups inside a loop
Impact:               the watchdog restarted a living but saturated process
```

## Design rules

These are load-bearing, not aspirations:

1. **Never block the monitored request.** No I/O on the request path. Per-request
   work is arithmetic into a preallocated context plus one bounded-buffer push;
   the database write happens on a different thread.
2. **Bounded memory everywhere.** Query groups, fingerprinting, call-site capture
   and the event buffer all have ceilings. A pathological request has a *fixed*
   memory cost no matter how pathological it gets.
3. **Never instrument itself.** `Observatory::Instrumentation.suppress` wraps
   everything Observatory does on its own behalf; every subscriber returns
   immediately when suppressed.
4. **Fail open.** `Observatory::Safely` absorbs every exception, rate-limits the
   report and counts the failure. Monitoring cannot turn a working request into
   a 500.
5. **Never fabricate a measurement.** Where a number is an estimate it is named
   and labelled as one; where it is unmeasurable it is `nil` and rendered as
   "unknown", never as zero.

## Measured overhead

Ruby 4.0.5, YJIT on, coverage off (`COVERAGE=0 bin/rails test test/lib/observatory/performance`):

| Path | Measured | Budget |
| --- | --- | --- |
| Ordinary request (30 queries) | **0.102 ms** | < 1 ms |
| Per-query collection | **5.3 µs** | < 8 µs |
| The 86,359-query incident | **308 ms (2.14% of the request)** | < 5% |
| Request context open + close | **0.009 ms** | < 1 ms |
| Disabled subscriber, per query | **below measurement noise** | < 2 µs |

## Installation

```ruby
gem "studio51-observatory"
```

Mount it wherever your application puts operator tooling, behind whatever gate
that tooling already sits behind — Observatory ships no authentication of its
own, on purpose:

```ruby
# config/routes.rb
mount(Observatory::Engine, at: "/observatory", as: :observatory)
```

```ruby
# config/initializers/observatory.rb
Observatory.configure do |config|
  config.parent_controller = "Admin::ApplicationController"
end
```

```ruby
# config/initializers/observatory.rb
Observatory.configure do |config|
  config.enabled = true
  config.normal_request_sample_rate = 0.01
  config.slow_request_threshold     = 1.second
  config.high_query_count           = 1_000
  config.client_id_secret           = Rails.application.secret_key_base
end
```

Every knob can be overridden from the environment, and the override is applied
*after* the block so it always wins. The one to remember during an incident:

```sh
OBSERVATORY_ENABLED=0
```

## Usage from application code

```ruby
Observatory.current                     # the execution being measured, or nil
Observatory.annotate(:full_rebuild)     # flag it; survives sampling, shows in the explorer
Observatory.retain!                     # keep this trace regardless of sampling

Observatory::Instrumentation.suppress { … }   # do something uninstrumented
```

## What it collects

Per HTTP request and per Sidekiq job: duration; route template (never the literal
URL); total ActiveRecord lookups split into executed / cached / schema /
transaction; normalised query fingerprints with per-shape counts, timings and a
representative application call site; view, cache and outbound-HTTP time;
estimated allocations and GC; connection-pool gauges; thread-seconds of capacity
consumed; traffic classification and an anonymised client identifier; the active
release.

## Privacy

No raw IP addresses (HMAC with a rotating salt, and the mechanism disables itself
rather than pretend if no secret is configured). No bind values — literals are
replaced during fingerprinting, *before* anything is stored, so a value cannot
reach the database even by accident. No request or response bodies, no
authentication headers, no query strings, no URLs for outbound calls (host only —
this application puts API keys in Steam query strings and bearer tokens in PSN
headers). Route templates, not paths.

## Development

The suite runs against a dummy Rails application under `test/dummy`, on SQLite —
which also exercises the path a host without MySQL takes, since the MySQL probe
detects the adapter and disables itself.

```sh
bundle install
bundle exec rake          # the suite
bundle exec rake benchmark # the overhead budgets, which need a quiet machine
bundle exec rubocop
```

## Documentation

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — the audit, the design and the risk register
- [`docs/RUNBOOK.md`](docs/RUNBOOK.md) — how to operate, disable and debug it

## Licence

Apache-2.0 © Studio51 Solutions. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
