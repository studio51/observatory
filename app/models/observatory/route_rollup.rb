# frozen_string_literal: true

module Observatory

  # Per-minute and per-day aggregates for one route.
  #
  # ## Why rollups exist even though traces do
  #
  # Traces are sampled; rollups are not. Every request updates a rollup whether
  # or not its trace is kept, so "this route served 41,000 requests in that
  # minute" is a true count rather than a hundred-fold extrapolation from four
  # hundred samples. Any question about *rates* — traffic, error rate, capacity
  # consumed — has to be answered from here; any question about *one request*
  # has to be answered from a trace.
  #
  # Latency percentiles come from {Observatory::Histogram}, a fixed set of
  # log-spaced buckets stored as JSON on the row. That makes p50/p95/p99
  # derivable from every request at the cost of one column, rather than from the
  # 1% of requests that happened to be sampled.
  #
  class RouteRollup < Record
    self.table_name = "observatory_route_rollups"

    MINUTE = "minute"
    DAY    = "day"

    scope :minutes, -> { where(granularity: MINUTE) }
    scope :days, -> { where(granularity: DAY) }
    scope :since, ->(time) { where(bucket_at: time..) }
    scope :between, ->(from, to) { where(bucket_at: from..to) }
    scope :for_endpoint, ->(endpoint) { where(endpoint:) }
    scope :for_release, ->(release) { where(release:) }
    scope :chronological, -> { order(:bucket_at) }

    # Routes ordered by the request capacity they consumed, not by how often they
    # were called.
    #
    # The ordering that changes an operator's mind. A route called ten times for
    # twenty seconds each costs 200 thread-seconds; one called a thousand times
    # for twenty milliseconds costs 20. Sorted by request count the second looks
    # like the problem, and it is not.
    #
    scope :by_thread_seconds, -> { order(thread_seconds: :desc) }

    # @return [Float] mean duration in milliseconds.
    #
    def average_duration_ms
      return 0.0 if count.to_i.zero?

      duration_sum_ms.to_f / count
    end

    # A latency percentile, derived from the stored histogram.
    #
    # @param percentile [Float] 0.0-1.0, e.g. 0.95.
    #
    # @return [Float, nil] milliseconds, or nil when the bucket is empty.
    #
    def duration_percentile(percentile)
      Histogram.percentile(duration_histogram, percentile, count.to_i)
    end

    # @return [Float, nil] median duration in milliseconds.
    #
    def p50 = duration_percentile(0.50)

    # @return [Float, nil] 95th-percentile duration in milliseconds.
    #
    def p95 = duration_percentile(0.95)

    # @return [Float, nil] 99th-percentile duration in milliseconds.
    #
    def p99 = duration_percentile(0.99)

    # @return [Float] 0.0-1.0 share of requests that returned a server error.
    #
    def error_rate
      return 0.0 if count.to_i.zero?

      error_count.to_f / count
    end

    # @return [Float] mean ActiveRecord lookups per request.
    #
    def average_query_count
      return 0.0 if count.to_i.zero?

      query_count_sum.to_f / count
    end

    # Share of this route's lookups that the ActiveRecord query cache served.
    #
    # High here, alongside high latency and low database time, is the fingerprint
    # of application-side repeated lookups — work that is completely invisible to
    # database monitoring because the database never sees it.
    #
    # @return [Float] 0.0-1.0.
    #
    def cached_query_ratio
      return 0.0 if query_count_sum.to_i.zero?

      cached_query_count_sum.to_f / query_count_sum
    end

    # @return [Float] 0.0-1.0 share of requests from automated clients.
    #
    def crawler_ratio
      return 0.0 if count.to_i.zero?

      crawler_count.to_f / count
    end

    # Mean estimated allocations per request.
    #
    # An estimate — CRuby's allocation counter is process-wide, so concurrent
    # requests contaminate it. Useful for spotting an order-of-magnitude change,
    # not for attributing a precise figure.
    #
    # @return [Float]
    #
    def average_allocations
      return 0.0 if count.to_i.zero?

      allocation_sum.to_f / count
    end
  end
end
