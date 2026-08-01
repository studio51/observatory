# frozen_string_literal: true

module Observatory

  # Fixed log-spaced latency buckets, and percentiles derived from them.
  #
  # ## The problem this solves
  #
  # Percentiles need the distribution, and the distribution normally means
  # keeping every value. At sixty requests a second that is five million values a
  # day per route — which is why most systems compute percentiles from *sampled*
  # traces instead, and then quietly report a p95 drawn from 1% of the traffic.
  #
  # A histogram keeps the distribution at fixed cost. Every request increments
  # one counter, the whole distribution is one small JSON column, and the
  # resulting percentiles describe **all** the traffic rather than the sample.
  #
  # ## What it costs in accuracy
  #
  # A percentile is resolved to a bucket, so it is reported as a bucket
  # boundary rather than an exact value. The buckets are log-spaced, so the
  # relative error is roughly constant — around a factor of 2.5 in the worst
  # case, tighter in the ranges that matter. For "did p95 on this route go from
  # 180 ms to 2.4 seconds?" that is far more precision than the question needs,
  # and unlike a sampled percentile it cannot be wrong by an order of magnitude
  # because the interesting requests happened not to be sampled.
  #
  module Histogram

    # Upper bounds in milliseconds. The last bucket is unbounded.
    #
    # Chosen around the thresholds this system reasons about: sub-100 ms is
    # resolved finely because that is where a healthy route lives, and the
    # 1s/10s/30s boundaries line up with the slow, extreme and watchdog-timeout
    # thresholds so a percentile can be compared against them directly.
    #
    BUCKETS = [ 1, 2, 5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000, 30_000, 60_000 ].freeze

    # The index of the overflow bucket, holding everything above the last bound.
    #
    OVERFLOW = BUCKETS.length

    module_function

    # An empty bucket array.
    #
    # @return [Array<Integer>]
    #
    def empty
      Array.new(BUCKETS.length + 1, 0)
    end

    # Add one observation.
    #
    # @param counts [Array<Integer>] the bucket array to increment, mutated in place.
    # @param milliseconds [Float] the observed duration.
    #
    # @return [Array<Integer>] the same array.
    #
    def observe(counts, milliseconds)
      counts[bucket_for(milliseconds)] += 1

      counts
    end

    # The bucket an observation falls into.
    #
    # A linear scan over fifteen entries, which beats a binary search at this
    # size and is called once per request.
    #
    # @param milliseconds [Float] the observed duration.
    #
    # @return [Integer] the bucket index.
    #
    def bucket_for(milliseconds)
      BUCKETS.each_with_index { |bound, index| return index if milliseconds <= bound }

      OVERFLOW
    end

    # Merge one bucket array into another.
    #
    # @param into [Array<Integer>] the destination, mutated in place.
    # @param from [Array<Integer>, nil] the source.
    #
    # @return [Array<Integer>] the destination.
    #
    def merge(into, from)
      return into if from.nil?

      from.each_with_index { |value, index| into[index] = into[index].to_i + value.to_i }

      into
    end

    # A percentile, resolved to the bucket that contains it.
    #
    # @param counts [Array<Integer>, nil] the bucket array.
    # @param percentile [Float] 0.0-1.0, e.g. 0.95.
    # @param total [Integer, nil] the observation count, recomputed when omitted.
    #
    # @return [Float, nil] the bucket's upper bound in milliseconds, or nil when empty.
    #
    def percentile(counts, percentile, total = nil)
      return nil if counts.nil?

      buckets = Array(counts).map(&:to_i)
      observations = total.to_i.positive? ? total.to_i : buckets.sum
      return nil if observations.zero?

      target = percentile * observations
      running = 0

      buckets.each_with_index do |value, index|
        running += value

        return bound_for(index) if running >= target
      end

      bound_for(OVERFLOW)
    end

    # The upper bound of a bucket.
    #
    # The overflow bucket has no upper bound; it reports the last real boundary,
    # which is a floor rather than a ceiling. Callers that care render it as
    # "60,000 ms or more".
    #
    # @param index [Integer] the bucket index.
    #
    # @return [Float] milliseconds.
    #
    def bound_for(index)
      return BUCKETS.last.to_f if index >= OVERFLOW

      BUCKETS[index].to_f
    end
  end
end
