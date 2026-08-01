# frozen_string_literal: true

module Observatory
  module Analysis
    module Rules

      # A queue is filling faster than it drains.
      #
      # ## Depth is not the signal
      #
      # A queue with half a million jobs in it is not, by itself, a problem —
      # this application routinely builds one during a full platform sync, and it
      # empties. What matters is whether the drain estimate is *rising*:
      #
      #   536,542 jobs at 56.3/second  ->  drains in 2h39m   healthy
      #   536,542 jobs at 56.3/second, and 3 minutes ago it was 2h10m
      #                                                      not draining
      #
      # So this rule ignores depth entirely and reasons about the trend in the
      # drain estimate across the window. A queue whose estimate keeps climbing
      # will never empty, whatever its current depth; one whose estimate is
      # falling is fine, however alarming its depth looks.
      #
      # {HealthyBacklog} is the companion rule that says so explicitly, because a
      # dashboard that stays silent about a big queue is indistinguishable from
      # one that has not noticed it.
      #
      class QueueDrainRegression < Rule
        MINIMUM_SAMPLES = 3

        # @return [Symbol]
        #
        def key = :queue_drain_regression

        # @return [Boolean]
        #
        def applicable?
          Probes::Sidekiq.available?
        end

        # @param window [Observatory::Analysis::Window] the measurements to reason over.
        #
        # @return [Array<Observatory::Analysis::Finding>]
        #
        def call(window)
          queue_series(window).filter_map { |queue, samples| build_finding(queue, samples) }
        end

      private

        # @param window [Observatory::Analysis::Window] the surrounding measurements.
        #
        # @return [Hash{String => Array<Observatory::DependencySample>}] readings per named queue.
        #
        def queue_series(window)
          window.dependency_samples
                .select { |sample| sample.dependency == DependencySample::SIDEKIQ && sample.subject.present? }
                .group_by(&:subject)
                .select { |_queue, samples| samples.size >= MINIMUM_SAMPLES }
        end

        # @param queue [String] the queue name.
        # @param samples [Array<Observatory::DependencySample>] its readings, oldest first.
        #
        # @return [Observatory::Analysis::Finding, nil]
        #
        def build_finding(queue, samples)
          ordered = samples.sort_by(&:sampled_at)
          first = ordered.first
          last = ordered.last

          return nil unless growing?(ordered)
          return nil if last.drain_seconds.to_f < config.queue_drain_threshold

          finding(
            title:      "Queue #{queue} is not draining",
            severity:   :warning,
            confidence: :medium,
            component:  "sidekiq",
            constrained_resource: "worker capacity",
            primary_contributor:  queue,
            failure_mode: "Jobs are arriving faster than they complete. The estimated drain time is rising " \
                          "across the window, so the backlog will not clear at the current rate.",
            impact: "Work queued on #{queue} is being delayed by a growing margin.",
            recommended_action: "Compare the per-job cost against its baseline before adding workers — a " \
                                "throughput regression and a genuine arrival-rate increase need opposite fixes.",
            started_at: first.sampled_at,
            supporting: [
              evidence_for("Queue depth", count(last.depth), baseline: count(first.depth),
                           observed_at: last.sampled_at),
              evidence_for("Completion rate", "#{last.throughput.to_f.round(1)} jobs/second",
                           baseline: "#{first.throughput.to_f.round(1)} jobs/second"),
              evidence_for("Estimated drain time", humanise(last.drain_seconds),
                           baseline: humanise(first.drain_seconds)),
              evidence_for("Trend across the window", "#{ordered.size} consecutive readings, drain estimate rising"),
            ],
            contradicting: contradicting(last),
            subjects: { dependency_samples: ordered.map(&:id) },
          )
        end

        # Whether the drain estimate rose monotonically enough to be a trend
        # rather than noise.
        #
        # Requires the last reading to exceed the first by a clear margin *and*
        # most consecutive pairs to be rising, so a single spike does not fire it.
        #
        # @param ordered [Array<Observatory::DependencySample>] readings, oldest first.
        #
        # @return [Boolean]
        #
        def growing?(ordered)
          estimates = ordered.filter_map { |sample| sample.drain_seconds&.to_f }
          return false if estimates.size < MINIMUM_SAMPLES
          return false if estimates.first <= 0

          rising = estimates.each_cons(2).count { |before, after| after > before }

          estimates.last > (estimates.first * 1.25) && rising >= (estimates.size / 2)
        end

        # @param sample [Observatory::DependencySample] the latest reading.
        #
        # @return [Array<Observatory::Analysis::Evidence>]
        #
        def contradicting(sample)
          items = []
          items << evidence_against("Jobs are still completing", "#{sample.throughput.to_f.round(1)}/second") if
            sample.throughput.to_f.positive?
          items << evidence_against("Queue is paused", "no") unless sample.metric("paused")

          items
        end

        # @param seconds [Float, nil] a duration.
        #
        # @return [String]
        #
        def humanise(seconds)
          return "unknown" if seconds.nil?
          return "not draining" if seconds.to_f.infinite?

          ActiveSupport::Duration.build(seconds.to_i).inspect
        end
      end
    end
  end
end
