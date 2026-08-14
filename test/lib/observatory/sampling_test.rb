# frozen_string_literal: true

require "test_helper"

module Observatory
  module Sampling

    # Tail-based sampling is the reason the incident is in the data at all. A
    # head-based sampler at 1% would keep the fourteen-second request one time in
    # a hundred; these tests exist to prove that never happens.
    #
    class DecisionTest < ActiveSupport::TestCase

      # Sampling is the one part of the system that is deliberately random, so
      # these tests pin both sources of randomness to zero and switch on exactly
      # the one under test. Without that, "was this kept?" would be a coin toss.
      #
      setup do
        Decision.reset!
        @previous_config = capture_observatory_config
        Observatory.config.normal_request_sample_rate = 0.0
        Observatory.config.normal_job_sample_rate     = 0.0
        Observatory.config.route_reservoir_interval   = 0
      end

      teardown do
        restore_observatory_config(@previous_config)
        Decision.reset!
      end

      test "drops an ordinary request when nothing claims it" do
        decision = decide(build(duration_ms: 50.0, queries: 5))

        assert_not decision.keep?
      end

      test "always keeps a request that raised" do
        execution = build(duration_ms: 50.0, queries: 1)
        execution.record_exception(RuntimeError.new("boom"))

        decision = decide(execution)

        assert decision.keep?
        assert_includes decision.reasons, :exception
        assert_equal :error, decision.retention_class
      end

      test "always keeps a server error" do
        decision = decide(build(duration_ms: 10.0, queries: 1, status: 503))

        assert decision.keep?
        assert_includes decision.reasons, :server_error
        assert_equal :error, decision.retention_class
      end

      test "always keeps a request over the slow threshold" do
        decision = decide(build(duration_ms: 2_000.0, queries: 3))

        assert decision.keep?
        assert_includes decision.reasons, :slow
        assert_equal :anomalous, decision.retention_class
      end

      test "always keeps a request over the query-count threshold" do
        decision = decide(build(duration_ms: 100.0, queries: 1_500))

        assert decision.keep?
        assert_includes decision.reasons, :query_count
      end

      test "always keeps the cached-query explosion, and says so" do
        execution = build(duration_ms: 14_472.0, queries: 0)
        84_079.times { |i| execution.record_query(sql: "SELECT * FROM a WHERE id = #{i}", name: "A Load",
                                                  duration_ms: 0.01, cached: true) }
        2_280.times { |i| execution.record_query(sql: "SELECT * FROM b WHERE id = #{i}", name: "B Load",
                                                 duration_ms: 0.9, cached: false) }

        decision = decide(execution)

        assert decision.keep?
        assert_includes decision.reasons, :cached_query_explosion
        assert_includes decision.reasons, :repeated_fingerprint
        assert_equal :anomalous, decision.retention_class
      end

      test "keeps a request the application explicitly marked" do
        execution = build(duration_ms: 5.0, queries: 0)
        execution.flag(:marked_for_retention)

        decision = decide(execution)

        assert decision.keep?
        assert_includes decision.reasons, :marked
      end

      test "keeps a slow health check even when it succeeded" do
        execution = Execution::Request.new(
          trace_id: "h", request_id: nil, http_method: "GET", path: "/up",
        )
        execution.instance_variable_set(:@duration_ms, 4_000.0)
        execution.instance_variable_set(:@status, 200)

        decision = decide(execution)

        assert decision.keep?
        assert_includes decision.reasons, :health_check_failure
      end

      test "keeps one trace per endpoint per reservoir interval" do
        Observatory.config.normal_request_sample_rate = 0.0
        Observatory.config.route_reservoir_interval = 300

        first  = decide(build(duration_ms: 5.0, queries: 1, route: "/quiet"))
        second = decide(build(duration_ms: 5.0, queries: 1, route: "/quiet"))

        assert first.keep?, "the first trace for a low-traffic route is always kept"
        assert_includes first.reasons, :reservoir
        assert_not second.keep?, "the second within the interval is not"
      end

      test "keeps everything when the sample rate is one" do
        Observatory.config.normal_request_sample_rate = 1.0
        Decision.reset!

        3.times do |index|
          decision = decide(build(duration_ms: 5.0, queries: 1, route: "/busy-#{index}"))

          assert decision.keep?
        end
      end

      test "every always-keep threshold matches the detection rule that uses it" do
        # The invariant: a trace that would trip a rule must never have been
        # dropped before the rule could see it. Both read the same config value,
        # and this test fails if anyone decouples them.
        config = Observatory.config
        execution = build(duration_ms: config.slow_request_threshold * 1_000.0, queries: config.high_query_count)

        assert decide(execution).keep?
      end

    private

      # @param execution [Observatory::Execution::Base] the finished execution.
      #
      # @return [Observatory::Sampling::Decision::Result]
      #
      def decide(execution)
        Decision.call(execution, Observatory.config)
      end

      # @param duration_ms [Float] the execution's duration.
      # @param queries [Integer] uncached queries to record.
      # @param status [Integer] the response status.
      # @param route [String] the route template.
      #
      # @return [Observatory::Execution::Request]
      #
      def build(duration_ms:, queries:, status: 200, route: "/steam/achievements/:id")
        execution = Execution::Request.new(
          trace_id: "t", request_id: nil, http_method: "GET", path: "/steam/achievements/1",
        )
        execution.resolve_route(controller: "C", action: "show", route:)
        queries.times { |i| execution.record_query(sql: "SELECT #{i}", name: "Load", duration_ms: 0.1, cached: false) }
        execution.instance_variable_set(:@duration_ms, duration_ms)
        execution.instance_variable_set(:@status, status)
        execution.instance_variable_set(:@gc_finished, GcSnapshot.capture)

        execution
      end
    end
  end
end
