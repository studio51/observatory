# frozen_string_literal: true

module Observatory

  # One detected incident: what is constrained, what is consuming it, how
  # confident the engine is, and what the evidence was on both sides.
  #
  # ## The shape of a conclusion
  #
  # An incident is not an alert. An alert says a number crossed a line; an
  # incident says *which finite resource ran out*, *what workload consumed it*,
  # and *what proves it* — including the measurements that argue against the
  # conclusion. Contradicting evidence is a first-class column here because a
  # finding supported only by confirming evidence is an assertion, and because
  # the contradictions are usually the most useful part:
  #
  #   Puma request capacity exhausted
  #   supporting:     16/16 threads busy, backlog 23, six requests over 10s,
  #                   59,349-86,359 lookups each, 97% query-cache served
  #   contradicting:  CPU below saturation, Redis at 7.6%, MySQL connections
  #                   far below maximum, no connection checkout wait
  #
  # The contradictions are what stop an operator spending the outage restarting
  # MySQL.
  #
  # ## Deduplication
  #
  # A continuing incident is one row whose `last_seen_at` advances and whose
  # `occurrence_count` climbs, not a row per detection cycle. Otherwise a
  # ten-minute saturation would produce forty identical incidents and the
  # dashboard would be the noise it was built to replace.
  #
  class Incident < Record
    self.table_name = "observatory_incidents"

    OPEN     = "open"
    RESOLVED = "resolved"
    IGNORED  = "ignored"

    CRITICAL = "critical"
    WARNING  = "warning"
    INFO     = "info"

    HIGH   = "high"
    MEDIUM = "medium"
    LOW    = "low"

    SEVERITY_ORDER = { CRITICAL => 0, WARNING => 1, INFO => 2 }.freeze

    has_many :evidence,
             -> { order(:stance, :position) },
             class_name: "Observatory::IncidentEvidence",
             dependent: :delete_all,
             inverse_of: :incident

    has_many :request_traces, class_name: "Observatory::RequestTrace", dependent: :nullify, inverse_of: :incident
    has_many :job_traces, class_name: "Observatory::JobTrace", dependent: :nullify, inverse_of: :incident
    has_many :watchdog_events, class_name: "Observatory::WatchdogEvent", dependent: :nullify, inverse_of: :incident

    belongs_to :deployment, class_name: "Observatory::Deployment", optional: true

    scope :open_incidents, -> { where(status: OPEN) }
    scope :resolved, -> { where(status: RESOLVED) }
    scope :since, ->(time) { where(started_at: time..) }
    scope :recent_first, -> { order(started_at: :desc) }
    scope :critical, -> { where(severity: CRITICAL) }
    scope :for_rule, ->(rule) { where(rule:) }

    # Open incidents, worst first — the ordering the dashboard's headline panel uses.
    #
    scope :by_severity, lambda {
      order(Arel.sql("FIELD(severity, '#{CRITICAL}', '#{WARNING}', '#{INFO}')"), started_at: :desc)
    }

    # Evidence supporting the conclusion.
    #
    # @return [ActiveRecord::Relation]
    #
    def supporting_evidence
      evidence.select { |item| item.stance == IncidentEvidence::SUPPORTING }
    end

    # Evidence arguing against it — deliberately as prominent as the support.
    #
    # @return [ActiveRecord::Relation]
    #
    def contradicting_evidence
      evidence.select { |item| item.stance == IncidentEvidence::CONTRADICTING }
    end

    # How long the incident has been running.
    #
    # @return [Float] seconds.
    #
    def duration_seconds
      ((ended_at || last_seen_at) - started_at).to_f
    end

    # Whether this incident is still current.
    #
    # @return [Boolean]
    #
    def open?
      status == OPEN
    end

    # Close the incident.
    #
    # @param at [Time] when it ended.
    # @param notes [String, nil] what resolved it.
    #
    # @return [Boolean]
    #
    def resolve!(at: Clock.wall, notes: nil)
      Instrumentation.suppress do
        update(status: RESOLVED, ended_at: at, resolution_notes: notes)
      end
    end

    # Whether the incident began close enough to a deployment to be worth
    # mentioning it.
    #
    # Deliberately returns a *correlation*, never a cause. The dashboard renders
    # it as "possible deployment correlation" with the window, so a reader can
    # judge it.
    #
    # @param window [ActiveSupport::Duration] how soon after a deploy counts.
    #
    # @return [Observatory::Deployment, nil]
    #
    def correlated_deployment(window: 30.minutes)
      candidate = Deployment.at(started_at)
      return nil if candidate.nil?
      return nil if (started_at - candidate.deployed_at) > window

      candidate
    end
  end
end
