# frozen_string_literal: true

module Observatory
  module Analysis

    # One measurement, on one side of a conclusion.
    #
    # Every line under "Evidence" in the dashboard is one of these, and each
    # carries the number it came from. That is deliberate: a conclusion has to be
    # traceable back to something somebody can go and check, not to prose. "MySQL
    # remained idle" is an opinion; "MySQL running threads stayed between 1 and 3
    # against a maximum of 10,000 connections, 54 in use" is a measurement, and
    # only the second survives an argument.
    #
    # Where a baseline exists it is carried too, because "16 of 16 threads busy"
    # means nothing to someone who does not know the usual figure is 4.
    #
    class Evidence
      SUPPORTING    = :supporting
      CONTRADICTING = :contradicting

      attr_reader :stance      # :supporting or :contradicting
      attr_reader :label       # what was measured
      attr_reader :value       # the measurement, already formatted
      attr_reader :baseline    # what it usually is, when known
      attr_reader :source      # which probe or trace produced it
      attr_reader :observed_at # when it was measured
      attr_reader :trace       # the trace it points at, when it points at one
      attr_reader :details     # anything else worth keeping

      # @param label [String] what was measured.
      # @param value [Object] the measurement.
      # @param stance [Symbol] :supporting or :contradicting.
      # @param baseline [Object, nil] the usual value.
      # @param source [String, nil] which probe or trace produced it.
      # @param observed_at [Time, nil] when it was measured.
      # @param trace [Observatory::Record, nil] the trace it points at.
      # @param details [Hash] anything else worth keeping.
      #
      # @return [Observatory::Analysis::Evidence]
      #
      def initialize(label:, value:, stance: SUPPORTING, baseline: nil, source: nil,
                     observed_at: nil, trace: nil, details: {})
        @label = label
        @value = value
        @stance = stance
        @baseline = baseline
        @source = source
        @observed_at = observed_at
        @trace = trace
        @details = details
      end

      # Build a piece of evidence that argues *against* the conclusion.
      #
      # @param label [String] what was measured.
      # @param value [Object] the measurement.
      # @param options [Hash] any other {#initialize} keyword.
      #
      # @return [Observatory::Analysis::Evidence]
      #
      def self.against(label:, value:, **options)
        new(label:, value:, stance: CONTRADICTING, **options)
      end

      # Build a piece of evidence that supports the conclusion.
      #
      # @param label [String] what was measured.
      # @param value [Object] the measurement.
      # @param options [Hash] any other {#initialize} keyword.
      #
      # @return [Observatory::Analysis::Evidence]
      #
      def self.for(label:, value:, **options)
        new(label:, value:, stance: SUPPORTING, **options)
      end

      # @return [Boolean] whether this argues against the conclusion.
      #
      def contradicting?
        @stance == CONTRADICTING
      end

      # The evidence as one readable line.
      #
      # @return [String] e.g. "Busy request threads: 15 of 15 (baseline 4)".
      #
      def to_line
        line = "#{@label}: #{@value}"
        line += " (baseline #{@baseline})" if @baseline

        line
      end

      # The evidence as a row ready for `insert_all`.
      #
      # @param incident_id [Integer] the incident it belongs to.
      # @param position [Integer] its order within its stance.
      #
      # @return [Hash{Symbol => Object}]
      #
      def to_row(incident_id:, position:)
        {
          incident_id:,
          position:,
          stance:      @stance.to_s,
          label:       @label.to_s[0, 255],
          value:       @value.to_s[0, 255],
          baseline:    @baseline&.to_s&.slice(0, 255),
          source:      @source&.to_s&.slice(0, 64),
          observed_at: @observed_at,
          trace_kind:  trace_kind,
          trace_row_id: @trace&.id,
          details:     @details.presence,
        }
      end

    private

      # @return [String, nil] "request" or "job", when this points at a trace.
      #
      def trace_kind
        case @trace
        when RequestTrace then QueryGroup::REQUEST
        when JobTrace     then QueryGroup::JOB
        end
      end
    end
  end
end
