# frozen_string_literal: true

require "test_helper"

module Observatory

  # The histogram is what makes percentiles describe *all* the traffic rather
  # than the 1% that was sampled, so these tests care most about that property.
  #
  class HistogramTest < ActiveSupport::TestCase

    test "an empty histogram has one slot per bucket plus the overflow" do
      assert_equal Histogram::BUCKETS.length + 1, Histogram.empty.length
      assert_equal 0, Histogram.empty.sum
    end

    test "places an observation in the first bucket at or above it" do
      assert_equal 0, Histogram.bucket_for(0.4)
      assert_equal 0, Histogram.bucket_for(1.0)
      assert_equal 1, Histogram.bucket_for(1.5)
      assert_equal Histogram::OVERFLOW, Histogram.bucket_for(120_000)
    end

    test "derives a median that describes every observation" do
      counts = Histogram.empty
      90.times { Histogram.observe(counts, 20.0) }
      10.times { Histogram.observe(counts, 4_000.0) }

      assert_operator Histogram.percentile(counts, 0.5), :<=, 25.0
      assert_operator Histogram.percentile(counts, 0.95), :>=, 2_500.0
      assert_operator Histogram.percentile(counts, 0.99), :>=, 2_500.0
    end

    test "a one-in-a-thousand slow request is still in the distribution" do
      # The property a sampled percentile loses. At a 1% trace sample rate this
      # request would usually not have been recorded at all, and the route would
      # look uniformly fast. The histogram sees every request, so the top of the
      # distribution knows about it.
      counts = Histogram.empty
      999.times { Histogram.observe(counts, 15.0) }
      Histogram.observe(counts, 14_472.0)

      assert_equal 25.0, Histogram.percentile(counts, 0.999), "999 of 1,000 requests really were fast"
      assert_operator Histogram.percentile(counts, 1.0), :>=, 10_000.0, "and the thousandth really was not"
    end

    test "merges histograms from separate processes" do
      worker_one = Histogram.empty
      worker_two = Histogram.empty
      5.times { Histogram.observe(worker_one, 10.0) }
      5.times { Histogram.observe(worker_two, 10.0) }

      merged = Histogram.merge(worker_one, worker_two)

      assert_equal 10, merged.sum
    end

    test "returns nil for an empty or missing histogram" do
      assert_nil Histogram.percentile(nil, 0.95)
      assert_nil Histogram.percentile(Histogram.empty, 0.95)
    end

    test "survives a histogram read back from JSON as strings" do
      counts = Histogram.empty
      10.times { Histogram.observe(counts, 300.0) }
      round_tripped = JSON.parse(counts.to_json)

      assert_equal 500.0, Histogram.percentile(round_tripped, 0.5)
    end

    test "bucket boundaries line up with the thresholds the system reasons about" do
      # A percentile has to be directly comparable against the slow (1s),
      # extreme (10s) and watchdog-timeout (30s) thresholds, or the comparison
      # needs interpolation nobody will do correctly at 3am.
      assert_includes Histogram::BUCKETS, 1_000
      assert_includes Histogram::BUCKETS, 10_000
      assert_includes Histogram::BUCKETS, 30_000
    end
  end
end
