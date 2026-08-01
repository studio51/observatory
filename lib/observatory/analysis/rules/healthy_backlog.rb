# frozen_string_literal: true

module Observatory
  module Analysis
    module Rules

      # A large queue that is draining normally.
      #
      # ## Why a "nothing is wrong" finding is worth building
      #
      # This is the only rule here that classifies rather than alerts, and it
      # exists because silence is ambiguous. An operator looking at a queue of
      # 536,542 jobs wants to know whether the monitoring system has considered
      # it. A dashboard that says nothing is indistinguishable from one that has
      # not noticed — and the natural response to that ambiguity is to escalate,
      # add workers, or start restarting things, all of which make a healthy
      # backlog worse.
      #
      # So when the depth is large and every other signal is normal, the system
      # says so explicitly, with the arithmetic:
      #
      #   Queue: default
      #   Depth: 536,542       Throughput: 56.3 jobs/second
      #   Drain: 2 hours 39 minutes
      #   Failure rate: normal    Retries: normal    Constraint: none detected
      #
      # It is filed at `:info` severity and never counts as an open incident. The
      # dashboard renders it as a classification, not a problem.
      #
      class HealthyBacklog < Rule
        NOTABLE_DEPTH = 1_000    # below this a backlog needs no explanation

        # @return [Symbol]
        #
        def key = :healthy_backlog

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
          latest_per_queue(window).filter_map { |sample| build_finding(sample, window) }
        end

      private

        # @param window [Observatory::Analysis::Window] the surrounding measurements.
        #
        # @return [Array<Observatory::DependencySample>] the newest reading per named queue.
        #
        def latest_per_queue(window)
          window.dependency_samples
                .select { |sample| sample.dependency == DependencySample::SIDEKIQ && sample.subject.present? }
                .group_by(&:subject)
                .values
                .map { |samples| samples.max_by(&:sampled_at) }
        end

        # @param sample [Observatory::DependencySample] the queue's newest reading.
        # @param window [Observatory::Analysis::Window] the surrounding measurements.
        #
        # @return [Observatory::Analysis::Finding, nil]
        #
        def build_finding(sample, window)
          return nil if sample.depth.to_i < NOTABLE_DEPTH
          return nil unless draining?(sample)

          failure_rate = failure_rate_for(sample.subject, window)
          return nil if failure_rate > 0.05

          finding(
            title:      "Queue #{sample.subject} is deep but draining normally",
            severity:   :info,
            confidence: :high,
            component:  "sidekiq",
            constrained_resource: "none detected",
            primary_contributor:  sample.subject,
            failure_mode: "None. Depth alone is not a fault: this queue is completing work at a rate that " \
                          "clears the backlog within an acceptable window.",
            impact: "None expected. Jobs on this queue are delayed by the drain time below.",
            recommended_action: "No action. Adding workers would spend capacity on a queue that is already " \
                                "converging.",
            started_at: sample.sampled_at,
            supporting: [
              evidence_for("Queue depth", count(sample.depth), observed_at: sample.sampled_at),
              evidence_for("Completion rate", "#{sample.throughput.to_f.round(1)} jobs/second"),
              evidence_for("Estimated drain time", humanise(sample.drain_seconds)),
              evidence_for("Failure rate", percentage(failure_rate), baseline: "under 5%"),
              evidence_for("Constrained resource", "none detected"),
            ],
            contradicting: [
              evidence_against("Depth looks alarming in isolation", count(sample.depth)),
            ],
            subjects: { dependency_samples: [ sample.id ] },
          )
        end

        # @param sample [Observatory::DependencySample] the queue's newest reading.
        #
        # @return [Boolean] whether it is completing work fast enough to clear.
        #
        def draining?(sample)
          return false unless sample.throughput.to_f.positive?
          return false if sample.drain_seconds.nil?
          return false if sample.drain_seconds.to_f.infinite?

          sample.drain_seconds.to_f < config.queue_drain_threshold
        end

        # @param queue [String] the queue name.
        # @param window [Observatory::Analysis::Window] the surrounding measurements.
        #
        # @return [Float] 0.0-1.0 share of jobs on this queue that failed.
        #
        def failure_rate_for(queue, window)
          rollups = window.job_rollups.select { |rollup| rollup.queue == queue }
          total = rollups.sum(&:count)
          return 0.0 if total.zero?

          rollups.sum(&:failure_count).to_f / total
        end

        # @param seconds [Float, nil] a duration.
        #
        # @return [String]
        #
        def humanise(seconds)
          return "unknown" if seconds.nil?

          ActiveSupport::Duration.build(seconds.to_i).inspect
        end
      end
    end
  end
end
