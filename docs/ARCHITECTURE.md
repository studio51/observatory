# Observatory — architecture note

> Causal observability for Rails. Phase 0 deliverable: what exists, what is
> reused, what is added, the production risks, and the implementation phases.

Observatory answers four questions that an infrastructure dashboard cannot:

1. **What is unhealthy?**
2. **Which finite resource is constrained?**
3. **What work is consuming that resource?**
4. **What evidence supports that conclusion?**

The motivating incident is one this repository can actually produce today: a
request performing tens of thousands of ActiveRecord lookups, most of them
served by the ActiveRecord *query cache*, occupying every Puma request thread
while MySQL, Redis and CPU all look idle — and `bin/dev`'s watchdog restarting a
living-but-saturated Puma because `/up` could not obtain a thread.

---

## 1. What already exists

Everything below was read from the repository at `a9758920c`, not assumed.

### Runtime

| Component | Version / value | Source |
| --- | --- | --- |
| Ruby | 4.0.5 | `.ruby-version`, `.tool-versions` |
| Rails | 8.1.3 (`load_defaults 8.1`) | `Gemfile.lock`, `config/application.rb` |
| YJIT | enabled (`config.yjit = true`) | `config/application.rb` |
| Puma | 8.0.2 | `Gemfile.lock` |
| Sidekiq | 8.1.6 | `Gemfile.lock` |
| MySQL adapter | `mysql2` 0.5.7 | `Gemfile.lock`, `config/database.yml` |
| Redis | `redis` 5.4.1 / `redis-client` 0.30.1 | `Gemfile.lock` |
| ViewComponent | 4.12.0 | `Gemfile.lock` |
| Turbo / Stimulus | `turbo-rails` 2.0.23, `stimulus-rails` 1.3.4 | `Gemfile.lock` |
| Bundler | Vite (`vite_rails` 3.11.0), entrypoints in `app/packs` | `config/vite.json` |
| Templating | Slim 5.2.1 | `Gemfile` |
| Tests | Minitest + fixtures, `parallelize(workers: :number_of_processors)` | `test/test_helper.rb` |

Note the deviation from the brief's assumption: this is **Rails 8.1 on Ruby
4.0**, not Rails 7.2 / Ruby 3.4. Verified against the installed runtime rather
than assumed:

```
$ ruby -e 'puts RUBY_VERSION; puts GC.measure_total_time; puts GC.total_time;
           puts Thread.instance_methods(false).grep(/alloc/).inspect'
4.0.5
true            # GC time measurement is ON by default — no opt-in needed
3158000         # GC.total_time, nanoseconds, process-wide
[]              # no per-thread allocation counter exists in CRuby 4.0.5
```

Three consequences:

- `GC.total_time` (ns) and `GC.stat[:time]` (ms) are both available with **no
  configuration change and no added cost** — `GC.measure_total_time` already
  defaults to `true`. GC time deltas are therefore free to collect.
- **There is no per-thread allocation counter.** `Thread#allocated_object_count`
  is a JRuby/TruffleRuby API; CRuby has only the process-wide
  `GC.stat[:total_allocated_objects]`. With 5 request threads per worker,
  *every* allocation and GC figure Observatory reports for a request is a
  process-wide delta contaminated by concurrent work. This is not a detail to
  gloss: the fields are named `estimated_*` / `*_delta` and the UI labels them
  as estimates (§R7).
- `ActiveSupport::CurrentAttributes` is fiber-safe here and is reset per request
  and per job by Rails' executor, so it is the correct context mechanism.

### Puma configuration (`config/puma.rb`)

- `threads 5, 5` by default (`RAILS_MAX_THREADS`, default **5**).
- Production: `workers 3` (`WEB_CONCURRENCY`), `preload_app!`.
- **Total production request capacity is 15 threads** (3 workers × 5). This is
  the finite resource the product is built around.
- `stdout_redirect "log/puma.log"` in production, so `bin/dev`'s log scanner can
  see fatal signatures.
- **No `activate_control_app`.** There is no Puma control socket, so stats must
  be read *in-process*. Reading Puma 8.0.2's source rather than trusting the
  API name turned up two things that shape the design:
  - `Puma.stats_object` is assigned exactly once, in `Puma::Launcher#run`
    (`puma-8.0.2/lib/puma/launcher.rb:110`), in the **master**. A forked cluster
    worker inherits that object, so `Puma.stats_hash` inside a worker returns
    *cluster* stats whose `worker_status` is a stale snapshot from fork time —
    not the calling worker's thread pool. It is only directly useful in single
    (development) mode.
  - `Puma::ThreadPool#stats` has a **side effect**: it zeroes `@backlog_max`
    (`thread_pool.rb:143`), and `Server#stats` additionally calls `reset_max`.
    Whoever reads it steals the high-water mark from everyone else. Observatory
    must be the sole caller. Nothing else in this app calls it (no control app,
    no systemd plugin on macOS), so that holds today — and it is documented in
    the runbook so it keeps holding.

  Capacity is therefore read through a three-layer adapter that records *which*
  layer answered, so the UI never presents a fallback as ground truth (§R5/R6).

