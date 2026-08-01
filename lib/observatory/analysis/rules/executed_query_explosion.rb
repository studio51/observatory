# frozen_string_literal: true

module Observatory
  module Analysis
    module Rules

      # A request is issuing a large number of queries the database actually runs.
      #
      # ## The uncached sibling of {CachedQueryExplosion}
      #
      # Same shape of bug — a lookup inside a loop — but without the query cache
      # softening it, because the statements differ enough not to hit, or because
      # writes are interleaved and keep invalidating it.
      #
      # This one is *more* damaging and *easier* to spot: every lookup is a real
      # round trip, so it consumes a connection, appears in MySQL's own counters,
      # and shows up as database time. It gets its own rule because the
      # recommendation differs — here the database is genuinely under load, so
      # both the loop and its effect on MySQL matter.
      #
      class ExecutedQueryExplosion < Rule

        # @return [Symbol]
        #
        def key = :executed_query_explosion

        # @param window [Observatory::Analysis::Window] the measurements to reason over.
        #
        # @return [Array<Observatory::Analysis::Finding>]
        #
        def call(window)
          window.request_traces
                .select { |trace| explosive?(trace) }
                .group_by(&:endpoint)
                .map { |endpoint, traces| build_finding(endpoint, traces, window) }
        end

      private

        # @param trace [Observatory::RequestTrace] the trace to test.
        #
        # @return [Boolean]
        #
        def explosive?(trace)
          trace.executed_query_count >= config.high_query_count &&
            trace.cached_query_ratio < config.high_cached_query_ratio &&
            trace.duration_ms >= (config.slow_request_threshold * 1_000)
        end

        # @param endpoint [String] the route template.
        # @param traces [Array<Observatory::RequestTrace>] its offending traces.
        # @param window [Observatory::Analysis::Window] the surrounding measurements.
        #
        # @return [Observatory::Analysis::Finding]
        #
        def build_finding(endpoint, traces, window)
          worst = traces.max_by(&:executed_query_count)
          group = worst.dominant_query_group

          finding(
            title:      "Query explosion on #{endpoint}",
            severity:   worst.executed_query_count >= config.extreme_query_count ? :critical : :warning,
            confidence: :high,
            component:  "activerecord",
            constrained_resource: "database round trips",
            primary_contributor:  endpoint,
            failure_mode: "A lookup is being issued inside a loop and the query cache is not absorbing it, " \
                          "so every iteration is a real round trip to MySQL.",
            impact: "#{count(worst.executed_query_count)} executed queries in one request, " \
                    "#{duration(worst.db_duration_ms)} of database time, and a Puma thread held throughout.",
            recommended_action: "Preload the association or batch the ids. Unlike a cached explosion, this " \
                                "one is also costing the database real work.",
            started_at: traces.map(&:started_at).min,
            supporting: [
              evidence_for("Queries the database executed", count(worst.executed_query_count), trace: worst),
              evidence_for("Served from the query cache", percentage(worst.cached_query_ratio), trace: worst),
              evidence_for("Time in ActiveRecord", duration(worst.db_duration_ms), trace: worst),
              evidence_for("Request duration", duration(worst.duration_ms), trace: worst),
              evidence_for("Records materialised", count(worst.instantiation_count), trace: worst),
              group ? evidence_for("Most repeated shape",
                                   "#{count(group.count)} executions of #{group.sample_sql.to_s[0, 120]}") : nil,
              group&.call_site ? evidence_for("Application call site", group.call_site) : nil,
            ].compact,
            contradicting: contradicting(worst, window),
            subjects: { request_traces: traces.map(&:id) },
          )
        end

        # @param worst [Observatory::RequestTrace] the worst trace.
        # @param window [Observatory::Analysis::Window] the surrounding measurements.
        #
        # @return [Array<Observatory::Analysis::Evidence>]
        #
        def contradicting(worst, window)
          items = []
          items << evidence_against("Threads waiting for a connection", worst.pool_waiting, trace: worst) unless
            worst.pool_waiting.nil?

          mysql = window.latest_dependency(DependencySample::MYSQL)
          if mysql
            items << evidence_against("MySQL connections in use",
                                      "#{mysql.metric("connections")} of #{mysql.metric("max_connections")}")
            items << evidence_against("Average query duration",
                                      duration(worst.db_duration_ms / [ worst.executed_query_count, 1 ].max),
                                      details: { note: "each query is fast; there are simply far too many" })
          end

          items
        end
      end
    end
  end
end
