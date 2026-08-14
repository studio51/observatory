# Observatory — production runbook

> How to operate, disable and debug the monitoring system. Written for someone
> reading it at three in the morning.

---

## 1. Turn it off

```sh
# On the production box, then restart the affected service.
export OBSERVATORY_ENABLED=0
```

Every subscriber, middleware and probe checks this on entry, so the application
returns to exactly its pre-Observatory behaviour. Nothing else needs changing and
no data is lost — what has already been written stays written.

Less drastic options, in increasing order of how much they leave working:

| Variable | Effect |
| --- | --- |
| `OBSERVATORY_ENABLED=0` | Complete off switch. Nothing is collected. |
| `OBSERVATORY_PERSIST=0` | Collects and logs, writes nothing to the database. |
| `OBSERVATORY_ANALYSIS_ENABLED=0` | Stops the detection rules; collection continues. |
| `OBSERVATORY_CAPTURE_QUERY_CALL_SITES=0` | Stops backtrace capture, the most expensive single operation. |
| `OBSERVATORY_NORMAL_REQUEST_SAMPLE_RATE=0` | Keeps only anomalies; drops the ordinary 1%. |

From a console, for one process only:

```ruby
Observatory.config.enabled = false
```

**If in doubt during an incident, turn it off.** Observatory is a diagnostic aid.
It is never worth an outage, and the data it has already collected is still there
when it comes back.

---

## 2. Is Observatory itself healthy?

```sh
bin/rails observatory:health
```

or the **Observatory itself** panel at the bottom of the dashboard. The number
that matters is `dropped`:

- **`dropped: 0`** — everything collected has been written.
- **`dropped > 0`** — the buffer filled and events were discarded, so the figures
  on the dashboard are incomplete. Under pressure the buffer drops ordinary
  requests first and keeps errors, health-check failures and saturation events,
  so a non-zero drop count during an incident usually means the *incident* data
  survived and the background traffic did not. Raise `buffer_capacity` or lower
  the sample rate if it happens routinely.

`failures` counts exceptions Observatory swallowed. Non-zero means something is
broken *inside* the monitoring; the details are in `log/observatory.log`, rate
limited to one report per minute per call site.

---

## 3. Diagnose without the dashboard

Everything retained is also one JSON line in `log/observatory.log`. During an
incident this is often faster than a browser, and it works when the browser
cannot get a Puma thread.

```sh
# Requests that performed more than ten thousand lookups.
jq 'select(.query_count > 10000)' log/observatory.log

# The worst offenders, ranked.
jq -c 'select(.event=="request") | {route, duration_ms, query_count, cached_query_ratio}' \
  log/observatory.log | sort -t: -k3 -rn | head

# Everything one crawler did.
jq 'select(.client_id == "a1b2c3d4e5f6a7b8")' log/observatory.log

# Where the repeated query came from.
jq -r 'select(.query_groups) | .query_groups[] | select(.count > 1000) | .call_site' \
  log/observatory.log | sort | uniq -c | sort -rn
```

From a console:

```ruby
# What are the rules saying right now?
puts Observatory::Analysis::Engine.evaluate.map(&:to_text).join("\n\n")

# What is holding threads at this instant, in this process?
Observatory::Capacity.in_flight.map { |r| [r.endpoint, r.query_count] }

# Why is the watchdog about to restart this?
Observatory::Watchdog.classify
```

---

## 4. The incident this was built for

**Symptom.** `/up` fails, the watchdog restarts Puma, everything recovers, and it
happens again ninety seconds later. CPU, MySQL and Redis all look fine.

**What to check, in order:**

1. **Dashboard → the panel at the top.** If it names *request threads* as the
   constrained resource, the process was full, not dead.
2. **The contradicting evidence on that finding.** "MySQL connections 54 of
   10,000", "Redis utilisation 7.6%", "no connection checkout wait". These are
   telling you where *not* to look.
3. **The primary contributor.** A route template. Open it.
4. **Route detail → query shapes → call site.** The line of application code
   inside the loop.

**What not to do:** add Puma threads. More threads on the same workload buys
seconds. The requests are not waiting on anything — they are executing Ruby — so
extra threads simply fill too, and each one adds GC pressure to a process already
struggling with it.

---

## 5. Watchdog advisory mode

`bin/dev`'s watchdog restarts Puma after three consecutive failed `/up` probes.
It cannot distinguish a dead master from one whose fifteen request threads are
all occupied.

Observatory records what it would have decided instead, and **changes nothing**:

```sh
# In log/deploy.log, beside every recycle:
WATCHDOG: [web] observatory: {"classification":"thread_saturation",
  "recommended_action":"capture_saturation_evidence","confidence":"high",
  "reason":"The process is alive and every request thread is occupied…"}
```

Turn the advisory off with `OBSERVATORY_ADVISORY=0`. It is backgrounded and
cannot delay a recycle, and `bin/observatory-watchdog` always exits 0.

**Before ever letting this change restart behaviour**, check the disagreement
record:

```ruby
Observatory::WatchdogEvent.misclassified.count   # restarts of living, saturated processes
Observatory::WatchdogEvent.recent_first.limit(20).map { |e| [e.trigger, e.action_taken, e.recommended_action] }
```

The failure mode of trusting it too early is refusing to restart a genuinely dead
process, which is worse than the problem it fixes. Wait for a body of real
incidents where the classification was right.

---

## 6. Storage and retention

Retention runs from a scheduled job. Run it by hand with:

```sh
bin/rails observatory:sweep
```