### Sidekiq configuration

- Two supervised processes: `sidekiq-regular` (`config/sidekiq.regular.yml`,
  concurrency **15**, weighted queues `default, psn_api, stm_api, xbx_api,
  cex_api×2, epic_api×2, gog_api×2, cache×2, network_api×2, gaming_api×2,
  api×3`) and `sidekiq-splash`.
- Existing server middleware chain (`config/initializers/sidekiq.rb`):
  `SidekiqUniqueJobs::Middleware::Server` → `SidekiqRequestStoreMiddleware` →
  `NetworkBackoffMiddleware`. Client chain: `SidekiqUniqueJobs::Middleware::Client`.
- Ecosystem gems already present and worth surfacing:
  `sidekiq-throttled`, `sidekiq-unique-jobs`, `sidekiq-pauzer`,
  `sidekiq-antidote`, `sidekiq-cron`, `sidekiq-scheduler`, `sidekiq-grouping`,
  `sidekiq-failures`, `sidekiq-status`.
- Redis for Sidekiq is the default `REDIS_URL` (logical DB 1 by convention).

### Database

- `pool: 25` for every environment (`config/database.yml`), against a Puma
  worker that only has 5 threads — so **pool starvation is unlikely by
  construction**, which is itself a useful piece of contradicting evidence.
- Production sets `timeout: 60000` and `variables: { max_execution_time: 60000 }`.
- Production has a second `queue` database (`directory-queue`,
  `migrations_paths: db/queue_migrate`) that is **configured but not connected
  to by any model** — no `connects_to` anywhere in `app/models`. It is a
  dormant slot, not a live shard.
- Development's `primary` points at `directory-live` over an SSH tunnel
  (`127.0.0.1:13306`). **Never migrate or seed development.**

### Redis clients in use

`Rails.cache` (`redis_cache_store`, logical DB **3** in production, ElastiCache),
Sidekiq (DB 1), Kredis (`config/redis/shared.yml`, DB 1), Action Cable,
`sidekiq-unique-jobs`, `sidekiq-throttled`, `sidekiq-pauzer`,
`sidekiq-antidote`, and the `Cacheable` write-behind service cache.

### Existing Rack middleware

`RequestStore::Middleware`, `Rack::Cors` (inserted at 0),
`OmniAuth::Builder`, `Rack::Attack` (AWS-range blocklist + login/search
throttles). `MiddlewareHealthcheck` exists in `app/middleware` but is **not
mounted** — it answers a misspelled `/healtcheck` and is dead code. Left alone.

### Existing instrumentation

**None.** `grep -rn "ActiveSupport::Notifications" app lib config` returns no
hits. There is no metrics, tracing, Prometheus, StatsD, OpenTelemetry, Yabeda or
`rack-mini-profiler` gem in the `Gemfile`. The only observability is:

- **Sentry** (`sentry-ruby`/`sentry-rails`/`sentry-sidekiq`), enabled in
  production only, `traces_sample_rate: 0.5`, `sample_rate` left at 1.0.
- `GDLogger` (`lib/g_d_logger.rb`) — a development-only string logger.
- `config.log_tags = [:request_id]` in production, logging to STDOUT via
  `ActiveSupport::TaggedLogging`.

So `request_id` **is** consistently available in Rails logs, but it is *not*
propagated into Sidekiq jobs, and Puma has no notion of it.

### Health checks

`get "up" => "rails/health#show"` (`config/routes.rb:11`) — the stock Rails
health controller, which only proves the process booted. It is a full Rails
request and therefore **needs a Puma thread**, which is precisely the failure
mode we must classify.

### Supervisor and watchdog (`bin/dev`, 932 lines)

Production is a macOS box; `bin/dev` is both deployer and supervisor (no
foreman), kept alive by `config/launchd/directory.games.supervisor.plist`. Its
watchdog sweeps every `WATCHDOG_INTERVAL` (30s) and recycles `web` when:

- a fatal signature appears in `log/puma.log` (`Too many open files`, `EMFILE`,
  `ENFILE`);
