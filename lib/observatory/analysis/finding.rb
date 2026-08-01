# frozen_string_literal: true

module Observatory
  module Analysis

    # What a detection rule returns: a conclusion, with the evidence on both
    # sides of it.
    #
    # ## Why contradicting evidence is a required field, not a nicety
    #
    # The incident this system exists to explain is one where almost every
    # measurement looks fine. CPU is at 40%, MySQL is idle, Redis is at 7.6%, and
    # a monitor that reports only confirming evidence produces a finding that
    # reads as if those things were bad. They are not — they are the *proof* that
    # the problem is somewhere else, and they are what stops an operator spending
    # the outage restarting the database.
    #
    # So a rule that cannot say what argues against its own conclusion has not
    # finished thinking, and `contradicting` is part of the constructor rather
    # than something to bolt on later.
    #
    # ## Confidence
    #
    # Reported, not implied. Three levels, and the rule says which and why.
    # "Medium confidence, because the correlation with the deploy is timing only"
    # is a useful thing to tell someone at 3am; a bare assertion is not.
    #
    class Finding
      attr_reader :rule            # the rule that produced it
      attr_reader :title           # a one-line statement of the conclusion
      attr_reader :severity        # :critical, :warning or :info
      attr_reader :component       # what is unhealthy: "puma", "mysql", "sidekiq", …
      attr_reader :constrained_resource # the finite thing that ran out
      attr_reader :primary_contributor  # the route or job consuming it
      attr_reader :failure_mode    # what is actually going wrong
      attr_reader :confidence      # :high, :medium or :low
      attr_reader :impact          # what this cost, in user-visible terms
      attr_reader :recommended_action # what to do next
      attr_reader :supporting      # Array<Evidence> for the conclusion
      attr_reader :contradicting   # Array<Evidence> against it
      attr_reader :started_at      # when the evidence begins
      attr_reader :ended_at        # when it ends, if it has
      attr_reader :subjects        # traces, rollups and events the finding rests on
      attr_reader :fingerprint     # dedupes a continuing incident across detection cycles

      # @param rule [Symbol] the rule that produced this finding.
      # @param title [String] a one-line statement of the conclusion.
      # @param severity [Symbol] :critical, :warning or :info.
      # @param confidence [Symbol] :high, :medium or :low.
      # @param constrained_resource [String] the finite thing that ran out.
      # @param component [String, nil] what is unhealthy.
      # @param primary_contributor [String, nil] the route or job consuming the resource.
      # @param failure_mode [String, nil] what is actually going wrong.
      # @param impact [String, nil] what this cost.
      # @param recommended_action [String, nil] what to do next.
      # @param supporting [Array<Observatory::Analysis::Evidence>] evidence for.
      # @param contradicting [Array<Observatory::Analysis::Evidence>] evidence against.
      # @param started_at [Time] when the evidence begins.
      # @param ended_at [Time, nil] when it ends.
      # @param subjects [Hash] traces, rollups and events the finding rests on.
      # @param fingerprint [String, nil] dedupe key; derived from rule and contributor when omitted.
      #
      # @return [Observatory::Analysis::Finding]
      #
      def initialize(rule:, title:, severity:, confidence:, constrained_resource:,
                     component: nil, primary_contributor: nil, failure_mode: nil,
                     impact: nil, recommended_action: nil,
                     supporting: [], contradicting: [],
                     started_at: Clock.wall, ended_at: nil, subjects: {}, fingerprint: nil)
        @rule = rule
        @title = title
        @severity = severity
        @confidence = confidence
        @constrained_resource = constrained_resource
        @component = component
        @primary_contributor = primary_contributor
        @failure_mode = failure_mode
        @impact = impact
        @recommended_action = recommended_action
        @supporting = supporting
        @contradicting = contradicting
        @started_at = started_at
        @ended_at = ended_at
        @subjects = subjects
        @fingerprint = fingerprint || derive_fingerprint
      end

      # Every piece of evidence, supporting first.
      #
      # @return [Array<Observatory::Analysis::Evidence>]
      #
      def evidence
        @supporting + @contradicting
      end

      # A plain-text rendering of the whole finding.
      #
      # Used by the rake task, the watchdog's advisory output and the test suite —
      # anywhere the conclusion has to be readable without a browser, which
      # includes the terminal an operator is already in when this matters.
      #
      # @return [String]
      #
      def to_text
        lines = [ "Incident: #{@title}", "Severity: #{@severity}",
                  "Constrained resource: #{@constrained_resource}", ]
        lines << "Primary contributor: #{@primary_contributor}" if @primary_contributor
        lines << ""
        lines << "Evidence:"
        lines.concat(@supporting.map { |item| "  - #{item.to_line}" })

        if @contradicting.any?
          lines << ""
          lines << "Contradicting evidence:"
          lines.concat(@contradicting.map { |item| "  - #{item.to_line}" })
        end

        lines << ""
        lines << "Likely failure mode: #{@failure_mode}" if @failure_mode
        lines << "Confidence: #{@confidence}"
        lines << "Impact: #{@impact}" if @impact
        lines << "Recommended: #{@recommended_action}" if @recommended_action

        lines.join("\n")
      end

    private

      # A stable key for the same ongoing problem.
      #
      # Rule plus contributor, so a saturation caused by one route is one
      # incident however many detection cycles observe it, but the same
      # saturation caused by a different route tomorrow is a new one.
      #
      # @return [String]
      #
      def derive_fingerprint
        "#{@rule}:#{@primary_contributor || @component || "global"}"
      end
    end
  end
end
