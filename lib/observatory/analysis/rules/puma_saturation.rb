# frozen_string_literal: true

module Observatory
  module Analysis
    module Rules

      # Puma has run out of request threads.
      #
      # ## The distinction this rule exists to make
      #
      # "Busy" and "saturated" are not the same thing, and a process with every
      # thread occupied is not a process that has died. Production here has
      # fifteen request threads — three workers of five — and once all fifteen
      # are held, *nothing else can be served*, including `/up`. From outside,
      # that is indistinguishable from a crashed master: `curl` times out either
      # way.
      #
      # `bin/dev`'s watchdog cannot tell the difference and restarts the process.
      # Every in-flight request is dropped, the workload that caused the
      # saturation is unaffected, and ninety seconds later it happens again.
      #
      # This rule provides the evidence that distinguishes the two, and it does
      # it from measurements the outside view does not have: how many threads
      # were busy, how long they had been busy, whether a backlog existed, and —
      # crucially — *which requests were holding them*.
      #
      # ## Backlog: unknown is not zero
      #
      # Saturation requires busy == max **and** something waiting. Where the
      # capacity adapter could not read a backlog it reports nil, and this rule
      # treats nil as "unknown" rather than "no backlog" — falling back to
      # sustained full occupancy, which is weaker evidence and is reported at
      # lower confidence. Treating an unmeasured backlog as zero would suppress
      # the finding in exactly the deployment where it matters most.
      #
      class PumaSaturation < Rule

        # @return [Symbol]
        #
        def key = :puma_saturation

        # @param window [Observatory::Analysis::Window] the measurements to reason over.
        #
        # @return [Array<Observatory::Analysis::Finding>]
        #
        def call(window)
          saturated = window.web_samples.select { |sample| sample.saturated? }
          return [] if saturated.empty?

          duration = saturation_duration(saturated)
          return [] if duration < config.puma_saturation_duration

          [ build_finding(saturated, duration, window) ]
        end

      private

        # @param samples [Array<Observatory::ProcessSample>] the saturated samples.
        # @param seconds [Float] how long saturation persisted.
        # @param window [Observatory::Analysis::Window] the surrounding measurements.
        #
        # @return [Observatory::Analysis::Finding]
        #
        def build_finding(samples, seconds, window)
          contributor = window.dominant_route
          endpoint = contributor&.first

          finding(
            title:      "Puma request capacity exhausted",
            severity:   :critical,
            confidence: confidence_for(samples),
            component:  "puma",
            constrained_resource: "request threads",
            primary_contributor:  endpoint,
            failure_mode: failure_mode_for(window, endpoint),
            impact: impact_for(window),
            recommended_action: "Reduce the per-request cost of #{endpoint || "the dominant route"} before " \
                                "adding threads. More threads on the same workload buys seconds, not capacity.",
            started_at: samples.map(&:sampled_at).min,
            ended_at:   samples.map(&:sampled_at).max,
            supporting: supporting(samples, seconds, window, contributor),
            contradicting: contradicting(window),
            subjects: { process_samples: samples.map(&:id) },
          )
        end

        # @param samples [Array<Observatory::ProcessSample>] the saturated samples.
        # @param seconds [Float] how long saturation persisted.
        # @param window [Observatory::Analysis::Window] the surrounding measurements.
        # @param contributor [Array(String, Hash), nil] the dominant route and its measurements.
        #
        # @return [Array<Observatory::Analysis::Evidence>]
        #
        def supporting(samples, seconds, window, contributor)
          worst = samples.max_by { |sample| sample.busy_threads.to_i }

          items = [
            evidence_for("Busy request threads",
                         "#{worst.busy_threads} of #{worst.max_threads}", observed_at: worst.sampled_at),
            evidence_for("Saturation sustained for", "#{seconds.round}s",
                         baseline: "threshold #{config.puma_saturation_duration.round}s"),
            evidence_for("Workers reporting saturation",
                         "#{samples.map(&:process_id).uniq.size} of " \
                         "#{window.web_samples.map(&:process_id).uniq.size}"),
            evidence_for("Capacity measured by", worst.capacity_source),
          ]

          backlog = samples.filter_map(&:backlog).max
          items << if backlog
            evidence_for("Requests waiting for a thread", backlog)
          else
            evidence_for("Requests waiting for a thread",
                         "not measurable in this deployment — no Puma control socket")
          end

          long = long_running(window)
          if long.any?
            items << evidence_for("Concurrent requests over #{config.extreme_request_threshold.round}s",
                                  long.size, trace: long.first)
            items << evidence_for("Longest request", duration(long.first.duration_ms), trace: long.first)
          end

          if contributor
            endpoint, measurements = contributor
            items << evidence_for("Thread-seconds consumed by #{endpoint}",
                                  measurements[:thread_seconds].round(1))
            items << evidence_for("Requests to #{endpoint}", count(measurements[:count]))
          end

          items
        end

        # The healthy-looking measurements, which are what tell an operator where
        # not to look.
        #
        # @param window [Observatory::Analysis::Window] the surrounding measurements.
        #
        # @return [Array<Observatory::Analysis::Evidence>]
        #
        def contradicting(window)
          items = []

          mysql = window.latest_dependency(DependencySample::MYSQL)
          if mysql
            items << evidence_against("MySQL connections in use",
                                      "#{mysql.metric("connections")} of #{mysql.metric("max_connections")}")
            items << evidence_against("MySQL running threads", mysql.metric("running_threads"))
            items << evidence_against("MySQL row-lock waits", mysql.metric("row_lock_waits"))
          end

          redis = window.latest_dependency(DependencySample::REDIS)
          if redis&.utilisation
            items << evidence_against("Redis utilisation", percentage(redis.utilisation))
            items << evidence_against("Redis blocked clients", redis.metric("blocked_clients"))
          end

          waiting = window.web_samples.filter_map(&:pool_waiting).max
          items << evidence_against("Threads waiting for a database connection", waiting) unless waiting.nil?

          alive = window.web_samples.map(&:process_id).uniq.size
          items << evidence_against("Puma worker processes alive", alive)

          items
        end

        # How long saturation persisted.
        #
        # Prefers the per-process stopwatch the capacity register keeps, because
        # it is exact. Falls back to the span between the first and last
        # saturated sample, which is quantised to the sampling interval.
        #
        # @param samples [Array<Observatory::ProcessSample>] the saturated samples.
        #
        # @return [Float] seconds.
        #
        def saturation_duration(samples)
          measured = samples.filter_map(&:saturated_for_seconds).max
          return measured if measured

          (samples.map(&:sampled_at).max - samples.map(&:sampled_at).min).to_f
        end

        # @param samples [Array<Observatory::ProcessSample>] the saturated samples.
        #
        # @return [Symbol] :high when a real backlog was measured, :medium otherwise.
        #
        def confidence_for(samples)
          measured_backlog = samples.any? { |sample| !sample.backlog.nil? && sample.backlog.positive? }
          authoritative = samples.any?(&:authoritative_capacity?)

          measured_backlog && authoritative ? :high : :medium
        end

        # @param window [Observatory::Analysis::Window] the surrounding measurements.
        #
        # @return [Array<Observatory::RequestTrace>] the longest requests, longest first.
        #
        def long_running(window)
          threshold = config.extreme_request_threshold * 1_000

          window.request_traces.select { |trace| trace.duration_ms >= threshold }
        end

        # @param window [Observatory::Analysis::Window] the surrounding measurements.
        # @param endpoint [String, nil] the dominant route.
        #
        # @return [String]
        #
        def failure_mode_for(window, endpoint)
          measurements = endpoint && window.routes[endpoint]

          if measurements && measurements[:cached_query_ratio] > config.high_cached_query_ratio &&
             measurements[:query_count_max] > config.high_query_count
            return "Long-running requests to #{endpoint} occupied every request thread. Those requests " \
                   "are dominated by repeated ActiveRecord lookups served from the query cache, so the " \
                   "cost is Ruby-side and leaves no trace in database monitoring."
          end

          "Long-running requests occupied every available Puma thread, leaving no capacity for new work " \
            "— including health checks."
        end

        # @param window [Observatory::Analysis::Window] the surrounding measurements.
        #
        # @return [String]
        #
        def impact_for(window)
          failed = window.health_checks.count { |check| check.status.to_i >= 400 || check.duration_ms > 1_000 }
          impact = "New requests could not be served while every thread was occupied."

          return impact if failed.zero?

          "#{impact} #{failed} health check(s) could not obtain a thread during this window, which is " \
            "indistinguishable from process death to an external prober."
        end
      end
    end
  end
end