- master or worker RSS exceeds `WEB_MEM_LIMIT_MB` (2048);
- **`curl -fsS -m 5 http://127.0.0.1:1337/up` fails `HEALTH_FAIL_LIMIT` (3)
  sweeps in a row** → `web_recycle "health check failed 3x in a row"`.

That last branch is the misclassification the brief describes, verbatim, in
this repository: it cannot tell a dead master from one whose 15 threads are all
busy. `WATCHDOG_COOLDOWN` (120s) is the only brake. Deploy state lives in
`tmp/pids/deploy.last-success` (the last successfully deployed SHA) — that file
is the **only existing release identifier**, and it is not exposed to Ruby.

### Admin surface

`Admin::ApplicationController` — `layout "admin"`, gated by
`before_action { redirect_to(root_url) unless current_user&.devops? }`; routes
wrapped in `authenticate :user, ->(u) { u.devops? }` inside a `main_domain`
constraint. A parallel `devops` namespace mounts `Sidekiq::Web` and
`Searchjoy::Engine` under the same gate. `admin_navigation_items`
(`app/helpers/navigation_helper.rb:55`) drives the sidebar.

### UI conventions

Slim templates, Tailwind (`tailwind.config.js`), ViewComponent under
`app/components` with a `V3` kit (atoms, molecules, components, pages), `Utilities::Ui::TimeSeriesComponent`
for **server-rendered inline-SVG charts** — house style is charts computed in
Ruby, with Chartkick reserved for admin. Turbo Frames are the default for
filterable UI; Stimulus only for what HTML cannot do. Copy lives in
`config/locales/<locale>/<module>.yml` with per-view lazy lookup.

### Proxy headers

Production is fronted by `kamal-proxy`. **No `X-Request-Start` / `X-Queue-Start`
is set today.** Request queue wait is therefore *unavailable* and must be
reported as unknown rather than fabricated — with a documented one-line proxy
change to enable it.

---

## 2. What can be reused

| Need | Reused from the repo |
| --- | --- |
| Admin authorisation | `Admin::ApplicationController`'s `devops?` gate + the `authenticate` route wrapper |
| Dashboard chrome | `layout "admin"`, `Ui::Page::HeadingComponent`, `V2::Ui::Navbar::TabsComponent`, Tailwind card/row/column utilities |
| Charts | the `Utilities::Ui::TimeSeriesComponent` pattern — inline SVG computed in Ruby |
| Filterable UI | `turbo_frame_tag` + `form_with(data: { turbo_frame: … })`, exactly as `admin/growth` does |
| Request identity | `ActionDispatch::RequestId` (already on) and `config.log_tags = [:request_id]` |
| Job identity | Sidekiq's own `jid`, `bid`, `created_at`, `enqueued_at`, `retry_count` |
| Job middleware slot | the existing `configure_server` / `configure_client` chains |
| Release identity | `tmp/pids/deploy.last-success` + `.version`, surfaced to Ruby by a new resolver |
| Copy | `config/locales/en/…` lazy lookup |
| Error reporting | Sentry, for Observatory's *own* failures (rate-limited) |
| Retention jobs | Sidekiq + `config/schedule.yml` (`sidekiq-cron`) |

## 3. What must be added

Everything is built as a **self-contained Rails engine at `engines/observatory`**,
added to the host `Gemfile` with `gem "observatory", path: "engines/observatory"`.
It has its own gemspec, `lib/`, `app/`, `config/routes.rb`, `db/migrate` and
`test/`. Extracting it to a standalone gem is a directory move plus a
`git subtree split` — no host code lives inside it, and its only hard
dependencies are `rails` and `view_component`. Puma, Sidekiq, mysql2 and redis
are **soft** dependencies, detected at boot and adapted behind version-guarded
adapters.

Top-level namespace: **`Observatory`**. *(Deviation from the brief, which used
`Monitoring`. A gem should not claim a constant as generic as `Monitoring`;
tables are `observatory_*` for the same reason. Everything else — the
suppression API, the config shape, the entity list — follows the brief.)*

Added, by layer:

- **Core** — `Observatory.config`, `Observatory::Current` (`CurrentAttributes`),
  `Observatory::Instrumentation.suppress`, `Observatory::Safely` (fail-open +
  rate-limited dedicated log).
- **Collection** — Rack middleware; subscribers for `sql.active_record`,
  `process_action.action_controller`, `render_template.action_view`,
  `cache_*.active_support`, `instantiation.active_record`; a Net::HTTP shim for
  external calls; GC/allocation deltas.
- **Analysis-time data** — SQL fingerprinting + bind redaction, query grouping,
  controlled call-site capture.
