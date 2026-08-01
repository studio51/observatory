# frozen_string_literal: true

require "digest"

module Observatory

  # One normalised query shape observed during one retained execution.
  #
  # This is the row that makes an 86,359-query request legible. There is one of
  # these per distinct *shape*, not per query — that request produces three.
  #
  class QueryGroup < Record
    self.table_name = "observatory_query_groups"

    REQUEST = "request"
    JOB     = "job"

    scope :for_request, ->(id) { where(trace_kind: REQUEST, trace_row_id: id) }
    scope :for_job, ->(id) { where(trace_kind: JOB, trace_row_id: id) }
    scope :since, ->(time) { where(traced_at: time..) }
    scope :application_queries, -> { where(kind: "query") }
    scope :most_repeated, -> { order(count: :desc) }
    scope :slowest, -> { order(duration_ms: :desc) }
    scope :with_call_site, -> { where.not(call_site: nil) }

    # A stable identifier for a query shape, used to group the same shape across
    # different traces.
    #
    # The fingerprint itself can be kilobytes long and is a poor index key, so a
    # truncated SHA256 stands in for it. Sixteen bytes is far more than enough to
    # keep query shapes distinct.
    #
    # @param fingerprint [String] the normalised statement.
    #
    # @return [String] 32 hex characters.
    #
    def self.digest(fingerprint)
      Digest::SHA256.hexdigest(fingerprint.to_s)[0, 32]
    end

    # Share of this shape's lookups that the ActiveRecord query cache served.
    #
    # @return [Float] 0.0-1.0.
    #
    def cached_ratio
      return 0.0 if count.to_i.zero?

      cached_count.to_f / count
    end

    # Whether this shape's cost is repetition rather than slowness.
    #
    # The distinction the brief insists on: 41,722 fast lookups and one
    # 28.9-second lookup are both "the database", and they need completely
    # different fixes. This says which one this is.
    #
    # @param config [Observatory::Configuration] thresholds to apply.
    #
    # @return [Boolean]
    #
    def repetition_bound?(config = Observatory.config)
      count.to_i >= config.repeated_fingerprint_count && average_duration_ms.to_f < 5.0
    end

    # Whether this shape's cost is one genuinely slow statement.
    #
    # @return [Boolean]
    #
    def slow_statement?
      max_duration_ms.to_f >= 1_000.0
    end
  end
end
