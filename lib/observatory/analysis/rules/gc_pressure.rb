# frozen_string_literal: true

module Observatory
  module Analysis
    module Rules

      # A route is spending a material share of its time in garbage collection.
      #
      # ## Handled with more caution than the other rules
      #
      # CRuby has no per-thread allocation counter, so every allocation and GC
      # figure attached to a request is a process-wide delta shared with up to
      # four other request threads. A request that allocated nothing can be
      # charged for its neighbour's collection.
      #
      # That makes marginal differences meaningless here, so this rule refuses to
      # fire on them. It needs a large multiple over the route's own baseline
      # (which averages the contamination away), a material GC share, and enough
      # requests to rule out a single unlucky sample. The finding then says out
      # loud that the figures are estimates.
      #
      # The useful version of this signal is the one no amount of noise can
      # manufacture: a route whose allocations went up eighteen-fold after a
      # deploy.
      #
      class GcPressure < Rule
        MINIMUM_REQUESTS = 20
        MINIMUM_MULTIPLE = 3.0

        # @return [Symbol]
        #
        def key = :gc_pressure

        # @param window [Observatory::Analysis::Window] the measurements to reason over.
        #
        # @return [Array<Observatory::Analysis::Finding>]
        #
        def call(window)
          window.routes.filter_map { |endpoint, measurements| build_finding(endpoint, measurements, window) }
        end

      private

        # @param endpoint [String] the route template.
        # @param measurements [Hash] its aggregated measurements.
        # @param window [Observatory::Analysis::Window] the surrounding measurements.
        #
        # @return [Observatory::Analysis::Finding, nil]
        #
        def build_finding(endpoint, measurements, window)
          return nil if measurements[:count] < MINIMUM_REQUESTS

          baseline = window.baseline_for(endpoint)
          return nil if baseline.nil? || baseline[:count] < MINIMUM_REQUESTS

          current = measurements[:allocation_sum].to_f / measurements[:count]
          multiple = multiple_of(current, baseline[:average_allocations])
          return nil if multiple.nil? || multiple < MINIMUM_MULTIPLE

          finding(
            title:      "Allocation pressure on #{endpoint}",
            severity:   :warning,
            confidence: :medium,
            component:  "ruby",
            constrained_resource: "CPU and heap",
            primary_contributor:  endpoint,
            failure_mode: "This route is allocating far more objects than it usually does, so more time goes " \
                          "into garbage collection and less into serving the request.",
            impact: "Latency rises with allocation, and the cost is paid by every request the worker serves, " \
                    "not only this route.",
            recommended_action: "Compare against the previous deployment, and look for a change that " \
                                "materialises records the route did not need.",
            started_at: window.from,
            supporting: [
              evidence_for("Estimated allocations per request", count(current.round),
                           baseline: count(baseline[:average_allocations].round)),
              evidence_for("Increase over baseline", "#{multiple}x"),
              evidence_for("Requests in the window", count(measurements[:count])),
              evidence_for("Measurement caveat",
                           "process-wide counters shared by concurrent threads — an estimate, not an " \
                           "attribution"),
            ],
            contradicting: [
              evidence_against("Average duration",
                               duration(measurements[:average_duration_ms]),
                               baseline: duration(baseline[:average_duration_ms])),
            ],
            subjects: { endpoint: endpoint },
          )
        end
      end
    end
  end
end