- **Pipeline** — bounded priority ring buffer → background batch writer thread →
  `ActiveRecord` insert-all, all inside `suppress`.
- **Probes** — Puma (`Puma.stats_hash`), Sidekiq (`Sidekiq::Stats`, `ProcessSet`,
  `Queue`), AR connection pool, MySQL (`SHOW GLOBAL STATUS`/`information_schema`),
  Redis (`INFO`), process RSS/GC.
- **Analysis** — deterministic rule registry, findings with supporting *and*
  contradicting evidence, incidents, causal timelines, route/job baselines.
- **UI** — engine-owned ViewComponents + Slim views mounted at
  `/devops/observatory`.
- **Watchdog** — a `bin/observatory-probe` CLI the shell watchdog calls before
  restarting, which records a structured event and returns an advisory verdict.

## 4. Production risks

| # | Risk | Mitigation |
| --- | --- | --- |
| R1 | **Instrumentation becomes the outage.** A per-query DB write or a synchronous flush on the request path would amplify exactly the incident we are hunting. | No I/O on the request path at all. Per-request work is integer/float arithmetic into a preallocated struct + one bounded-buffer push. Batch writer runs on its own thread. Budget: <1 ms median, <3 ms p95, enforced by `test/performance/overhead_test.rb`. |
| R2 | **Unbounded memory.** A query-explosion request could accumulate 86k query records in memory — the monitoring equivalent of the bug. | Query groups are keyed by fingerprint and capped at `max_query_groups` (200); beyond the cap, counts fold into an `:other` bucket. Only aggregates are kept, never per-query rows. The ring buffer is fixed-capacity with priority eviction. |
| R3 | **Recursive instrumentation.** Observatory's own writes are ActiveRecord queries. | `Observatory::Instrumentation.suppress` sets a thread-local depth counter; every subscriber and middleware returns immediately when suppressed. The writer thread runs permanently suppressed. Its models use a dedicated connection role so its queries cannot land in an application request's tally. |
| R4 | **Writing to the primary DB adds load.** | Phase 2 defaults to the primary connection because that is the only *safe, repo-compatible* thing that works today — but every write is batched `insert_all` on append-only tables with no application foreign keys, capped by `batch_size` and `flush_interval`, and the whole subsystem is one boolean away from off. `ObservatoryRecord.connects_to` is driven by an `observatory` entry in `database.yml`, so moving it to the dormant `directory-queue` slot or a separate schema is configuration, not code. Retention cleanup is `delete_all` in strict batches on an indexed timestamp. |
| R5 | **Puma internals drift**, and `Puma.stats_hash` does not mean in a worker what it means in the master. | A three-layer `Observatory::Probes::Puma` adapter that records its `source`: (1) the worker's own `Puma::Server`, located once per process by a memoised `ObjectSpace.each_object(::Puma::Server)` scan run **on the sampler thread, never the request path**; (2) `Puma.stats_hash` when it actually returns thread-pool keys (single/dev mode); (3) Observatory's own in-flight request gauge plus the configured `max_threads`, with `backlog` reported as `nil` — *unknown*, not zero. Keys are feature-detected, tests pin the 8.0.2 shape, and the adapter never raises. |
| R6 | **Cross-process aggregation.** With `preload_app!` + 3 workers there is no shared memory and no control socket, so no process can see total capacity. | Each worker writes its own sample keyed by `worker_index`; the aggregate is a `SUM`/`MAX` over the newest sample per worker inside the sampling window, rendered as "3 of 3 workers reporting". A worker that stops reporting is shown as stale, not as zero — a saturated worker that cannot run the sampler thread is itself a signal. |
| R7 | **Per-request GC and allocation attribution is not exact and cannot be made exact.** Verified: CRuby 4.0.5 has no per-thread allocation counter, so both figures are process-wide deltas shared by up to 5 concurrent request threads. | Never reported as exact. Columns and UI labels are `estimated_gc_time_ms`, `allocation_delta`, `worker_gc_delta`; the request-detail view states the contamination explicitly and shows the concurrent-request count during the window so a reader can judge it. The detection rules that use these signals require a *large* multiple over baseline, never a marginal one, precisely because the measurement is noisy. |
| R8 | **Call-site capture is expensive.** `caller_locations` in the SQL subscriber would dominate the budget. | Off the hot path by construction: only after a fingerprint crosses `query_call_site_threshold` (100) *within one execution*, at most `max_call_sites` (3) per execution, `caller_locations(start, 25)` with framework frames filtered, and killable via `capture_query_call_sites = false`. Benchmarked separately. |
| R9 | **PII leakage.** Traces would otherwise hold IPs, bind values and URLs. | Binds redacted at fingerprint time (never stored raw), route *templates* not paths, query strings dropped except an allowlist, headers allowlisted, IPs replaced by a rotatable HMAC, `Rails.application.config.filter_parameters` reused. Admin-only, `devops?` gated. |
| R10 | **Changing restart behaviour breaks production.** | Phase 6 ships **advisory only**. `bin/dev` gains an opt-in `OBSERVATORY_ADVISORY` hook that *records* and *logs* a recommendation; the restart still happens exactly as today. Enforcement is a separate, later, flag-gated change. |
| R11 | **Sidekiq recursion.** Aggregation/retention jobs would monitor themselves. | They run on a dedicated `observatory` queue and are wrapped in `suppress`; the server middleware skips any job whose class is under `Observatory::`. |
| R12 | **The test suite runs in parallel with shared fixtures.** | Observatory is disabled by default in `test` and enabled per-test with an explicit helper; the buffer and writer are synchronous in test mode. |

