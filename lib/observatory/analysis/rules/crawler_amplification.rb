# frozen_string_literal: true

module Observatory
  module Analysis
    module Rules

      # A small number of automated requests is consuming a large share of
      # capacity.
      #
      # ## Why request count is the wrong lens
      #
      # Eighty-three requests an hour from one crawler is nothing. Eighty-three
      # requests that generate 3.2 million queries and six hundred thread-seconds
      # is most of a worker's capacity, and no rate limiter keyed on request
      # count will ever notice it — the crawler is politely under every threshold
      # it is being measured against.
      #
      # This rule measures the *cost* instead: thread-seconds and queries per
      # request, compared against what a human costs on the same routes. When a
      # traffic class is disproportionately expensive, it says so.
      #
      # ## Deliberately about cost, not about blocking
      #
      # The finding does not recommend blocking anyone. A crawler that costs six
      # hundred thread-seconds is usually revealing that a route is expensive
      # per request — the crawler is the *messenger*, and the same cost is being
      # paid by every human who visits that route. The recommendation is to fix
      # the route first.
      #
      class CrawlerAmplification < Rule
        MINIMUM_REQUESTS = 10
        AMPLIFICATION_FACTOR = 3.0

        # @return [Symbol]
        #
        def key = :crawler_amplification

        # @param window [Observatory::Analysis::Window] the measurements to reason over.
        #
        # @return [Array<Observatory::Analysis::Finding>]
        #
        def call(window)
          groups = window.request_traces.reject(&:health_check).group_by(&:traffic_class)
          automated, human = partition(groups)
          return [] if automated.empty? || human.empty?

          automated.filter_map { |traffic_class, traces| build_finding(traffic_class, traces, human, window) }
        end

      private

        # @param groups [Hash{String => Array}] traces grouped by traffic class.
        #
        # @return [Array(Hash, Array)] the automated groups and the human traces.
        #
        def partition(groups)
          automated = groups.select do |traffic_class, traces|
            traffic_class.present? &&
              Traffic::Classifier.automated?(traffic_class.to_sym) &&
              traces.size >= MINIMUM_REQUESTS
          end
          human = groups.values_at("human", "authenticated_user").compact.flatten

          [ automated, human ]
        end

        # @param traffic_class [String] the automated class.
        # @param traces [Array<Observatory::RequestTrace>] its traces.
        # @param human [Array<Observatory::RequestTrace>] traces from people.
        # @param window [Observatory::Analysis::Window] the surrounding measurements.
        #
        # @return [Observatory::Analysis::Finding, nil]
        #
        def build_finding(traffic_class, traces, human, window)
          bot_cost = average(traces, :thread_seconds)
          human_cost = average(human, :thread_seconds)
          multiple = multiple_of(bot_cost, human_cost)
          return nil if multiple.nil? || multiple < AMPLIFICATION_FACTOR

          finding(
            title:      "#{traffic_class.tr("_", " ").capitalize} traffic is disproportionately expensive",
            severity:   :warning,
            confidence: :medium,
            component:  "application",
            constrained_resource: "request threads",
            primary_contributor:  dominant_endpoint(traces),
            failure_mode: "A low request rate is producing a high share of capacity consumption, because " \
                          "each request is expensive rather than because there are many of them.",
            impact: "#{traces.size} requests consumed #{traces.sum(&:thread_seconds).round(1)} thread-seconds.",
            recommended_action: "Reduce the per-request cost of the route being traversed. A human pays the " \
                                "same cost on the same route; the crawler is only the thing that found it.",
            started_at: traces.map(&:started_at).min,
            supporting: [
              evidence_for("Requests", traces.size),
              evidence_for("Distinct routes visited", traces.map(&:endpoint).uniq.size),
              evidence_for("Thread-seconds consumed", traces.sum(&:thread_seconds).round(1)),
              evidence_for("Cost per request", "#{bot_cost.round(2)}s",
                           baseline: "#{human_cost.round(2)}s for a human"),
              evidence_for("Amplification", "#{multiple}x a human request"),
              evidence_for("Queries generated", count(traces.sum(&:query_count))),
              evidence_for("Served from the query cache", percentage(cached_ratio(traces))),
            ],
            contradicting: [
              evidence_against("Share of total requests",
                               percentage(traces.size.to_f / (traces.size + human.size))),
              evidence_against("Error rate for this traffic", percentage(error_rate(traces))),
            ],
            subjects: { request_traces: traces.map(&:id) },
          )
        end

        # @param traces [Array<Observatory::RequestTrace>] the traces.
        # @param attribute [Symbol] the measurement to average.
        #
        # @return [Float]
        #
        def average(traces, attribute)
          return 0.0 if traces.empty?

          traces.sum { |trace| trace.public_send(attribute).to_f } / traces.size
        end

        # @param traces [Array<Observatory::RequestTrace>] the traces.
        #
        # @return [Float] 0.0-1.0.
        #
        def cached_ratio(traces)
          total = traces.sum(&:query_count)
          return 0.0 if total.zero?

          traces.sum(&:cached_query_count).to_f / total
        end

        # @param traces [Array<Observatory::RequestTrace>] the traces.
        #
        # @return [Float] 0.0-1.0.
        #
        def error_rate(traces)
          return 0.0 if traces.empty?

          traces.count { |trace| trace.status.to_i >= 500 }.to_f / traces.size
        end

        # @param traces [Array<Observatory::RequestTrace>] the traces.
        #
        # @return [String, nil] the route costing the most thread-seconds.
        #
        def dominant_endpoint(traces)
          traces.group_by(&:endpoint)
                .max_by { |_endpoint, group| group.sum(&:thread_seconds) }
                &.first
        end
      end
    end
  end
end
