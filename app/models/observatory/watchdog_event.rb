# frozen_string_literal: true

module Observatory

  # One supervisor or watchdog action, recorded with the application state that
  # surrounded the decision.
  #
  # ## Why this table exists
  #
  # `bin/dev`'s watchdog recycles Puma after three consecutive failed `/up`
  # probes. It has no way to tell a dead master from one whose fifteen request
  # threads are all occupied by fourteen-second requests — from the outside both
  # are "curl timed out". So it restarts a living, saturated process, drops every
  # in-flight request, and the incident recurs in ninety seconds because nothing
  # about the workload changed.
  #
  # Recording the busy-thread count, the backlog and the long-running requests
  # *at the moment of the decision* is what turns that from a recurring mystery
  # into a provable misclassification.
  #
  # ## Advisory first
  #
  # Rows carry both `action_taken` (what the supervisor did) and
  # `recommended_action` (what Observatory would have done). While
  # `advisory_only` is true they will differ and nothing changes in production —
  # which is the point. Changing restart behaviour before the classification has
  # been observed to be right would be trading a known failure for an unknown one.
  #
  class WatchdogEvent < Record
    self.table_name = "observatory_watchdog_events"

    # How the event was classified. The first two are the distinction the whole
    # table exists to make.
    #
    PROCESS_DEATH     = "process_death"
    THREAD_SATURATION = "thread_saturation"
    MEMORY_PRESSURE   = "memory_pressure"
    DEPENDENCY_FAILURE = "dependency_failure"
    SLOW_HEALTH_CHECK = "slow_health_check"
    UNKNOWN           = "unknown"

    belongs_to :incident, class_name: "Observatory::Incident", optional: true

    scope :since, ->(time) { where(occurred_at: time..) }
    scope :between, ->(from, to) { where(occurred_at: from..to) }
    scope :recent_first, -> { order(occurred_at: :desc) }
    scope :for_service, ->(service) { where(service:) }
    scope :restarts, -> { where.not(action_taken: nil) }

    # Events where the supervisor acted on a process that was alive and merely
    # full. These are the misclassifications.
    #
    scope :misclassified, -> { where(classification: THREAD_SATURATION, process_alive: true).restarts }

    # Whether Observatory disagreed with what the supervisor did.
    #
    # @return [Boolean]
    #
    def disagreed?
      recommended_action.present? && action_taken.present? && recommended_action != action_taken
    end

    # Whether the process was alive and saturated rather than dead.
    #
    # @return [Boolean]
    #
    def saturated_not_dead?
      process_alive? && classification == THREAD_SATURATION
    end

    # Share of request threads busy when the decision was taken.
    #
    # @return [Float, nil] 0.0-1.0, or nil when capacity could not be measured.
    #
    def thread_utilisation
      return nil if max_threads.to_i.zero?

      busy_threads.to_f / max_threads
    end
  end
end