### Data-volume estimate

Production peak is ~15 concurrent request threads. Assume a sustained 60 req/s.

- Tail-based sampling at `normal_request_sample_rate = 0.01` plus always-keep
  rules ⇒ roughly **1–3 retained traces/s** ≈ 100–250k rows/day at ~400 B ⇒
  **~40–100 MB/day** for `observatory_request_traces`.
- Query groups: only for retained traces, capped at 200 and in practice ~5–20 ⇒
  ~1–2 M rows/day at ~250 B ⇒ **~250–500 MB/day**. This is the dominant table,
  so it carries the shortest retention (24 h for ordinary traces) and is the
  first thing to disable if storage bites.
- Minute rollups: ~300 distinct routes × 1440 min ⇒ **~430 k rows/day** at
  ~200 B ⇒ ~85 MB/day, 90-day retention ⇒ ~8 GB steady state.
- Process samples: (3 Puma workers + 2 Sidekiq + 1 DB + 1 Redis) × 1/15 s ⇒
  **~40 k rows/day**, negligible.

Steady state with the default retention is on the order of **15–25 GB**. That is
acceptable on the primary for now and is the reason retention is configurable
per class of row, and why the migration is one `connects_to` away from moving.

### Storage recommendation

**Primary MySQL, dedicated append-only tables, batched writes, aggressive
retention — with a first-class escape hatch.** Rationale: the app has no
time-series backend, no second live database (the `queue` slot is dormant), and
introducing one would be a much larger production risk than the write volume
above. `ObservatoryRecord` is an abstract base that calls `connects_to` when a
`observatory` key exists in `database.yml` and falls back to the primary
otherwise, so the migration path is open without being taken now.

## 5. Implementation phases

Each phase is independently deployable and independently useful. Phase order
follows the brief, except that **Phase 5 (analysis) lands before Phase 4 (UI)**
— the dashboard's whole reason to exist is to render findings, and building it
first would mean building it twice.

| Phase | Deliverable | Independently useful because |
| --- | --- | --- |
| 0 | This note | The audit is the product decision |
| 1 | Engine, config, context, suppression, Rack + AR/AV instrumentation, structured log | `log/observatory.log` already answers "which request did 86k lookups" |
| 2 | Bounded buffer, batch writer, models, migrations, rollups, retention | Queryable history in SQL |
| 3 | Puma / Sidekiq / MySQL / Redis / process probes, thread-seconds | Capacity accounting |
| 5 | Rule registry, findings, incidents, baselines, causal timeline | The causal answer, readable from the console |
| 4 | Admin UI | The answer, readable by a human at 03:00 |
| 6 | Watchdog events + advisory classification | Stops blaming a saturated process for being dead |
| 7 | Demo scenarios, benchmarks, runbook, feature flags, exporter interface | Operable |

## 6. Assumptions

1. `Observatory` replaces the brief's `Monitoring` namespace (gem hygiene, §3).
2. Request queue wait is **unavailable** until `kamal-proxy` sets
   `X-Request-Start`; it is reported as `nil`/"unknown", never estimated. The
   middleware reads the header if it ever appears, so enabling it upstream is a
   proxy config change with no code change here.
3. Cross-worker Puma aggregation is sample-based, not authoritative, and is
   labelled with how many workers reported.
4. **Both** per-request GC time and per-request allocations are estimates on
   CRuby — there is no exact per-thread counter to fall back to (verified, §1).
5. Production restart behaviour does not change in this work (advisory only).
6. The `queue` database stays dormant; Observatory writes to the primary.
7. Observatory is the sole caller of Puma's `stats`, because reading it resets
   Puma's `backlog_max` high-water mark.
