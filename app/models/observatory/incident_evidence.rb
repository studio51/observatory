# frozen_string_literal: true

module Observatory

  # One measurement attached to an incident, on one side of the argument.
  #
  # Every line the dashboard shows under "Evidence" is one of these, and each
  # carries the measurement that produced it — so a conclusion can always be
  # traced back to a number somebody can go and check, rather than to prose.
  #
  class IncidentEvidence < Record
    self.table_name = "observatory_incident_evidence"

    SUPPORTING     = "supporting"
    CONTRADICTING  = "contradicting"

    belongs_to :incident, class_name: "Observatory::Incident", inverse_of: :evidence

    scope :supporting, -> { where(stance: SUPPORTING) }
    scope :contradicting, -> { where(stance: CONTRADICTING) }
    scope :ordered, -> { order(:position) }

    # The evidence rendered as one line.
    #
    # @return [String] e.g. "Busy request threads: 16 of 16 (baseline 4 of 16)".
    #
    def to_line
      parts = [ label ]
      parts << value if value.present?
      parts << "(baseline #{baseline})" if baseline.present?

      parts.join(": ").sub(": (", " (")
    end

    # The trace this evidence points at, when it points at one.
    #
    # @return [Observatory::RequestTrace, Observatory::JobTrace, nil]
    #
    def trace
      return nil if trace_row_id.nil?

      case trace_kind
      when QueryGroup::REQUEST then RequestTrace.find_by(id: trace_row_id)
      when QueryGroup::JOB     then JobTrace.find_by(id: trace_row_id)
      end
    end
  end
end
