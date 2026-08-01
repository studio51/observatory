# frozen_string_literal: true

module Observatory
  module Analysis
    module Rules

      # The rule this whole system was built around.
      #
      # ## What it detects
      #
      # A request that is slow, issued an enormous number of ActiveRecord
      # lookups, had most of them served by the *query cache*, and spent
      # comparatively little time in the database. That combination has exactly
      # one cause: application code issuing the same lookup over and over inside
      # a loop.
      #
      # ## Why nothing else catches it
      #
      # The ActiveRecord query cache is a hash in process memory. A cache hit
      # never reaches MySQL, never appears in the slow query log, never consumes
      # a connection and never moves a single database metric. So while a request
      # performs 84,079 cached lookups over fourteen seconds, MySQL's dashboard
      # is flat and its operator is confident the database is fine — which it is.
      # The time goes into Ruby: building the query object, hashing the cache
      # key, allocating the result, and collecting the garbage from all of it.
      #
      # ## What the finding says, and does not say
      #
      # It does not say query caching is bad. Query caching is doing exactly what
      # it was designed to do, and it is *saving* this request from being far
      # worse. The finding says that caching is **hiding repeated application
      # work from database-level monitoring**, and that the fix is in the
      # application, not the database.
      #
      # Deliberately distinct from {SlowSql}: 41,722 fast lookups and one
      # 28.9-second lookup are both "the database is involved", and merging them
      # into a single "database slow" warning would send someone to tune indexes
      # when the problem is a loop.
      #
      class CachedQueryExplosion < Rule

        # @return [Symbol]
        #
        def key = :cached_query_explosion

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

        # Whether one trace shows the signature.
        #
        # All four conditions, together. Any one alone is ordinary: a slow
        # request might be waiting on an API, a query-heavy request might be a
        # legitimate report, a high cached ratio is usually a *good* sign, and low
        # database time is normally excellent news. It is the conjunction that
        # can only mean one thing.
        #
        # @param trace [Observatory::RequestTrace] the trace to test.
        #
        # @return [Boolean]
        #
        def explosive?(trace)
          trace.query_count >= config.high_query_count &&
            trace.cached_query_ratio >= config.high_cached_query_ratio &&
            trace.duration_ms >= (config.slow_request_threshold * 1_000) &&
            database_is_not_the_problem?(trace)
        end

        # Whether the database's share of the request is small enough that it
        # cannot be the explanation.
        #
        # The discriminator between this rule and {SlowSql}. If ActiveRecord time
        # accounts for most of the request, the database *is* the story and this
        # rule should stay quiet.
        #
        # @param trace [Observatory::RequestTrace] the trace to test.
        #
        # @return [Boolean]
        #
        def database_is_not_the_problem?(trace)
          return true if trace.duration_ms.to_f <= 0

          (trace.db_duration_ms.to_f / trace.duration_ms) < 0.5
        end

        # @param endpoint [String] the route template.
        # @param traces [Array<Observatory::RequestTrace>] its offending traces.
        # @param window [Observatory::Analysis::Window] the surrounding measurements.
        #
        # @return [Observatory::Analysis::Finding]
        #
        def build_finding(endpoint, traces, window)
          worst = traces.max_by(&:query_count)
          group = worst.dominant_query_group
          baseline = window.baseline_for(endpoint)

          finding(
            title:    "Repeated ActiveRecord lookups on #{endpoint}",
            severity: severity_for(worst),
            confidence: :high,
            component: "application",
            constrained_resource: "request threads",
            primary_contributor:  endpoint,
            failure_mode: "Repeated ActiveRecord lookups inside a loop. Most are served by the " \
                          "ActiveRecord query cache, so the cost is Ruby-side and invisible to MySQL.",
            impact: impact_for(traces),
            recommended_action: recommendation_for(group),
            started_at: traces.map(&:started_at).min,
            supporting: supporting(traces, worst, group, baseline),
            contradicting: contradicting(worst, window),
            subjects: { request_traces: traces.map(&:id) },
          )
        end

        # @param traces [Array<Observatory::RequestTrace>] the offending traces.
        # @param worst [Observatory::RequestTrace] the worst of them.
        # @param group [Observatory::QueryGroup, nil] its dominant query shape.
        # @param baseline [Hash, nil] the route's usual measurements.
        #
        # @return [Array<Observatory::Analysis::Evidence>]
        #
        def supporting(traces, worst, group, baseline)
          items = [
            evidence_for("Requests affected", traces.size, observed_at: worst.started_at),
            evidence_for("ActiveRecord lookups per request", lookup_range(traces),
                         baseline: baseline && count(baseline[:average_query_count].round),
                         trace: worst),
            evidence_for("Served from the ActiveRecord query cache", percentage(worst.cached_query_ratio),
                         baseline: baseline && percentage(baseline[:cached_query_ratio]), trace: worst),
            evidence_for("Request duration", duration(worst.duration_ms),
                         baseline: baseline && duration(baseline[:average_duration_ms]), trace: worst),
            evidence_for("Time in ActiveRecord", "#{duration(worst.db_duration_ms)} of " \
                                                 "#{duration(worst.duration_ms)} " \
                                                 "(#{percentage(worst.db_duration_ms / worst.duration_ms)})",
                         trace: worst),
            evidence_for("Time unaccounted for by any measured subsystem",
                         "#{duration(worst.unaccounted_ms)} (#{percentage(worst.unaccounted_ratio)})",
                         trace: worst),
          ]

          if group
            items << evidence_for("Most repeated query shape",
                                  "#{count(group.count)} executions of one normalised statement",
                                  details: { fingerprint: group.fingerprint })
            items << evidence_for("Representative statement", group.sample_sql.to_s[0, 200])
            items << evidence_for("Application call site", group.call_site) if group.call_site
          end

          allocations = multiple_of(worst.allocation_delta, baseline&.dig(:average_allocations))
          if allocations && allocations > 2
            items << evidence_for("Estimated allocations", "#{count(worst.allocation_delta)} " \
                                                           "(#{allocations}x baseline, process-wide estimate)")
          end

          if worst.estimated_gc_time_ms.to_f.positive?
            items << evidence_for("Estimated GC during the request",
                                  "#{duration(worst.estimated_gc_time_ms)} " \
                                  "(#{percentage(worst.estimated_gc_ratio)}, process-wide estimate)")
          end

          items
        end

        # The measurements that argue against a database explanation.
        #
        # These are the most useful lines in the finding. Without them the reader
        # sees "lots of queries" and goes to look at MySQL, which is exactly the
        # wrong place and exactly what happened during the incident that prompted
        # this system.
        #
        # @param worst [Observatory::RequestTrace] the worst trace.
        # @param window [Observatory::Analysis::Window] the surrounding measurements.
        #
        # @return [Array<Observatory::Analysis::Evidence>]
        #
        def contradicting(worst, window)
          items = [
            evidence_against("Queries the database actually executed",
                             "#{count(worst.executed_query_count)} of #{count(worst.query_count)}",
                             trace: worst),
          ]

          mysql = window.latest_dependency(DependencySample::MYSQL)
          if mysql
            items << evidence_against("MySQL running threads", mysql.metric("running_threads"))
            items << evidence_against("MySQL connections in use",
                                      "#{mysql.metric("connections")} of #{mysql.metric("max_connections")}")
            items << evidence_against("MySQL row-lock waits", mysql.metric("row_lock_waits"))
          end

          if worst.pool_waiting
            items << evidence_against("Threads waiting for a database connection", worst.pool_waiting,
                                      trace: worst)
          end

          redis = window.latest_dependency(DependencySample::REDIS)
          items << evidence_against("Redis utilisation", percentage(redis.utilisation)) if redis&.utilisation

          items
        end

        # @param traces [Array<Observatory::RequestTrace>] the offending traces.
        #
        # @return [String] e.g. "59,349-86,359".
        #
        def lookup_range(traces)
          counts = traces.map(&:query_count)
          return count(counts.first) if counts.uniq.size == 1

          "#{count(counts.min)}-#{count(counts.max)}"
        end

        # @param worst [Observatory::RequestTrace] the worst trace.
        #
        # @return [Symbol] :critical or :warning.
        #
        def severity_for(worst)
          return :critical if worst.query_count >= config.extreme_query_count
          return :critical if worst.duration_ms >= (config.extreme_request_threshold * 1_000)

          :warning
        end

        # @param traces [Array<Observatory::RequestTrace>] the offending traces.
        #
        # @return [String]
        #
        def impact_for(traces)
          seconds = traces.sum(&:thread_seconds).round(1)

          "#{traces.size} request(s) consumed #{seconds} thread-seconds of Puma request capacity. " \
            "Production has #{Capacity.max_threads} threads per worker, so requests of this shape " \
            "exhaust capacity long before CPU, MySQL or Redis show any strain."
        end

        # @param group [Observatory::QueryGroup, nil] the dominant query shape.
        #
        # @return [String]
        #
        def recommendation_for(group)
          base = "Find the loop issuing this statement and hoist the lookup out of it — preload the " \
                 "association, batch the ids, or memoise the result."

          return base if group.nil? || group.call_site.blank?

          "#{base} The call site sampled during the incident was #{group.call_site}."
        end
      end
    end
  end
end
