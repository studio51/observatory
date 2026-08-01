# frozen_string_literal: true

module Observatory
  module Analysis
    module Rules

      # A route got materially worse shortly after a deployment.
      #
      # ## Correlation, stated as correlation
      #
      # The brief is explicit and it is right: following a deploy is not being
      # caused by it. Traffic changes, crawlers arrive, data grows, and something
      # is always the most recent deploy.
      #
      # So this rule never says "the deploy caused it". It says the route changed,
      # by how much, and that a deploy happened this long before — at medium
      # confidence, with the deploy's own details as evidence the reader can
      # weigh. That is genuinely useful (it is where anyone would look first) and
      # it is honest about what was measured.
      #
      # Confidence rises to high only when the regression is large *and* began
      # within a few minutes of the cutover, which is the pattern a coincidence
      # rarely produces.
      #
      class DeploymentRegression < Rule
        MINIMUM_REQUESTS = 20
        CORRELATION_WINDOW = 1_800   # 30 minutes
        TIGHT_WINDOW = 300           # 5 minutes: close enough to raise confidence
        REGRESSION_MULTIPLE = 2.0

        # @return [Symbol]
        #
        def key = :deployment_regression

        # @param window [Observatory::Analysis::Window] the measurements to reason over.
        #
        # @return [Array<Observatory::Analysis::Finding>]
        #
        def call(window)
          deployment = recent_deployment(window)
          return [] if deployment.nil?

          window.routes.filter_map { |endpoint, current| build_finding(endpoint, current, deployment, window) }
        end

      private

        # @param window [Observatory::Analysis::Window] the surrounding measurements.
        #
        # @return [Observatory::Deployment, nil] the deploy that could correlate.
        #
        def recent_deployment(window)
          Instrumentation.suppress do
            Deployment.where(deployed_at: (window.from - CORRELATION_WINDOW)..window.to)
                      .recent_first
                      .first
          end
        end

        # @param endpoint [String] the route template.
        # @param current [Hash] its measurements in this window.
        # @param deployment [Observatory::Deployment] the correlating deploy.
        # @param window [Observatory::Analysis::Window] the surrounding measurements.
        #
        # @return [Observatory::Analysis::Finding, nil]
        #
        def build_finding(endpoint, current, deployment, window)
          return nil if current[:count] < MINIMUM_REQUESTS

          baseline = window.baseline_for(endpoint)
          return nil if baseline.nil? || baseline[:count] < MINIMUM_REQUESTS

          changes = material_changes(current, baseline)
          return nil if changes.empty?

          elapsed = (window.from - deployment.deployed_at).to_f

          finding(
            title:      "#{endpoint} regressed after deploying #{deployment.release}",
            severity:   :warning,
            confidence: elapsed <= TIGHT_WINDOW && changes.size >= 2 ? :high : :medium,
            component:  "application",
            constrained_resource: "request threads",
            primary_contributor:  endpoint,
            failure_mode: "This route's cost changed materially, and a deployment happened " \
                          "#{humanise(elapsed)} before the window. This is a correlation in time, not a " \
                          "demonstrated cause.",
            impact: "Requests to #{endpoint} now cost #{duration(current[:average_duration_ms])} on average.",
            recommended_action: "Compare #{deployment.release} against #{deployment.previous&.release || "the " \
                                "previous release"} for changes touching this route, then confirm by " \
                                "measuring rather than by reading the diff.",
            started_at: deployment.deployed_at,
            supporting: changes + [
              evidence_for("Deployment", deployment.label, observed_at: deployment.deployed_at),
              evidence_for("Time between deploy and window", humanise(elapsed)),
              evidence_for("Requests measured", "#{count(current[:count])} now, " \
                                                "#{count(baseline[:count])} in the baseline"),
            ],
            contradicting: contradicting(elapsed, current, baseline),
            subjects: { endpoint: endpoint, deployment_id: deployment.id },
          )
        end

        # The measurements that moved by more than the regression multiple.
        #
        # @param current [Hash] this window's measurements.
        # @param baseline [Hash] the route's usual measurements.
        #
        # @return [Array<Observatory::Analysis::Evidence>]
        #
        def material_changes(current, baseline)
          [
            [ "Average duration", current[:average_duration_ms], baseline[:average_duration_ms], :duration ],
            [ "Queries per request", current[:query_count_sum].to_f / current[:count],
              baseline[:average_query_count], :count, ],
            [ "Estimated allocations per request", current[:allocation_sum].to_f / current[:count],
              baseline[:average_allocations], :count, ],
          ].filter_map do |label, now, before, format|
            multiple = multiple_of(now, before)
            next if multiple.nil? || multiple < REGRESSION_MULTIPLE

            evidence_for("#{label} (#{multiple}x)", render(now, format), baseline: render(before, format))
          end
        end

        # @param elapsed [Float] seconds between the deploy and the window.
        # @param current [Hash] this window's measurements.
        # @param baseline [Hash] the route's usual measurements.
        #
        # @return [Array<Observatory::Analysis::Evidence>]
        #
        def contradicting(elapsed, current, baseline)
          items = [
            evidence_against("Traffic to this route",
                             count(current[:count]), baseline: count(baseline[:count])),
          ]

          if elapsed > TIGHT_WINDOW
            items << evidence_against("Gap between the deploy and the change", humanise(elapsed))
          end

          crawlers = current[:crawler_count].to_i
          if crawlers.positive?
            items << evidence_against("Automated requests in this window",
                                      "#{count(crawlers)} of #{count(current[:count])} — traffic mix may " \
                                      "have changed independently of the deploy")
          end

          items
        end

        # @param value [Numeric] the measurement.
        # @param format [Symbol] :duration or :count.
        #
        # @return [String]
        #
        def render(value, format)
          format == :duration ? duration(value) : count(value.round)
        end

        # @param seconds [Float] a duration.
        #
        # @return [String]
        #
        def humanise(seconds)
          return "unknown" if seconds.nil?

          ActiveSupport::Duration.build(seconds.abs.to_i).inspect
        end
      end
    end
  end
end
