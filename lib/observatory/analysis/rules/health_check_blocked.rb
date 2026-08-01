# frozen_string_literal: true

module Observatory
  module Analysis
    module Rules

      # A health check failed because it could not obtain a request thread.
      #
      # ## The most consequential finding in the system
      #
      # `/up` is a full Rails request. It needs a Puma thread like any other. When
      # all fifteen are held by fourteen-second requests, `/up` waits — and
      # `bin/dev`'s watchdog, which allows it five seconds and three consecutive
      # attempts, concludes the process is dead and restarts it.
      #
      # The restart drops every in-flight request, achieves nothing about the
      # workload that caused the saturation, and the whole thing repeats. Worse,
      # the incident is then filed as "Puma crashed", which sends the next
      # investigation in entirely the wrong direction.
      #
      # This rule produces the record that says otherwise: the process was alive,
      # its threads were all busy, these are the requests that were holding them,
      # and the health check was queued behind application traffic rather than
      # unanswered.
      #
      # ## What it will not claim
      #
      # If the process was *not* saturated when the check failed, this rule stays
      # silent. A health check failing on a process with idle threads is a real
      # failure and deserves to be treated as one — misclassifying that as
      # saturation would be the same error in the opposite direction.
      #
      class HealthCheckBlocked < Rule
        SLOW_CHECK_MS = 1_000.0

        # @return [Symbol]
        #
        def key = :health_check_blocked

        # @param window [Observatory::Analysis::Window] the measurements to reason over.
        #
        # @return [Array<Observatory::Analysis::Finding>]
        #
        def call(window)
          troubled = window.health_checks.select { |check| troubled?(check) }
          return [] if troubled.empty?

          saturated = saturated_samples(window, troubled)
          return [] if saturated.empty?

          [ build_finding(troubled, saturated, window) ]
        end

      private

        # @param check [Observatory::RequestTrace] the health-check trace.
        #
        # @return [Boolean] whether it failed or was slow enough to trip a prober.
        #
        def troubled?(check)
          check.status.to_i >= 400 || check.duration_ms.to_f >= SLOW_CHECK_MS
        end

        # Saturation samples overlapping the failed checks.
        #
        # The overlap is what makes the causal claim rather than a coincidence:
        # the process must have been full *at the time*, not merely at some point
        # in the window.
        #
        # @param window [Observatory::Analysis::Window] the surrounding measurements.
        # @param checks [Array<Observatory::RequestTrace>] the failed checks.
        #
        # @return [Array<Observatory::ProcessSample>]
        #
        def saturated_samples(window, checks)
          span = (checks.map(&:started_at).min - 60)..(checks.map(&:started_at).max + 60)

          window.web_samples.select { |sample| sample.saturated? && span.cover?(sample.sampled_at) }
        end

        # @param checks [Array<Observatory::RequestTrace>] the failed checks.
        # @param saturated [Array<Observatory::ProcessSample>] the overlapping saturation.
        # @param window [Observatory::Analysis::Window] the surrounding measurements.
        #
        # @return [Observatory::Analysis::Finding]
        #
        def build_finding(checks, saturated, window)
          worst = saturated.max_by { |sample| sample.busy_threads.to_i }
          long = window.request_traces.select do |trace|
            trace.duration_ms >= (config.extreme_request_threshold * 1_000)
          end

          finding(
            title:      "Health checks blocked by Puma thread exhaustion",
            severity:   :critical,
            confidence: :high,
            component:  "puma",
            constrained_resource: "request threads",
            primary_contributor:  window.dominant_route&.first,
            failure_mode: "The process is alive and every request thread is occupied. /up is an ordinary " \
                          "Rails request and needs a thread like any other, so it waits behind application " \
                          "traffic. To an external prober this is indistinguishable from process death.",
            impact: "A watchdog acting on failed probes alone will restart a living process, dropping every " \
                    "in-flight request without changing the workload that caused the saturation.",
            recommended_action: "Treat this as saturation, not death. Capture the long-running requests, " \
                                "then reduce their cost. Do not add threads: they will fill too.",
            started_at: checks.map(&:started_at).min,
            supporting: supporting(checks, worst, long),
            contradicting: contradicting(window, worst),
            subjects: { request_traces: checks.map(&:id), process_samples: saturated.map(&:id) },
          )
        end

        # @param checks [Array<Observatory::RequestTrace>] the failed checks.
        # @param worst [Observatory::ProcessSample] the most saturated sample.
        # @param long [Array<Observatory::RequestTrace>] the long-running requests.
        #
        # @return [Array<Observatory::Analysis::Evidence>]
        #
        def supporting(checks, worst, long)
          slowest = checks.max_by(&:duration_ms)

          items = [
            evidence_for("Health checks affected", checks.size, observed_at: slowest.started_at),
            evidence_for("Slowest health check", duration(slowest.duration_ms), trace: slowest,
                         baseline: "normally under 20ms"),
            evidence_for("Busy request threads at the time",
                         "#{worst.busy_threads} of #{worst.max_threads}", observed_at: worst.sampled_at),
          ]

          failed = checks.count { |check| check.status.to_i >= 400 }
          items << evidence_for("Health checks that did not return 200", failed) if failed.positive?

          if long.any?
            items << evidence_for("Long-running requests holding threads", long.size, trace: long.first)
            items << evidence_for("Longest of them", duration(long.first.duration_ms), trace: long.first)
          end

          items
        end

        # The evidence that the process was alive — which is the whole point.
        #
        # @param window [Observatory::Analysis::Window] the surrounding measurements.
        # @param worst [Observatory::ProcessSample] the most saturated sample.
        #
        # @return [Array<Observatory::Analysis::Evidence>]
        #
        def contradicting(window, worst)
          items = [
            evidence_against("Puma worker processes reporting", window.web_samples.map(&:process_id).uniq.size,
                             observed_at: worst.sampled_at),
            evidence_against("The process answered its own sampler", "yes — this reading came from it"),
          ]

          mysql = window.latest_dependency(DependencySample::MYSQL)
          items << evidence_against("MySQL running threads", mysql.metric("running_threads")) if mysql

          redis = window.latest_dependency(DependencySample::REDIS)
          items << evidence_against("Redis utilisation", percentage(redis.utilisation)) if redis&.utilisation

          items
        end
      end
    end
  end
end