| Data | Kept for | Configure with |
| --- | --- | --- |
| Ordinary traces | 24 hours | `raw_trace_retention` |
| Anomalous traces | 14 days | `anomalous_trace_retention` |
| Error traces | 30 days | `error_trace_retention` |
| Query groups | 30 days | follows error retention |
| Minute rollups | 90 days | `rollup_retention` |
| Daily rollups | 1 year | `daily_rollup_retention` |
| Process/dependency samples | 14 days | `sample_retention` |
| Incidents | forever | `incident_retention` (nil) |

Expected steady state is **15–25 GB**. Check with:

```sql
SELECT table_name, ROUND(((data_length + index_length) / 1024 / 1024), 0) AS mb
FROM information_schema.TABLES
WHERE table_schema = DATABASE() AND table_name LIKE 'observatory_%'
ORDER BY mb DESC;
```

If it grows beyond that, in order of effectiveness: lower
`normal_request_sample_rate`, shorten `anomalous_trace_retention`, then
`rollup_retention`. `observatory_query_groups` is the largest table by a wide
margin and the first place to look.

**Moving it off the primary database.** Add an `observatory` entry to
`config/database.yml` for the environment; `Observatory::Record` picks it up
automatically at boot and no model changes are needed.

---

## 7. Development

```sh
bin/rails observatory:demo:incident   # stage the full incident and print the findings
bin/rails observatory:demo:list       # every available scenario
bin/rails observatory:demo:run[slow_sql]
bin/rails observatory:demo:clear      # remove only the demo's rows
bin/rails observatory:analyse         # run the rules now and print what they found
```

Development collects everything (`normal_request_sample_rate = 1.0`) but
**never persists**, because `config/database.yml` frequently points development
at the production host over an SSH tunnel. Traces go to `log/observatory.log`
only.

Demo scenarios raise unless `demo_enabled` is true, which only development sets.
Fabricated monitoring rows in an environment where someone might act on them
would destroy the property this system depends on: that every row describes
something that really happened.

---

## 8. Known limitations, stated plainly

These are measurement limits, not bugs, and the UI labels each one where it
appears.

**Allocation and GC figures are estimates.** CRuby has no per-thread allocation
counter, so a request's figures are process-wide deltas shared with up to four
concurrent request threads. Useful for spotting an order-of-magnitude change;
useless for attributing a precise number. Fields are named `estimated_*` and the
request page shows the concurrency that contaminated them.

**Request queue wait is unavailable.** `kamal-proxy` does not send
`X-Request-Start`. It reads as "unknown", never zero. Setting that header
upstream makes it start working with no code change.

**Puma backlog may be unmeasurable.** With `preload_app!` and no control socket,
the capacity adapter falls back to Observatory's own in-flight register, which
knows busy threads exactly but cannot see the queue. It reports `nil`, rendered
as "not measurable" — and never as zero, because zero and unknown lead to
opposite conclusions about saturation.

**Cross-worker capacity is an aggregate of independent samples**, not a
synchronised snapshot. The dashboard says how many workers reported. A worker
that stops reporting shows as stale rather than idle: a saturated worker that
cannot schedule its sampler thread is itself a signal.

**Per-queue Sidekiq throughput is apportioned**, not measured. Sidekiq reports
completions globally, so per-queue rates are shares of the total weighted by
backlog.

**Reading Puma's stats resets its `backlog_max`.** Observatory must remain the
only caller. Nothing else in this application calls it today; if something starts
to, both will see wrong numbers.

---

## 9. Overhead

Measured on Ruby 4.0.5 with YJIT, coverage off:

| Path | Measured | Budget |
| --- | --- | --- |
| Ordinary request (30 queries) | 0.102 ms | < 1 ms |
| Per-query collection | 5.3 µs | < 8 µs |
| The 86,359-query incident | 308 ms — 2.14% of the request | < 5% |
| Request context open + close | 0.009 ms | < 1 ms |
| Disabled subscriber, per query | below measurement noise | < 2 µs |

Re-measure after any change to the collection path:

```sh
COVERAGE=0 bin/rails test test/lib/observatory/performance
```

The benchmarks refuse to run under `SimpleCov` — line coverage inflates them
two- to threefold, and a budget asserted against an instrumented number is
measuring SimpleCov rather than Observatory.

---

## 10. If Observatory is the problem

Symptoms, and what they mean:

| Symptom | Cause | Fix |
| --- | --- | --- |
| Memory climbing in Puma workers | Buffer full and not draining — writer thread dead | `Observatory::Pipeline::Writer.stats`; `OBSERVATORY_PERSIST=0` |
| Request latency up after deploying it | Call-site capture, or the sample rate | `OBSERVATORY_CAPTURE_QUERY_CALL_SITES=0` |
| `observatory_query_groups` growing fast | Sample rate too high for the traffic | Lower `normal_request_sample_rate` |
| Dashboard slow to load | Window too wide over unswept data | Use a shorter period; run `observatory:sweep` |
| Monitoring queries in application traces | A suppression gap | Report it — this is a bug, not a tuning issue |
| Everything, and no time to diagnose | — | `OBSERVATORY_ENABLED=0` |

---

## 11. Where things live

```
engines/observatory/                    the engine; self-contained, extractable
  lib/observatory/collectors/           notification subscribers
  lib/observatory/probes/               Puma, MySQL, Redis, Sidekiq, process
  lib/observatory/analysis/rules/       one file per detection rule
  lib/observatory/pipeline/             buffer, writer, rollup aggregator
  app/models/observatory/               the eleven tables
  app/views/observatory/                the dashboard
config/initializers/observatory.rb      everything application-specific
bin/observatory-watchdog                the supervisor's advisory hook
log/observatory.log                     one JSON line per retained execution
docs/observatory/architecture.md        the design, and why
```

The detection rules are deliberately one small file each. If a conclusion looks
wrong, open the rule named on the incident and read it — it is thresholds and
arithmetic, and it is meant to be argued with.
