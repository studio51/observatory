# frozen_string_literal: true

module Observatory
  module Analysis
    module Rules

      # One or a few statements the database genuinely takes a long time to run.
      #
      # ## Deliberately not the same rule as {CachedQueryExplosion}
      #
      # Both produce a request dominated by ActiveRecord. They need opposite
      # fixes, and merging them into one "database slow" warning is how an
      # afternoon gets spent adding indexes to a table that was never the
      # problem.
      #
      #   Repeated lookups     86,359 queries, 97% cached, 2.1s in the database
      #                        -> fix the loop in the application
      #
      #   Slow SQL             52 queries, few cached, 29.5s in ActiveRecord,
      #                        one shape accounting for 28.9s of it
      #                        -> fix the query, the index or the data volume
      #
      # The discriminator is the ratio of database time to request time, plus
      # whether one *shape* owns most of it. This rule fires only when the
      # database really is where the time went.
      #
      class SlowSql < Rule

        # @return [Symbol]
        #
        def key = :slow_sql

        # @param window [Observatory::Analysis::Window] the measurements to reason over.
        #
        # @return [Array<Observatory::Analysis::Finding>]
        #
        def call(window)
          window.request_traces
                .select { |trace| database_bound?(trace) }
                .filter_map { |trace| build_finding(trace, window) }
                .group_by(&:fingerprint)
                .values
                .map(&:first)
        end

      private

        # Whether the database accounts for most of this request.
        #
        # @param trace [Observatory::RequestTrace] the trace to test.
        #
        # @return [Boolean]
        #
        def database_bound?(trace)
          return false if trace.duration_ms.to_f < (config.slow_request_threshold * 1_000)
          return false if trace.duration_ms.to_f <= 0

          (trace.db_duration_ms.to_f / trace.duration_ms) >= config.slow_query_share
        end

        # @param trace [Observatory::RequestTrace] the database-bound trace.
        # @param window [Observatory::Analysis::Window] the surrounding measurements.
        #
        # @return [Observatory::Analysis::Finding, nil]
        #
        def build_finding(trace, window)
          group = trace.query_groups.max_by(&:duration_ms)
          return nil if group.nil?

          # The finding is about a *statement*, not a request, so it is keyed on
          # the query shape — twenty requests hitting the same slow statement are
          # one problem, not twenty.
          #
          share = group.duration_ms.to_f / trace.duration_ms

          finding(
            title:      "Slow SQL on #{trace.endpoint}",
            severity:   share >= 0.8 ? :critical : :warning,
            confidence: :high,
            component:  "mysql",
            constrained_resource: "database execution time",
            primary_contributor:  trace.endpoint,
            fingerprint: "#{key}:#{group.fingerprint_digest}",
            failure_mode: "One query shape accounts for most of the request's duration. Unlike a repeated-" \
                          "lookup explosion, the database really is executing this work.",
            impact: "#{duration(group.duration_ms)} of a #{duration(trace.duration_ms)} request, " \
                    "holding a Puma thread throughout.",
            recommended_action: "EXPLAIN this statement. Check for a missing index, an unbounded scan or a " \
                                "join whose row count has grown.",
            started_at: trace.started_at,
            supporting: supporting(trace, group, share),
            contradicting: contradicting(trace, window),
            subjects: { request_traces: [ trace.id ], query_groups: [ group.id ] },
          )
        end

        # @param trace [Observatory::RequestTrace] the trace.
        # @param group [Observatory::QueryGroup] the dominant shape.
        # @param share [Float] its share of the request's duration.
        #
        # @return [Array<Observatory::Analysis::Evidence>]
        #
        def supporting(trace, group, share)
          [
            evidence_for("Time in ActiveRecord",
                         "#{duration(trace.db_duration_ms)} of #{duration(trace.duration_ms)} " \
                         "(#{percentage(trace.db_duration_ms / trace.duration_ms)})", trace:),
            evidence_for("Queries issued", count(trace.query_count), trace:),
            evidence_for("Slowest query shape",
                         "#{duration(group.duration_ms)} across #{count(group.count)} execution(s) " \
                         "(#{percentage(share)} of the request)"),
            evidence_for("Slowest single execution", duration(group.max_duration_ms)),
            evidence_for("Statement", group.sample_sql.to_s[0, 200]),
          ]
        end

        # @param trace [Observatory::RequestTrace] the trace.
        # @param window [Observatory::Analysis::Window] the surrounding measurements.
        #
        # @return [Array<Observatory::Analysis::Evidence>]
        #
        def contradicting(trace, window)
          items = [
            evidence_against("Served from the ActiveRecord query cache", percentage(trace.cached_query_ratio),
                             trace:),
            evidence_against("Estimated GC during the request", duration(trace.estimated_gc_time_ms), trace:),
          ]

          mysql = window.latest_dependency(DependencySample::MYSQL)
          if mysql
            items << evidence_against("MySQL connections in use",
                                      "#{mysql.metric("connections")} of #{mysql.metric("max_connections")}")
          end

          items
        end
      end
    end
  end
end
