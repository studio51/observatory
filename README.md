# Observatory

> Causal observability for Rails. Not "is it up?" — "what is consuming capacity,
> why, and what proves it?"

Observatory is a self-contained Rails engine. It currently lives in-tree at
`engines/observatory` inside games.directory and is loaded as a path gem; it
depends on nothing in that application, so extracting it is a directory move.

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
gem "observatory", path: "engines/observatory"
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

## Extracting this as a gem

The engine is already self-contained. To extract:

1. `git subtree split -P engines/observatory -b observatory` (history preserved).
2. Replace `inherit_from: ../../.rubocop.yml` in `.rubocop.yml` with the
   `inherit_gem` / `plugins` / `require` block from the host's config.
3. Decide the licence — `observatory.gemspec` currently inherits the host
   repository's proprietary terms, which is a deliberate placeholder.
4. Confirm the gem name is free on rubygems.org; if not, change `spec.name` (the
   `Observatory` namespace and `lib/observatory.rb` entry point stay as they are).
5. Point the host at it: `gem "observatory", github: "…"`.

Nothing else changes. `rails`, `view_component` and `activerecord` are the only
hard dependencies; Puma, Sidekiq, mysql2 and redis are each detected at boot and
instrumented through a guarded adapter, so the gem installs cleanly in an
application that uses none of them.

## Documentation

- `docs/observatory/architecture.md` — the audit, the design and the risk register
- `docs/observatory/runbook.md` — how to operate, disable and debug it
