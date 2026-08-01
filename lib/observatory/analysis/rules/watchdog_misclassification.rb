# frozen_string_literal: true

module Observatory
  module Analysis
    module Rules

      # The supervisor restarted a process that was alive and merely full.
      #
      # ## Why this is worth its own finding
      #
      # {HealthCheckBlocked} says the probes could not get through. This says
      # what was *done about it*, and that the action was wrong — which is a
      # different fact and a more actionable one, because it is about the
      # supervisor's policy rather than the application's workload.
      #
      # The evidence is unambiguous when it exists: the process was alive (it was
      # reporting samples), every thread was busy, long-running requests were in
      # flight, and the supervisor issued a restart anyway. Nothing about that
      # sequence required a restart, and the restart dropped every in-flight
      # request for nothing.
      #
      # ## What it is for
      #
      # Advisory mode writes both what the supervisor did and what Observatory
      # would have done. This rule counts the disagreements. That count is the
      # evidence base for eventually changing the restart policy — the brief is
      # explicit that behaviour must not change until the classification has been
      # observed to be right, and this is how "observed to be right" gets
      # measured rather than asserted.
      #
      class WatchdogMisclassification < Rule

        # @return [Symbol]
        #
        def key = :watchdog_misclassification

        # @param window [Observatory::Analysis::Window] the measurements to reason over.
        #
        # @return [Array<Observatory::Analysis::Finding>]
        #
        def call(window)
          misclassified = window.watchdog_events.select { |event| misclassified?(event, window) }
          return [] if misclassified.empty?

          [ build_finding(misclassified, window) ]
        end

      private

        # Whether this event restarted a living, saturated process.
        #
        # All three conditions are required. A restart of a genuinely dead
        # process is correct behaviour; a restart during saturation where the
        # process had stopped responding to its own sampler might genuinely have
        # been a deadlock. Only the full conjunction is a misclassification.
        #
        # @param event [Observatory::WatchdogEvent] the supervisor action.
        # @param window [Observatory::Analysis::Window] the surrounding measurements.
        #
        # @return [Boolean]
        #
        def misclassified?(event, window)
          return false if event.action_taken.blank?
          return false unless event.process_alive?
          return false unless saturated_at?(event, window)

          true
        end

        # @param event [Observatory::WatchdogEvent] the supervisor action.
        # @param window [Observatory::Analysis::Window] the surrounding measurements.
        #
        # @return [Boolean] whether every thread was busy when the action was taken.
        #
        def saturated_at?(event, window)
          return true if event.busy_threads.to_i.positive? && event.busy_threads.to_i >= event.max_threads.to_i

          span = (event.occurred_at - 60)..(event.occurred_at + 30)

          window.web_samples.any? { |sample| sample.saturated? && span.cover?(sample.sampled_at) }
        end

        # @param events [Array<Observatory::WatchdogEvent>] the misclassified actions.
        # @param window [Observatory::Analysis::Window] the surrounding measurements.
        #
        # @return [Observatory::Analysis::Finding]
        #
        def build_finding(events, window)
          latest = events.max_by(&:occurred_at)

          finding(
            title:      "Watchdog restarted a saturated but living process",
            severity:   :warning,
            confidence: :high,
            component:  "supervisor",
            constrained_resource: "request threads",
            primary_contributor:  window.dominant_route&.first,
            failure_mode: "The supervisor treats consecutive failed /up probes as process death. A process " \
                          "whose threads are all occupied fails those probes while being entirely alive, so " \
                          "the trigger cannot distinguish saturation from death.",
            impact: "#{events.size} restart(s) dropped every in-flight request without addressing the " \
                    "workload, so the condition recurs as soon as traffic resumes.",
            recommended_action: "Before restarting on failed probes, check whether the process is reporting " \
                                "and whether its threads are all busy. If both, capture the long-running " \
                                "requests and let them finish — restarting will not help.",
            started_at: events.map(&:occurred_at).min,
            supporting: supporting(events, latest),
            contradicting: contradicting(latest, window),
            subjects: { watchdog_events: events.map(&:id) },
          )
        end

        # @param events [Array<Observatory::WatchdogEvent>] the misclassified actions.
        # @param latest [Observatory::WatchdogEvent] the most recent of them.
        #
        # @return [Array<Observatory::Analysis::Evidence>]
        #
        def supporting(events, latest)
          items = [
            evidence_for("Restarts of a living process", events.size, observed_at: latest.occurred_at),
            evidence_for("Trigger", latest.trigger),
            evidence_for("Action taken", latest.action_taken),
            evidence_for("Busy threads at that moment",
                         "#{latest.busy_threads} of #{latest.max_threads}"),
          ]

          if latest.failed_probe_count
            items << evidence_for("Consecutive failed probes", latest.failed_probe_count)
          end

          if latest.long_running_requests.to_i.positive?
            items << evidence_for("Long-running requests in flight", latest.long_running_requests)
          end

          if latest.recommended_action.present?
            items << evidence_for("Observatory recommended instead", latest.recommended_action)
          end

          items
        end

        # The proof the process was alive.
        #
        # @param latest [Observatory::WatchdogEvent] the most recent action.
        # @param window [Observatory::Analysis::Window] the surrounding measurements.
        #
        # @return [Array<Observatory::Analysis::Evidence>]
        #
        def contradicting(latest, window)
          span = (latest.occurred_at - 60)..(latest.occurred_at + 30)
          reporting = window.web_samples.select { |sample| span.cover?(sample.sampled_at) }

          [
            evidence_against("Process was alive when the action was taken", latest.process_alive? ? "yes" : "no"),
            evidence_against("Workers still reporting samples", reporting.map(&:process_id).uniq.size),
            evidence_against("Backlog measured", reporting.filter_map(&:backlog).max || "not measurable"),
          ]
        end
      end
    end
  end
end
