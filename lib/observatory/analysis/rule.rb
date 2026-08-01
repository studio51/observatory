# frozen_string_literal: true

module Observatory
  module Analysis

    # The base every detection rule inherits from.
    #
    # A rule is deliberately a plain object with one entry point and no state:
    # given a {Window}, return zero or more {Finding}s. That makes each one
    # readable on its own, testable without a database, and — the part that
    # matters most — *arguable*. When someone disagrees with a conclusion the
    # dashboard reached, they should be able to open one file, read forty lines,
    # and see exactly what was compared against what.
    #
    # ## Deterministic, and no language model anywhere near it
    #
    # Every rule here is thresholds and arithmetic over measurements. The brief
    # asks for a deterministic engine before considering anything generative, and
    # that ordering is right for a reason beyond caution: an incident conclusion
    # has to be reproducible. If two people looking at the same window get
    # different explanations, the explanation is worthless — and if the
    # explanation cannot be traced to a number, nobody can check it.
    #
    # ## Writing a rule
    #
    #   class MyRule < Rule
    #     def key = :my_rule
    #
    #     def call(window)
    #       return [] unless something_is_wrong(window)
    #
    #       [ finding(title: "…", severity: :warning, confidence: :high,
    #                 constrained_resource: "…",
    #                 supporting: [ evidence_for("Measured", 42) ],
    #                 contradicting: [ evidence_against("Not this", "fine") ]) ]
    #     end
    #   end
    #
    class Rule

      # This rule's identifier, used as the incident's `rule` column and as the
      # configuration key that can disable it.
      #
      # @return [Symbol]
      #
      def key
        raise NotImplementedError, "#{self.class} must define #key"
      end

      # Evaluate the rule against a window.
      #
      # @param _window [Observatory::Analysis::Window] the measurements to reason over.
      #
      # @return [Array<Observatory::Analysis::Finding>]
      #
      def call(_window)
        raise NotImplementedError, "#{self.class} must define #call"
      end

      # Whether this rule should run at all.
      #
      # Overridden by rules that need a dependency the host may not have — the
      # Sidekiq rules are pointless in an application without Sidekiq, and should
      # be absent rather than perpetually finding nothing.
      #
      # @return [Boolean]
      #
      def applicable?
        true
      end

    protected

      # @return [Observatory::Configuration]
      #
      def config
        Observatory.config
      end

      # Build a finding attributed to this rule.
      #
      # @param attributes [Hash] any {Observatory::Analysis::Finding#initialize} keyword.
      #
      # @return [Observatory::Analysis::Finding]
      #
      def finding(**attributes)
        Finding.new(rule: key, **attributes)
      end

      # Build a piece of supporting evidence.
      #
      # @param label [String] what was measured.
      # @param value [Object] the measurement.
      # @param options [Hash] any other {Observatory::Analysis::Evidence#initialize} keyword.
      #
      # @return [Observatory::Analysis::Evidence]
      #
      def evidence_for(label, value, **options)
        Evidence.for(label:, value:, source: key.to_s, **options)
      end

      # Build a piece of contradicting evidence.
      #
      # Reach for this as readily as for {#evidence_for}. The measurements that
      # look healthy during an incident are not noise to be filtered out — they
      # are how an operator knows where *not* to look.
      #
      # @param label [String] what was measured.
      # @param value [Object] the measurement.
      # @param options [Hash] any other {Observatory::Analysis::Evidence#initialize} keyword.
      #
      # @return [Observatory::Analysis::Evidence]
      #
      def evidence_against(label, value, **options)
        Evidence.against(label:, value:, source: key.to_s, **options)
      end

      # Format a ratio as a percentage.
      #
      # @param ratio [Float, nil] 0.0-1.0.
      # @param places [Integer] decimal places.
      #
      # @return [String]
      #
      def percentage(ratio, places = 1)
        return "unknown" if ratio.nil?

        "#{(ratio * 100).round(places)}%"
      end

      # Format a duration in milliseconds for display.
      #
      # @param milliseconds [Float, nil] the duration.
      #
      # @return [String]
      #
      def duration(milliseconds)
        return "unknown" if milliseconds.nil?
        return "#{milliseconds.round}ms" if milliseconds < 1_000

        "#{(milliseconds / 1_000.0).round(2)}s"
      end

      # Format an integer with thousands separators.
      #
      # @param number [Numeric, nil] the value.
      #
      # @return [String]
      #
      def count(number)
        return "unknown" if number.nil?

        number.to_i.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
      end

      # How much larger a value is than its baseline.
      #
      # @param value [Numeric, nil] the current value.
      # @param baseline [Numeric, nil] the usual value.
      #
      # @return [Float, nil] the multiple, or nil when there is no usable baseline.
      #
      def multiple_of(value, baseline)
        return nil if value.nil? || baseline.nil? || baseline.to_f <= 0

        (value.to_f / baseline.to_f).round(1)
      end
    end
  end
end
