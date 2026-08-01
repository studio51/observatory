# frozen_string_literal: true

module Observatory
  module Analysis

    # Everything the rules need about one slice of time, gathered once.
    #
    # ## Why the rules do not query for themselves
    #
    # Fourteen rules each issuing their own queries would be fourteen times the
    # database work per detection cycle, and — worse — they would disagree.
    # Two rules reading "busy threads" a second apart during a saturation event
    # can get different answers and produce two findings that contradict each
    # other, which is precisely the sort of thing that destroys trust in a
    # monitoring system.
    #
    # So the window loads once, lazily and memoised, and every rule reasons over
    # the same numbers. A detection cycle is therefore a fixed, small number of
    # queries regardless of how many rules are registered.
    #
    # Everything here runs inside {Observatory::Instrumentation.suppress}: the
    # analysis engine reading a hundred trace rows must not appear in its own
    # dashboard as a query-heavy execution.
    #
    class Window
      DEFAULT_SPAN = 300      # five minutes: long enough to see a trend, short enough to be current
      BASELINE_SPAN = 86_400  # what "normal" means, for comparison
      TRACE_LIMIT = 200       # traces loaded per window; the worst ones, not the newest

      attr_reader :from, :to

      # @param from [Time] the start of the window.
      # @param to [Time] the end of the window.
      #
      # @return [Observatory::Analysis::Window]
      #
      def initialize(from: Clock.wall - DEFAULT_SPAN, to: Clock.wall)
        @from = from
        @to = to
        @cache = {}
      end

      # The window's width.
      #
      # @return [Float] seconds.
      #
      def span
        (@to - @from).to_f
      end

      # Request traces retained in this window, worst first.
      #
      # Ordered by duration rather than recency, and capped: a rule looking for a
      # capacity problem wants the expensive requests, and loading the most
      # recent two hundred 12-millisecond requests would find nothing while
      # costing the same.
      #
      # @return [Array<Observatory::RequestTrace>]
      #
      def request_traces
        fetch(:request_traces) do
          RequestTrace.between(@from, @to).order(duration_ms: :desc).limit(TRACE_LIMIT).to_a
        end
      end

      # Job traces retained in this window, worst first.
      #
      # @return [Array<Observatory::JobTrace>]
      #
      def job_traces
        fetch(:job_traces) do
          JobTrace.between(@from, @to).order(duration_ms: :desc).limit(TRACE_LIMIT).to_a
        end
      end

      # Route rollups covering this window — true counts, not a sample.
      #
      # @return [Array<Observatory::RouteRollup>]
      #
      def route_rollups
        fetch(:route_rollups) { RouteRollup.minutes.between(@from, @to).to_a }
      end

      # Job rollups covering this window.
      #
      # @return [Array<Observatory::JobRollup>]
      #
      def job_rollups
        fetch(:job_rollups) { JobRollup.minutes.between(@from, @to).to_a }
      end

      # Process samples in this window.
      #
      # @return [Array<Observatory::ProcessSample>]
      #
      def process_samples
        fetch(:process_samples) { ProcessSample.between(@from, @to).chronological.to_a }
      end

      # Web process samples only.
      #
      # @return [Array<Observatory::ProcessSample>]
      #
      def web_samples
        fetch(:web_samples) { process_samples.select { |sample| sample.role == ProcessSample::WEB } }
      end

      # Dependency samples in this window.
      #
      # @return [Array<Observatory::DependencySample>]
      #
      def dependency_samples
        fetch(:dependency_samples) { DependencySample.between(@from, @to).chronological.to_a }
      end

      # The newest reading for a dependency in this window.
      #
      # @param dependency [String] "mysql", "redis" or "sidekiq".
      # @param subject [String] the queue name, where the dependency has one.
      #
      # @return [Observatory::DependencySample, nil]
      #
      def latest_dependency(dependency, subject: "")
        dependency_samples
          .select { |sample| sample.dependency == dependency && sample.subject == subject }
          .max_by(&:sampled_at)
      end

      # Watchdog events in this window.
      #
      # @return [Array<Observatory::WatchdogEvent>]
      #
      def watchdog_events
        fetch(:watchdog_events) { WatchdogEvent.between(@from, @to).recent_first.to_a }
      end

      # Health-check requests in this window.
      #
      # @return [Array<Observatory::RequestTrace>]
      #
      def health_checks
        fetch(:health_checks) do
          RequestTrace.between(@from, @to).health_checks.recent_first.limit(50).to_a
        end
      end

      # Deployments that started running in this window.
      #
      # @return [Array<Observatory::Deployment>]
      #
      def deployments
        fetch(:deployments) { Deployment.where(deployed_at: @from..@to).recent_first.to_a }
      end

      # The baseline for a route: the same measurements over a much longer span,
      # ending where this window begins.
      #
      # Ending at `@from` rather than at `@to` is deliberate. A baseline that
      # includes the incident is a baseline the incident has already moved, which
      # is how a system convinces itself that a tenfold regression is normal.
      #
      # @param endpoint [String] the route template.
      #
      # @return [Hash{Symbol => Float}, nil] nil when there is not enough history.
      #
      def baseline_for(endpoint)
        baselines[endpoint]
      end

      # Route baselines, loaded in one query for every route in the window.
      #
      # @return [Hash{String => Hash{Symbol => Float}}]
      #
      def baselines
        fetch(:baselines) do
          endpoints = route_rollups.map(&:endpoint).uniq
          next {} if endpoints.empty?

          rows = RouteRollup.minutes
                            .where(endpoint: endpoints)
                            .where(bucket_at: (@from - BASELINE_SPAN)...@from)
                            .group(:endpoint)
                            .pluck(
                              Arel.sql("endpoint"),
                              Arel.sql("SUM(count)"),
                              Arel.sql("SUM(duration_sum_ms)"),
                              Arel.sql("SUM(query_count_sum)"),
                              Arel.sql("SUM(cached_query_count_sum)"),
                              Arel.sql("SUM(allocation_sum)"),
                              Arel.sql("SUM(error_count)"),
                              Arel.sql("SUM(thread_seconds)"),
                            )

          rows.each_with_object({}) do |(endpoint, count, duration, queries, cached, allocations, errors, seconds), out|
            next if count.to_i.zero?

            out[endpoint] = {
              count:              count.to_i,
              average_duration_ms: duration.to_f / count.to_i,
              average_query_count: queries.to_f / count.to_i,
              cached_query_ratio:  (queries.to_i.positive? ? cached.to_f / queries.to_i : 0.0),
              average_allocations: allocations.to_f / count.to_i,
              error_rate:          errors.to_f / count.to_i,
              thread_seconds:      seconds.to_f,
            }
          end
        end
      end

      # Route rollups for this window, summed per endpoint.
      #
      # @return [Hash{String => Hash{Symbol => Object}}]
      #
      def routes
        fetch(:routes) do
          route_rollups.group_by(&:endpoint).transform_values do |rollups|
            count = rollups.sum(&:count)
            queries = rollups.sum(&:query_count_sum)

            {
              count:               count,
              error_count:         rollups.sum(&:error_count),
              duration_sum_ms:     rollups.sum(&:duration_sum_ms),
              duration_max_ms:     rollups.map(&:duration_max_ms).max.to_f,
              average_duration_ms: (count.positive? ? rollups.sum(&:duration_sum_ms) / count : 0.0),
              query_count_sum:     queries,
              query_count_max:     rollups.map(&:query_count_max).max.to_i,
              cached_query_count_sum: rollups.sum(&:cached_query_count_sum),
              cached_query_ratio:  (queries.positive? ? rollups.sum(&:cached_query_count_sum).to_f / queries : 0.0),
              db_duration_sum_ms:  rollups.sum(&:db_duration_sum_ms),
              allocation_sum:      rollups.sum(&:allocation_sum),
              thread_seconds:      rollups.sum(&:thread_seconds),
              crawler_count:       rollups.sum(&:crawler_count),
              histogram:           rollups.each_with_object(Histogram.empty) { |r, h| Histogram.merge(h, r.duration_histogram) },
            }
          end
        end
      end

      # The route that consumed the most request capacity in this window.
      #
      # Thread-seconds, not request count — the ordering that identifies the
      # capacity risk rather than the busiest-looking route.
      #
      # @return [Array(String, Hash), nil] the endpoint and its measurements.
      #
      def dominant_route
        routes.max_by { |_endpoint, measurements| measurements[:thread_seconds] }
      end

      # Load everything the rules will need, in one pass, suppressed.
      #
      # @return [self]
      #
      def preload!
        Instrumentation.suppress do
          request_traces
          job_traces
          route_rollups
          job_rollups
          process_samples
          dependency_samples
          watchdog_events
          health_checks
          baselines
        end

        self
      end

    private

      # @param key [Symbol] the cache slot.
      #
      # @yield loads the value.
      #
      # @return [Object] the memoised value.
      #
      def fetch(key)
        return @cache[key] if @cache.key?(key)

        @cache[key] = Instrumentation.suppress { yield }
      end
    end
  end
end
