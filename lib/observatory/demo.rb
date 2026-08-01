# frozen_string_literal: true

module Observatory

  # Reproduces the incident, on demand, in development.
  #
  # ## Why this exists
  #
  # Everything else in this system is judged by whether it explains an incident
  # that happened once, on a production box, at an inconvenient hour. That is a
  # terrible feedback loop for building a dashboard. This makes the incident
  # reproducible in a second, so the detection rules and the UI can be developed
  # against the real signature rather than against a guess at it.
  #
  # It also serves as the executable definition of "working": if
  # {reproduce_incident!} does not produce a finding naming request threads as
  # the constrained resource, something has regressed.
  #
  # ## The signature it produces
  #
  #   request duration        > 10 seconds
  #   ActiveRecord lookups    > 50,000
  #   cached share            > 90%
  #   database execution      comparatively low
  #   allocations             high
  #   GC activity             elevated
  #   Puma thread occupancy   full
  #
  # ## Not available in production
  #
  # Guarded by `demo_enabled`, which the host initializer sets only in
  # development. Generating fake monitoring data in production would poison the
  # thing it is meant to measure — an operator has to be able to trust that every
  # row in these tables describes something that really happened.
  #
  module Demo
    ENDPOINT = "/steam/achievements/:id".freeze

    class << self

      # Build the full incident: exploding requests, saturated workers, idle
      # dependencies, blocked health checks and a watchdog restart.
      #
      # @param concurrency [Integer] how many simultaneous slow requests to stage.
      #
      # @return [Hash{Symbol => Object}] what was created, and what the rules made of it.
      #
      def reproduce_incident!(concurrency: 6)
        guard!

        Instrumentation.suppress do
          traces = concurrency.times.map { |index| exploding_request(index) }
          saturated_workers
          idle_dependencies
          blocked_health_checks
          watchdog_restart
          rollup(traces)

          findings = Analysis::Engine.evaluate(Analysis::Window.new(from: 30.minutes.ago, to: Clock.wall))
          Analysis::Engine.run!(Analysis::Window.new(from: 30.minutes.ago, to: Clock.wall))

          { traces: traces.size, findings: findings.map(&:title), report: findings.map(&:to_text).join("\n\n") }
        end
      end

      # Every scenario, by name, for exercising one signal at a time.
      #
      # @return [Hash{Symbol => String}]
      #
      def scenarios
        {
          cached_query_explosion: "A request performing 86,359 lookups, 97% from the query cache",
          executed_query_explosion: "A request performing 5,000 lookups the database really runs",
          slow_sql:               "A request dominated by one genuinely slow statement",
          allocation_heavy:       "A request allocating tens of millions of objects",
          slow_external:          "A request waiting on an upstream API",
          puma_saturation:        "Every request thread occupied for longer than the threshold",
          health_check_blocked:   "Health checks unable to obtain a thread during saturation",
          watchdog_misclassified: "A restart of a living, saturated process",
          healthy_backlog:        "A 536,542-job queue draining normally",
          queue_regression:       "A queue whose drain estimate keeps rising",
          database_pool_wait:     "Threads waiting for a database connection",
        }
      end

      # Run one named scenario.
      #
      # @param name [Symbol, String] a key from {scenarios}.
      #
      # @return [Object] whatever the scenario produced.
      #
      def run!(name)
        guard!

        method_name = :"scenario_#{name}"
        raise ArgumentError, "Unknown scenario: #{name}. Try one of: #{scenarios.keys.join(", ")}" unless
          respond_to?(method_name, true)

        Instrumentation.suppress { send(method_name) }
      end

      # Delete everything the demo created.
      #
      # Identifiable because every demo row carries a release of "demo", so this
      # cannot take real data with it.
      #
      # @return [Integer] rows deleted.
      #
      def clear!
        guard!

        Instrumentation.suppress do
          [ RequestTrace, JobTrace, ProcessSample, WatchdogEvent ]
            .sum { |model| model.where(release: RELEASE).delete_all }
        end
      end

      # The release stamped on every demo row, so it can be told from real data
      # and removed without touching any.
      #
      RELEASE = "demo".freeze

    private

      # @return [void]
      #
      def guard!
        return if Observatory.config.demo_enabled

        raise "Observatory demo scenarios are disabled. They generate fabricated monitoring data, which " \
              "must never appear in an environment where somebody might act on it. Set " \
              "`config.demo_enabled = true` in development if you need them."
      end

      # @param index [Integer] which of the concurrent requests this is.
      #
      # @return [Observatory::RequestTrace]
      #
      def exploding_request(index)
        queries = 86_359 - (index * 4_500)
        cached  = (queries * 0.9736).round

        trace = RequestTrace.create!(
          trace_id: Trace.generate, started_at: (10 - index).minutes.ago, endpoint: ENDPOINT,
          controller: "Steam::AchievementsController", action: "show", http_method: "GET",
          status: 200, duration_ms: 14_472.0 - (index * 400), query_count: queries,
          cached_query_count: cached, executed_query_count: queries - cached,
          cached_query_ratio: cached.to_f / queries, db_duration_ms: 2_104.3,
          allocation_delta: 48_000_000, estimated_gc_time_ms: 1_832.0,
          unaccounted_ms: 10_500.0, peak_concurrency: 6, concurrent_requests: 6,
          thread_seconds: 14.47, pool_waiting: 0, hostname: Observatory.hostname,
          process_id: 1_000 + (index % 3), traffic_class: "unknown_automation",
          client_id: "demo-crawler-01", retention_class: "anomalous",
          retained_because: %w[slow query_count cached_query_explosion], release: RELEASE,
        )

        query_group(trace, "SELECT * FROM achievements WHERE id = ?", 41_722, 41_000)
        query_group(trace, "SELECT * FROM trophies WHERE game_id = ?", 42_357, 41_800,
                    "app/services/steam/achievements.rb:88:in `block in decorate'")
        query_group(trace, "SELECT * FROM games WHERE id = ?", 2_280, 0)

        trace
      end

      # @param trace [Observatory::RequestTrace] the trace it belongs to.
      # @param fingerprint [String] the normalised statement.
      # @param count [Integer] how often it ran.
      # @param cached [Integer] how many were query-cache hits.
      # @param call_site [String, nil] the application line that issued it.
      #
      # @return [Observatory::QueryGroup]
      #
      def query_group(trace, fingerprint, count, cached, call_site = nil)
        QueryGroup.create!(
          trace_kind: QueryGroup::REQUEST, trace_row_id: trace.id, traced_at: trace.started_at,
          fingerprint:, fingerprint_digest: QueryGroup.digest(fingerprint), sample_sql: fingerprint,
          count:, cached_count: cached, executed_count: count - cached,
          duration_ms: cached.positive? ? 1_050.0 : 1_950.0,
          max_duration_ms: 4.2, average_duration_ms: 0.025, call_site:,
        )
      end

      # @return [void]
      #
      def saturated_workers
        3.times do |worker|
          6.times do |tick|
            ProcessSample.create!(
              sampled_at: (9 - tick).minutes.ago, hostname: Observatory.hostname,
              process_id: 1_000 + worker, role: ProcessSample::WEB, worker_index: worker,
              capacity_source: "server", max_threads: 5, busy_threads: 5, idle_threads: 0,
              backlog: 23, backlog_max: 23, saturated: true,
              saturated_for_seconds: 60.0 + (tick * 30), pool_size: 25, pool_busy: 5,
              pool_waiting: 0, rss_bytes: 900_000_000, release: RELEASE,
            )
          end
        end

        nil
      end

      # Every dependency measurably fine. This is the contradicting evidence, and
      # it is the half of the demo people forget to stage.
      #
      # @return [void]
      #
      def idle_dependencies
        DependencySample.create!(
          sampled_at: 5.minutes.ago, dependency: DependencySample::MYSQL, subject: "",
          utilisation: 0.0054,
          metrics: { "connections" => 54, "max_connections" => 10_000, "peak_connections" => 56,
                     "running_threads" => 2, "row_lock_waits" => 0, "slow_queries" => 0,
                     "deadlocks" => 0, },
        )
        DependencySample.create!(
          sampled_at: 5.minutes.ago, dependency: DependencySample::REDIS, subject: "",
          utilisation: 0.076,
          metrics: { "blocked_clients" => 0, "connected_clients" => 41, "max_clients" => 65_000,
                     "slow_commands_per_hour" => 7.0, "used_memory_bytes" => 2_000_000,
                     "max_memory_bytes" => 8_000_000_000, "keyspace_hit_ratio" => 0.94,
                     "rejected_connections" => 0, "evicted_keys" => 0, },
        )

        nil
      end

      # @return [void]
      #
      def blocked_health_checks
        3.times do |index|
          RequestTrace.create!(
            trace_id: Trace.generate, started_at: (8 - index).minutes.ago, endpoint: "/up",
            http_method: "GET", status: 0, duration_ms: 5_100.0, health_check: true,
            query_count: 0, hostname: Observatory.hostname, process_id: 1_000,
            traffic_class: "health_check", retention_class: "anomalous",
            retained_because: %w[health_check_failure], release: RELEASE,
          )
        end

        nil
      end

      # @return [Observatory::WatchdogEvent]
      #
      def watchdog_restart
        WatchdogEvent.create!(
          occurred_at: 7.minutes.ago, hostname: Observatory.hostname, service: "web",
          process_id: 1_000, trigger: "health_check_failed", failed_probe_count: 3,
          probe_duration_ms: 5_000.0, process_alive: true, busy_threads: 15, max_threads: 15,
          backlog: 23, long_running_requests: 6,
          classification: WatchdogEvent::THREAD_SATURATION, action_taken: "web_recycle",
          recommended_action: Watchdog::CAPTURE_AND_WAIT,
          advisory_reason: "The process is alive and every request thread is occupied.",
          advisory_only: true, release: RELEASE,
        )
      end

      # @param traces [Array<Observatory::RequestTrace>] the staged requests.
      #
      # @return [Observatory::RouteRollup]
      #
      def rollup(traces)
        RouteRollup.create!(
          granularity: RouteRollup::MINUTE, bucket_at: 10.minutes.ago.change(sec: 0),
          endpoint: ENDPOINT, release: RELEASE, count: traces.size, error_count: 0,
          crawler_count: traces.size, thread_seconds: traces.sum(&:thread_seconds),
          duration_sum_ms: traces.sum(&:duration_ms), duration_max_ms: 14_472.0,
          query_count_sum: traces.sum(&:query_count), query_count_max: 86_359,
          cached_query_count_sum: traces.sum(&:cached_query_count),
          executed_query_count_sum: traces.sum(&:executed_query_count),
          db_duration_sum_ms: traces.size * 2_104.3, allocation_sum: traces.size * 48_000_000,
          gc_time_sum_ms: traces.size * 1_832.0, sampled_trace_count: traces.size,
          duration_histogram: traces.each_with_object(Histogram.empty) do |trace, histogram|
            Histogram.observe(histogram, trace.duration_ms)
          end,
        )
      end

      # --- Individual scenarios ---

      # @return [Hash]
      #
      def scenario_cached_query_explosion
        reproduce_incident!(concurrency: 1)
      end

      # @return [Observatory::RequestTrace]
      #
      def scenario_executed_query_explosion
        trace = RequestTrace.create!(
          trace_id: Trace.generate, started_at: 2.minutes.ago, endpoint: "/games/:id/library",
          http_method: "GET", status: 200, duration_ms: 8_400.0, query_count: 5_000,
          cached_query_count: 100, executed_query_count: 4_900, cached_query_ratio: 0.02,
          db_duration_ms: 6_100.0, instantiation_count: 5_000, allocation_delta: 12_000_000,
          hostname: Observatory.hostname, process_id: 1_000, retention_class: "anomalous",
          release: RELEASE,
        )
        query_group(trace, "SELECT * FROM game_sessions WHERE user_id = ?", 4_900, 0,
                    "app/models/user/library.rb:41:in `each'")

        trace
      end

      # @return [Observatory::RequestTrace]
      #
      def scenario_slow_sql
        trace = RequestTrace.create!(
          trace_id: Trace.generate, started_at: 2.minutes.ago, endpoint: "/reports/annual",
          http_method: "GET", status: 200, duration_ms: 29_500.0, query_count: 52,
          cached_query_count: 2, executed_query_count: 50, cached_query_ratio: 0.04,
          db_duration_ms: 29_000.0, hostname: Observatory.hostname, process_id: 1_000,
          retention_class: "anomalous", release: RELEASE,
        )
        QueryGroup.create!(
          trace_kind: QueryGroup::REQUEST, trace_row_id: trace.id, traced_at: trace.started_at,
          fingerprint: "SELECT * FROM orders WHERE created_at BETWEEN ? AND ?",
          fingerprint_digest: QueryGroup.digest("SELECT * FROM orders WHERE created_at BETWEEN ? AND ?"),
          sample_sql: "SELECT * FROM orders WHERE created_at BETWEEN ? AND ?",
          count: 1, executed_count: 1, duration_ms: 28_900.0, max_duration_ms: 28_900.0,
          average_duration_ms: 28_900.0,
        )

        trace
      end

      # @return [Observatory::RequestTrace]
      #
      def scenario_allocation_heavy
        RequestTrace.create!(
          trace_id: Trace.generate, started_at: 2.minutes.ago, endpoint: "/exports/everything",
          http_method: "GET", status: 200, duration_ms: 6_200.0, query_count: 40,
          allocation_delta: 92_000_000, estimated_gc_time_ms: 2_400.0, unaccounted_ms: 5_600.0,
          hostname: Observatory.hostname, process_id: 1_000, retention_class: "anomalous",
          release: RELEASE,
        )
      end

      # @return [Observatory::RequestTrace]
      #
      def scenario_slow_external
        RequestTrace.create!(
          trace_id: Trace.generate, started_at: 2.minutes.ago, endpoint: "/steam/sync",
          http_method: "POST", status: 200, duration_ms: 11_800.0, query_count: 12,
          external_call_count: 8, external_duration_ms: 11_200.0,
          external_hosts: [ "api.steampowered.com" ], hostname: Observatory.hostname,
          process_id: 1_000, retention_class: "anomalous", release: RELEASE,
        )
      end

      # @return [void]
      #
      def scenario_puma_saturation
        saturated_workers
      end

      # @return [void]
      #
      def scenario_health_check_blocked
        saturated_workers

        blocked_health_checks
      end

      # @return [Observatory::WatchdogEvent]
      #
      def scenario_watchdog_misclassified
        saturated_workers

        watchdog_restart
      end

      # @return [Observatory::DependencySample]
      #
      def scenario_healthy_backlog
        DependencySample.create!(
          sampled_at: 1.minute.ago, dependency: DependencySample::SIDEKIQ, subject: "default",
          depth: 536_542, throughput: 56.3, drain_seconds: 9_530.0,
          metrics: { "name" => "default", "depth" => 536_542, "throughput" => 56.3,
                     "latency" => 4.2, },
        )
      end

      # @return [Array<Observatory::DependencySample>]
      #
      def scenario_queue_regression
        [ 8_000, 14_000, 21_000, 32_000 ].each_with_index.map do |drain, index|
          DependencySample.create!(
            sampled_at: (4 - index).minutes.ago, dependency: DependencySample::SIDEKIQ,
            subject: "stm_api", depth: 40_000 + (index * 30_000),
            throughput: 6.0 - index, drain_seconds: drain.to_f,
            metrics: { "name" => "stm_api" },
          )
        end
      end

      # @return [void]
      #
      def scenario_database_pool_wait
        3.times do |index|
          ProcessSample.create!(
            sampled_at: (3 - index).minutes.ago, hostname: Observatory.hostname,
            process_id: 1_000 + index, role: ProcessSample::WEB, capacity_source: "server",
            max_threads: 5, busy_threads: 5, idle_threads: 0, backlog: 4, saturated: true,
            saturated_for_seconds: 45.0, pool_size: 5, pool_busy: 5, pool_waiting: 7,
            rss_bytes: 700_000_000, release: RELEASE,
          )
        end

        nil
      end
    end
  end
end
