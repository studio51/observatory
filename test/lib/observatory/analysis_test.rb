# frozen_string_literal: true

require "test_helper"

module Observatory
  module Analysis

    # The whole product, asserted as one scenario.
    #
    # This test reconstructs the incident from the brief — every infrastructure
    # dashboard green, one route performing 86,359 ActiveRecord lookups with 97%
    # served from the query cache, every Puma thread held, `/up` unable to get a
    # thread, and the watchdog restarting a living process — and asserts that the
    # engine reaches the right conclusion *and* offers the right contradicting
    # evidence.
    #
    # If this passes, the system does what it was built to do.
    #
    class EngineTest < ActiveSupport::TestCase

      setup do
        clear_observatory_tables
        Capacity.reset!
      end

      teardown do
        clear_observatory_tables
        Capacity.reset!
      end

      test "identifies request threads as the constrained resource, not the database" do
        build_incident_scenario

        findings = with_observatory { Engine.evaluate(window) }
        saturation = findings.find { |found| found.rule == :puma_saturation }

        assert_not_nil saturation, "Puma saturation must be detected"
        assert_equal "request threads", saturation.constrained_resource
        assert_equal :critical, saturation.severity
        assert_equal "/steam/achievements/:id", saturation.primary_contributor
      end

      test "identifies the repeated-lookup workload and names the responsible route" do
        build_incident_scenario

        findings = with_observatory { Engine.evaluate(window) }
        explosion = findings.find { |found| found.rule == :cached_query_explosion }

        assert_not_nil explosion
        assert_equal "/steam/achievements/:id", explosion.primary_contributor
        assert_match(/query cache/i, explosion.failure_mode)
        assert_equal :high, explosion.confidence
      end

      test "supports the conclusion with the lookup counts and the cache ratio" do
        build_incident_scenario

        explosion = with_observatory { Engine.evaluate(window) }.find { |f| f.rule == :cached_query_explosion }
        evidence = explosion.supporting.map(&:to_line).join("\n")

        assert_match(/86,359/, evidence, "the lookup count must appear in the evidence")
        assert_match(/97\.\d%/, evidence, "the query-cache ratio must appear in the evidence")
        assert_match(/thread|duration|14\./i, evidence)
      end

      test "contradicts the conclusion with the healthy database and Redis measurements" do
        # The most important assertion here. Without these lines an operator
        # reads "86,359 queries" and goes to look at MySQL, which is exactly
        # where the problem is not.
        build_incident_scenario

        explosion = with_observatory { Engine.evaluate(window) }.find { |f| f.rule == :cached_query_explosion }
        against = explosion.contradicting.map(&:to_line).join("\n")

        assert_match(/MySQL connections in use: 54 of 10000/, against)
        assert_match(/MySQL running threads: 2/, against)
        assert_match(/Redis utilisation: 7\.6%/, against)
        assert_match(/executed.*2,280 of 86,359/i, against)
      end

      test "classifies a blocked health check as saturation rather than process death" do
        build_incident_scenario

        blocked = with_observatory { Engine.evaluate(window) }.find { |f| f.rule == :health_check_blocked }

        assert_not_nil blocked
        assert_match(/alive/i, blocked.failure_mode)
        assert_match(/indistinguishable from process death/i, blocked.failure_mode)
        assert_match(/Puma worker processes reporting/, blocked.contradicting.map(&:label).join("\n"))
      end

      test "flags the watchdog restart of a living process as a misclassification" do
        build_incident_scenario

        misclassified = with_observatory { Engine.evaluate(window) }.find do |found|
          found.rule == :watchdog_misclassification
        end

        assert_not_nil misclassified
        assert_match(/saturated but living/i, misclassified.title)
        assert_match(/dropped every in-flight request/i, misclassified.impact)
      end

      test "does not report slow SQL when the database was not where the time went" do
        build_incident_scenario

        findings = with_observatory { Engine.evaluate(window) }

        assert_nil findings.find { |found| found.rule == :slow_sql },
                   "2.1s of database time in a 14.4s request is not a slow-SQL finding"
      end

      test "reports slow SQL separately when the database really is the problem" do
        # The other half of the distinction: same symptom, opposite cause,
        # different finding.
        trace = create_trace(
          endpoint: "/reports/annual", duration_ms: 29_500.0, query_count: 52,
          cached_query_count: 2, executed_query_count: 50, cached_query_ratio: 0.04,
          db_duration_ms: 29_000.0,
        )
        QueryGroup.create!(
          trace_kind: "request", trace_row_id: trace.id, traced_at: trace.started_at,
          fingerprint: "SELECT * FROM orders WHERE year = ?",
          fingerprint_digest: QueryGroup.digest("SELECT * FROM orders WHERE year = ?"),
          sample_sql: "SELECT * FROM orders WHERE year = ?", count: 1, executed_count: 1,
          duration_ms: 28_900.0, max_duration_ms: 28_900.0, average_duration_ms: 28_900.0,
        )

        findings = with_observatory { Engine.evaluate(window) }
        slow = findings.find { |found| found.rule == :slow_sql }

        assert_not_nil slow
        assert_equal "database execution time", slow.constrained_resource
        assert_nil findings.find { |f| f.rule == :cached_query_explosion },
                   "a genuinely slow statement is not a cached-lookup explosion"
      end

      test "classifies a deep but draining queue instead of alerting on it" do
        DependencySample.create!(
          sampled_at: 1.minute.ago, dependency: DependencySample::SIDEKIQ, subject: "default",
          depth: 536_542, throughput: 56.3, drain_seconds: 9_530.0,
          metrics: { name: "default", depth: 536_542, throughput: 56.3 },
        )

        findings = with_observatory { Engine.evaluate(window) }
        healthy = findings.find { |found| found.rule == :healthy_backlog }

        assert_not_nil healthy, "a large but draining queue must be classified, not left ambiguous"
        assert_equal :info, healthy.severity
        assert_equal "none detected", healthy.constrained_resource
        assert_match(/536,542/, healthy.supporting.map(&:to_line).join("\n"))
      end

      test "does not report Redis as saturated from slowlog entries alone" do
        DependencySample.create!(
          sampled_at: 1.minute.ago, dependency: DependencySample::REDIS, subject: "",
          utilisation: 0.076,
          metrics: { "slow_commands_per_hour" => 7.0, "blocked_clients" => 0, "connected_clients" => 40,
                     "used_memory_bytes" => 1_000, "max_memory_bytes" => 100_000, },
        )

        findings = with_observatory { Engine.evaluate(window) }

        assert_nil findings.find { |found| found.rule == :redis_saturation },
                   "7 slow commands an hour at 7.6% utilisation is not saturation"
      end

      test "records a finding as an incident with its evidence on both sides" do
        build_incident_scenario

        result = with_observatory { Engine.run!(window) }

        assert_operator result[:opened], :>, 0

        incident = Incident.open_incidents.by_severity.first

        assert_equal "request threads", incident.constrained_resource
        assert_operator incident.supporting_evidence.size, :>, 3
        assert_operator incident.contradicting_evidence.size, :>, 0
      end

      test "an ongoing incident is one row, not one per detection cycle" do
        build_incident_scenario

        with_observatory do
          Engine.run!(window)
          Engine.run!(window)
          Engine.run!(window)
        end

        saturation = Incident.where(rule: "puma_saturation")

        assert_equal 1, saturation.count, "a continuing incident deduplicates"
        assert_equal 3, saturation.first.occurrence_count
      end

      test "an incident that stops being detected resolves itself" do
        build_incident_scenario
        with_observatory { Engine.run!(window) }

        Incident.update_all(last_seen_at: 1.hour.ago)
        with_observatory { Engine.resolve_stale! }

        assert_equal 0, Incident.open_incidents.count
        assert Incident.first.ended_at.present?
      end

      test "a rule that raises does not stop the other rules" do
        build_incident_scenario
        broken = Class.new(Rule) do
          def key = :deliberately_broken
          def call(_window) = raise("this rule is broken")
        end

        Engine.register(broken)

        findings = with_observatory { Engine.evaluate(window) }

        assert_operator findings.size, :>, 0, "the other rules still produced findings"
        assert_operator Safely.failure_counts["analysis.deliberately_broken"], :>=, 1
      ensure
        Engine.rules.delete(broken)
      end

      test "the finding renders as readable text for a terminal" do
        build_incident_scenario

        text = with_observatory { Engine.evaluate(window) }
               .find { |f| f.rule == :cached_query_explosion }
               .to_text

        assert_match(/^Incident: /, text)
        assert_match(/^Constrained resource: request threads/, text)
        assert_match(/^Evidence:/, text)
        assert_match(/^Contradicting evidence:/, text)
        assert_match(/^Confidence: high/, text)
      end

    private

      # @return [Observatory::Analysis::Window] a window covering the fixtures.
      #
      def window
        Window.new(from: 30.minutes.ago, to: 1.second.from_now)
      end

      # Reconstruct the incident from the brief.
      #
      # Six concurrent requests to one route, each performing tens of thousands
      # of lookups with 97% served from the query cache; every Puma thread
      # occupied; MySQL and Redis measurably idle; /up unable to complete; and a
      # watchdog restart of a process that was alive throughout.
      #
      # @return [void]
      #
      def build_incident_scenario
        traces = build_exploding_requests
        build_saturated_workers
        build_idle_dependencies
        build_blocked_health_checks
        build_watchdog_restart
        build_route_rollups(traces)

        nil
      end

      # @return [Array<Observatory::RequestTrace>]
      #
      def build_exploding_requests
        [ 86_359, 79_112, 71_004, 66_890, 62_331, 59_349 ].map.with_index do |queries, index|
          cached = (queries * 0.9736).round
          trace = create_trace(
            endpoint: "/steam/achievements/:id",
            controller: "Steam::AchievementsController", action: "show",
            started_at: (10 - index).minutes.ago,
            duration_ms: 14_472.0 - (index * 400),
            query_count: queries, cached_query_count: cached,
            executed_query_count: queries - cached,
            cached_query_ratio: cached.to_f / queries,
            db_duration_ms: 2_104.3, allocation_delta: 48_000_000,
            estimated_gc_time_ms: 1_832.0, unaccounted_ms: 10_500.0,
            peak_concurrency: 6, thread_seconds: 14.47, pool_waiting: 0,
            retention_class: "anomalous",
          )

          create_query_group(trace, "SELECT * FROM achievements WHERE id = ?", 41_722, cached: 41_000)
          create_query_group(trace, "SELECT * FROM trophies WHERE game_id = ?", 42_357, cached: 41_800,
                             call_site: "app/services/steam/achievements.rb:88:in `block in decorate'")

          trace
        end
      end

      # @return [void]
      #
      def build_saturated_workers
        3.times do |worker|
          6.times do |tick|
            ProcessSample.create!(
              sampled_at: (9 - tick).minutes.ago, hostname: "prod", process_id: 1_000 + worker,
              role: ProcessSample::WEB, worker_index: worker, capacity_source: "server",
              max_threads: 5, busy_threads: 5, idle_threads: 0, backlog: 23, backlog_max: 23,
              saturated: true, saturated_for_seconds: 60.0 + (tick * 30),
              pool_size: 25, pool_busy: 5, pool_waiting: 0, rss_bytes: 900_000_000,
            )
          end
        end

        nil
      end

      # Every dependency measurably fine — the contradicting evidence.
      #
      # @return [void]
      #
      def build_idle_dependencies
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
      def build_blocked_health_checks
        3.times do |index|
          create_trace(
            endpoint: "/up", started_at: (8 - index).minutes.ago, duration_ms: 5_100.0,
            status: 0, health_check: true, query_count: 0, retention_class: "anomalous",
          )
        end

        nil
      end

      # @return [void]
      #
      def build_watchdog_restart
        WatchdogEvent.create!(
          occurred_at: 7.minutes.ago, hostname: "prod", service: "web", process_id: 1_000,
          trigger: "health_check_failed", failed_probe_count: 3, probe_duration_ms: 5_000.0,
          process_alive: true, busy_threads: 15, max_threads: 15, backlog: 23,
          long_running_requests: 6,
          classification: WatchdogEvent::THREAD_SATURATION,
          action_taken: "restart_puma",
          recommended_action: "capture_saturation_evidence",
          advisory_reason: "process alive, all request threads occupied",
          advisory_only: true,
        )

        nil
      end

      # @param traces [Array<Observatory::RequestTrace>] the exploding requests.
      #
      # @return [void]
      #
      def build_route_rollups(traces)
        RouteRollup.create!(
          granularity: RouteRollup::MINUTE, bucket_at: 10.minutes.ago.change(sec: 0),
          endpoint: "/steam/achievements/:id", release: "",
          count: traces.size, error_count: 0, crawler_count: 6,
          thread_seconds: traces.sum(&:thread_seconds),
          duration_sum_ms: traces.sum(&:duration_ms), duration_max_ms: 14_472.0,
          query_count_sum: traces.sum(&:query_count), query_count_max: 86_359,
          cached_query_count_sum: traces.sum(&:cached_query_count),
          executed_query_count_sum: traces.sum(&:executed_query_count),
          db_duration_sum_ms: 12_625.8, allocation_sum: 288_000_000,
          duration_histogram: Histogram.empty.tap { |h| traces.each { |t| Histogram.observe(h, t.duration_ms) } },
        )

        nil
      end

      # @param attributes [Hash] overrides for the trace row.
      #
      # @return [Observatory::RequestTrace]
      #
      def create_trace(**attributes)
        RequestTrace.create!(
          {
            trace_id: Trace.generate, started_at: 5.minutes.ago, endpoint: "/x",
            duration_ms: 100.0, status: 200, http_method: "GET", hostname: "prod",
            process_id: 1_000, traffic_class: "unknown_automation", client_id: "abc123",
          }.merge(attributes),
        )
      end

      # @param trace [Observatory::RequestTrace] the trace it belongs to.
      # @param fingerprint [String] the normalised statement.
      # @param count [Integer] how often it ran.
      # @param cached [Integer] how many were query-cache hits.
      # @param call_site [String, nil] the application line that issued it.
      #
      # @return [Observatory::QueryGroup]
      #
      def create_query_group(trace, fingerprint, count, cached:, call_site: nil)
        QueryGroup.create!(
          trace_kind: "request", trace_row_id: trace.id, traced_at: trace.started_at,
          fingerprint:, fingerprint_digest: QueryGroup.digest(fingerprint),
          sample_sql: fingerprint, count:, cached_count: cached,
          executed_count: count - cached, duration_ms: 1_050.0,
          max_duration_ms: 4.2, average_duration_ms: 0.025, call_site:,
        )
      end

      # @return [void]
      #
      def clear_observatory_tables
        Instrumentation.suppress do
          [ IncidentEvidence, Incident, QueryGroup, RequestTrace, JobTrace, RouteRollup,
            JobRollup, ProcessSample, DependencySample, WatchdogEvent, ].each(&:delete_all)
        end

        nil
      end
    end
  end
end
