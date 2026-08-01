# frozen_string_literal: true

module Observatory

  # Per-minute and per-day aggregates for one job class on one queue.
  #
  # As with {RouteRollup}, these are computed from every job rather than only the
  # sampled ones, so throughput and failure rate are true counts. Throughput is
  # the number that turns a frightening queue depth into an ordinary one — see
  # {Observatory::Probes::Sidekiq} for the drain estimate it feeds.
  #
  class JobRollup < Record
    self.table_name = "observatory_job_rollups"

    MINUTE = "minute"
    DAY    = "day"

    scope :minutes, -> { where(granularity: MINUTE) }
    scope :days, -> { where(granularity: DAY) }
    scope :since, ->(time) { where(bucket_at: time..) }
    scope :between, ->(from, to) { where(bucket_at: from..to) }
    scope :for_job_class, ->(job_class) { where(job_class:) }
    scope :for_queue, ->(queue) { where(queue:) }
    scope :chronological, -> { order(:bucket_at) }

    # Job classes ordered by the worker capacity they consumed.
    #
    scope :by_worker_seconds, -> { order(worker_seconds: :desc) }

    # @return [Float] mean runtime in milliseconds.
    #
    def average_duration_ms
      return 0.0 if count.to_i.zero?

      duration_sum_ms.to_f / count
    end

    # @param percentile [Float] 0.0-1.0.
    #
    # @return [Float, nil] milliseconds.
    #
    def duration_percentile(percentile)
      Histogram.percentile(duration_histogram, percentile, count.to_i)
    end

    # @return [Float] 0.0-1.0 share of jobs that failed.
    #
    def failure_rate
      return 0.0 if count.to_i.zero?

      failure_count.to_f / count
    end

    # @return [Float] mean queue latency in milliseconds.
    #
    def average_queue_latency_ms
      return 0.0 if count.to_i.zero?

      queue_latency_sum_ms.to_f / count
    end

    # Jobs completed per second during this bucket.
    #
    # @param seconds [Integer] the bucket's width in seconds.
    #
    # @return [Float]
    #
    def throughput(seconds = 60)
      return 0.0 if seconds <= 0

      count.to_f / seconds
    end
  end
end
