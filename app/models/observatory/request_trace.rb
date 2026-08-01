# frozen_string_literal: true

module Observatory

  # One retained HTTP request.
  #
  # The scopes here are the query vocabulary of the whole product — each one
  # answers a question an operator actually asks during an incident, and the
  # request explorer is little more than a chain of them.
  #
  class RequestTrace < Record
    self.table_name = "observatory_request_traces"

    has_many :query_groups,
             -> { order(count: :desc) },
             class_name: "Observatory::QueryGroup",
             foreign_key: :trace_row_id,
             primary_key: :id,
             inverse_of: false,
             dependent: nil

    belongs_to :incident, class_name: "Observatory::Incident", optional: true

    # --- Time ---

    scope :since, ->(time) { where(started_at: time..) }
    scope :between, ->(from, to) { where(started_at: from..to) }
    scope :recent_first, -> { order(started_at: :desc) }

    # --- Shape of the problem ---

    scope :slow, ->(seconds = Observatory.config.slow_request_threshold) { where(duration_ms: (seconds * 1_000)..) }
    scope :errored, -> { where(status: 500..) }
    scope :failed, -> { where.not(exception_class: nil).or(errored) }
    scope :for_endpoint, ->(endpoint) { where(endpoint:) }
    scope :for_release, ->(release) { where(release:) }
    scope :health_checks, -> { where(health_check: true) }
    scope :application_traffic, -> { where(health_check: false) }

    # Requests that issued an abnormal number of ActiveRecord lookups.
    #
    scope :query_heavy, ->(threshold = Observatory.config.high_query_count) { where(query_count: threshold..) }

    # The signature this system exists to detect: a slow request that made a very
    # large number of lookups, most of them served by the ActiveRecord query
    # cache, while the database itself did comparatively little.
    #
    # Expressed as a scope because it is the single most useful filter in the
    # explorer — "show me the requests that look busy to Ruby and idle to MySQL".
    #
    scope :cached_query_explosions, lambda { |config = Observatory.config|
      query_heavy(config.high_query_count)
        .where(cached_query_ratio: config.high_cached_query_ratio..)
        .where(duration_ms: (config.slow_request_threshold * 1_000)..)
    }

    # Requests running while their process had every request thread occupied.
    #
    scope :during_saturation, -> { where("peak_concurrency >= ?", Capacity.max_threads) }

    scope :by_traffic_class, ->(traffic_class) { where(traffic_class:) }
    scope :crawlers, -> { where(traffic_class: %w[search_crawler ai_crawler seo_crawler unknown_automation]) }
    scope :for_client, ->(client_id) { where(client_id:) }

    # --- Presentation ---

    # Share of this request's duration that no measured subsystem accounts for.
    #
    # A high value is the signature of Ruby-side work — building queries,
    # allocating objects, collecting garbage — as opposed to waiting on anything.
    #
    # @return [Float] 0.0-1.0.
    #
    def unaccounted_ratio
      return 0.0 if duration_ms.to_f <= 0

      unaccounted_ms.to_f / duration_ms
    end

    # Estimated GC time as a share of the request's duration.
    #
    # An estimate, and labelled as one wherever it is shown: CRuby's GC counters
    # are process-wide, so a concurrent thread's collection is counted here too.
    #
    # @return [Float] 0.0-1.0.
    #
    def estimated_gc_ratio
      return 0.0 if duration_ms.to_f <= 0

      estimated_gc_time_ms.to_f / duration_ms
    end

    # The query shape that repeated most often in this request.
    #
    # @return [Observatory::QueryGroup, nil]
    #
    def dominant_query_group
      query_groups.first
    end

    # Other requests that were in flight in the same process at the same time.
    #
    # The question a saturation incident turns on — "what else was holding a
    # thread?" — and also the honest caveat on this request's allocation and GC
    # figures, which those requests contaminated.
    #
    # @param limit [Integer] maximum requests to return.
    #
    # @return [ActiveRecord::Relation]
    #
    def concurrent_requests_in_process(limit: 20)
      finished_at = started_at + (duration_ms / 1_000.0)

      self.class
          .where(process_id:, hostname:)
          .where.not(id:)
          .where(started_at: ..finished_at)
          .where("DATE_ADD(started_at, INTERVAL duration_ms * 1000 MICROSECOND) >= ?", started_at)
          .recent_first
          .limit(limit)
    end

    # Whether this request's measurements are contaminated by concurrent work.
    #
    # @return [Boolean]
    #
    def concurrent?
      peak_concurrency.to_i > 1
    end
  end
end
