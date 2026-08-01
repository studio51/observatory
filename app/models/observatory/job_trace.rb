# frozen_string_literal: true

module Observatory

  # One retained Sidekiq job.
  #
  # Carries everything a request trace carries, plus the measurements that only
  # queued work has: how long it waited in the queue before starting, and how
  # long a throttle or uniqueness lock held it back once it had.
  #
  # Queue latency is the measurement that distinguishes "the queue is deep" from
  # "the queue is not draining" — a 536,000-job queue with two-second latency is
  # healthy; a 500-job queue with nine-minute latency is not.
  #
  class JobTrace < Record
    self.table_name = "observatory_job_traces"

    has_many :query_groups,
             -> { order(count: :desc) },
             class_name: "Observatory::QueryGroup",
             foreign_key: :trace_row_id,
             primary_key: :id,
             inverse_of: false,
             dependent: nil

    belongs_to :incident, class_name: "Observatory::Incident", optional: true

    scope :since, ->(time) { where(started_at: time..) }
    scope :between, ->(from, to) { where(started_at: from..to) }
    scope :recent_first, -> { order(started_at: :desc) }

    scope :slow, ->(seconds = Observatory.config.slow_job_threshold) { where(duration_ms: (seconds * 1_000)..) }
    scope :failed, -> { where(result: "failure") }
    scope :succeeded, -> { where(result: "success") }
    scope :retried, -> { where(retry_count: 1..) }
    scope :for_job_class, ->(job_class) { where(job_class:) }
    scope :for_queue, ->(queue) { where(queue:) }
    scope :for_release, ->(release) { where(release:) }

    scope :query_heavy, ->(threshold = Observatory.config.high_query_count) { where(query_count: threshold..) }

    # Jobs that waited materially longer in the queue than they took to run — the
    # shape of a starved queue rather than a slow job.
    #
    scope :queue_starved, -> { where("queue_latency_ms > duration_ms * 2") }

    # Jobs held back by a throttle or a uniqueness lock, which look identical to
    # "slow" from the outside and are not.
    #
    scope :throttled, -> { where(throttle_wait_ms: 1..) }
    scope :lock_delayed, -> { where(lock_wait_ms: 1..) }

    # Whether this job spent most of its life waiting on an upstream service
    # rather than doing its own work.
    #
    # @return [Boolean]
    #
    def upstream_bound?
      duration_ms.to_f.positive? && (external_duration_ms.to_f / duration_ms) > 0.6
    end

    # Estimated GC time as a share of the job's runtime. An estimate — CRuby's GC
    # counters are process-wide and Sidekiq runs 15 threads per process.
    #
    # @return [Float] 0.0-1.0.
    #
    def estimated_gc_ratio
      return 0.0 if duration_ms.to_f <= 0

      estimated_gc_time_ms.to_f / duration_ms
    end

    # The query shape that repeated most often in this job.
    #
    # @return [Observatory::QueryGroup, nil]
    #
    def dominant_query_group
      query_groups.first
    end
  end
end
